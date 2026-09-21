-- 003_vistas.sql — Dystopia Finanzas: las 5 vistas.
-- Todas con security_invoker = true: la RLS de las tablas se aplica con el
-- usuario que consulta. Ninguna vista expone fin_reparto ni
-- fin_comision_agencia. Idempotente (create or replace).
-- Requiere 001_esquema_fin.sql. cs_hoy() ya existe (Seguimiento).

begin;

-- ---------------------------------------------------------------------------
-- fin_v_pnl_mensual: P&L por cliente y mes, con el ingreso real (fin_pagos)
-- al lado del declarado en Opps. Solo fundador y cliente (closer/setter no
-- ven P&L en ninguna forma; el filtro por rol lo hace explicito ademas de la
-- RLS de fin_pnl).
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_pnl_mensual
with (security_invoker = true) as
with pnl as (
  select cliente_id, anio, mes,
         sum(monto_usd) filter (where categoria = 'revenue')   as revenue_declarado,
         sum(monto_usd) filter (where categoria = 'staff')     as staff,
         sum(monto_usd) filter (where categoria = 'softwares') as softwares,
         sum(monto_usd) filter (where categoria = 'others')    as others,
         sum(monto_usd) filter (where categoria <> 'revenue')  as gastos_total
  from public.fin_pnl
  group by cliente_id, anio, mes
),
pagos as (
  select cliente_id,
         extract(year from fecha)::int  as anio,
         extract(month from fecha)::int as mes,
         sum(monto_usd) as ingreso_real,
         count(*)       as cantidad_pagos
  from public.fin_pagos
  group by 1, 2, 3
)
select coalesce(p.cliente_id, g.cliente_id) as cliente_id,
       coalesce(p.anio, g.anio)             as anio,
       coalesce(p.mes, g.mes)               as mes,
       coalesce(p.revenue_declarado, 0)     as revenue_declarado,
       coalesce(g.ingreso_real, 0)          as ingreso_real,
       coalesce(g.cantidad_pagos, 0)        as cantidad_pagos,
       coalesce(p.staff, 0)                 as staff,
       coalesce(p.softwares, 0)             as softwares,
       coalesce(p.others, 0)                as others,
       coalesce(p.gastos_total, 0)          as gastos_total,
       coalesce(p.revenue_declarado, 0) - coalesce(p.gastos_total, 0) as net_cash_flow,
       s.opening_balance,
       s.closing_balance,
       s.dividends_released
from pnl p
full join pagos g
  on g.cliente_id = p.cliente_id and g.anio = p.anio and g.mes = p.mes
left join public.fin_pnl_saldos s
  on s.cliente_id = coalesce(p.cliente_id, g.cliente_id)
 and s.anio = coalesce(p.anio, g.anio)
 and s.mes = coalesce(p.mes, g.mes)
where public.es_fundador() or public.rol_actual() = 'cliente';

-- ---------------------------------------------------------------------------
-- fin_v_conciliacion: Total Revenue de Opps contra la suma de fin_pagos del
-- mismo mes. diferencia > 0: Opps declara mas de lo que figura en Pagos.
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_conciliacion
with (security_invoker = true) as
with opps as (
  select cliente_id, anio, mes, sum(monto_usd) as revenue_opps
  from public.fin_pnl
  where categoria = 'revenue'
  group by 1, 2, 3
),
pagos as (
  select cliente_id,
         extract(year from fecha)::int  as anio,
         extract(month from fecha)::int as mes,
         sum(monto_usd) as revenue_pagos,
         count(*)       as cantidad_pagos
  from public.fin_pagos
  group by 1, 2, 3
)
select coalesce(o.cliente_id, p.cliente_id) as cliente_id,
       coalesce(o.anio, p.anio)             as anio,
       coalesce(o.mes, p.mes)               as mes,
       coalesce(o.revenue_opps, 0)          as revenue_opps,
       coalesce(p.revenue_pagos, 0)         as revenue_pagos,
       coalesce(p.cantidad_pagos, 0)        as cantidad_pagos,
       round(coalesce(o.revenue_opps, 0) - coalesce(p.revenue_pagos, 0), 2) as diferencia,
       case when coalesce(o.revenue_opps, 0) = 0 then null
            else round((coalesce(o.revenue_opps, 0) - coalesce(p.revenue_pagos, 0)) / o.revenue_opps * 100, 1)
       end as diferencia_pct
from opps o
full join pagos p
  on p.cliente_id = o.cliente_id and p.anio = o.anio and p.mes = o.mes
where public.es_fundador() or public.rol_actual() = 'cliente';

-- ---------------------------------------------------------------------------
-- fin_v_ranking_closers: cierres y monto por closer y por mes.
-- cierre = alumno distinto con un pago cuyo concepto contiene FEE o PIF
-- (supuesto a validar con la agencia). Un closer ve solo sus filas (RLS).
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_ranking_closers
with (security_invoker = true) as
select cliente_id,
       extract(year from fecha)::int  as anio,
       extract(month from fecha)::int as mes,
       btrim(closer)                  as closer,
       count(*)                       as pagos,
       count(distinct lower(btrim(alumno))) filter (
         where concepto ilike '%FEE%' or concepto ilike '%PIF%') as cierres,
       sum(monto_usd)                 as monto_usd
