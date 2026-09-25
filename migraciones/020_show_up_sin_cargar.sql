-- =====================================================================
-- 020_show_up_sin_cargar.sql
-- Agrega sin_show_up a fin_v_metricas_ventas. Reemplaza la 019.
--
-- POR QUE: al correr la 019 aparecio que en septiembre las dos formulas
-- se separan muchisimo, y NO por regendas. La cuenta de mauro:
--
--   40 agendadas - 16 presentadas - 7 no show - 3 regendas = 14 filas
--   con la columna "Show up" VACIA.
--
-- En liam septiembre son 24 filas de 153. En agosto de liam, cero.
--
-- Consecuencia en el calculo: show_up_rate_agendadas divide por TODAS
-- las agendadas, asi que cuando falta carga el porcentaje baja solo. El
-- 40 % de mauro en septiembre no es un mal show up, es media planilla
-- sin llenar. show_up_rate no sufre eso porque solo mira lo cargado, y
-- por eso la brecha entre las dos se agranda.
--
-- La columna sin_show_up deja eso a la vista en vez de esconderlo.
--
-- POR QUE: en la reunion del 24/09 la agencia dijo que el show up de la
-- app no coincide con su Excel. Verificado con agosto de Liam:
--
--   agendadas   82   app 82   Excel 82
--   presentadas 71   app 71   Excel 71
--   no show      7   app  7   Excel  7
--
-- Los tres conteos coinciden EXACTO. La app lee bien la planilla.
-- La diferencia esta solo en el denominador:
--
--   app:   71 / (71 + 7)  = 91,0 %   excluye regendas y canceladas
--   Excel: 71 / 82        = 86,6 %   las incluye
--
-- Las 4 llamadas de diferencia son regendas y canceladas por closer.
-- El 22/09 la agencia habia definido excluirlas ("las canceladas por
-- closer no, las reagendas tampoco cuentan como no showup hasta que se
-- presente"). El Excel nunca se cambio.
--
-- En vez de elegir una y que la otra quede mal, se muestran las dos:
--
--   show_up_rate            mide al CLOSER. Solo cuentan las llamadas
--                           que dependian de el.
--   show_up_rate_agendadas  mide el FUNNEL completo. Replica el Excel.
--
-- Una regenda no es culpa del closer, pero si es una agenda que no se
-- convirtio en llamada. Las dos preguntas son validas.
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

  -- Agendadas que no son ni presentada, ni no show, ni regenda: la
  -- columna "Show up" de la planilla esta vacia. Si es mayor a cero,
  -- show_up_rate_agendadas esta subestimado.
  count(*) filter (where m.es_agendada
                     and not m.es_presentada
                     and not m.es_no_show
                     and not m.es_regenda_o_cancelada)        as sin_show_up,

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

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================

-- El efectivo nunca puede ser MENOR que el de agendadas: mismo
-- numerador, denominador mas chico o igual.
select 'efectivo menor que sobre agendadas' as control,
       count(*) as valor_esperado_0
from fin_v_metricas_ventas
where show_up_rate < show_up_rate_agendadas;

-- Ninguna tasa pasa de 100
select 'tasas fuera de rango' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where show_up_rate > 100 or show_up_rate_agendadas > 100;

-- Donde no hay regendas ni canceladas NI filas sin cargar, las dos
-- formulas tienen que dar igual. Si sin_show_up es mayor a cero las
-- formulas difieren aunque no haya regendas, y eso es correcto: por
-- eso entra en la condicion.
select 'sin regendas las formulas difieren' as control,
       count(*) as valor_esperado_0
from fin_v_metricas_ventas
where regendas_canceladas = 0
  and sin_show_up = 0
  and show_up_rate is distinct from show_up_rate_agendadas;

-- Las cuatro categorias tienen que sumar exactamente las agendadas.
select 'categorias no suman agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where agendadas <> presentadas + no_show + regendas_canceladas + sin_show_up;

-- EL CONTROL QUE IMPORTA: agosto de Liam contra el Excel de la agencia.
-- Esperado: 82 agendadas, 71 presentadas, 7 no show,
--           91,0 efectivo y 86,6 sobre agendadas.
select 'liam agosto contra el Excel' as control,
       agendadas, presentadas, no_show, regendas_canceladas,
       sin_show_up as esperado_0,
       show_up_rate      as efectivo_esperado_91_0,
       show_up_rate_agendadas as sobre_agendadas_esperado_86_6
from fin_v_metricas_ventas
where cliente_id = 'liam' and periodo = '2026-08';

-- Cuanto se separan las dos formulas, y por que.
-- La brecha se explica por regendas MAS filas sin cargar. Cuando
-- sin_show_up es alto, el numero sobre agendadas no es comparable con
-- meses anteriores.
select cliente_id, periodo, agendadas,
       regendas_canceladas, sin_show_up,
       round(100.0 * sin_show_up / nullif(agendadas, 0), 1) as pct_sin_cargar,
       show_up_rate, show_up_rate_agendadas,
       round(show_up_rate - show_up_rate_agendadas, 1) as brecha
from fin_v_metricas_ventas
where periodo >= '2026-06' and agendadas > 0
order by brecha desc nulls last
limit 12;

-- Cuantas llamadas sin show up hay por cliente, en total.
select cliente_id,
       sum(agendadas)    as agendadas,
       sum(sin_show_up)  as sin_show_up,
       round(100.0 * sum(sin_show_up) / nullif(sum(agendadas), 0), 1) as pct
from fin_v_metricas_ventas
group by cliente_id
order by pct desc;

commit;
