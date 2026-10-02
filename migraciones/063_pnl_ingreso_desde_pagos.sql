-- =====================================================================
-- 063_pnl_ingreso_desde_pagos.sql
-- FINANZAS, fase 2 (decision V2, FASE0-FINANZAS.md).
--
-- Hasta ahora el net cash flow del P&L era:
--   revenue declarado en Opps (tipeado a mano) - gastos de Opps.
-- Desde esta migracion es:
--   ingreso real (suma de fin_pagos por fecha de pago) - gastos de Opps,
--   desde el primer pago cargado de cada cliente. Los meses anteriores
--   (la hoja de Pagos todavia no existia) siguen usando Opps.
--   La columna fuente_ingreso dice cual se uso: 'pagos' u 'opps'.
--
-- Por que: el "ventas" de Opps es la suma de Pagos copiada a mano y en
-- agus y lucas esta en el mes equivocado (agus mete 73.844,50 USD de mas
-- en el ano). Pagos tiene la fecha real de cada cobro.
--
-- revenue_declarado sigue en la vista como referencia, y se agregan al
-- final diferencia_opps = revenue_declarado - ingreso_real (alerta de
-- conciliacion) y fuente_ingreso.
--
-- OJO agus: su Opps tiene julio en el bloque JANUARY y agosto en
-- FEBRUARY. Como su primer pago es de julio, enero y febrero usan Opps y
-- esos ingresos se cuentan dos veces hasta que la agencia corrija los
-- rotulos (punto 3 del mensaje). Hoy pasa lo mismo, no es nuevo. Mismas columnas, mismo orden, misma seguridad:
-- las pantallas actuales siguen funcionando sin cambios de codigo.
--
-- Idempotente. Probada dos veces contra Postgres local con el esquema
-- real y los pagos del export del 2026-10-02.
-- =====================================================================

create or replace view public.fin_v_pnl_mensual
with (security_invoker = true) as
with pnl as (
  select cliente_id, anio, mes,
         sum(monto_usd) filter (where categoria = 'revenue')   as revenue_declarado,
         sum(monto_usd) filter (where categoria = 'staff')     as staff,
         sum(monto_usd) filter (where categoria = 'softwares') as softwares,
         sum(monto_usd) filter (where categoria = 'others')    as others,
         sum(monto_usd) filter (where categoria = 'sin_categoria') as sin_categoria,
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
),
inicio as (
  -- Primer pago cargado de cada cliente. Antes de ese mes la hoja de
  -- Pagos no existia (liam arranca en febrero, teo en marzo, lucas en
  -- abril, agus en julio) y el unico dato de ingreso es Opps.
  select cliente_id, date_trunc('month', min(fecha))::date as primer_mes
  from public.fin_pagos
  group by 1
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
       coalesce(p.sin_categoria, 0)         as sin_categoria,
       coalesce(p.gastos_total, 0)          as gastos_total,
       case when make_date(coalesce(p.anio, g.anio), coalesce(p.mes, g.mes), 1) < i.primer_mes
                 or i.primer_mes is null
            then coalesce(p.revenue_declarado, 0)
            else coalesce(g.ingreso_real, 0)
       end - coalesce(p.gastos_total, 0) as net_cash_flow,   -- 063: ingreso de Pagos desde el primer pago
       s.opening_balance,
       s.closing_balance,
       s.dividends_released,
       round(coalesce(p.revenue_declarado, 0) - coalesce(g.ingreso_real, 0), 2) as diferencia_opps,   -- 063
       case when make_date(coalesce(p.anio, g.anio), coalesce(p.mes, g.mes), 1) < i.primer_mes
                 or i.primer_mes is null
            then 'opps' else 'pagos'
       end as fuente_ingreso   -- 063
from pnl p
full join pagos g
  on g.cliente_id = p.cliente_id and g.anio = p.anio and g.mes = p.mes
left join public.fin_pnl_saldos s
  on s.cliente_id = coalesce(p.cliente_id, g.cliente_id)
 and s.anio = coalesce(p.anio, g.anio)
 and s.mes = coalesce(p.mes, g.mes)
left join inicio i
  on i.cliente_id = coalesce(p.cliente_id, g.cliente_id)
where public.es_fundador() or public.rol_actual() = 'cliente';

comment on column public.fin_v_pnl_mensual.net_cash_flow is
  '063: ingreso real (fin_pagos) - gastos (Opps). Ya no usa el revenue declarado en Opps.';
comment on column public.fin_v_pnl_mensual.fuente_ingreso is
  '063: pagos = el net usa fin_pagos; opps = mes anterior al primer pago cargado, usa el revenue de Opps.';
comment on column public.fin_v_pnl_mensual.diferencia_opps is
  '063: revenue declarado en Opps - ingreso real. Distinto de 0 = Opps y Pagos no cuadran.';

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. La vista nueva quedo arriba: las 2 en true.
-- select pg_get_viewdef('public.fin_v_pnl_mensual'::regclass) like '%COALESCE(g.ingreso_real, (0)::numeric) - COALESCE(p.gastos_total%' as net_desde_pagos,
--        (select count(*) from information_schema.columns
--          where table_name = 'fin_v_pnl_mensual'
--            and column_name in ('diferencia_opps', 'fuente_ingreso')) = 2 as columnas_nuevas;

-- C2. Una fila por cliente con el mes donde arranca Pagos. Esperado:
--     liam 2026-02, teo 2026-03, lucas 2026-04, agus 2026-07 y mauro 2025-12.
-- select cliente_id, min(make_date(anio, mes, 1)) as primer_mes_pagos
--   from public.fin_v_pnl_mensual
--  where fuente_ingreso = 'pagos'
--  group by 1 order by 1;

-- C3. liam y teo por mes. Esperado: liam mes 1 y teo meses 1 y 2 con
--     fuente_ingreso 'opps' y net positivo; el resto 'pagos'.
-- select cliente_id, mes, fuente_ingreso, revenue_declarado, ingreso_real,
--        gastos_total, net_cash_flow, diferencia_opps
--   from public.fin_v_pnl_mensual
--  where cliente_id in ('liam', 'teo') and anio = 2026
--  order by 1, 2;
