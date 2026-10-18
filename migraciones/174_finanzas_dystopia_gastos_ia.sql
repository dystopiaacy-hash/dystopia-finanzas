-- =====================================================================
-- 174_finanzas_dystopia_gastos_ia.sql
-- Finanzas Dystopia (solo fundador) + panel Gastos + gasto de IA por cliente.
-- Numero asignado por el jefe (17/10). SIN CORRER, NO PROBADA contra Postgres.
--
-- Que crea (todo nuevo; no modifica pagos, comisiones, ia_uso ni la sync):
--   Tablas
--     fin_dys_acceso        quien, ademas del fundador, ve Dystopia / Gastos / edita gastos (vacia).
--     fin_gasto_categorias  categorias editables (alta, renombrar, desactivar). 6 predeterminadas.
--     fin_gastos            gastos manuales (baja logica con activo=false).
--   Funciones
--     fin_dys_puede_ver(), fin_gastos_puede_ver(), fin_gastos_puede_editar()  (fundador o fin_dys_acceso)
--     fin_dys_mi_acceso()   los tres permisos del usuario, para ocultar el menu.
--   Vistas (las 3 publicas filtran por permiso adentro; las 2 internas no se otorgan a nadie)
--     fin_ia_uso_norm       [interna] ia_uso normalizada: mes (hora AR), entidad, proveedor.
--     fin_gastos_mes_base   [interna] gastos manuales (recurrentes expandidos por mes) + IA automatica.
--     fin_v_ia_uso_mes      IA por mes x entidad x proveedor x app x funcion.
--     fin_v_gastos_mes      gastos por mes con el reparto Dystopia / cliente.
--     fin_v_dys_mes         por mes y cliente: base, %, ingreso de Dystopia, gastos, neto.
--
-- REGLAS (decididas por Joaquin, 17/10)
--   * Ingreso de Dystopia = base x % de fin_comision_agencia vigente ese mes (desde/hasta). No hay % en el codigo.
--   * BASE = fin_v_pnl_mensual.ingreso_real (063): suma de fin_pagos.monto_usd por mes de fecha de pago, la
--     misma cifra del P&L. NO existia otro calculo de comision de agencia (fin_reparto no se lee y
--     fin_v_comisiones* son de closers/setters). Para cambiar la base (ej. neto de gastos) se toca UN solo
--     lugar: el CTE ing de fin_v_dys_mes. Pregunta abierta de FASE0/PLAN: si el % va sobre cash o sobre neto.
--   * Gasto compartido de un cliente (reparto 'comision'): Dystopia paga su % del mes, el cliente el resto.
--     'cliente' = 100% cliente, 'dystopia' = 100% Dystopia. Entidad 'dystopia' siempre 100% Dystopia.
--   * IA automatica: ia_uso.cliente_id en (liam, agus, teo) (sin importar mayusculas) va a ese cliente;
--     'dystopia' (uso interno de las apps) y TODO lo demas (UUIDs, null, otros) va 100% a Dystopia, categoria IA
--     (decision de Joaquin, 17/10). Lo que no se pudo asignar queda marcado con sin_asignar = true: las pantallas
--     lo muestran como "Sin asignar -> Dystopia" pero suma en los totales de Dystopia. Proveedor por modelo:
--     claude* / anthropic* = claude, gemini* = gemini, resto = otro. Las llamadas con costo 0 o null se
--     cuentan aparte (sin_costo) para que se note que el total puede estar subestimado.
--   * Gasto en ARS: monto_usd = monto / tipo_cambio (tipo_cambio = pesos por 1 USD, se guarda en el gasto).
--     Un recurrente usa siempre ese tipo de cambio. Un recurrente corre desde el mes de su fecha hasta su
--     fecha de fin o el mes actual (no proyecta el futuro).
--   * Siembra de porcentajes: solo para liam / agus / teo y solo si ese cliente NO tiene ninguna fila en
--     fin_comision_agencia (desde 2026-01-01, abierto). Si ya hay filas no se toca nada.
--
-- Depende de: 001 (fin_comision_agencia, fin_pagos), 063 (fin_v_pnl_mensual), 137 (ia_uso con creado_en),
--   es_fundador(), crm_clients. No usa begin/commit (el SQL Editor pasa por un pooler): todo re-ejecutable.
--   No toca tablas que lee la sync: no hace falta lock. Correr fuera de :00/:15/:30/:45 y de las 9:00.
-- ORDEN: correr cada BLOQUE por separado y en orden: 1 (guardas, tablas, permisos) > 2 (vistas) > 3 (humo,
--   termina en ERROR "HUMO 174 OK" y revierte solo el humo) > controles C1.. de a uno (al final) > front.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas, tablas, funciones de permiso, RLS y siembra
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.ia_uso') is null then v_falta := v_falta || ' ia_uso(137)'; end if;
  if to_regclass('public.fin_comision_agencia') is null then v_falta := v_falta || ' fin_comision_agencia(001)'; end if;
  if to_regclass('public.fin_pagos') is null then v_falta := v_falta || ' fin_pagos'; end if;
  if to_regclass('public.fin_v_pnl_mensual') is null then v_falta := v_falta || ' fin_v_pnl_mensual(063)'; end if;
  if to_regclass('public.crm_clients') is null then v_falta := v_falta || ' crm_clients'; end if;
  if to_regclass('public.crm_members') is null then v_falta := v_falta || ' crm_members'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if v_falta <> '' then raise exception 'GUARDA 174: faltan:%', v_falta; end if;
  -- columnas de ia_uso que lee la vista
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'ia_uso'
         and column_name in ('creado_en', 'app', 'funcion', 'cliente_id', 'modelo',
                             'tokens_entrada', 'tokens_salida', 'costo_usd', 'ok')) <> 9 then
    raise exception 'GUARDA 174: ia_uso no tiene creado_en, app, funcion, cliente_id, modelo, tokens_entrada, tokens_salida, costo_usd y ok (mirar select * from ia_uso limit 1)';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'fin_comision_agencia'
         and column_name in ('cliente_id', 'desde', 'hasta', 'porcentaje')) <> 4 then
    raise exception 'GUARDA 174: fin_comision_agencia no tiene cliente_id, desde, hasta y porcentaje';
  end if;