from public.fin_pagos
where closer is not null and btrim(closer) <> ''
group by 1, 2, 3, 4;

-- ---------------------------------------------------------------------------
-- fin_v_cobranzas: cuotas pendientes con dias al vencimiento.
-- pendiente = estado vacio o distinto de pagado/churn/pausado/cancelado
-- (supuesto a validar). Setter no ve cuotas (RLS de fin_cuotas).
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_cobranzas
with (security_invoker = true) as
select c.id,
       c.cliente_id,
       c.alumno,
       c.telefono,
       c.programa,
       c.numero_cuota,
       c.tipo_cuota,
       c.monto,
       c.monto_cobrado,
       c.fecha_pago,
       c.estado,
       c.closer,
       c.contexto,
       c.fila_planilla,
       c.fecha_pago - public.cs_hoy()                          as dias_al_vencimiento,
       (c.fecha_pago is not null and c.fecha_pago < public.cs_hoy()) as vencida
from public.fin_cuotas c
where c.estado is null
   or lower(btrim(c.estado)) not in ('pagado', 'pagada', 'cuota pagada', 'churn', 'pausado', 'cancelado');

-- ---------------------------------------------------------------------------
-- fin_v_salud_sync: ultima corrida por fuente (solo fundador, por la RLS de
-- fin_sync_corridas y fin_fuentes).
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_salud_sync
with (security_invoker = true) as
select f.id as fuente_id,
       f.cliente_id,
       f.tipo,
       f.nombre_hoja_esperado,
       f.activo,
       c.id as corrida_id,
       c.inicio,
       c.fin,
       c.estado,
       c.filas_leidas,
       c.filas_cargadas,
       c.filas_rechazadas,
       c.filas_descartadas,
       c.mensaje,
       now() - c.inicio as antiguedad
from public.fin_fuentes f
left join lateral (
  select * from public.fin_sync_corridas sc
  where sc.fuente_id = f.id
  order by sc.inicio desc
  limit 1
) c on true;

-- ---------------------------------------------------------------------------
-- Permisos: anon nada; authenticated SELECT (la RLS filtra).
-- ---------------------------------------------------------------------------
do $$
declare v text;
begin
  foreach v in array array['fin_v_pnl_mensual', 'fin_v_conciliacion', 'fin_v_ranking_closers', 'fin_v_cobranzas', 'fin_v_salud_sync']
  loop
    execute format('revoke all on public.%I from anon, public', v);
    execute format('revoke all on public.%I from authenticated', v);
    execute format('grant select on public.%I to authenticated', v);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Prueba de humo (se autorrevierte): un mes con Opps 1000 y Pagos 900 en 2027-12 (mes sin datos reales).
-- En el SQL Editor no hay sesion de usuario, asi que es_fundador() deberia
-- dar false y la vista no mostrar la fila (filtro por rol). Si la muestra,
-- la diferencia tiene que ser 100.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fuente bigint;
  v_n      int;
  v_dif    numeric;
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, anio, tope_monto)
    values ('liam', 'SMOKE_TEST', 1, 'Smoke', 'opps', 2026, null)
    returning id into v_fuente;
    insert into public.fin_pnl (cliente_id, fuente_id, anio, mes, categoria, item, monto_usd, fila_planilla, columna_planilla)
    values ('liam', v_fuente, 2027, 12, 'revenue', 'ventas', 1000, 7, 5);
    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, monto_usd, monto_origen, moneda_origen)
    values ('liam', v_fuente, 2, date '2027-12-10', 'Smoke', 900, 900, 'USD');

    select diferencia into v_dif from public.fin_v_conciliacion
    where cliente_id = 'liam' and anio = 2027 and mes = 12;
    if v_dif is null then
      raise notice 'smoke 003: fin_v_conciliacion oculta filas sin sesion (filtro por rol activo)';
    elsif v_dif <> 100 then
      raise exception 'smoke: fin_v_conciliacion dio % y se esperaba 100', v_dif;
    end if;

    select count(*) into v_n from public.fin_v_salud_sync where fuente_id = v_fuente;
    if v_n <> 1 then raise exception 'smoke: fin_v_salud_sync no devuelve la fuente'; end if;

    select count(*) into v_n from public.fin_v_ranking_closers;  -- que compile y corra
    select count(*) into v_n from public.fin_v_cobranzas;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 003: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control: las 5 vistas con security_invoker.
-- ---------------------------------------------------------------------------
select c.relname as vista,
       coalesce(c.reloptions::text, '') like '%security_invoker=true%' as security_invoker,
       has_table_privilege('anon', c.oid, 'select') as anon_lee
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'v' and c.relname like 'fin\_v\_%'
order by c.relname;

commit;
