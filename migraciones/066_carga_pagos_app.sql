-- =====================================================================
-- 066_carga_pagos_app.sql
-- FINANZAS, fase 6: cargar, anular y devolver pagos desde la app.
-- Ver ESQUEMA-FINANZAS.md, seccion 2.
--
-- Decisiones (02/10):
--   - Cargan: fundadores, el cliente (sus pagos) y closers/setters (los
--     clientes donde trabajan). Todo entra directo, sin aprobacion.
--   - Anular y devolver: solo fundadores y el cliente.
--   - Comprobante: link (Drive), como hoy.
--   - La carga se habilita POR CLIENTE recien cuando su planilla de
--     pagos esta cortada (fin_fuentes.cortada_en). Asi nunca se carga el
--     mismo pago en la app y en el Sheet. El corte es un paso aparte.
--
-- 1. fin_pagos: creado_por/en, pago_original_clave, nota.
-- 2. Concepto REFUND (catalogo de los 4 clientes + categoria 'devolucion').
-- 3. fin_pagos_anulados: copia completa de cada pago anulado (nunca se
--    pierde nada). En fin_pagos solo queda lo vigente, asi las vistas que
--    ya existen (P&L, comisiones, conciliacion) no cambian.
-- 4. Funciones de permiso: fin_puede_cargar, fin_puede_anular,
--    fin_carga_habilitada, fin_clientes_carga.
-- 5. RPC (security definer, validan todo): fin_pago_cargar,
--    fin_pago_anular, fin_pago_devolver y fin_carga_opciones (lo que
--    necesita el formulario: catalogos y vendedores del cliente).
-- 6. fin_v_pagos_app: lo cargado en la app con quien lo cargo.
--
-- Nadie recibe permiso de INSERT/UPDATE/DELETE directo sobre fin_pagos:
-- solo se escribe por estas funciones.
-- Idempotente. Probada dos veces contra Postgres local con el esquema
-- real, los pagos del 2026-10-02 y usuarios de prueba de cada rol.
-- =====================================================================

-- Todo en una transaccion. Las tablas que se modifican se toman juntas y
-- en orden fijo al principio: evita el deadlock con la sync o con alguien
-- leyendo la app (40P01). Si en 10 s no las consigue, falla limpio y no
-- aplica nada: se vuelve a correr.
begin;
set local lock_timeout = '10s';
lock table public.fin_conceptos, public.fin_catalogos, public.fin_pagos in access exclusive mode;

-- ---------------------------------------------------------------------
-- 1. Columnas nuevas
-- ---------------------------------------------------------------------
alter table public.fin_pagos
  add column if not exists creado_por          uuid,
  add column if not exists creado_en           timestamptz,
  add column if not exists pago_original_clave text,
  add column if not exists nota                text;

comment on column public.fin_pagos.creado_por is
  '066: usuario que cargo el pago en la app. Null en filas de la planilla.';
comment on column public.fin_pagos.pago_original_clave is
  '066: solo en devoluciones (monto negativo): clave del pago que se devuelve.';

alter table public.fin_pagos drop constraint if exists fin_pagos_app_ck;
alter table public.fin_pagos add constraint fin_pagos_app_ck
  check (origen = 'sheet' or (creado_por is not null and creado_en is not null));

alter table public.fin_pagos drop constraint if exists fin_pagos_devolucion_ck;
alter table public.fin_pagos add constraint fin_pagos_devolucion_ck
  check (pago_original_clave is null or monto_usd < 0);

-- ---------------------------------------------------------------------
-- 2. Concepto REFUND
-- ---------------------------------------------------------------------
alter table public.fin_conceptos drop constraint if exists fin_conceptos_categoria_check;
alter table public.fin_conceptos add constraint fin_conceptos_categoria_check
  check (categoria in ('venta_nueva', 'cuota', 'producto', 'sin_clasificar', 'devolucion'));

insert into public.fin_conceptos (concepto_norm, cliente_id, categoria, nota)
select 'REFUND', null, 'devolucion', '066: devoluciones cargadas desde la app (monto negativo)'
where not exists (select 1 from public.fin_conceptos where concepto_norm = 'REFUND' and cliente_id is null);

insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
select c, 'concepto', 'REFUND', 99
from unnest(array['liam', 'agus', 'teo', 'lucas']) c
on conflict (cliente_id, dimension, valor) do nothing;

