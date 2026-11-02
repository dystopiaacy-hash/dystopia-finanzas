-- =====================================================================
-- 269_cierre_de_mes.sql
-- Apartado "Cierre de mes" (solo fundador): a quien hay que transferirle y cuanto, mes por mes.
-- Numero asignado por el jefe (2/11/2026). SIN CORRER, SQL NO PROBADO contra Postgres.
--
-- QUE AGREGA (todo nuevo; no borra ni pisa datos existentes, no toca la sync ni fin_pagos)
--   Tablas:  fin_cierre_meses (estado + foto del cierre), fin_cierre_log (quien cerro/reabrio y cuando),
--            fin_cierre_parametros (% por defecto de closer 10 / setter 5), fin_cierre_socios (reparto configurable),
--            fin_cierre_comision_persona (% por persona), fin_cierre_comision_venta (% por venta),
--            fin_cierre_transferencias (la lista de transferencias del mes, con "quien pago").
--   Vistas:  fin_v_cierre_ventas (detalle de ventas que componen cada comision), fin_v_cierre_avisos (que falta para cerrar).
--   Funciones: fin_cierre_generar(mes), fin_cierre_cerrar(mes, nota), fin_cierre_reabrir(mes, nota),
--              fin_cierre_bloquear() (trigger que frena la edicion de un mes cerrado).
--   Triggers: sobre fin_gastos y fin_webinar_gastos (por fecha), fin_cierre_transferencias y fin_cierre_comision_venta (por mes).
--
-- REGLAS
--   * Todo es solo fundador (es_fundador()), tambien las vistas (filtran adentro como las de la 267).
--   * Comision por pago (cash) de fin_pagos: closer 10% y setter 5% de monto_usd por defecto. Prioridad del %: el de la venta
--     (fin_cierre_comision_venta) > el de la persona (fin_cierre_comision_persona, de un cliente o de todos) > el por defecto.
--     Closer/setter salen de fin_pagos.closer/.setter; el alias se resuelve a la persona con fin_personas/fin_vendedores (009).
--     Se excluyen es_persona = false y asignaciones con comisiona = false. La venta se identifica por fin_pagos.clave (062).
--   * Ganancia neta de Dystopia = ganancia bruta - gastos propios (incluye el sueldo): sale de fin_v_dys_ganancia_mes (267),
--     que NO se toca. Se reparte entre fin_cierre_socios (Nacho 50 / Valen 50 al arrancar). Joaquin NO es socio: cobra el sueldo
--     que ya esta en fin_dys_gastos_fijos.
--   * fin_cierre_generar arma las lineas automaticas (sueldo, comisiones por persona y cliente, socios, cada cliente a Dystopia).
--     Es idempotente: actualiza las PENDIENTES, no toca monto/concepto de las HECHAS (solo guarda el monto calculado nuevo en
--     monto_calc para avisar la diferencia) y da de baja las pendientes que ya no corresponden (no las borra).
--   * Cerrar: genera, guarda la foto (jsonb) y bloquea. Reabrir deja registro en fin_cierre_log y en fin_cierre_meses.
--   * Bloqueo de un mes cerrado: por fecha del gasto (fin_gastos, fin_webinar_gastos) y por mes (transferencias, % por venta).
--     Un gasto recurrente se bloquea solo por el mes de su fecha de inicio. Cambios a porcentajes de Dystopia, sueldo o pagos
--     no se bloquean (no son del mes): la foto del cierre es la que vale para el mes cerrado.
--   * "Pago sin fuente" = fuente_ingreso (228) nula Y fuente_lead (209) vacia.
--   * Sin delete de datos: las bajas son logicas (activo). Los % por persona/venta si se pueden borrar (tablas nuevas, vuelven al por defecto).
--
-- Depende de: 001, 009 (vendedores/personas), 062 (clave), 174, 209, 228, 267. Falta es_fundador() => se frena.
-- ORDEN: BLOQUE 1 (guardas, tablas, RLS) > 2 (semillas) > 3 (vistas) > 4 (funciones) > 5 (triggers de bloqueo)
--   > 6 (humo, termina en ERROR "HUMO 269 OK" y se revierte solo) > controles C1.. de a uno > front.
--   Correr cada bloque por separado. No correr a las :00/:15/:30/:45 ni a las 9:00.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas, tablas, RLS
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.fin_pagos') is null then v_falta := v_falta || ' fin_pagos'; end if;
  if to_regclass('public.fin_gastos') is null then v_falta := v_falta || ' fin_gastos(174)'; end if;
  if to_regclass('public.fin_webinar_gastos') is null then v_falta := v_falta || ' fin_webinar_gastos(267)'; end if;
  if to_regclass('public.fin_dys_gastos_fijos') is null then v_falta := v_falta || ' fin_dys_gastos_fijos(267)'; end if;
  if to_regclass('public.fin_v_dys_ganancia_mes') is null then v_falta := v_falta || ' fin_v_dys_ganancia_mes(267)'; end if;
  if to_regclass('public.fin_vendedores') is null then v_falta := v_falta || ' fin_vendedores(009)'; end if;
  if to_regclass('public.fin_vendedor_asignaciones') is null then v_falta := v_falta || ' fin_vendedor_asignaciones(009)'; end if;
  if to_regclass('public.fin_personas') is null then v_falta := v_falta || ' fin_personas(009)'; end if;
  if to_regclass('public.crm_clients') is null then v_falta := v_falta || ' crm_clients'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if to_regprocedure('public.fin_normalizar_nombre(text)') is null then v_falta := v_falta || ' fin_normalizar_nombre(009)'; end if;
  if v_falta <> '' then raise exception 'GUARDA 269: faltan:%', v_falta; end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'fin_pagos'
         and column_name in ('clave', 'closer', 'setter', 'fuente_lead', 'fuente_ingreso', 'monto_usd', 'fecha', 'cliente_id', 'alumno')) <> 9 then
    raise exception 'GUARDA 269: fin_pagos no tiene clave, closer, setter, fuente_lead, fuente_ingreso, monto_usd, fecha, cliente_id y alumno';
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 15, 30, 45) then
    raise exception 'GUARDA 269: no correr en los minutos :00/:15/:30/:45 (corre la sync). Reintentar.';
  end if;