end
$g$;

-- Acceso a Dystopia y Gastos para quien no es fundador. Vacia: hoy entra solo el fundador.
create table if not exists public.fin_dys_acceso (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  dystopia      boolean not null default false,   -- ve la seccion Dystopia y la pantalla de IA
  gastos        boolean not null default false,   -- ve el panel Gastos
  edita_gastos  boolean not null default false,   -- da de alta, edita y da de baja gastos y categorias
  nota          text,
  creado_en     timestamptz not null default now()
);
comment on table public.fin_dys_acceso is '174: usuarios (ademas del fundador) con acceso a Dystopia / Gastos. Vacia a proposito.';

create table if not exists public.fin_gasto_categorias (
  id        bigint generated always as identity primary key,
  nombre    text not null check (btrim(nombre) <> ''),
  clave     text,                      -- 'ia' marca la categoria donde cae el gasto de IA automatico; sobrevive a renombrar
  activa    boolean not null default true,
  orden     int not null default 100,
  creado_en timestamptz not null default now()
);
create unique index if not exists fin_gasto_categorias_nombre_uq on public.fin_gasto_categorias (lower(btrim(nombre)));
create unique index if not exists fin_gasto_categorias_clave_uq on public.fin_gasto_categorias (clave) where clave is not null;

create table if not exists public.fin_gastos (
  id               bigint generated always as identity primary key,
  entidad          text    not null check (entidad in ('liam', 'agus', 'teo', 'dystopia')),
  categoria_id     bigint  not null references public.fin_gasto_categorias(id),
  descripcion      text    not null check (btrim(descripcion) <> ''),
  monto            numeric not null check (monto > 0),
  moneda           text    not null check (moneda in ('USD', 'ARS')),
  tipo_cambio      numeric,            -- pesos por 1 USD; obligatorio si moneda = ARS
  fecha            date    not null,
  recurrente       boolean not null default false,
  recurrente_hasta date,
  reparto          text    not null default 'comision' check (reparto in ('comision', 'cliente', 'dystopia')),
  nota             text,
  activo           boolean not null default true,   -- baja logica
  creado_por       uuid,
  creado_en        timestamptz not null default now(),
  editado_por      uuid,
  editado_en       timestamptz,
  constraint fin_gastos_cambio_ck check ((moneda = 'ARS' and tipo_cambio is not null and tipo_cambio > 0)
                                      or (moneda = 'USD' and (tipo_cambio is null or tipo_cambio > 0))),
  constraint fin_gastos_dys_ck check (entidad <> 'dystopia' or reparto = 'dystopia'),
  constraint fin_gastos_fin_ck check (recurrente_hasta is null or (recurrente and recurrente_hasta >= fecha))
);
create index if not exists fin_gastos_fecha_idx on public.fin_gastos (entidad, fecha) where activo;