-- ---------------------------------------------------------------------
-- 3. Pagos anulados
-- ---------------------------------------------------------------------
create table if not exists public.fin_pagos_anulados (
  id           bigint generated always as identity primary key,
  cliente_id   text        not null references public.crm_clients(id),
  clave        text        not null,
  pago         jsonb       not null,
  motivo       text        not null,
  anulado_por  uuid        not null,
  anulado_en   timestamptz not null default now(),
  constraint fin_pagos_anulados_motivo_ck check (btrim(motivo) <> '')
);

comment on table public.fin_pagos_anulados is
  '066: copia completa de cada pago anulado desde la app. El pago sale de fin_pagos, la copia queda aca para siempre.';

alter table public.fin_pagos_anulados enable row level security;
drop policy if exists fin_pagos_anulados_lectura on public.fin_pagos_anulados;
create policy fin_pagos_anulados_lectura on public.fin_pagos_anulados for select
  using (public.es_fundador() or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id)));
revoke all on public.fin_pagos_anulados from anon;
grant select on public.fin_pagos_anulados to authenticated;
grant all on public.fin_pagos_anulados to service_role;

-- ---------------------------------------------------------------------
-- 4. Permisos
-- ---------------------------------------------------------------------
-- La planilla de pagos del cliente esta cortada: se carga en la app.
create or replace function public.fin_carga_habilitada(p_cliente text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.fin_fuentes f
    where f.cliente_id = p_cliente and f.tipo = 'pagos' and f.cortada_en is not null
  );
$$;

-- Cargar: fundador, el cliente de ese cliente, o un closer/setter vinculado.
create or replace function public.fin_puede_cargar(p_cliente text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(p_cliente))
    or exists (select 1 from public.fin_personas p
               where p.user_id = auth.uid() and p.cliente_id = p_cliente)
  );
$$;

-- Anular y devolver: solo fundador o el cliente.
create or replace function public.fin_puede_anular(p_cliente text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(p_cliente))
  );
$$;