end
$g$;

-- Estado de cada mes y foto del cierre.
create table if not exists public.fin_cierre_meses (
  mes           date primary key check (mes = date_trunc('month', mes)::date),
  estado        text not null default 'abierto' check (estado in ('abierto', 'cerrado')),
  snapshot      jsonb,
  nota          text,
  cerrado_por   uuid,
  cerrado_en    timestamptz,
  reabierto_por uuid,
  reabierto_en  timestamptz,
  reaperturas   int not null default 0
);
comment on table public.fin_cierre_meses is '269: un mes cerrado bloquea gastos, transferencias y % por venta de ese mes. snapshot = foto de los totales al cerrar.';

create table if not exists public.fin_cierre_log (
  id     bigint generated always as identity primary key,
  mes    date not null,
  accion text not null check (accion in ('cerrar', 'reabrir')),
  por    uuid default auth.uid(),
  en     timestamptz not null default now(),
  nota   text
);

-- Parametros numericos (% de comision por defecto).
create table if not exists public.fin_cierre_parametros (
  clave text primary key,
  valor numeric not null check (valor >= 0 and valor <= 100),
  nota  text
);

-- Reparto de la ganancia neta de Dystopia (configurable: socios y %).
create table if not exists public.fin_cierre_socios (
  id         bigint generated always as identity primary key,
  nombre     text    not null check (btrim(nombre) <> ''),
  porcentaje numeric not null check (porcentaje > 0 and porcentaje <= 100),
  desde      date    not null,
  hasta      date,
  nota       text,
  activo     boolean not null default true,
  creado_por uuid default auth.uid(),
  creado_en  timestamptz not null default now(),
  constraint fin_cierre_socios_periodo_ck check (hasta is null or hasta >= desde)
);

-- % de comision por persona (de un cliente, o de todos si cliente_id es null).
create table if not exists public.fin_cierre_comision_persona (
  id           bigint generated always as identity primary key,
  cliente_id   text references public.crm_clients(id),
  persona      text not null check (btrim(persona) <> ''),
  persona_norm text generated always as (public.fin_normalizar_nombre(persona)) stored,
  rol          text not null check (rol in ('closer', 'setter')),
  porcentaje   numeric not null check (porcentaje >= 0 and porcentaje <= 100),
  nota         text,
  creado_por   uuid default auth.uid(),
  creado_en    timestamptz not null default now()
);
create unique index if not exists fin_cierre_comision_persona_uq
  on public.fin_cierre_comision_persona (coalesce(cliente_id, '*'), persona_norm, rol);

-- % de comision de una venta puntual (fin_pagos.clave + rol). mes = mes del pago (lo pone el front; lo usa el bloqueo).
create table if not exists public.fin_cierre_comision_venta (
  id         bigint generated always as identity primary key,
  mes        date not null check (mes = date_trunc('month', mes)::date),
  cliente_id text not null references public.crm_clients(id),
  pago_clave text not null,
  rol        text not null check (rol in ('closer', 'setter')),
  porcentaje numeric not null check (porcentaje >= 0 and porcentaje <= 100),
  nota       text,
  creado_por uuid default auth.uid(),
  creado_en  timestamptz not null default now(),
  unique (cliente_id, pago_clave, rol)
);