-- Permisos (security definer: leen fin_dys_acceso aunque el usuario no pueda).
create or replace function public.fin_dys_acceso_de(p_campo text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.es_fundador(), false) or exists (
    select 1 from public.fin_dys_acceso a
     where a.user_id = auth.uid()
       and case p_campo when 'dystopia' then a.dystopia when 'gastos' then a.gastos when 'edita' then a.edita_gastos else false end);
$$;
create or replace function public.fin_dys_puede_ver()        returns boolean language sql stable security definer set search_path = public as $$ select public.fin_dys_acceso_de('dystopia') $$;
create or replace function public.fin_gastos_puede_ver()     returns boolean language sql stable security definer set search_path = public as $$ select public.fin_dys_acceso_de('gastos') $$;
create or replace function public.fin_gastos_puede_editar()  returns boolean language sql stable security definer set search_path = public as $$ select public.fin_dys_acceso_de('edita') $$;
-- El menu de la app: una sola llamada.
create or replace function public.fin_dys_mi_acceso()
returns table (dystopia boolean, gastos boolean, edita boolean)
language sql stable security definer set search_path = public as $$
  select public.fin_dys_acceso_de('dystopia'), public.fin_dys_acceso_de('gastos'), public.fin_dys_acceso_de('edita');
$$;

-- Quien creo / edito, sin confiar en el front.
create or replace function public.fin_gastos_sello()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.creado_por := auth.uid(); new.creado_en := now(); new.editado_por := null; new.editado_en := null;
  else
    new.creado_por := old.creado_por; new.creado_en := old.creado_en;
    new.editado_por := auth.uid(); new.editado_en := now();
  end if;
  return new;
end $$;
drop trigger if exists fin_gastos_sello_trg on public.fin_gastos;
create trigger fin_gastos_sello_trg before insert or update on public.fin_gastos
  for each row execute function public.fin_gastos_sello();

-- RLS y permisos: revoke primero, grant despues. Sin delete (la baja es logica).
alter table public.fin_dys_acceso enable row level security;
alter table public.fin_gasto_categorias enable row level security;
alter table public.fin_gastos enable row level security;
revoke all on table public.fin_dys_acceso, public.fin_gasto_categorias, public.fin_gastos from public, anon, authenticated;
revoke all on sequence public.fin_gasto_categorias_id_seq, public.fin_gastos_id_seq from public, anon, authenticated;
grant select, insert, update, delete on public.fin_dys_acceso to authenticated;
grant select, insert, update on public.fin_gasto_categorias, public.fin_gastos to authenticated;
grant all on public.fin_dys_acceso, public.fin_gasto_categorias, public.fin_gastos to service_role;

drop policy if exists fin_dys_acceso_sel on public.fin_dys_acceso;
create policy fin_dys_acceso_sel on public.fin_dys_acceso for select to authenticated
  using ((select public.es_fundador()) or user_id = (select auth.uid()));
drop policy if exists fin_dys_acceso_fundador on public.fin_dys_acceso;
create policy fin_dys_acceso_fundador on public.fin_dys_acceso for all to authenticated
  using ((select public.es_fundador())) with check ((select public.es_fundador()));

drop policy if exists fin_gasto_cat_sel on public.fin_gasto_categorias;
create policy fin_gasto_cat_sel on public.fin_gasto_categorias for select to authenticated
  using ((select public.fin_gastos_puede_ver()));
drop policy if exists fin_gasto_cat_ins on public.fin_gasto_categorias;
create policy fin_gasto_cat_ins on public.fin_gasto_categorias for insert to authenticated
  with check ((select public.fin_gastos_puede_editar()));
