-- =====================================================================
-- 021_show_up_null.sql
-- Corrige sin_show_up en fin_v_metricas_ventas. Reemplaza la 020.
--
-- EL BUG (mio, en la 020):
--
-- Los flags de fin_v_llamadas_clasificadas se calculan asi:
--
--   es_presentada = (l.fecha_llamada <= current_date and l.show_up = 'si')
--
-- Si show_up esta vacio, "show_up = 'si'" no da false: da NULL.
-- Y "true and NULL" es NULL. Entonces es_presentada queda NULL, no
-- false. Eso no molesta en los contadores normales, porque
-- "filter (where es_presentada)" descarta NULL igual que false.
--
-- Pero en la 020 escribi la condicion al reves:
--
--   filter (where es_agendada and not es_presentada and ...)
--
-- y "not NULL" es NULL, asi que el filtro descarta justo las filas que
-- yo queria contar. sin_show_up daba 0 por construccion, para cualquier
-- dato. Nunca iba a encontrar nada.
--
-- LA CORRECCION: "is not true" en vez de "not". Cubre false y NULL.
--
-- Va tambien la consulta cruda contra fin_llamadas, que no depende de
-- ninguna vista mia. Si esa consulta muestra filas con show_up vacio y
-- sin_show_up sigue en 0, el problema es otro y hay que seguir mirando.
-- =====================================================================


-- =====================================================================
-- BLOQUE A - DIAGNOSTICO CRUDO (solo lectura, corre antes de tocar nada)
-- =====================================================================

-- Que valores tiene show_up en la tabla, tal cual entraron del Sheet.
select coalesce(nullif(btrim(show_up), ''), '(vacio o null)') as show_up_valor,
       count(*) as filas
from fin_llamadas
group by 1
order by filas desc;

-- Filas con show_up vacio por cliente y mes, de junio en adelante.
-- Esto es lo que sin_show_up tendria que estar contando.
select cliente_id,
       to_char(fecha_llamada, 'YYYY-MM') as periodo,
       count(*) as filas_sin_show_up
from fin_llamadas
where fecha_llamada is not null
  and fecha_llamada <= current_date
  and nullif(btrim(show_up), '') is null
  and fecha_llamada >= date '2026-06-01'
group by 1, 2
order by filas_sin_show_up desc
limit 20;


-- =====================================================================
-- BLOQUE B - LA CORRECCION
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
-- BLOQUE C - CONTROLES
-- =====================================================================

-- EL CONTROL QUE IMPORTA. Las cuatro categorias tienen que sumar
-- exactamente las agendadas. Si esto no da 0, la clasificacion tiene un
-- caso que no esta contemplado y todo lo de show up queda en duda.
select 'categorias no suman agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where agendadas <> presentadas + no_show + regendas_canceladas + sin_show_up;

-- El efectivo nunca puede ser MENOR que el de agendadas.
select 'efectivo menor que sobre agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where show_up_rate < show_up_rate_agendadas;

-- Ninguna tasa pasa de 100.
select 'tasas fuera de rango' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where show_up_rate > 100 or show_up_rate_agendadas > 100;

-- Sin regendas Y sin filas vacias, las dos formulas dan igual.
select 'sin regendas las formulas difieren' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where regendas_canceladas = 0 and sin_show_up = 0
  and show_up_rate is distinct from show_up_rate_agendadas;

-- Agosto de Liam contra el Excel de la agencia.
-- Esperado: 82 agendadas, 71 presentadas, 7 no show, sin_show_up 0,
--           91,0 efectivo y 86,6 sobre agendadas.
select 'liam agosto contra el Excel' as control,
       agendadas, presentadas, no_show, regendas_canceladas,
       sin_show_up as esperado_0,
       show_up_rate           as efectivo_esperado_91_0,
       show_up_rate_agendadas as sobre_agendadas_esperado_86_6
from fin_v_metricas_ventas
where cliente_id = 'liam' and periodo = '2026-08';

-- Mauro septiembre. Si mi lectura del CSV era correcta, aca tiene que
-- aparecer sin_show_up = 14 sobre 40 agendadas.
select 'mauro septiembre' as control,
       agendadas, presentadas, no_show, regendas_canceladas, sin_show_up
from fin_v_metricas_ventas
where cliente_id = 'mauro' and periodo = '2026-09';

-- Donde se separan las dos formulas y por que.
select cliente_id, periodo, agendadas,
       regendas_canceladas, sin_show_up,
       round(100.0 * sin_show_up / nullif(agendadas, 0), 1) as pct_sin_cargar,
       show_up_rate, show_up_rate_agendadas,
       round(show_up_rate - show_up_rate_agendadas, 1) as brecha
from fin_v_metricas_ventas
where periodo >= '2026-06' and agendadas > 0
order by brecha desc nulls last
limit 12;

-- Total por cliente.
select cliente_id,
       sum(agendadas)   as agendadas,
       sum(sin_show_up) as sin_show_up,
       round(100.0 * sum(sin_show_up) / nullif(sum(agendadas), 0), 1) as pct
from fin_v_metricas_ventas
group by cliente_id
order by pct desc;
