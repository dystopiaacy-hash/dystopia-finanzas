-- =====================================================================
-- 117_ventas_setters_rapido.sql
-- Ventas. La pantalla Setters da "canceling statement due to statement
-- timeout" desde la 115. Solo cambia fin_v_metricas_setter; no toca datos.
--
-- CAUSA: la 036 calcula agendadas_del_cliente con una subconsulta
-- correlacionada (select count(*) from fin_v_llamadas_clasificadas c where
-- c.cliente_id = ... and c.periodo = ...) que corre UNA VEZ POR CADA FILA
-- (cliente, mes, setter). Desde la 115 esa vista tiene un NOT EXISTS sobre
-- fin_v_llamadas_duplicadas (tres funciones de ventana sobre TODO
-- fin_llamadas, y el filtro por periodo no baja hasta ahi). Cada ejecucion
-- recalcula las ventanas enteras: filas del resultado x calculo completo.
--
-- ARREGLO: el denominador se calcula UNA vez, agrupado por cliente y mes, y
-- se une. Mismas 17 columnas, mismo orden, mismos tipos y mismos valores
-- (create or replace view sin cambios de firma). El resto de las vistas que
-- leen fin_v_llamadas_clasificadas (metricas_ventas, closer, booking) ya
-- hacen un solo recorrido con group by: no tienen el problema.
--
-- Ademas, indices que ayudan a la vista de duplicadas y a las lecturas por
-- cliente y fecha (idempotentes; si ya existen no hacen nada).
--
-- Sin begin/commit (SQL Editor). Correr cada bloque entero, fuera de
-- :00/:15/:30/:45. Idempotente. Controles y vuelta atras al final.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Indices
-- ---------------------------------------------------------------------
create index if not exists fin_llamadas_cliente_fecha_idx
  on fin_llamadas (cliente_id, fecha_llamada);

-- ---------------------------------------------------------------------
-- BLOQUE 2. fin_v_metricas_setter con el denominador precalculado
-- ---------------------------------------------------------------------
create or replace view fin_v_metricas_setter
with (security_invoker = true) as
with del_cliente as (
  select c.cliente_id, c.periodo, count(*) as agendadas
  from fin_v_llamadas_clasificadas c
  where c.es_agendada
  group by c.cliente_id, c.periodo
)
select
  l.cliente_id,
  l.periodo,
  s.setter_vendedor_id                                     as vendedor_id,
  max(s.setter)                                            as vendedor,

  count(*) filter (where l.es_agendada)                    as agendadas,
  count(*) filter (where l.es_agendada and l.es_calificada) as calificadas,

  count(*) filter (where l.es_presentada)                  as presentadas,
  count(*) filter (where l.es_no_show)                     as no_show,
  count(*) filter (where l.es_regenda_o_cancelada)         as regendas_canceladas,
  count(*) filter (where l.es_agendada
                     and l.es_presentada          is not true
                     and l.es_no_show             is not true
                     and l.es_regenda_o_cancelada is not true) as sin_show_up,
  round(100.0 * count(*) filter (where l.es_presentada)
        / nullif(count(*) filter (where l.es_agendada), 0), 1)
                                                           as show_up_rate,
  round(100.0 * count(*) filter (where l.es_presentada)
        / nullif(count(*) filter (where l.es_presentada or l.es_no_show), 0), 1)
                                                           as show_up_sin_regendas,

  count(*) filter (where l.es_cerrada)                     as cerradas,
  round(100.0 * count(*) filter (where l.es_cerrada)
        / nullif(count(*) filter (where l.es_presentada), 0), 1)
                                                           as tasa_cierre,

  round(sum(l.cc_cobrado)     filter (where l.es_agendada), 2) as cc_cobrado_data,
  round(sum(l.cc_valor_trato) filter (where l.es_cerrada), 2)  as valor_tratos_cerrados,
  round(sum(l.cc_valor_trato) filter (where l.es_cerrada)
        / nullif(count(*) filter (where l.es_cerrada), 0), 2)  as ticket_promedio,

  count(*) filter (where l.es_futura)                      as agendadas_a_futuro,

  coalesce(max(d.agendadas), 0)                            as agendadas_del_cliente

from fin_v_llamadas_clasificadas l
join fin_v_llamadas_setter s on s.llamada_id = l.id
left join del_cliente d on d.cliente_id = l.cliente_id and d.periodo = l.periodo
where s.setter_vendedor_id is not null
group by l.cliente_id, l.periodo, s.setter_vendedor_id
order by l.periodo desc, l.cliente_id, agendadas desc;

comment on view fin_v_metricas_setter is
  'Metricas por setter sobre las llamadas ATRIBUIDAS (fuente de setter + mes con setter determinado). No es todo el trabajo del setter: ver agendadas_del_cliente. Denominador precalculado (117).';

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. Tiene que contestar en segundos y devolver filas (antes: timeout).
-- select cliente_id, periodo, vendedor, agendadas, agendadas_del_cliente, cerradas
--   from fin_v_metricas_setter order by periodo desc, cliente_id, agendadas desc limit 20;

-- C2. Misma firma que la 036: 17 columnas, la ultima agendadas_del_cliente.
-- select count(*) as columnas_esperado_17,
--        max(column_name) filter (where ordinal_position = 17) as ultima
--   from information_schema.columns where table_name = 'fin_v_metricas_setter';

-- C3. Las agendadas de un setter nunca pasan las del cliente (esperado 0).
-- select count(*) as valor_esperado_0 from fin_v_metricas_setter
--  where agendadas > agendadas_del_cliente;

-- C4. Conserva security_invoker (tiene que dar true).
-- select relname, coalesce('security_invoker=true' = any(reloptions), false)
--   from pg_class where relname = 'fin_v_metricas_setter';

-- C5. Las otras vistas que leen la clasificada siguen rapidas (cada una,
--     por separado, tiene que volver en pocos segundos).
-- select count(*) from fin_v_metricas_ventas;
-- select count(*) from fin_v_metricas_closer;
-- select count(*) from fin_v_metricas_booking;
-- select count(*) from fin_v_llamadas_clasificadas;

-- C6. Si C1 sigue lento, mirar el plan y pasarlo:
-- explain (analyze, buffers) select * from fin_v_metricas_setter;

-- =====================================================================
-- VUELTA ATRAS
-- =====================================================================
-- Volver a correr el "create or replace view fin_v_metricas_setter" de
-- 036_metricas_setter.sql (con la subconsulta correlacionada). Quedaria lento
-- de nuevo mientras fin_v_llamadas_clasificadas tenga el NOT EXISTS de la 115.
-- El indice se puede dejar; si se quiere sacar:
-- drop index if exists fin_llamadas_cliente_fecha_idx;