drop policy if exists fin_gasto_cat_upd on public.fin_gasto_categorias;
create policy fin_gasto_cat_upd on public.fin_gasto_categorias for update to authenticated
  using ((select public.fin_gastos_puede_editar())) with check ((select public.fin_gastos_puede_editar()));

drop policy if exists fin_gastos_sel on public.fin_gastos;
create policy fin_gastos_sel on public.fin_gastos for select to authenticated
  using ((select public.fin_gastos_puede_ver()));
drop policy if exists fin_gastos_ins on public.fin_gastos;
create policy fin_gastos_ins on public.fin_gastos for insert to authenticated
  with check ((select public.fin_gastos_puede_editar()));
drop policy if exists fin_gastos_upd on public.fin_gastos;
create policy fin_gastos_upd on public.fin_gastos for update to authenticated
  using ((select public.fin_gastos_puede_editar())) with check ((select public.fin_gastos_puede_editar()));

revoke all on function public.fin_dys_acceso_de(text), public.fin_dys_puede_ver(), public.fin_gastos_puede_ver(),
  public.fin_gastos_puede_editar(), public.fin_dys_mi_acceso(), public.fin_gastos_sello() from public, anon;
grant execute on function public.fin_dys_acceso_de(text), public.fin_dys_puede_ver(), public.fin_gastos_puede_ver(),
  public.fin_gastos_puede_editar(), public.fin_dys_mi_acceso() to authenticated, service_role;

-- Categorias predeterminadas (solo las que falten, por nombre).
insert into public.fin_gasto_categorias (nombre, clave, orden)
select v.nombre, v.clave, v.orden
  from (values ('IA', 'ia', 10), ('Software y suscripciones', null, 20), ('Ads', null, 30),
               ('Sueldos y comisiones', null, 40), ('Impuestos', null, 50), ('Otros', null, 60)) as v(nombre, clave, orden)
 where not exists (select 1 from public.fin_gasto_categorias c where lower(btrim(c.nombre)) = lower(v.nombre))
   and (v.clave is null or not exists (select 1 from public.fin_gasto_categorias c where c.clave = v.clave));

-- Porcentajes de la agencia: Agus 25, Liam 30, Teo 40, solo si el cliente no tiene ninguna fila.
insert into public.fin_comision_agencia (cliente_id, desde, hasta, porcentaje, nota)
select v.cliente_id, date '2026-01-01', null, v.pct, '174: sembrado segun decision de Joaquin (17/10/2026)'
  from (values ('liam', 30::numeric), ('agus', 25::numeric), ('teo', 40::numeric)) as v(cliente_id, pct)
 where exists (select 1 from public.crm_clients c where c.id = v.cliente_id)
   and not exists (select 1 from public.fin_comision_agencia a where a.cliente_id = v.cliente_id);

-- ---------------------------------------------------------------------
-- BLOQUE 2. Vistas
-- ---------------------------------------------------------------------
-- Interna: ia_uso normalizada. Sin grants: solo la leen las vistas de abajo (dueño de las vistas).
create or replace view public.fin_ia_uso_norm as
select (date_trunc('month', u.creado_en at time zone 'America/Argentina/Buenos_Aires'))::date as mes,
       case when lower(btrim(u.cliente_id::text)) in ('liam', 'agus', 'teo')
            then lower(btrim(u.cliente_id::text)) else 'dystopia' end as entidad,
       coalesce(lower(btrim(u.cliente_id::text)) not in ('liam', 'agus', 'teo', 'dystopia'), true) as sin_asignar,
       case when lower(coalesce(u.modelo, '')) like 'claude%' or lower(coalesce(u.modelo, '')) like '%anthropic%' then 'claude'
            when lower(coalesce(u.modelo, '')) like '%gemini%' then 'gemini'
            else 'otro' end as proveedor,
       coalesce(u.app, '(sin app)') as app,
       coalesce(u.funcion, '(sin funcion)') as funcion,
       coalesce(u.costo_usd, 0)::numeric as costo_usd,
       coalesce(u.tokens_entrada, 0) as tokens_entrada,
       coalesce(u.tokens_salida, 0) as tokens_salida,
       coalesce(u.costo_usd, 0) = 0 as sin_costo,
       coalesce(u.ok, true) as ok
  from public.ia_uso u;
