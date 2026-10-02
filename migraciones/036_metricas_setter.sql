-- =====================================================================
-- 036_metricas_setter.sql (numerado 036: 031 a 034 son de Finanzas)
-- Metricas por setter, en paralelo a fin_v_metricas_closer.
-- Requiere la 029 corrida.
--
-- POR QUE RECIEN AHORA: hasta la 025 no se podia. La hoja Data no tiene
-- columna de setter, asi que no habia forma de saber quien agendo. Con
-- la atribucion por fuente (025) mas el calendario de setters (026), si.
--
-- LO QUE ESTAS METRICAS SON, EXACTAMENTE: las llamadas cuya fuente esta
-- marcada como del setter, en los meses donde ese cliente tiene setter
-- determinado. NO son todo el trabajo del setter:
--
--   - Una llamada de fuente landing no entra, aunque el setter la haya
--     tocado.
--   - Un mes sin setter determinado no entra para nadie (julio en liam
--     y en lucas, mayo y junio en teo).
--   - mauro no tiene setter cargado, asi que no aparece nunca.
--
-- Por eso la vista expone agendadas_del_cliente al lado: sin ese
-- denominador, "Juani agendo 135 en septiembre" se lee como si fueran
-- todas las del mes, y son 135 de 158.
-- =====================================================================

begin;

create or replace view fin_v_metricas_setter
with (security_invoker = true) as
select
  l.cliente_id,
  l.periodo,
  s.setter_vendedor_id                                     as vendedor_id,
  max(s.setter)                                            as vendedor,

  -- VOLUMEN
  count(*) filter (where l.es_agendada)                    as agendadas,
  count(*) filter (where l.es_agendada and l.es_calificada) as calificadas,

  -- SHOW UP. Mismo criterio que el resto de la app desde la 021: el
  -- numero principal es sobre agendadas, y se informa cuantas filas
  -- estan sin cargar para que nadie lea una caida que no paso.
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

  -- VENTAS. Un setter no cierra, pero su agenda termina o no en venta:
  -- es la medida de si trae gente que compra.
  count(*) filter (where l.es_cerrada)                     as cerradas,
  round(100.0 * count(*) filter (where l.es_cerrada)
        / nullif(count(*) filter (where l.es_presentada), 0), 1)
                                                           as tasa_cierre,

  round(sum(l.cc_cobrado)     filter (where l.es_agendada), 2) as cc_cobrado_data,
  round(sum(l.cc_valor_trato) filter (where l.es_cerrada), 2)  as valor_tratos_cerrados,
  round(sum(l.cc_valor_trato) filter (where l.es_cerrada)
        / nullif(count(*) filter (where l.es_cerrada), 0), 2)  as ticket_promedio,

  count(*) filter (where l.es_futura)                      as agendadas_a_futuro,

  -- El denominador que evita leer estos numeros como si fueran el mes
  -- entero. Sale de contar TODAS las llamadas del cliente en ese mes,
  -- atribuidas o no.
  (select count(*) from fin_v_llamadas_clasificadas c
    where c.cliente_id = l.cliente_id
      and c.periodo    = l.periodo
      and c.es_agendada)                                   as agendadas_del_cliente

from fin_v_llamadas_clasificadas l
join fin_v_llamadas_setter s on s.llamada_id = l.id
where s.setter_vendedor_id is not null
group by l.cliente_id, l.periodo, s.setter_vendedor_id
order by l.periodo desc, l.cliente_id, agendadas desc;

comment on view fin_v_metricas_setter is
  'Metricas por setter sobre las llamadas ATRIBUIDAS (fuente de setter + mes con setter determinado). No es todo el trabajo del setter: ver agendadas_del_cliente.';

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. Como queda. Mira la relacion agendadas / agendadas_del_cliente:
--    ahi se ve cuanto del mes cubre la atribucion.
select cliente_id, periodo, vendedor, agendadas, agendadas_del_cliente,
       round(100.0 * agendadas / nullif(agendadas_del_cliente, 0), 1) as pct_del_mes,
       presentadas, sin_show_up, show_up_rate, cerradas, tasa_cierre,
       cc_cobrado_data
from fin_v_metricas_setter
order by periodo desc, cliente_id, agendadas desc;

-- 2. Ninguna tasa pasa de 100.
select 'tasas fuera de rango' as control, count(*) as valor_esperado_0
from fin_v_metricas_setter
where show_up_rate > 100 or show_up_sin_regendas > 100 or tasa_cierre > 100;

-- 3. Las agendadas de un setter nunca pueden pasar las del cliente.
select 'setter con mas agendadas que el cliente' as control,
       count(*) as valor_esperado_0
from fin_v_metricas_setter
where agendadas > agendadas_del_cliente;

-- 4. CONTROL DE CRUCE: el total atribuido por cliente y mes tiene que
--    coincidir con lo que da fin_v_llamadas_setter. Si no, el group by
--    perdio o duplico filas.
select 'no cuadra con la vista de atribucion' as control,
       count(*) as valor_esperado_0
from (
  select cliente_id, periodo, sum(agendadas) as ag
  from fin_v_metricas_setter group by cliente_id, periodo
) m
join (
  select l.cliente_id, l.periodo, count(*) as ag
  from fin_v_llamadas_clasificadas l
  join fin_v_llamadas_setter s on s.llamada_id = l.id
  where s.setter_vendedor_id is not null and l.es_agendada
  group by l.cliente_id, l.periodo
) v using (cliente_id, periodo)
where m.ag <> v.ag;
