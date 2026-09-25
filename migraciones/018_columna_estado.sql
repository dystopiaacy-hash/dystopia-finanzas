-- =====================================================================
-- 018_columna_estado.sql
-- Agrega cliente_tiene_columna_estado a fin_v_metricas_ventas.
--
-- POR QUE: la app estaba decidiendo con un umbral (llamadas_sin_estado
-- sobre agendadas mayor a 0.8) si la planilla del cliente tiene la
-- columna "Estado de la llamada". Ese umbral se rompe solo: en
-- septiembre teo llego a 0.34 y mauro a 0.40, contra menos de 0.15 en
-- sus otros meses, porque dejaron de completar la planilla. Si siguen
-- asi, en un mes cruzan el 0.8 y la app les dice que les falta una
-- columna que si tienen.
--
-- La pregunta se responde con el historico completo, no con un mes:
-- si el cliente tiene AL MENOS UNA llamada con estado cargado, la
-- columna existe. Eso no se rompe nunca.
-- =====================================================================

begin;

drop view if exists fin_v_metricas_ventas cascade;

create view fin_v_metricas_ventas
with (security_invoker = true) as
select
  m.cliente_id,
  m.periodo,

  -- VOLUMEN
  count(*) filter (where m.es_agendada)                      as agendadas,
  count(*) filter (where m.es_agendada and m.es_calificada)  as calificadas,
  count(*) filter (where m.es_agendada and m.calificacion = 'no calificado')
                                                             as no_calificadas,
  round(100.0 * count(*) filter (where m.es_agendada and m.es_calificada)
        / nullif(count(*) filter (where m.es_agendada), 0), 1) as pct_calificados,

  -- SHOW UP
  count(*) filter (where m.es_presentada)                    as presentadas,
  count(*) filter (where m.es_no_show)                       as no_show,
  count(*) filter (where m.es_regenda_o_cancelada)           as regendas_canceladas,
  round(100.0 * count(*) filter (where m.es_presentada)
        / nullif(count(*) filter (where m.es_presentada or m.es_no_show), 0), 1)
                                                             as show_up_rate,
  count(*) filter (where m.es_presentada and m.es_calificada) as presentadas_calificadas,

  -- VENTAS
  count(*) filter (where m.es_cerrada)                       as cerradas,
  count(*) filter (where m.es_cerrada_en_llamada)            as cerradas_en_llamada,
  count(*) filter (where m.es_cerrada_en_seguimiento)        as cerradas_en_seguimiento,
  count(*) filter (where m.es_fee)                           as fees,
  round(100.0 * count(*) filter (where m.es_cerrada)
        / nullif(count(*) filter (where m.es_presentada), 0), 1)
                                                             as tasa_cierre_total,
  round(100.0 * count(*) filter (where m.es_cerrada and m.es_calificada)
        / nullif(count(*) filter (where m.es_presentada and m.es_calificada), 0), 1)
                                                             as tasa_cierre_calificadas,

  -- CASH (declarado en el CRM; el que factura sale de fin_pagos)
  round(sum(m.cc_cobrado)     filter (where m.es_agendada), 2) as cc_cobrado_data,
  round(sum(m.cc_valor_trato) filter (where m.es_cerrada), 2)  as valor_tratos_cerrados,
  round(sum(m.cc_dia1)        filter (where m.es_agendada), 2) as cc_dia1_total,
  round(sum(m.cc_dia1) filter (where m.es_cerrada)
        / nullif(count(*) filter (where m.es_cerrada), 0), 2)  as aov_dia1,
  round(sum(m.cc_valor_trato) filter (where m.es_cerrada)
        / nullif(count(*) filter (where m.es_cerrada), 0), 2)  as aov_trato_cerrado,

  -- CONTEXTO
  count(*) filter (where m.es_futura)                        as agendadas_a_futuro,
  count(*) filter (where m.cierre_por_cash)                  as llamadas_sin_estado,

  -- Se responde sobre TODO el historico del cliente, no sobre este mes.
  -- false = la planilla no tiene la columna: la tasa de cierre de ese
  --         cliente se estima por cash y fees nunca puede ser mayor a 0.
  -- true  = la columna existe; llamadas_sin_estado son filas sin completar.
  exists (
    select 1 from fin_llamadas l2
    where l2.cliente_id = m.cliente_id
      and nullif(btrim(l2.estado_llamada), '') is not null
  )                                                          as cliente_tiene_columna_estado

from fin_v_llamadas_clasificadas m
group by m.cliente_id, m.periodo
order by m.periodo desc, m.cliente_id;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================

-- liam y lucas en false, teo y mauro en true, sin importar el mes
select cliente_id,
       bool_and(cliente_tiene_columna_estado) as siempre_true,
       bool_or(cliente_tiene_columna_estado)  as alguna_true,
       count(*)                               as meses
from fin_v_metricas_ventas
group by cliente_id order by 1;

-- Donde no hay columna, fees tiene que ser 0 en todos los meses
select 'fees con columna inexistente' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where not cliente_tiene_columna_estado and fees > 0;

-- El umbral viejo fallaba: esto muestra cuanto se acercaron teo y mauro
select cliente_id, periodo, agendadas, llamadas_sin_estado,
       round(llamadas_sin_estado::numeric / nullif(agendadas, 0), 2) as ratio
from fin_v_metricas_ventas
where cliente_tiene_columna_estado and agendadas > 0
order by ratio desc limit 5;

commit;