revoke all on public.fin_ia_uso_norm from public, anon, authenticated;

-- Interna: gastos por mes y entidad, con reparto. Manuales (recurrentes expandidos) + IA automatica.
create or replace view public.fin_gastos_mes_base as
with hoy as (
  select (date_trunc('month', now() at time zone 'America/Argentina/Buenos_Aires'))::date as mes_actual
), man as (
  select 'manual'::text as origen, g.id as gasto_id, m::date as mes, g.entidad, g.categoria_id, g.descripcion,
         g.monto as monto_original, g.moneda, g.tipo_cambio,
         round(case when g.moneda = 'USD' then g.monto else g.monto / g.tipo_cambio end, 2) as monto_usd,
         g.reparto, g.recurrente, g.nota, null::bigint as llamadas_sin_costo, false as sin_asignar
    from public.fin_gastos g
   cross join hoy
   cross join lateral generate_series(
          (date_trunc('month', g.fecha))::timestamp,
          (case when g.recurrente
               then least((date_trunc('month', coalesce(g.recurrente_hasta, hoy.mes_actual)))::date, hoy.mes_actual)
               else (date_trunc('month', g.fecha))::date end)::timestamp,
          interval '1 month') as m
   where g.activo
), ia as (
  select 'ia_auto'::text as origen, null::bigint as gasto_id, n.mes, n.entidad,
         (select c.id from public.fin_gasto_categorias c where c.clave = 'ia') as categoria_id,
         (case when n.sin_asignar then 'Uso de IA sin asignar a un cliente (va a Dystopia)'
               else 'Uso de IA (automatico desde ia_uso)' end)::text as descripcion,
         round(sum(n.costo_usd), 2) as monto_original, 'USD'::text as moneda, null::numeric as tipo_cambio,
         round(sum(n.costo_usd), 2) as monto_usd,
         case n.entidad when 'dystopia' then 'dystopia' else 'comision' end as reparto,
         false as recurrente, null::text as nota, count(*) filter (where n.sin_costo) as llamadas_sin_costo, n.sin_asignar
    from public.fin_ia_uso_norm n
   group by n.mes, n.entidad, n.sin_asignar
), u as (
  select * from man union all select * from ia
), con_pct as (
  select u.*,
         case when u.reparto = 'comision' then
           (select a.porcentaje from public.fin_comision_agencia a
             where a.cliente_id = u.entidad and a.desde <= ((u.mes + interval '1 month')::date - 1)
               and (a.hasta is null or a.hasta >= u.mes)
             order by a.desde desc limit 1) end as pct_comision
    from u
)
select p.origen, p.gasto_id, p.mes, p.entidad, p.categoria_id, c.nombre as categoria, c.clave as categoria_clave,
       p.descripcion, p.monto_original, p.moneda, p.tipo_cambio, p.monto_usd, p.reparto,
       case p.reparto when 'dystopia' then 100::numeric when 'cliente' then 0::numeric
                      when 'comision' then coalesce(p.pct_comision, 0) end as porcentaje_dystopia,
       round(p.monto_usd * case p.reparto when 'dystopia' then 100 when 'cliente' then 0
                                          else coalesce(p.pct_comision, 0) end / 100, 2) as usd_dystopia,
       case p.reparto when 'dystopia' then 0::numeric
            else p.monto_usd - round(p.monto_usd * case p.reparto when 'cliente' then 0
                                                       else coalesce(p.pct_comision, 0) end / 100, 2) end as usd_cliente,
       p.recurrente, p.nota, p.llamadas_sin_costo,
       (p.reparto = 'comision' and p.pct_comision is null) as falta_comision, p.sin_asignar
  from con_pct p
  left join public.fin_gasto_categorias c on c.id = p.categoria_id;
revoke all on public.fin_gastos_mes_base from public, anon, authenticated;

-- Publicas: filtran por permiso adentro (mismo patron que fin_v_pnl_mensual).
create or replace view public.fin_v_ia_uso_mes as
select n.mes, n.entidad, n.proveedor, n.app, n.funcion, n.sin_asignar,
       count(*) as llamadas,
       count(*) filter (where n.sin_costo) as sin_costo,
       count(*) filter (where not n.ok) as con_error,
       sum(n.tokens_entrada) as tokens_entrada, sum(n.tokens_salida) as tokens_salida,
       round(sum(n.costo_usd), 4) as costo_usd
  from public.fin_ia_uso_norm n
 where public.fin_dys_puede_ver() or public.fin_gastos_puede_ver()
 group by n.mes, n.entidad, n.sin_asignar, n.proveedor, n.app, n.funcion;

