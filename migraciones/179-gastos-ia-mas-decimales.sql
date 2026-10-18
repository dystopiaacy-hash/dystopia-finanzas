-- =====================================================================
-- 179-gastos-ia-mas-decimales.sql
-- Panel Gastos: las filas de IA automatica conservan hasta 6 decimales (antes se redondeaban a 2 en la
-- vista fin_gastos_mes_base, por eso los centavos de IA se veian como US$ 0,00).
-- Numero asignado por el jefe. SIN CORRER, NO PROBADA contra Postgres.
--
-- DONDE SE PERDIA LA PRECISION (migraciones/174_finanzas_dystopia_gastos_ia.sql, vista fin_gastos_mes_base):
--   * CTE ia: monto_original = round(sum(costo_usd), 2) (linea 260) y monto_usd = round(sum(costo_usd), 2) (linea 261).
--   * usd_dystopia = round(monto_usd * pct / 100, 2) (linea 281-282) y usd_cliente = monto_usd - round(..., 2) (283-285).
--   Las columnas NO son el problema: ia_uso.costo_usd y el calculo son numeric sin escala; fin_gastos.monto es numeric
--   sin escala. No se toca ninguna tabla ni dato guardado: la vista se calcula en cada consulta desde ia_uso,
--   asi que no hay montos redondeados guardados que recalcular.
--
-- Que hace: create or replace de fin_gastos_mes_base (mismas columnas, mismos tipos numeric, mismo orden).
--   Filas 'manual': siguen redondeadas a 2 decimales (sin cambios). Filas 'ia_auto': round(..., 6).
--   Como fin_v_gastos_mes (select *) y fin_v_dys_mes (suma usd_dystopia) leen esta vista, los totales se calculan
--   con la precision completa. No cambia el texto, ni el reparto, ni ingresos/comision.
--   create or replace view conserva los grants existentes (la vista interna sigue sin permisos para nadie);
--   se repite el revoke por las dudas. No hay tablas, secuencias ni funciones nuevas.
-- Depende de: 174. Correr fuera de :00/:15/:30/:45 y de las 9:00. Re-ejecutable.
-- ORDEN: control A (ANTES, como fundador) > bloque de la vista > controles B..D (DESPUES) > front ya desplegado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE UNICO. Vista
-- ---------------------------------------------------------------------
do $g$
begin
  if to_regclass('public.fin_gastos_mes_base') is null or to_regclass('public.fin_ia_uso_norm') is null then
    raise exception 'GUARDA 179: falta la 174 (fin_gastos_mes_base / fin_ia_uso_norm)';
  end if;
end
$g$;

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
         round(sum(n.costo_usd), 6) as monto_original, 'USD'::text as moneda, null::numeric as tipo_cambio,   -- 179: era 2
         round(sum(n.costo_usd), 6) as monto_usd,                                                            -- 179: era 2
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
                                          else coalesce(p.pct_comision, 0) end / 100,
             case when p.origen = 'ia_auto' then 6 else 2 end) as usd_dystopia,   -- 179: IA con 6 decimales
       case p.reparto when 'dystopia' then 0::numeric
            else p.monto_usd - round(p.monto_usd * case p.reparto when 'cliente' then 0
                                                       else coalesce(p.pct_comision, 0) end / 100,
                                     case when p.origen = 'ia_auto' then 6 else 2 end) end as usd_cliente,
       p.recurrente, p.nota, p.llamadas_sin_costo,
       (p.reparto = 'comision' and p.pct_comision is null) as falta_comision, p.sin_asignar
  from con_pct p
  left join public.fin_gasto_categorias c on c.id = p.categoria_id;
revoke all on public.fin_gastos_mes_base from public, anon, authenticated;

-- =====================================================================
-- CONTROLES (de a uno). Los que leen fin_v_* necesitan ser fundador:
--   select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- Guardar el resultado de A antes de correr el bloque, para comparar con B.
-- =====================================================================

-- A/B. Gasto de IA por mes y entidad (correr ANTES y DESPUES). Esperado: igual por mes con diferencia < 0,01 por fila
--      (antes redondeado a 2 decimales, ahora con 6); octubre total ~ US$ 0,56 pero sin perder los centavos de cada fila.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, entidad, sum(monto_usd) as usd, sum(usd_dystopia) as dystopia, sum(usd_cliente) as cliente
--   from public.fin_v_gastos_mes where origen = 'ia_auto' group by 1, 2 order by 1 desc, 2;

-- B2. Total de IA por mes contra la fuente (esperado: diferencia = 0 en cada mes con la vista nueva, tolerancia 0,000001 por fila).
-- select b.mes, round(sum(b.monto_usd), 6) as vista, round(sum(n.usd), 6) as fuente
--   from (select mes, sum(monto_usd) as monto_usd from public.fin_gastos_mes_base where origen = 'ia_auto' group by 1) b
--   join (select mes, sum(costo_usd) as usd from public.fin_ia_uso_norm group by 1) n on n.mes = b.mes
--  group by b.mes order by 1 desc;

-- C. El resto de los gastos no cambio (conteo y suma por mes; esperado: identico antes y despues de la migracion).
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, count(*) as filas, sum(monto_usd) as usd, sum(usd_dystopia) as dystopia, sum(usd_cliente) as cliente
--   from public.fin_v_gastos_mes where origen = 'manual' group by 1 order by 1 desc;

-- D. Dystopia por mes: gasto_ia_dystopia_usd ahora con mas decimales; ingreso_usd, base_usd y porcentaje sin cambios.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, entidad, base_usd, porcentaje, ingreso_usd, gasto_dystopia_usd, gasto_ia_dystopia_usd, neto_usd
--   from public.fin_v_dys_mes order by mes desc, entidad;

-- E. La vista interna sigue sin permisos (esperado: false).
-- select has_table_privilege('authenticated', 'public.fin_gastos_mes_base', 'select');

-- =====================================================================
-- VUELTA ATRAS: volver a correr el create or replace view fin_gastos_mes_base de la 174 (BLOQUE 2).
-- =====================================================================
