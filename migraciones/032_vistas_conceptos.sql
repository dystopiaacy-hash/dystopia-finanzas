-- ============================================================================
-- Migración 032: vistas de desglose por concepto (torta de cash collected)
-- Proyecto: Dystopia Finanzas
-- Fecha: 2026-09-25
-- Depende de: 031 (fin_conceptos, fin_categoria_concepto)
--
-- Controles de la 031 verificados antes de escribir esta migración:
--   catálogo  30 filas globales (11 / 1 / 17 / 1)
--   fin_pagos 1471 venta_nueva, 102 producto, 34 cuota, 14 sin_clasificar = 1621
--
-- Qué crea:
--   1. fin_v_pagos_categoria        fila a fila, sin datos personales
--   2. fin_v_cash_collected_concepto  agregado por cliente / mes / categoría  <- la torta
--   3. fin_v_conceptos_desconocidos   los que caen en sin_clasificar sin estar en el catálogo
--
-- Las tres con security_invoker = true: respetan la RLS de fin_pagos, así que
-- cada rol ve lo mismo que ya ve hoy. anon revocado.
--
-- Nota sobre refunds: fin_pagos.estado existe pero todavía no sé qué valores
-- toma. Las vistas NO filtran por estado y exponen la columna tal cual, para
-- que puedas verlo en el CONTROL 1. Si hay que descontar refunds de la torta,
-- va en la 033 con la decisión tomada, no adivinada acá.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Fila a fila con la categoría resuelta.
--    Sin alumno ni teléfono: esta vista es para agregar y auditar, no para
--    listar personas. Si el front necesita el detalle del alumno, ya tiene
--    fin_pagos.
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_pagos_categoria
with (security_invoker = true) as
select
  p.id,
  p.cliente_id,
  p.fecha,
  date_trunc('month', p.fecha)::date            as mes_inicio,
  extract(year  from p.fecha)::int               as anio,
  extract(month from p.fecha)::int               as mes,
  p.programa,
  p.concepto                                     as concepto_original,
  public.fin_normalizar_concepto(p.concepto)     as concepto_norm,
  public.fin_categoria_concepto(p.cliente_id, p.concepto) as categoria,
  p.monto_usd,
  p.moneda_origen,
  p.estado,
  p.fuente_id,
  p.fila_planilla
from public.fin_pagos p;

comment on view public.fin_v_pagos_categoria is
  'fin_pagos + categoría de concepto resuelta. Sin alumno ni teléfono. security_invoker.';

-- ---------------------------------------------------------------------------
-- 2. La torta: agregado por cliente, mes y categoría.
--    Cuatro porciones posibles: venta_nueva, cuota, producto, sin_clasificar.
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_cash_collected_concepto
with (security_invoker = true) as
select
  v.cliente_id,
  v.anio,
  v.mes,
  v.mes_inicio,
  v.categoria,
  count(*)                              as pagos,
  sum(v.monto_usd)                      as monto_usd,
  min(v.fecha)                          as primer_pago,
  max(v.fecha)                          as ultimo_pago
from public.fin_v_pagos_categoria v
group by v.cliente_id, v.anio, v.mes, v.mes_inicio, v.categoria;

comment on view public.fin_v_cash_collected_concepto is
  'Cash collected agregado por cliente / mes / categoría de concepto. Fuente de la torta.';

-- ---------------------------------------------------------------------------
-- 3. Conceptos que llegaron desde la planilla y no están en el catálogo.
--    Hoy tiene que dar 0 filas. Cuando devuelva algo, es un concepto nuevo
--    que alguien escribió en el Sheet y hay que clasificar a mano.
--    De acá va a leer la alerta de Discord en la 033.
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_conceptos_desconocidos
with (security_invoker = true) as
select
  public.fin_normalizar_concepto(p.concepto) as concepto_norm,
  p.cliente_id,
  count(*)         as pagos,
  sum(p.monto_usd) as monto_usd,
  min(p.fecha)     as primer_pago,
  max(p.fecha)     as ultimo_pago
from public.fin_pagos p
where not exists (
  select 1
  from public.fin_conceptos c
  where c.concepto_norm = public.fin_normalizar_concepto(p.concepto)
    and (c.cliente_id = p.cliente_id or c.cliente_id is null)
)
group by 1, 2;

comment on view public.fin_v_conceptos_desconocidos is
  'Conceptos presentes en fin_pagos y ausentes del catálogo fin_conceptos. Debe dar 0 filas.';