create or replace view public.fin_v_gastos_mes as
select * from public.fin_gastos_mes_base where public.fin_gastos_puede_ver();

-- Dystopia: por mes y cliente (liam, agus, teo) y la propia agencia (entidad dystopia).
create or replace view public.fin_v_dys_mes as
with ing as (   -- BASE de la comision: ingreso real de Pagos (= fin_v_pnl_mensual.ingreso_real). Unico lugar donde cambiarla.
  select p.cliente_id as entidad, (date_trunc('month', p.fecha))::date as mes, sum(p.monto_usd) as base_usd
    from public.fin_pagos p
   where p.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
  having coalesce(sum(p.monto_usd), 0) <> 0
), gas as (
  select b.entidad, b.mes, sum(b.usd_dystopia) as gasto_dystopia_usd,
         sum(b.usd_dystopia) filter (where b.categoria_clave = 'ia') as gasto_ia_dystopia_usd
    from public.fin_gastos_mes_base b
   group by b.entidad, b.mes
), claves as (
  select entidad, mes from ing union select entidad, mes from gas
), arm as (
  select k.entidad, k.mes, coalesce(i.base_usd, 0) as base_usd,
         case when k.entidad = 'dystopia' then null else
           (select a.porcentaje from public.fin_comision_agencia a
             where a.cliente_id = k.entidad and a.desde <= ((k.mes + interval '1 month')::date - 1)
               and (a.hasta is null or a.hasta >= k.mes)
             order by a.desde desc limit 1) end as porcentaje,
         coalesce(g.gasto_dystopia_usd, 0) as gasto_dystopia_usd,
         coalesce(g.gasto_ia_dystopia_usd, 0) as gasto_ia_dystopia_usd
    from claves k
    left join ing i on i.entidad = k.entidad and i.mes = k.mes
    left join gas g on g.entidad = k.entidad and g.mes = k.mes
)
select a.mes, a.entidad, a.base_usd, a.porcentaje,
       round(a.base_usd * coalesce(a.porcentaje, 0) / 100, 2) as ingreso_usd,
       a.gasto_dystopia_usd, a.gasto_ia_dystopia_usd,
       round(a.base_usd * coalesce(a.porcentaje, 0) / 100, 2) - a.gasto_dystopia_usd as neto_usd
  from arm a
 where public.fin_dys_puede_ver();

revoke all on public.fin_v_ia_uso_mes, public.fin_v_gastos_mes, public.fin_v_dys_mes from public, anon, authenticated;
grant select on public.fin_v_ia_uso_mes, public.fin_v_gastos_mes, public.fin_v_dys_mes to authenticated;
grant select on public.fin_v_ia_uso_mes, public.fin_v_gastos_mes, public.fin_v_dys_mes to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 3. Humo (se revierte solo: termina en ERROR "HUMO 174 OK"). Corre como el primer fundador.
-- ---------------------------------------------------------------------
do $h$
declare
  v_uid uuid; v_cat bigint; v_id bigint; v_f record; v_n int;
