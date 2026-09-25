-- =====================================================================
-- 030_show_up_antiguedad.sql
-- Parte sin_show_up en reciente y viejo. Reemplaza la 021.
--
-- POR QUE: la columna Show up se completa unos dias despues de la
-- llamada. Al 25/09 los huecos arrancan el dia 15 y son totales desde el
-- 21; antes del 15 no falta nada en ninguno de los cuatro clientes.
--
-- Entonces el aviso de la app, tal como estaba, iba a saltar todos los
-- meses sin excepcion, porque el mes en curso siempre tiene los ultimos
-- dias sin completar. Un aviso que salta siempre no se lee, y el dia que
-- aparezca un hueco de verdad va a estar mezclado con el ruido normal.
--
-- Corte en 10 dias. No es un numero sagrado: es mas que la demora que se
-- observa hoy y menos que un mes. Si la demora cambia, se cambia el 10.
--
-- Las dos columnas nuevas suman siempre sin_show_up. El control 1 lo
-- verifica.
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

  -- Agendadas sin ninguna de las tres marcas: la columna "Show up" del
  -- Sheet esta vacia. "is not true" y no "not", porque los flags son
  -- NULL cuando show_up viene vacio.
  count(*) filter (where m.es_agendada
                     and m.es_presentada          is not true
                     and m.es_no_show             is not true
                     and m.es_regenda_o_cancelada is not true) as sin_show_up,

  -- El mismo hueco, partido por antiguedad. Verificado el 25/09: los
  -- huecos de septiembre arrancan el dia 15 y son totales desde el 21,
  -- y antes del 15 no falta nada en ningun cliente. O sea que la columna
  -- se completa unos dias despues de la llamada.
  --
  -- Sin esta division el aviso salta TODOS los meses, porque el mes en
  -- curso siempre tiene los ultimos dias sin completar. Un aviso que
  -- salta siempre deja de leerse, y el dia que haya un hueco real de
  -- mitad de mes va a estar mezclado con el ruido normal.
  count(*) filter (where m.es_agendada
                     and m.es_presentada          is not true
                     and m.es_no_show             is not true
                     and m.es_regenda_o_cancelada is not true
                     and m.fecha_llamada > current_date - 10)  as sin_show_up_reciente,
  count(*) filter (where m.es_agendada
                     and m.es_presentada          is not true
                     and m.es_no_show             is not true
                     and m.es_regenda_o_cancelada is not true
                     and m.fecha_llamada <= current_date - 10) as sin_show_up_viejo,

  -- Efectivo: mide al closer. Regendas y canceladas fuera del denominador.
  round(100.0 * count(*) filter (where m.es_presentada)
        / nullif(count(*) filter (where m.es_presentada or m.es_no_show), 0), 1)
                                                             as show_up_rate,

  -- Sobre agendadas: mide el funnel. Es el numero que da el Excel.
  round(100.0 * count(*) filter (where m.es_presentada)
        / nullif(count(*) filter (where m.es_agendada), 0), 1)
                                                             as show_up_rate_agendadas,

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
  exists (
    select 1 from fin_llamadas l2
    where l2.cliente_id = m.cliente_id
      and nullif(btrim(l2.estado_llamada), '') is not null
  )                                                          as cliente_tiene_columna_estado

from fin_v_llamadas_clasificadas m
group by m.cliente_id, m.periodo
order by m.periodo desc, m.cliente_id;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. Las dos partes suman el total. Si no, el corte perdio filas.
select 'reciente + viejo no da sin_show_up' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where sin_show_up <> sin_show_up_reciente + sin_show_up_viejo;

-- 2. Las cuatro categorias siguen sumando agendadas.
select 'categorias no suman agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where agendadas <> presentadas + no_show + regendas_canceladas + sin_show_up;

-- 3. Como queda repartido. Lo esperado hoy: casi todo en reciente, y
--    viejo cerca de cero salvo algun caso suelto.
select cliente_id, periodo, agendadas, sin_show_up,
       sin_show_up_reciente, sin_show_up_viejo
from fin_v_metricas_ventas
where sin_show_up > 0
order by sin_show_up_viejo desc, periodo desc, cliente_id;
