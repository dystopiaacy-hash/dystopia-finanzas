-- =====================================================================
-- 161_ventas_closers_show_up.sql
-- Ventas. Closers y Dashboard daban distinto show up: Ivan (liam, octubre)
-- figuraba con No show 0 y Show up 100 % y el Dashboard decia 79,2 %
-- (19 presentadas de 24 agendadas con show up cargado).
--
-- CAUSA: fin_v_metricas_closer (017) solo trae show_up_rate = presentadas /
-- (presentadas + no_show). Si nadie cargo ningun no show, da 100 % aunque
-- haya llamadas sin cargar o reagendadas. El Dashboard usa presentadas /
-- (agendadas - sin_show_up) y la vista del closer no tenia sin_show_up.
--
-- ARREGLO: la vista agrega AL FINAL (mismo orden y tipos de las 14
-- columnas actuales) regendas_canceladas, sin_show_up, sin_show_up_reciente,
-- sin_show_up_viejo y show_up_rate_agendadas (con las mismas definiciones
-- que fin_v_metricas_ventas, 030). El front (closers.js) muestra
-- presentadas / (agendadas - sin_show_up), la misma cuenta del Dashboard.
-- No toca datos ni permisos (create or replace conserva grants y
-- security_invoker). Sin la 161 el front sigue andando con el calculo viejo.
--
-- Sin begin/commit (SQL Editor). Correr el bloque entero, fuera de
-- :00/:15/:30/:45. Idempotente. Controles y vuelta atras al final.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. fin_v_metricas_closer con las columnas de show up sin cargar
-- ---------------------------------------------------------------------
create or replace view fin_v_metricas_closer
with (security_invoker = true) as
select
  cliente_id,
  periodo,
  vendedor_id,
  coalesce(vendedor, closer_crudo)                         as vendedor,
  count(*) filter (where es_agendada)                      as agendadas,
  count(*) filter (where es_presentada)                    as presentadas,
  count(*) filter (where es_no_show)                       as no_show,
  round(100.0 * count(*) filter (where es_presentada)
        / nullif(count(*) filter (where es_presentada or es_no_show), 0), 1)
                                                           as show_up_rate,
  count(*) filter (where es_cerrada)                       as cerradas,
  round(100.0 * count(*) filter (where es_cerrada)
        / nullif(count(*) filter (where es_presentada), 0), 1)
                                                           as tasa_cierre,
  round(100.0 * count(*) filter (where es_cerrada and es_calificada)
        / nullif(count(*) filter (where es_presentada and es_calificada), 0), 1)
                                                           as tasa_cierre_calificadas,
  round(sum(cc_cobrado)     filter (where es_agendada), 2) as cc_cobrado_data,
  round(sum(cc_valor_trato) filter (where es_cerrada), 2)  as valor_tratos_cerrados,
  round(sum(cc_valor_trato) filter (where es_cerrada)
        / nullif(count(*) filter (where es_cerrada), 0), 2) as ticket_promedio,
  -- Nuevas (al final). Mismas definiciones que fin_v_metricas_ventas (030).
  count(*) filter (where es_regenda_o_cancelada)           as regendas_canceladas,
  count(*) filter (where es_agendada
                     and es_presentada          is not true
                     and es_no_show             is not true
                     and es_regenda_o_cancelada is not true) as sin_show_up,
  count(*) filter (where es_agendada
                     and es_presentada          is not true
                     and es_no_show             is not true
                     and es_regenda_o_cancelada is not true
                     and fecha_llamada > current_date - 10)  as sin_show_up_reciente,
  count(*) filter (where es_agendada
                     and es_presentada          is not true
                     and es_no_show             is not true
                     and es_regenda_o_cancelada is not true
                     and fecha_llamada <= current_date - 10) as sin_show_up_viejo,
  round(100.0 * count(*) filter (where es_presentada)
        / nullif(count(*) filter (where es_agendada), 0), 1)
                                                           as show_up_rate_agendadas
from fin_v_llamadas_clasificadas
group by cliente_id, periodo, vendedor_id, coalesce(vendedor, closer_crudo)
order by periodo desc, cliente_id, cerradas desc;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno)
-- ---------------------------------------------------------------------
-- C1. Las 14 columnas viejas siguen y hay 5 nuevas (esperado: 19 filas).
-- select count(*) from information_schema.columns
--  where table_schema = 'public' and table_name = 'fin_v_metricas_closer';
--
-- C2. Por cliente y mes, los closers suman lo mismo que la vista de ventas
-- (esperado: 0 filas).
-- select c.cliente_id, c.periodo, c.ag, v.agendadas, c.pres, v.presentadas, c.ss, v.sin_show_up
--   from (select cliente_id, periodo, sum(agendadas) ag, sum(presentadas) pres, sum(sin_show_up) ss
--           from fin_v_metricas_closer group by 1, 2) c
--   join fin_v_metricas_ventas v using (cliente_id, periodo)
--  where c.ag <> v.agendadas or c.pres <> v.presentadas or c.ss <> v.sin_show_up;
--
-- C3. Liam octubre 2026: Ivan ya no da 100 %. Esperado: la suma de
-- presentadas / (agendadas - sin_show_up) de todos los closers = 79,2.
-- select vendedor, agendadas, presentadas, no_show, regendas_canceladas, sin_show_up,
--        show_up_rate, round(100.0 * presentadas / nullif(agendadas - sin_show_up, 0), 1) as show_up_cargado
--   from fin_v_metricas_closer
--  where cliente_id = 'liam' and periodo = '2026-10' order by cerradas desc;
--
-- VUELTA ATRAS: volver a correr el create or replace view de la 017
-- (migraciones/017_metricas_ventas_fix_cash.sql, seccion 3). Quita las 5
-- columnas nuevas; hay que hacer "drop view fin_v_metricas_closer" antes
-- porque create or replace no puede sacar columnas, y despues repetir los
-- grants que tenga la vista (la 084 los dejo por pg_depend).