-- Lista de transferencias del mes. auto = la armo fin_cierre_generar (clave_auto estable por mes); manual = cargada a mano.
create table if not exists public.fin_cierre_transferencias (
  id            bigint generated always as identity primary key,
  mes           date not null check (mes = date_trunc('month', mes)::date),
  tipo          text not null check (tipo in ('sueldo', 'comision', 'editor', 'equipo', 'socio', 'cliente', 'otro')),
  destinatario  text not null check (btrim(destinatario) <> ''),
  concepto      text not null check (btrim(concepto) <> ''),
  monto_usd     numeric not null check (monto_usd >= 0),
  monto_calc    numeric,              -- ultimo monto que calculo el sistema (auto); si difiere de monto_usd en una hecha, se avisa
  cliente_id    text references public.crm_clients(id),
  pagador_tipo  text not null default 'dystopia' check (pagador_tipo in ('dystopia', 'cliente', 'otro')),
  pagador_texto text,
  estado        text not null default 'pendiente' check (estado in ('pendiente', 'hecha')),
  fecha_pago    date,
  comprobante   text,                 -- link (la app no tiene adjuntos para transferencias de cierre)
  nota          text,
  auto          boolean not null default false,
  clave_auto    text,
  activo        boolean not null default true,
  baja_manual   boolean not null default false,
  creado_por    uuid default auth.uid(),
  creado_en     timestamptz not null default now(),
  actualizado_en timestamptz,
  constraint fin_cierre_transf_pagador_ck check (pagador_tipo <> 'otro' or btrim(coalesce(pagador_texto, '')) <> ''),
  constraint fin_cierre_transf_hecha_ck check (estado <> 'hecha' or fecha_pago is not null),
  constraint fin_cierre_transf_auto_ck check (not auto or clave_auto is not null)
);
create unique index if not exists fin_cierre_transf_auto_uq on public.fin_cierre_transferencias (mes, clave_auto);
create index if not exists fin_cierre_transf_mes_idx on public.fin_cierre_transferencias (mes) where activo;

-- RLS: solo fundador. Sin delete en la lista de transferencias ni en meses/socios/log (bajas logicas);
-- los % por persona y por venta si se pueden borrar (vuelven al por defecto).
do $r$
declare t text;
begin
  foreach t in array array['fin_cierre_meses', 'fin_cierre_log', 'fin_cierre_parametros', 'fin_cierre_socios',
                           'fin_cierre_comision_persona', 'fin_cierre_comision_venta', 'fin_cierre_transferencias']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_sel', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.es_fundador()))', t || '_sel', t);
  end loop;
  -- el estado de los meses y el log se escriben SOLO por las funciones (security definer): el front los lee nada mas
  foreach t in array array['fin_cierre_meses', 'fin_cierre_log']
  loop
    execute format('grant select on table public.%I to authenticated', t);
  end loop;
  foreach t in array array['fin_cierre_parametros', 'fin_cierre_socios', 'fin_cierre_comision_persona', 'fin_cierre_comision_venta', 'fin_cierre_transferencias']
  loop
    execute format('grant select, insert, update on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_ins', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.es_fundador()))', t || '_ins', t);
    execute format('drop policy if exists %I on public.%I', t || '_upd', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.es_fundador())) with check ((select public.es_fundador()))', t || '_upd', t);
  end loop;
  foreach t in array array['fin_cierre_comision_persona', 'fin_cierre_comision_venta']
  loop
    execute format('grant delete on table public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_del', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.es_fundador()))', t || '_del', t);
  end loop;
  -- las secuencias de identity las usa quien inserta
  grant usage, select on all sequences in schema public to service_role;
end
$r$;
grant usage on sequence public.fin_cierre_socios_id_seq, public.fin_cierre_comision_persona_id_seq,
  public.fin_cierre_comision_venta_id_seq, public.fin_cierre_transferencias_id_seq to authenticated;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Semillas (solo INSERT, idempotente)
-- ---------------------------------------------------------------------
insert into public.fin_cierre_parametros (clave, valor, nota)
select v.c, v.m, v.n
  from (values ('comision_closer_pct', 10::numeric, '269: % por defecto del closer sobre cada venta (editable por persona y por venta)'),
               ('comision_setter_pct', 5::numeric,  '269: % por defecto del setter sobre cada venta (editable por persona y por venta)')) as v(c, m, n)
 where not exists (select 1 from public.fin_cierre_parametros p where p.clave = v.c);