-- Para la pantalla: clientes donde el usuario puede cargar hoy.
create or replace function public.fin_clientes_carga()
returns table (cliente_id text, habilitada boolean, puede_anular boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id, public.fin_carga_habilitada(c.id), public.fin_puede_anular(c.id)
  from public.crm_clients c
  where c.id <> 'mauro' and public.fin_puede_cargar(c.id)
  order by c.orden;
$$;

-- ---------------------------------------------------------------------
-- 5a. Cargar un pago
--     p = { cliente_id, fecha, alumno, telefono?, monto_usd,
--           programa_id, concepto_id, metodo_pago_id, quien_recibe_id?,
--           closer_id?, setter_id? (fin_vendedores.id), comprobante?, nota? }
-- ---------------------------------------------------------------------
create or replace function public.fin_pago_cargar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cli     text    := nullif(btrim(p ->> 'cliente_id'), '');
  v_fecha   date;
  v_monto   numeric;
  v_alumno  text    := nullif(btrim(p ->> 'alumno'), '');
  v_comp    text    := nullif(btrim(p ->> 'comprobante'), '');
  v_fuente  public.fin_fuentes%rowtype;
  v_prog    text; v_conc text; v_met text; v_rec text;
  v_closer  text; v_setter text;
  v_hoy     date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_fila    public.fin_pagos%rowtype;
begin
  if v_cli is null then raise exception 'Falta el cliente'; end if;
  if not public.fin_puede_cargar(v_cli) then
    raise exception 'No tenes permiso para cargar pagos de %', v_cli;
  end if;
  if not public.fin_carga_habilitada(v_cli) then
    raise exception 'La carga en la app de % todavia no esta habilitada (la planilla no esta cortada)', v_cli;
  end if;

  select * into v_fuente from public.fin_fuentes
   where cliente_id = v_cli and tipo = 'pagos' and cortada_en is not null
   order by id limit 1;

  begin
    v_fecha := (p ->> 'fecha')::date;
  exception when others then
    raise exception 'Fecha invalida: %', p ->> 'fecha';
  end;
  if v_fecha is null then raise exception 'Falta la fecha'; end if;
  if v_fecha > v_hoy then raise exception 'La fecha % es futura', v_fecha; end if;
  if v_fecha < date '2024-01-01' then raise exception 'La fecha % es demasiado vieja', v_fecha; end if;

  if v_alumno is null then raise exception 'Falta el alumno'; end if;

  begin
    v_monto := round((p ->> 'monto_usd')::numeric, 2);
  exception when others then
    raise exception 'Monto invalido: %', p ->> 'monto_usd';
  end;
  if v_monto is null or v_monto <= 0 then raise exception 'El monto tiene que ser mayor a 0'; end if;
  if v_fuente.tope_monto is not null and v_monto > v_fuente.tope_monto then
    raise exception 'El monto % supera el tope de % USD. Si es correcto, lo carga un fundador desde la base.', v_monto, v_fuente.tope_monto;
  end if;

  select valor into v_prog from public.fin_catalogos
   where id = (p ->> 'programa_id')::bigint and cliente_id = v_cli and dimension = 'programa' and activo;
  if v_prog is null then raise exception 'Programa invalido para %', v_cli; end if;

  select valor into v_conc from public.fin_catalogos
   where id = (p ->> 'concepto_id')::bigint and cliente_id = v_cli and dimension = 'concepto' and activo;
  if v_conc is null then raise exception 'Concepto invalido para %', v_cli; end if;
  if v_conc = 'REFUND' then raise exception 'Las devoluciones se cargan con "Devolver" sobre el pago original'; end if;

  select valor into v_met from public.fin_catalogos
   where id = (p ->> 'metodo_pago_id')::bigint and cliente_id = v_cli and dimension = 'metodo_pago' and activo;
  if v_met is null then raise exception 'Metodo de pago invalido para %', v_cli; end if;

  if nullif(p ->> 'quien_recibe_id', '') is not null then
    select valor into v_rec from public.fin_catalogos
     where id = (p ->> 'quien_recibe_id')::bigint and cliente_id = v_cli and dimension = 'quien_recibe' and activo;
    if v_rec is null then raise exception 'Quien recibe invalido para %', v_cli; end if;
  end if;

  -- Closer y setter: vendedor asignado a este cliente con ese rol. Se guarda
  -- el alias que ya usa fin_v_pago_vendedores, asi la comision sale igual
  -- que con los pagos de la planilla.
  if nullif(p ->> 'closer_id', '') is not null then
    select coalesce(
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id = v_cli order by x.id limit 1),
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id is null order by x.id limit 1))
      into v_closer
      from public.fin_vendedor_asignaciones a
     where a.vendedor_id = (p ->> 'closer_id')::bigint and a.cliente_id = v_cli and a.es_closer
       and (a.hasta is null or a.hasta >= v_fecha)
     limit 1;
    if v_closer is null then raise exception 'Ese closer no esta asignado a % o no tiene alias', v_cli; end if;
  end if;
  if nullif(p ->> 'setter_id', '') is not null then
    select coalesce(
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id = v_cli order by x.id limit 1),
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id is null order by x.id limit 1))
      into v_setter
      from public.fin_vendedor_asignaciones a
     where a.vendedor_id = (p ->> 'setter_id')::bigint and a.cliente_id = v_cli and a.es_setter
       and (a.hasta is null or a.hasta >= v_fecha)
     limit 1;
    if v_setter is null then raise exception 'Ese setter no esta asignado a % o no tiene alias', v_cli; end if;
  end if;

  if v_comp is not null and v_comp !~* '^https?://' then
    raise exception 'El comprobante tiene que ser un link (https://...)';
  end if;

  insert into public.fin_pagos (
    cliente_id, fuente_id, origen, fila_planilla, fecha, programa, programa_id, alumno, telefono,
    concepto, concepto_id, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente,
    metodo_pago, metodo_pago_id, quien_recibe, quien_recibe_id, closer, setter, comprobante,
    nota, creado_por, creado_en)
  values (
    v_cli, v_fuente.id, 'app', null, v_fecha, v_prog, (p ->> 'programa_id')::bigint, v_alumno,
    nullif(btrim(p ->> 'telefono'), ''),
    v_conc, (p ->> 'concepto_id')::bigint, v_monto, v_monto, 'USD', 1, 'app',
    v_met, (p ->> 'metodo_pago_id')::bigint, v_rec, nullif(p ->> 'quien_recibe_id', '')::bigint,
    v_closer, v_setter, v_comp, nullif(btrim(p ->> 'nota'), ''), auth.uid(), now())
  returning * into v_fila;

  return jsonb_build_object('ok', true, 'id', v_fila.id, 'clave', v_fila.clave);