-- ---------------------------------------------------------------------------
-- 4. Permisos
-- ---------------------------------------------------------------------------
revoke all on public.fin_v_pagos_categoria            from anon;
revoke all on public.fin_v_cash_collected_concepto    from anon;
revoke all on public.fin_v_conceptos_desconocidos     from anon;

grant select on public.fin_v_pagos_categoria          to authenticated;
grant select on public.fin_v_cash_collected_concepto  to authenticated;
grant select on public.fin_v_conceptos_desconocidos   to authenticated;

grant all on public.fin_v_pagos_categoria             to service_role;
grant all on public.fin_v_cash_collected_concepto     to service_role;
grant all on public.fin_v_conceptos_desconocidos      to service_role;

-- ---------------------------------------------------------------------------
-- 5. Smoke test: la torta tiene que sumar exactamente lo mismo que fin_pagos.
--    Si una fila se pierde o se duplica en el agregado, esto aborta.
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_pagos_base  bigint;
  v_monto_base  numeric;
  v_pagos_torta bigint;
  v_monto_torta numeric;
  v_desconocidos bigint;
begin
  select count(*), coalesce(sum(monto_usd), 0) into v_pagos_base, v_monto_base
  from public.fin_pagos;

  select coalesce(sum(pagos), 0), coalesce(sum(monto_usd), 0) into v_pagos_torta, v_monto_torta
  from public.fin_v_cash_collected_concepto;

  if v_pagos_base <> v_pagos_torta then
    raise exception 'SMOKE 032 FALLA: fin_pagos tiene % filas y la torta suma % pagos',
      v_pagos_base, v_pagos_torta;
  end if;

  if round(v_monto_base, 2) <> round(v_monto_torta, 2) then
    raise exception 'SMOKE 032 FALLA: fin_pagos suma % USD y la torta suma % USD',
      round(v_monto_base, 2), round(v_monto_torta, 2);
  end if;

  select count(*) into v_desconocidos from public.fin_v_conceptos_desconocidos;

  raise notice 'SMOKE 032 OK: % pagos / % USD cuadran. Conceptos desconocidos: %',
    v_pagos_base, round(v_monto_base, 2), v_desconocidos;
end
$smoke$;

commit;

-- ============================================================================
-- CONTROLES. De a uno, en orden.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONTROL 1  (lo necesito para decidir qué hacemos con los refunds)
-- Qué valores toma fin_pagos.estado y cuánta plata hay en cada uno.
-- ----------------------------------------------------------------------------
-- select coalesce(estado, '(NULL)') as estado,
--        count(*) as pagos,
--        round(sum(monto_usd), 2) as monto_usd
-- from public.fin_pagos
-- group by 1
-- order by 2 desc;


-- ----------------------------------------------------------------------------
-- CONTROL 2
-- La torta completa, sin cortar por mes. Esperado:
--   venta_nueva 1471 / 763.396   producto 102 / 56.883
--   cuota         34 /  18.215   sin_clasificar 14 / 4.199
--   TOTAL       1621 / 842.692,15
-- ----------------------------------------------------------------------------
-- select categoria,
--        sum(pagos) as pagos,
--        round(sum(monto_usd), 2) as monto_usd,
--        round(100 * sum(monto_usd) / sum(sum(monto_usd)) over (), 1) as pct
-- from public.fin_v_cash_collected_concepto
-- group by categoria
-- order by 3 desc;


-- ----------------------------------------------------------------------------
-- CONTROL 3
-- Conceptos desconocidos. Tiene que dar 0 filas.
-- ----------------------------------------------------------------------------
-- select * from public.fin_v_conceptos_desconocidos order by pagos desc;


-- ----------------------------------------------------------------------------
-- CONTROL 4
-- La torta por cliente en los últimos 3 meses. Es el corte que va a mostrar
-- la app. Mirá que ningún cliente tenga sin_clasificar arriba de 0.
-- ----------------------------------------------------------------------------
-- select cliente_id, mes_inicio, categoria, pagos, round(monto_usd, 2) as monto_usd
-- from public.fin_v_cash_collected_concepto
-- where mes_inicio >= date_trunc('month', current_date) - interval '2 months'
-- order by cliente_id, mes_inicio, monto_usd desc;


-- ----------------------------------------------------------------------------
-- CONTROL 5
-- anon no llega a ninguna de las 3 vistas. Tiene que dar 0 filas.
-- ----------------------------------------------------------------------------
-- select table_name, grantee, privilege_type
-- from information_schema.role_table_grants
-- where table_schema = 'public'
--   and table_name in ('fin_v_pagos_categoria',
--                      'fin_v_cash_collected_concepto',
--                      'fin_v_conceptos_desconocidos')
--   and grantee = 'anon';