insert into public.fin_cierre_socios (nombre, porcentaje, desde, nota)
select v.n, 50, date '2026-10-01', '269: reparto 50/50 de la ganancia neta de Dystopia (Joaquin no es socio: cobra sueldo)'
  from (values ('Nacho'), ('Valen')) as v(n)
 where not exists (select 1 from public.fin_cierre_socios s where lower(btrim(s.nombre)) = lower(v.n));

-- ---------------------------------------------------------------------
-- BLOQUE 3. Vistas (publicas: filtran por es_fundador() adentro; corren con permisos del dueño como las de la 267)
-- ---------------------------------------------------------------------
create or replace view public.fin_v_cierre_ventas as
with base as (
  select p.cliente_id, (date_trunc('month', p.fecha))::date as mes, coalesce(p.clave, 'id:' || p.id) as pago_clave,
         p.fecha, p.alumno, p.programa, p.concepto, p.monto_usd, p.closer, p.setter
    from public.fin_pagos p
   where p.cliente_id in ('liam', 'agus', 'teo') and public.es_fundador()
), roles as (
  select b.*, 'closer'::text as rol, b.closer as alias from base b
  union all
  select b.*, 'setter'::text as rol, b.setter as alias from base b
), res as (
  select r.*, nullif(btrim(r.alias), '') as alias_ok, v.nombre as vendedor, v.es_persona, ag.comisiona
    from roles r
    left join lateral (
      select vv.id, vv.nombre, vv.es_persona
        from public.fin_personas a
        join public.fin_vendedores vv on vv.id = a.vendedor_id
       where lower(btrim(a.alias)) = lower(btrim(r.alias))
         and (a.cliente_id = r.cliente_id or a.cliente_id is null)
         and (a.campo is null or a.campo in (r.rol, 'ambos'))
       order by (a.cliente_id is not null) desc
       limit 1) v on true
    left join lateral (
      select g.comisiona from public.fin_vendedor_asignaciones g
       where g.vendedor_id = v.id and g.cliente_id = r.cliente_id limit 1) ag on true
), calc as (
  select s.*,
         case when s.alias_ok is null then null else coalesce(s.vendedor, btrim(s.alias_ok)) end as persona,
         case when s.alias_ok is null then null else public.fin_normalizar_nombre(coalesce(s.vendedor, btrim(s.alias_ok))) end as persona_norm
    from res s
)
select c.mes, c.cliente_id, c.pago_clave, c.fecha, c.alumno, c.programa, c.concepto, c.monto_usd, c.rol,
       c.persona, c.persona_norm,
       (c.alias_ok is null) as falta_persona,
       (c.alias_ok is not null and (coalesce(c.es_persona, true) = false or coalesce(c.comisiona, true) = false)) as no_comisiona,
       (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct') as pct_base,
       (select cp.porcentaje from public.fin_cierre_comision_persona cp
         where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
         order by (cp.cliente_id is not null) desc limit 1) as pct_persona,
       cv.porcentaje as pct_venta,
       coalesce(cv.porcentaje,
                (select cp.porcentaje from public.fin_cierre_comision_persona cp
                  where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
                  order by (cp.cliente_id is not null) desc limit 1),
                (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct'), 0) as pct_aplicado,
       case when c.alias_ok is null or c.alias_ok is not null and (coalesce(c.es_persona, true) = false or coalesce(c.comisiona, true) = false) then 0
            else round(c.monto_usd * coalesce(cv.porcentaje,
                (select cp.porcentaje from public.fin_cierre_comision_persona cp
                  where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
                  order by (cp.cliente_id is not null) desc limit 1),
                (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct'), 0) / 100, 2) end as comision_usd
  from calc c
  left join public.fin_cierre_comision_venta cv on cv.cliente_id = c.cliente_id and cv.pago_clave = c.pago_clave and cv.rol = c.rol;

-- Que falta para cerrar, por mes: tipo, cliente, cantidad y monto.
create or replace view public.fin_v_cierre_avisos as
select (date_trunc('month', p.fecha))::date as mes, 'pago_sin_fuente'::text as tipo, p.cliente_id, count(*)::int as cantidad,
       coalesce(sum(p.monto_usd), 0) as monto_usd
  from public.fin_pagos p
 where p.cliente_id in ('liam', 'agus', 'teo') and p.fuente_ingreso is null and nullif(btrim(p.fuente_lead), '') is null
   and public.es_fundador()
 group by 1, 3
union all
select v.mes, case v.rol when 'closer' then 'sin_closer' else 'sin_setter' end, v.cliente_id, count(distinct v.pago_clave)::int,
       coalesce(sum(v.monto_usd), 0)
  from public.fin_v_cierre_ventas v
 where v.falta_persona
 group by v.mes, v.rol, v.cliente_id
union all
select g.mes, 'sin_gastos', g.entidad, 1, g.facturacion_usd
  from public.fin_v_dys_ganancia_mes g
 where g.sin_gastos and g.entidad <> 'dystopia'
union all
select g.mes, 'sin_porcentaje', g.entidad, 1, g.facturacion_usd
  from public.fin_v_dys_ganancia_mes g
 where g.falta_porcentaje and g.entidad <> 'dystopia' and g.facturacion_usd <> 0
union all
select t.mes, 'transferencia_pendiente', t.cliente_id, count(*)::int, coalesce(sum(t.monto_usd), 0)
  from public.fin_cierre_transferencias t
 where t.activo and t.estado = 'pendiente' and t.monto_usd > 0 and public.es_fundador()
 group by t.mes, t.cliente_id
union all
select t.mes, 'diferencia_con_calculo', t.cliente_id, count(*)::int, coalesce(sum(t.monto_calc - t.monto_usd), 0)
  from public.fin_cierre_transferencias t
 where t.activo and t.estado = 'hecha' and t.monto_calc is not null and t.monto_calc <> t.monto_usd and public.es_fundador()
 group by t.mes, t.cliente_id;

revoke all on public.fin_v_cierre_ventas, public.fin_v_cierre_avisos from public, anon, authenticated;
grant select on public.fin_v_cierre_ventas, public.fin_v_cierre_avisos to authenticated;
grant select on public.fin_v_cierre_ventas, public.fin_v_cierre_avisos to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 4. Funciones
-- ---------------------------------------------------------------------
-- Genera / actualiza las lineas automaticas de la lista de transferencias del mes. Devuelve cuantas lineas toco.
create or replace function public.fin_cierre_generar(p_mes date)
returns integer language plpgsql security definer set search_path = public as $f$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_bruta numeric; v_propio numeric; v_neta numeric; v_n int;
begin
  if not coalesce(public.es_fundador(), false) then raise exception 'Solo fundador'; end if;
  if exists (select 1 from public.fin_cierre_meses m where m.mes = v_mes and m.estado = 'cerrado') then
    raise exception 'El mes % esta cerrado: reabrirlo para recalcular', to_char(v_mes, 'YYYY-MM');
  end if;
  select coalesce(sum(g.ganancia_dystopia_usd), 0), coalesce(sum(g.gasto_propio_usd), 0) into v_bruta, v_propio
    from public.fin_v_dys_ganancia_mes g where g.mes = v_mes;
  v_neta := v_bruta - v_propio;

  with cand as (
    -- sueldo y demas gastos fijos vigentes en el mes
    select 'fijo:' || f.id as clave_auto,
           case when f.concepto ilike 'sueldo%' then 'sueldo' else 'equipo' end as tipo,
           coalesce(nullif(btrim(regexp_replace(f.concepto, '^sueldo\s*', '', 'i')), ''), f.concepto) as destinatario,
           f.concepto || ' ' || to_char(v_mes, 'YYYY-MM') as concepto,
           f.monto_usd as monto_usd, null::text as cliente_id, 'dystopia'::text as pagador_tipo
      from public.fin_dys_gastos_fijos f
     where f.activo and date_trunc('month', f.desde)::date <= v_mes
       and (f.hasta is null or date_trunc('month', f.hasta)::date >= v_mes)
    union all
    -- comisiones de closers y setters, una linea por persona y cliente
    select 'com:' || v.cliente_id || ':' || v.persona_norm, 'comision', min(v.persona),
           'Comisiones ' || to_char(v_mes, 'YYYY-MM') || ' (' || string_agg(distinct v.rol, ' + ') || ', '
             || count(distinct v.pago_clave) || ' ventas)',
           sum(v.comision_usd), v.cliente_id, 'dystopia'
      from public.fin_v_cierre_ventas v
     where v.mes = v_mes and v.persona_norm is not null and not v.no_comisiona
     group by v.cliente_id, v.persona_norm
    having sum(v.comision_usd) <> 0
    union all
    -- reparto de la ganancia neta entre socios
    select 'socio:' || s.id, 'socio', s.nombre,
           'Reparto de la ganancia neta ' || to_char(v_mes, 'YYYY-MM') || ' (' || s.porcentaje || '% de ' || round(v_neta, 2) || ')',
           round(v_neta * s.porcentaje / 100, 2), null::text, 'dystopia'
      from public.fin_cierre_socios s
     where s.activo and v_neta > 0 and date_trunc('month', s.desde)::date <= v_mes
       and (s.hasta is null or date_trunc('month', s.hasta)::date >= v_mes)
    union all
    -- lo que cada cliente le transfiere a Dystopia
    select 'cli:' || g.entidad, 'cliente', 'Dystopia',
           'Participacion de Dystopia ' || to_char(v_mes, 'YYYY-MM') || ' (' || coalesce(g.porcentaje, 0) || '% de la ganancia del cliente)',
           g.ganancia_dystopia_usd, g.entidad, 'cliente'
      from public.fin_v_dys_ganancia_mes g
     where g.mes = v_mes and g.entidad <> 'dystopia' and g.ganancia_dystopia_usd > 0
  ), ins as (
    insert into public.fin_cierre_transferencias as t
      (mes, tipo, destinatario, concepto, monto_usd, monto_calc, cliente_id, pagador_tipo, auto, clave_auto)
    select v_mes, c.tipo, c.destinatario, c.concepto, c.monto_usd, c.monto_usd, c.cliente_id, c.pagador_tipo, true, c.clave_auto
      from cand c
    on conflict (mes, clave_auto) do update
      set monto_calc = excluded.monto_usd,
          monto_usd = case when t.estado = 'pendiente' then excluded.monto_usd else t.monto_usd end,
          concepto = case when t.estado = 'pendiente' then excluded.concepto else t.concepto end,
          destinatario = case when t.estado = 'pendiente' then excluded.destinatario else t.destinatario end,
          activo = case when t.estado = 'pendiente' and not t.baja_manual then true else t.activo end,
          actualizado_en = now()
    returning 1
  ), baja as (
    update public.fin_cierre_transferencias t
       set activo = false, actualizado_en = now()
     where t.mes = v_mes and t.auto and t.estado = 'pendiente' and t.activo
       and not exists (select 1 from cand c where c.clave_auto = t.clave_auto)
    returning 1
  )
  select (select count(*) from ins) + (select count(*) from baja) into v_n;
  return v_n;
end
$f$;

create or replace function public.fin_cierre_cerrar(p_mes date, p_nota text default null)
returns void language plpgsql security definer set search_path = public as $f$
declare
  v_mes date := date_trunc('month', p_mes)::date;
  v_snap jsonb; v_bruta numeric; v_propio numeric;
begin
  if not coalesce(public.es_fundador(), false) then raise exception 'Solo fundador'; end if;
  if v_mes > (date_trunc('month', now() at time zone 'America/Argentina/Buenos_Aires'))::date then
    raise exception 'No se puede cerrar un mes que todavia no empezo';
  end if;
  if exists (select 1 from public.fin_cierre_meses m where m.mes = v_mes and m.estado = 'cerrado') then
    raise exception 'El mes % ya esta cerrado', to_char(v_mes, 'YYYY-MM');
  end if;
  perform public.fin_cierre_generar(v_mes);
  select coalesce(sum(g.ganancia_dystopia_usd), 0), coalesce(sum(g.gasto_propio_usd), 0) into v_bruta, v_propio
    from public.fin_v_dys_ganancia_mes g where g.mes = v_mes;
  v_snap := jsonb_build_object(
    'mes', v_mes, 'cerrado_en', now(),
    'bruta_usd', v_bruta, 'gasto_propio_usd', v_propio, 'neta_usd', v_bruta - v_propio,
    'clientes', coalesce((select jsonb_agg(to_jsonb(g) order by g.entidad) from public.fin_v_dys_ganancia_mes g
                           where g.mes = v_mes and g.entidad <> 'dystopia'), '[]'::jsonb),
    'comisiones', coalesce((select jsonb_agg(to_jsonb(c) order by c.cliente_id, c.persona, c.fecha) from public.fin_v_cierre_ventas c
                             where c.mes = v_mes and c.persona_norm is not null), '[]'::jsonb),
    'transferencias', coalesce((select jsonb_agg(to_jsonb(t) order by t.tipo, t.destinatario) from public.fin_cierre_transferencias t
                                 where t.mes = v_mes and t.activo), '[]'::jsonb),
    'avisos', coalesce((select jsonb_agg(to_jsonb(a)) from public.fin_v_cierre_avisos a where a.mes = v_mes), '[]'::jsonb));
  insert into public.fin_cierre_meses as m (mes, estado, snapshot, nota, cerrado_por, cerrado_en)
  values (v_mes, 'cerrado', v_snap, p_nota, auth.uid(), now())
  on conflict (mes) do update
    set estado = 'cerrado', snapshot = excluded.snapshot, nota = excluded.nota, cerrado_por = excluded.cerrado_por, cerrado_en = excluded.cerrado_en
    where m.estado = 'abierto';
  insert into public.fin_cierre_log (mes, accion, nota) values (v_mes, 'cerrar', p_nota);
end
$f$;

create or replace function public.fin_cierre_reabrir(p_mes date, p_nota text default null)
returns void language plpgsql security definer set search_path = public as $f$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not coalesce(public.es_fundador(), false) then raise exception 'Solo fundador'; end if;
  update public.fin_cierre_meses m
     set estado = 'abierto', reabierto_por = auth.uid(), reabierto_en = now(), reaperturas = m.reaperturas + 1
   where m.mes = v_mes and m.estado = 'cerrado';
  if not found then raise exception 'El mes % no esta cerrado', to_char(v_mes, 'YYYY-MM'); end if;
  insert into public.fin_cierre_log (mes, accion, nota) values (v_mes, 'reabrir', p_nota);
end
$f$;

-- Trigger de bloqueo: TG_ARGV[0] = nombre de la columna date que fija el mes (fecha o mes).
create or replace function public.fin_cierre_bloquear()
returns trigger language plpgsql security definer set search_path = public as $f$
declare v_col text := tg_argv[0]; v_f date; v_o date; v_n date;
begin
  if tg_op <> 'INSERT' then v_o := (to_jsonb(old) ->> v_col)::date; end if;
  if tg_op <> 'DELETE' then v_n := (to_jsonb(new) ->> v_col)::date; end if;
  foreach v_f in array array[v_o, v_n] loop
    if v_f is not null and exists (select 1 from public.fin_cierre_meses m
                                    where m.mes = date_trunc('month', v_f)::date and m.estado = 'cerrado') then
      raise exception 'El mes % esta cerrado: reabrirlo en Cierre de mes para editar', to_char(v_f, 'YYYY-MM');
    end if;
  end loop;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end
$f$;

revoke all on function public.fin_cierre_generar(date), public.fin_cierre_cerrar(date, text), public.fin_cierre_reabrir(date, text),
  public.fin_cierre_bloquear() from public, anon;
grant execute on function public.fin_cierre_generar(date), public.fin_cierre_cerrar(date, text), public.fin_cierre_reabrir(date, text) to authenticated;

-- ---------------------------------------------------------------------
-- BLOQUE 5. Triggers de bloqueo (agregar un trigger toma un lock corto sobre cada tabla: sin lock_timeout largo)
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';
lock table public.fin_gastos, public.fin_webinar_gastos, public.fin_cierre_transferencias, public.fin_cierre_comision_venta in share row exclusive mode;
drop trigger if exists fin_cierre_bloq on public.fin_gastos;
create trigger fin_cierre_bloq before insert or update or delete on public.fin_gastos
  for each row execute function public.fin_cierre_bloquear('fecha');
drop trigger if exists fin_cierre_bloq on public.fin_webinar_gastos;
create trigger fin_cierre_bloq before insert or update or delete on public.fin_webinar_gastos
  for each row execute function public.fin_cierre_bloquear('fecha');
drop trigger if exists fin_cierre_bloq on public.fin_cierre_transferencias;
create trigger fin_cierre_bloq before insert or update or delete on public.fin_cierre_transferencias
  for each row execute function public.fin_cierre_bloquear('mes');
drop trigger if exists fin_cierre_bloq on public.fin_cierre_comision_venta;
create trigger fin_cierre_bloq before insert or update or delete on public.fin_cierre_comision_venta
  for each row execute function public.fin_cierre_bloquear('mes');
commit;

-- ---------------------------------------------------------------------
-- BLOQUE 6. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 269 OK"). No usa las funciones con es_fundador().
-- ---------------------------------------------------------------------
do $h$
begin
  insert into public.fin_cierre_meses (mes, estado) values (date '2099-01-01', 'cerrado');
  -- 1. un mes cerrado frena transferencias
  begin
    insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd) values (date '2099-01-01', 'otro', 'HUMO', 'HUMO 269', 1);
    raise exception 'HUMO 269: dejo cargar una transferencia en un mes cerrado';
  exception when raise_exception then
    if sqlerrm like 'HUMO 269%' then raise; end if;
  end;
  -- 2. en un mes abierto si deja, y las reglas de la tabla se cumplen
  update public.fin_cierre_meses set estado = 'abierto' where mes = date '2099-01-01';
  insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd) values (date '2099-01-01', 'otro', 'HUMO', 'HUMO 269', 1);
  begin
    insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd, pagador_tipo) values (date '2099-01-01', 'otro', 'HUMO', 'sin texto', 1, 'otro');
    raise exception 'HUMO 269: acepto "otro" sin texto';
  exception when check_violation then null;
  end;
  begin
    insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd, estado) values (date '2099-01-01', 'otro', 'HUMO', 'hecha sin fecha', 1, 'hecha');
    raise exception 'HUMO 269: acepto una hecha sin fecha de pago';
  exception when check_violation then null;
  end;
  begin
    insert into public.fin_cierre_comision_venta (mes, cliente_id, pago_clave, rol, porcentaje) values (date '2099-01-01', 'liam', 'humo#1', 'closer', 101);
    raise exception 'HUMO 269: acepto un porcentaje mayor a 100';
  exception when check_violation then null;
  end;
  -- 3. cerrar de nuevo frena fin_gastos de ese mes
  update public.fin_cierre_meses set estado = 'cerrado' where mes = date '2099-01-01';
  begin
    insert into public.fin_gastos (entidad, categoria_id, descripcion, monto, moneda, fecha, reparto)
    select 'dystopia', (select min(id) from public.fin_gasto_categorias), 'HUMO 269', 1, 'USD', date '2099-01-15', 'dystopia';
    raise exception 'HUMO 269: dejo cargar un gasto en un mes cerrado';
  exception when raise_exception then
    if sqlerrm like 'HUMO 269%' then raise; end if;
  end;
  if (select count(*) from public.fin_cierre_socios where activo) < 2 then raise exception 'HUMO 269: faltan los socios'; end if;
  if (select count(*) from public.fin_cierre_parametros) < 2 then raise exception 'HUMO 269: faltan los porcentajes por defecto'; end if;
  raise exception 'HUMO 269 OK';
end
$h$;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno; las vistas y funciones piden fundador: poner el uuid de un fundador en la misma ejecucion)
-- ---------------------------------------------------------------------
-- C1. Tablas y semillas. Esperado: socios 2 (Nacho 50, Valen 50), parametros 2 (10 y 5), meses 0, transferencias 0.
-- select (select count(*) from public.fin_cierre_socios where activo) as socios, (select sum(porcentaje) from public.fin_cierre_socios where activo) as suma_pct,
--        (select count(*) from public.fin_cierre_parametros) as parametros, (select count(*) from public.fin_cierre_meses) as meses,
--        (select count(*) from public.fin_cierre_transferencias) as transferencias;
-- C2. Triggers y policies. Esperado: 4 triggers fin_cierre_bloq y 7 tablas con RLS.
-- select (select count(*) from pg_trigger where tgname = 'fin_cierre_bloq' and not tgisinternal) as triggers,
--        (select count(*) from pg_tables where schemaname = 'public' and tablename like 'fin_cierre_%' and rowsecurity) as tablas_rls;
-- C3. Permisos: anon y public no pueden nada. Esperado: 0 filas.
-- select grantee, table_name, privilege_type from information_schema.role_table_grants
--  where table_schema = 'public' and table_name like 'fin_cierre_%' and grantee in ('anon', 'PUBLIC');
-- C4. Octubre: ventas que componen las comisiones, por persona y rol (cambiar el uuid).
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select persona, rol, count(*) as ventas, sum(monto_usd) as base, sum(comision_usd) as comision, min(pct_aplicado) as pct_min, max(pct_aplicado) as pct_max
--   from public.fin_v_cierre_ventas where mes = date '2026-10-01' and persona is not null group by 1, 2 order by 1, 2;
-- C5. Octubre: avisos de lo que falta.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select tipo, cliente_id, cantidad, monto_usd from public.fin_v_cierre_avisos where mes = date '2026-10-01' order by tipo, cliente_id;
-- C6. Generar las transferencias de octubre (ESCRIBE en fin_cierre_transferencias) y listarlas. Esperado: sueldo 1.000, socios 50/50 de la neta, un renglon por cliente.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select public.fin_cierre_generar(date '2026-10-01');
-- C7. Lista de octubre.
-- select tipo, destinatario, cliente_id, monto_usd, pagador_tipo, estado from public.fin_cierre_transferencias where mes = date '2026-10-01' and activo order by tipo, destinatario;
-- C8. Vuelta atras (solo si hace falta; las tablas son nuevas): drop trigger fin_cierre_bloq on public.fin_gastos / fin_webinar_gastos / fin_cierre_transferencias /
--     fin_cierre_comision_venta; drop function fin_cierre_generar(date), fin_cierre_cerrar(date, text), fin_cierre_reabrir(date, text), fin_cierre_bloquear();
--     drop view fin_v_cierre_avisos, fin_v_cierre_ventas; drop table fin_cierre_transferencias, fin_cierre_comision_venta, fin_cierre_comision_persona,
--     fin_cierre_socios, fin_cierre_parametros, fin_cierre_log, fin_cierre_meses;