end $$;

-- ---------------------------------------------------------------------
-- 5b. Anular un pago cargado en la app
-- ---------------------------------------------------------------------
create or replace function public.fin_pago_anular(p_clave text, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.fin_pagos%rowtype;
begin
  select * into v from public.fin_pagos where clave = p_clave;
  if not found then raise exception 'No existe el pago %', p_clave; end if;
  if not public.fin_puede_anular(v.cliente_id) then
    raise exception 'Solo un fundador o el cliente puede anular pagos';
  end if;
  if v.origen <> 'app' then
    raise exception 'Este pago viene de la planilla: no se anula desde la app';
  end if;
  if nullif(btrim(p_motivo), '') is null then raise exception 'Falta el motivo'; end if;
  if exists (select 1 from public.fin_liquidacion_items i
               join public.fin_liquidaciones l on l.id = i.liquidacion_id
              where l.estado = 'cerrada' and i.pago_clave = v.clave) then
    raise exception 'Este pago ya esta en una liquidacion cerrada: en vez de anularlo, carga una devolucion';
  end if;
  if exists (select 1 from public.fin_pagos d where d.pago_original_clave = v.clave) then
    raise exception 'Este pago tiene devoluciones cargadas: anula primero las devoluciones';
  end if;

  insert into public.fin_pagos_anulados (cliente_id, clave, pago, motivo, anulado_por)
  values (v.cliente_id, v.clave, to_jsonb(v), btrim(p_motivo), auth.uid());
  delete from public.fin_pagos where id = v.id;

  return jsonb_build_object('ok', true, 'clave', v.clave);
end $$;

-- ---------------------------------------------------------------------
-- 5c. Devolver (total o parcial) un pago: fila negativa enganchada
-- ---------------------------------------------------------------------
create or replace function public.fin_pago_devolver(p_clave text, p_monto numeric, p_fecha date, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v        public.fin_pagos%rowtype;
  v_fila   public.fin_pagos%rowtype;
  v_ya     numeric;
  v_conc   bigint;
  v_monto  numeric := round(p_monto, 2);
  v_hoy    date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  select * into v from public.fin_pagos where clave = p_clave;
  if not found then raise exception 'No existe el pago %', p_clave; end if;
  if not public.fin_puede_anular(v.cliente_id) then
    raise exception 'Solo un fundador o el cliente puede cargar devoluciones';
  end if;
  if not public.fin_carga_habilitada(v.cliente_id) then
    raise exception 'La carga en la app de % todavia no esta habilitada', v.cliente_id;
  end if;
  if v.monto_usd <= 0 then raise exception 'No se puede devolver una devolucion'; end if;
  if v_monto is null or v_monto <= 0 then raise exception 'El monto a devolver tiene que ser mayor a 0'; end if;
  if p_fecha is null or p_fecha > v_hoy or p_fecha < v.fecha then
    raise exception 'La fecha de la devolucion tiene que estar entre % y hoy', v.fecha;
  end if;
  if nullif(btrim(p_motivo), '') is null then raise exception 'Falta el motivo'; end if;

  select coalesce(-sum(monto_usd), 0) into v_ya
    from public.fin_pagos where pago_original_clave = v.clave;
  if v_monto > v.monto_usd - v_ya then
    raise exception 'Se puede devolver como maximo % USD (ya se devolvieron %)', v.monto_usd - v_ya, v_ya;
  end if;

  select id into v_conc from public.fin_catalogos
   where cliente_id = v.cliente_id and dimension = 'concepto' and valor = 'REFUND';

  insert into public.fin_pagos (
    cliente_id, fuente_id, origen, fila_planilla, fecha, programa, programa_id, alumno, telefono,
    concepto, concepto_id, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente,
    metodo_pago, metodo_pago_id, quien_recibe, quien_recibe_id, closer, setter,
    pago_original_clave, nota, creado_por, creado_en)
  values (
    v.cliente_id, v.fuente_id, 'app', null, p_fecha, v.programa, v.programa_id, v.alumno, v.telefono,
    'REFUND', v_conc, -v_monto, -v_monto, 'USD', 1, 'app',
    v.metodo_pago, v.metodo_pago_id, v.quien_recibe, v.quien_recibe_id, v.closer, v.setter,
    v.clave, btrim(p_motivo), auth.uid(), now())
  returning * into v_fila;

  return jsonb_build_object('ok', true, 'id', v_fila.id, 'clave', v_fila.clave);
end $$;

-- ---------------------------------------------------------------------
-- 5d. Opciones del formulario de un cliente (no depende de la RLS de
--     cada tabla: valida el mismo permiso que la carga)
-- ---------------------------------------------------------------------
create or replace function public.fin_carga_opciones(p_cliente text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.fin_puede_cargar(p_cliente) then
    raise exception 'No tenes permiso para cargar pagos de %', p_cliente;
  end if;
  return jsonb_build_object(
    'habilitada', public.fin_carga_habilitada(p_cliente),
    'puede_anular', public.fin_puede_anular(p_cliente),
    'programas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor) order by orden, valor), '[]')
                    from public.fin_catalogos where cliente_id = p_cliente and dimension = 'programa' and activo),
    'conceptos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor) order by orden, valor), '[]')
                    from public.fin_catalogos where cliente_id = p_cliente and dimension = 'concepto' and activo
                     and valor <> 'REFUND'),
    'metodos', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor) order by orden, valor), '[]')
                  from public.fin_catalogos where cliente_id = p_cliente and dimension = 'metodo_pago' and activo),
    'quien_recibe', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'valor', valor) order by orden, valor), '[]')
                       from public.fin_catalogos where cliente_id = p_cliente and dimension = 'quien_recibe' and activo),
    'closers', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'nombre', v.nombre) order by v.nombre), '[]')
                  from public.fin_vendedores v join public.fin_vendedor_asignaciones a on a.vendedor_id = v.id
                 where a.cliente_id = p_cliente and a.es_closer and v.activo and a.hasta is null),
    'setters', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'nombre', v.nombre) order by v.nombre), '[]')
                  from public.fin_vendedores v join public.fin_vendedor_asignaciones a on a.vendedor_id = v.id
                 where a.cliente_id = p_cliente and a.es_setter and v.activo and a.hasta is null)
  );