begin
  select user_id into v_uid from public.crm_members where rol = 'fundador' limit 1;
  if v_uid is null then raise exception 'HUMO 174: no hay un fundador en crm_members'; end if;
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  if not public.fin_gastos_puede_editar() then raise exception 'HUMO 174: el fundador no puede editar gastos'; end if;
  if (select count(*) from public.fin_gasto_categorias where clave = 'ia') <> 1 then raise exception 'HUMO 174: falta la categoria IA'; end if;
  select id into v_cat from public.fin_gasto_categorias where clave = 'ia';
  if not exists (select 1 from public.fin_comision_agencia where cliente_id = 'liam') then raise exception 'HUMO 174: liam sin porcentaje'; end if;

  -- ARS compartido: 120000 pesos a 1200 = 100 USD; Dystopia paga su % de liam del mes actual.
  insert into public.fin_gastos (entidad, categoria_id, descripcion, monto, moneda, tipo_cambio, fecha, reparto)
  values ('liam', v_cat, 'humo 174', 120000, 'ARS', 1200, (date_trunc('month', now()))::date, 'comision')
  returning id into v_id;
  select * into v_f from public.fin_v_gastos_mes where gasto_id = v_id;
  if v_f.gasto_id is null then raise exception 'HUMO 174: el gasto no aparece en fin_v_gastos_mes'; end if;
  if v_f.monto_usd <> 100 then raise exception 'HUMO 174: ARS dio % y esperaba 100', v_f.monto_usd; end if;
  if round(v_f.usd_dystopia + v_f.usd_cliente, 2) <> 100 then raise exception 'HUMO 174: el reparto no suma 100'; end if;
  if v_f.falta_comision then raise exception 'HUMO 174: liam sin comision vigente este mes'; end if;

  -- Recurrente: tres meses atras sin fin = 4 filas (3 anteriores + el actual).
  insert into public.fin_gastos (entidad, categoria_id, descripcion, monto, moneda, fecha, recurrente, reparto)
  values ('dystopia', v_cat, 'humo 174 rec', 10, 'USD', (date_trunc('month', now()) - interval '3 months')::date, true, 'dystopia')
  returning id into v_id;
  select count(*) into v_n from public.fin_v_gastos_mes where gasto_id = v_id;
  if v_n <> 4 then raise exception 'HUMO 174: el recurrente dio % filas y esperaba 4', v_n; end if;

  -- Sin permiso: un usuario inexistente no ve nada.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
  select count(*) into v_n from public.fin_v_gastos_mes;
  if v_n <> 0 then raise exception 'HUMO 174: un usuario sin acceso ve % filas de gastos', v_n; end if;
  select count(*) into v_n from public.fin_v_dys_mes;
  if v_n <> 0 then raise exception 'HUMO 174: un usuario sin acceso ve la seccion Dystopia'; end if;

  raise exception 'HUMO 174 OK';
end
$h$;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado).
-- Los que leen vistas necesitan ser fundador: en la misma ejecucion,
--   select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- =====================================================================

-- C1. Tablas, vistas y funciones creadas, y RLS prendida en las 3 tablas (esperado: 3 filas true).
-- select relname, relrowsecurity from pg_class where relname in ('fin_dys_acceso', 'fin_gasto_categorias', 'fin_gastos') order by 1;

-- C2. Categorias predeterminadas (esperado: 6, IA con clave 'ia').
-- select id, nombre, clave, activa, orden from public.fin_gasto_categorias order by orden;

-- C3. Porcentajes de la agencia (esperado: liam 30, agus 25, teo 40, o lo que ya hubiera).
-- select cliente_id, desde, hasta, porcentaje, nota from public.fin_comision_agencia order by cliente_id, desde;

-- C4. Mapa de ia_uso: cuanto cae a cada entidad y cuanto de Dystopia es "sin asignar" (esto es lo que hay que mirar).
-- select entidad, sin_asignar, proveedor, count(*) as llamadas, count(*) filter (where sin_costo) as sin_costo, round(sum(costo_usd), 2) as usd
--   from public.fin_ia_uso_norm group by 1, 2, 3 order by 1, 2, 3;

-- C5. Los valores de cliente_id que quedaron sin asignar (van a Dystopia; para saber que hay que arreglar en las apps).
-- select cliente_id, app, funcion, count(*) as llamadas, round(sum(costo_usd), 2) as usd
--   from public.ia_uso where lower(btrim(cliente_id::text)) not in ('liam', 'agus', 'teo', 'dystopia') or cliente_id is null
--  group by 1, 2, 3 order by 4 desc limit 30;

-- C6. Pantalla de IA: la tabla mes x entidad x proveedor (como fundador).
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, entidad, proveedor, sum(llamadas) as llamadas, sum(sin_costo) as sin_costo, sum(costo_usd) as usd
--   from public.fin_v_ia_uso_mes group by 1, 2, 3 order by 1 desc, 2, 3;