end $$;

-- Permisos de ejecucion: solo usuarios logueados (las funciones validan el rol).
do $$
declare f text;
begin
  foreach f in array array[
    'public.fin_carga_habilitada(text)', 'public.fin_puede_cargar(text)', 'public.fin_puede_anular(text)',
    'public.fin_clientes_carga()', 'public.fin_pago_cargar(jsonb)', 'public.fin_pago_anular(text,text)',
    'public.fin_pago_devolver(text,numeric,date,text)', 'public.fin_carga_opciones(text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 6. Lo cargado en la app, con quien lo cargo
-- ---------------------------------------------------------------------
create or replace view public.fin_v_pagos_app
with (security_invoker = true) as
select p.cliente_id, p.fecha, p.alumno, p.concepto, p.monto_usd, p.closer, p.setter,
       p.clave, p.pago_original_clave, p.nota, p.creado_en,
       coalesce(m.nombre, x.alias, p.creado_por::text) as cargado_por
from public.fin_pagos p
left join public.crm_members m on m.user_id = p.creado_por
left join lateral (select alias from public.fin_personas
                   where user_id = p.creado_por order by id limit 1) x on true
where p.origen = 'app';

revoke all on public.fin_v_pagos_app from anon;
grant select on public.fin_v_pagos_app to authenticated;
grant all on public.fin_v_pagos_app to service_role;

commit;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Funciones y tabla arriba: las 4 en true.
-- select to_regprocedure('public.fin_pago_cargar(jsonb)') is not null as cargar,
--        to_regprocedure('public.fin_pago_anular(text,text)') is not null as anular,
--        to_regprocedure('public.fin_pago_devolver(text,numeric,date,text)') is not null as devolver,
--        to_regclass('public.fin_pagos_anulados') is not null as anulados;

-- C2. Nadie tiene la carga habilitada todavia (ninguna planilla de pagos
--     cortada). Esperado: 5 filas, todas en false.
-- select cliente_id, public.fin_carga_habilitada(cliente_id)
--   from public.fin_fuentes where tipo = 'pagos' order by 1;

-- C3. REFUND en el catalogo de los 4 clientes. Esperado: 4.
-- select count(*) from public.fin_catalogos where dimension = 'concepto' and valor = 'REFUND';

-- C4. Nada cambio en los pagos. Esperado: igual que antes de la 066
--     (~1.621, todos sheet).
-- select origen, count(*) from public.fin_pagos group by 1;