-- C7. Dystopia por mes: la base debe coincidir con fin_v_pnl_mensual.ingreso_real (como fundador).
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select d.mes, d.entidad, d.base_usd, d.porcentaje, d.ingreso_usd, d.gasto_dystopia_usd, d.gasto_ia_dystopia_usd, d.neto_usd,
--        p.ingreso_real as ingreso_real_pnl, d.base_usd - coalesce(p.ingreso_real, 0) as diferencia
--   from public.fin_v_dys_mes d
--   left join public.fin_v_pnl_mensual p on p.cliente_id = d.entidad and make_date(p.anio, p.mes, 1) = d.mes
--  order by d.mes desc, d.entidad;

-- C8. Nadie mas ve nada (usuario inexistente: esperado 0, 0, 0).
-- select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
-- select (select count(*) from public.fin_v_gastos_mes) as gastos, (select count(*) from public.fin_v_dys_mes) as dys,
--        (select count(*) from public.fin_v_ia_uso_mes) as ia;

-- C9. Las vistas internas no se leen desde la app (esperado: false, false).
-- select has_table_privilege('authenticated', 'public.fin_ia_uso_norm', 'select') as norm,
--        has_table_privilege('authenticated', 'public.fin_gastos_mes_base', 'select') as base;

-- C10. Ningun permiso para anon ni para public en tablas, vistas ni secuencias nuevas (esperado: 0 filas).
-- select c.relname, a.grantee, a.privilege_type
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--   cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
--  where n.nspname = 'public' and a.grantee in (0, (select oid from pg_roles where rolname = 'anon'))
--    and c.relname in ('fin_dys_acceso', 'fin_gasto_categorias', 'fin_gastos', 'fin_gasto_categorias_id_seq', 'fin_gastos_id_seq',
--                      'fin_ia_uso_norm', 'fin_gastos_mes_base', 'fin_v_ia_uso_mes', 'fin_v_gastos_mes', 'fin_v_dys_mes');

-- C11. Authenticated solo tiene lo previsto (esperado: tablas sin delete/truncate salvo fin_dys_acceso; vistas internas sin filas;
--      las 3 vistas publicas solo select).
-- select c.relname, a.privilege_type
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--   cross join lateral aclexplode(c.relacl) a
--  where n.nspname = 'public' and a.grantee = (select oid from pg_roles where rolname = 'authenticated')
--    and c.relname in ('fin_dys_acceso', 'fin_gasto_categorias', 'fin_gastos', 'fin_gasto_categorias_id_seq', 'fin_gastos_id_seq',
--                      'fin_ia_uso_norm', 'fin_gastos_mes_base', 'fin_v_ia_uso_mes', 'fin_v_gastos_mes', 'fin_v_dys_mes')
--  order by 1, 2;

-- C12. La IA sin asignar cae en Dystopia (como fundador): esperado, filas con sin_asignar = true en entidad dystopia, y su monto
--      incluido en gasto_ia_dystopia_usd de fin_v_dys_mes.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, entidad, sin_asignar, sum(llamadas) as llamadas, sum(costo_usd) as usd from public.fin_v_ia_uso_mes
--  group by 1, 2, 3 order by 1 desc, 2, 3;

-- =====================================================================
-- VUELTA ATRAS (no se corre salvo pedido). Las vistas se borran y se pueden recrear de este archivo.
-- Las TABLAS guardan datos cargados a mano: exportar fin_gastos y fin_gasto_categorias antes de borrarlas.
-- La siembra de fin_comision_agencia no se borra sola: delete from public.fin_comision_agencia where nota like '174:%';
-- =====================================================================
-- drop view if exists public.fin_v_dys_mes;
-- drop view if exists public.fin_v_gastos_mes;
-- drop view if exists public.fin_v_ia_uso_mes;
-- drop view if exists public.fin_gastos_mes_base;
-- drop view if exists public.fin_ia_uso_norm;
-- drop table if exists public.fin_gastos;
-- drop table if exists public.fin_gasto_categorias;
-- drop table if exists public.fin_dys_acceso;
-- drop function if exists public.fin_gastos_sello();
-- drop function if exists public.fin_dys_mi_acceso();
-- drop function if exists public.fin_gastos_puede_editar();
-- drop function if exists public.fin_gastos_puede_ver();
-- drop function if exists public.fin_dys_puede_ver();
-- drop function if exists public.fin_dys_acceso_de(text);
