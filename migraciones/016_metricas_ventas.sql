-- =====================================================================
-- 016_metricas_ventas.sql
-- Vistas de metricas de VENTAS, sobre fin_llamadas.
--
-- Replica el "Maestro de Metricas" que la consultoria armo en las
-- planillas de BPF y Academia Apple, con las definiciones que confirmo
-- la agencia el 2026-09-22.
--
-- DIFERENCIAS A PROPOSITO CON EL MAESTRO DE LA PLANILLA:
--
--   1. Show Up Rate. El Maestro divide presentadas / agendadas totales,
--      lo que mete regendas y canceladas en el denominador. La agencia
--      definio que NO van. Aca el denominador es presentadas + no show.
--      Los numeros de la app van a ser MAS ALTOS que los de la planilla.
--
--   2. Tasa de Cierre Calificadas. La formula del Maestro es
--      "tasa de cierre total / show up rate", que no es una tasa:
--      mezcla dos ratios con denominadores distintos. Verificado en
--      marzo, abril y junio de liam, da exacto. Aca se calcula bien:
--      cierres de calificados sobre presentadas calificadas.
--
--   3. Llamadas a futuro. Las que todavia no ocurrieron se excluyen de
--      todo y se cuentan aparte. Si no, entrarian como no show.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Drop previo
--    create or replace view no permite renombrar ni sacar columnas.
--    Se dropean en orden inverso a la dependencia; la capa base va
--    ultima porque las demas cuelgan de ella.
-- ---------------------------------------------------------------------
drop view if exists fin_v_conciliacion_cc;
drop view if exists fin_v_metricas_booking;
drop view if exists fin_v_metricas_closer;
drop view if exists fin_v_metricas_ventas;
drop view if exists fin_v_llamadas_clasificadas;

-- ---------------------------------------------------------------------
-- 1. Capa base: una fila por llamada, ya clasificada.
--    Todas las vistas de arriba salen de aca, asi que la definicion de
--    cada concepto vive en UN solo lugar.
-- ---------------------------------------------------------------------
create or replace view fin_v_llamadas_clasificadas
with (security_invoker = true) as
select
  l.id,
  l.cliente_id,
  l.fecha_llamada,
  to_char(l.fecha_llamada, 'YYYY-MM')          as periodo,
  l.nombre,
  l.programa,
  btrim(l.closer)                              as closer_crudo,
  ven.vendedor_id,
  v.nombre                                     as vendedor,
  coalesce(nullif(btrim(l.tipo_booking), ''), '(sin fuente)') as tipo_booking,
  l.show_up,
  l.calificacion,
  l.estado_llamada,

  -- Cash
  coalesce(l.cc_dia1, 0)                       as cc_dia1,
  coalesce(l.cc_cerrado, 0)                    as cc_cerrado,
  coalesce(l.cc_seguimiento, 0)                as cc_seguimiento,
  coalesce(l.cc_dia1, 0) + coalesce(l.cc_cerrado, 0)
    + coalesce(l.cc_seguimiento, 0)            as cc_total,

  -- Una llamada a futuro todavia no ocurrio: no es no show.
  (l.fecha_llamada > current_date)             as es_futura,

  -- Agendada: cuenta para volumen. Excluye futuras.
  (l.fecha_llamada <= current_date)            as es_agendada,

  -- Presentada: el prospecto se presento.
  (l.fecha_llamada <= current_date
     and l.show_up = 'si')                     as es_presentada,

  -- No show: se presento que no. Regenda y cancelada por closer NO
  -- entran al denominador, por definicion de la agencia.
  (l.fecha_llamada <= current_date
     and l.show_up = 'no')                     as es_no_show,

  -- Fuera del calculo de show up, pero se cuentan aparte.
  (l.fecha_llamada <= current_date
     and l.show_up in ('regenda', 'cancelado por closer')) as es_regenda_o_cancelada,

  (l.calificacion = 'calificado')              as es_calificada,

  -- Unidad cerrada.
  --   teo y mauro tienen "Estado de la llamada": manda esa columna.
  --   liam y lucas no la tienen: se usa el cash.
  --   Las filas de teo/mauro con estado vacio caen tambien al cash.
  --   FEE NO cuenta como cierre: es una sena. Ver el analisis del
  --   2026-09-22: en mauro, 107 FEE con cash dia 1 pero solo 31 con
  --   trato cerrado y 6.279 USD, contra 102.754 USD de ADENTRO EN LLAMADA.
  (
    case
      when nullif(btrim(l.estado_llamada), '') is not null
        then upper(btrim(l.estado_llamada)) in
             ('ADENTRO EN LLAMADA', 'ADENTRO EN SEGUIMIENTO')
      else coalesce(l.cc_dia1, 0) + coalesce(l.cc_cerrado, 0)
             + coalesce(l.cc_seguimiento, 0) > 0
    end
    and l.fecha_llamada <= current_date
  )                                            as es_cerrada,

  (
    case
      when nullif(btrim(l.estado_llamada), '') is not null
        then upper(btrim(l.estado_llamada)) = 'ADENTRO EN LLAMADA'
      else coalesce(l.cc_dia1, 0) > 0
    end
    and l.fecha_llamada <= current_date
  )                                            as es_cerrada_en_llamada,

  (
    case
      when nullif(btrim(l.estado_llamada), '') is not null
        then upper(btrim(l.estado_llamada)) = 'ADENTRO EN SEGUIMIENTO'
      else coalesce(l.cc_dia1, 0) = 0
             and coalesce(l.cc_cerrado, 0) + coalesce(l.cc_seguimiento, 0) > 0
    end
    and l.fecha_llamada <= current_date
  )                                            as es_cerrada_en_seguimiento,

  -- FEE aparte: pendiente de definir con la agencia si es venta.
  (upper(btrim(coalesce(l.estado_llamada, ''))) = 'FEE'
     and l.fecha_llamada <= current_date)       as es_fee,

  -- Marca los clientes sin columna de estado, para leer los numeros
  -- sabiendo que su tasa de cierre es una aproximacion por cash.
  (nullif(btrim(l.estado_llamada), '') is null) as cierre_por_cash

from fin_llamadas l
left join lateral (
  select a.vendedor_id
  from fin_personas x
  join fin_vendedor_asignaciones a
    on a.vendedor_id = x.vendedor_id
   and a.cliente_id  = l.cliente_id
  where lower(btrim(x.alias)) = lower(btrim(l.closer))
    and (x.cliente_id is null or x.cliente_id = l.cliente_id)
    and (x.campo is null or x.campo in ('closer', 'ambos'))
  order by (x.cliente_id is not null) desc
  limit 1
) ven on true
left join fin_vendedores v on v.id = ven.vendedor_id;

-- ---------------------------------------------------------------------
-- 2. Maestro de metricas: por cliente y mes
-- ---------------------------------------------------------------------
create or replace view fin_v_metricas_ventas
with (security_invoker = true) as
select
  cliente_id,
  periodo,

  -- VOLUMEN
  count(*) filter (where es_agendada)                      as agendadas,
  count(*) filter (where es_agendada and es_calificada)    as calificadas,
  count(*) filter (where es_agendada and calificacion = 'no calificado')
                                                           as no_calificadas,
  round(100.0 * count(*) filter (where es_agendada and es_calificada)
        / nullif(count(*) filter (where es_agendada), 0), 1) as pct_calificados,

  -- SHOW UP. Denominador: presentadas + no show.
  count(*) filter (where es_presentada)                    as presentadas,
  count(*) filter (where es_no_show)                       as no_show,
  count(*) filter (where es_regenda_o_cancelada)           as regendas_canceladas,
  round(100.0 * count(*) filter (where es_presentada)
        / nullif(count(*) filter (where es_presentada or es_no_show), 0), 1)
                                                           as show_up_rate,
  count(*) filter (where es_presentada and es_calificada)  as presentadas_calificadas,

  -- VENTAS
  count(*) filter (where es_cerrada)                       as cerradas,
  count(*) filter (where es_cerrada_en_llamada)            as cerradas_en_llamada,
  count(*) filter (where es_cerrada_en_seguimiento)        as cerradas_en_seguimiento,
  count(*) filter (where es_fee)                           as fees,

  round(100.0 * count(*) filter (where es_cerrada)
        / nullif(count(*) filter (where es_presentada), 0), 1)
                                                           as tasa_cierre_total,
  round(100.0 * count(*) filter (where es_cerrada and es_calificada)
        / nullif(count(*) filter (where es_presentada and es_calificada), 0), 1)
                                                           as tasa_cierre_calificadas,

  -- CASH
  round(sum(cc_dia1)     filter (where es_agendada), 2)    as cc_dia1_total,
  round(sum(cc_cerrado)  filter (where es_agendada), 2)    as cc_cerrado_total,
  round(sum(cc_total)    filter (where es_agendada), 2)    as cc_mes,
  round(sum(cc_dia1)    filter (where es_cerrada)
        / nullif(count(*) filter (where es_cerrada), 0), 2) as aov_dia1,
  round(sum(cc_cerrado) filter (where es_cerrada)
        / nullif(count(*) filter (where es_cerrada), 0), 2) as aov_trato_cerrado,

  -- CONTEXTO
  count(*) filter (where es_futura)                        as agendadas_a_futuro,
  count(*) filter (where cierre_por_cash)                  as llamadas_sin_estado

from fin_v_llamadas_clasificadas
group by cliente_id, periodo
order by periodo desc, cliente_id;

-- ---------------------------------------------------------------------
-- 3. Por closer
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
  round(sum(cc_total) filter (where es_agendada), 2)       as cc_generado,
  round(sum(cc_total) filter (where es_cerrada)
        / nullif(count(*) filter (where es_cerrada), 0), 2) as ticket_promedio
from fin_v_llamadas_clasificadas
group by cliente_id, periodo, vendedor_id, coalesce(vendedor, closer_crudo)
order by periodo desc, cliente_id, cerradas desc;

-- ---------------------------------------------------------------------
-- 4. Por fuente de la agenda (tipo de booking)
--    El Maestro de Academia Apple repite el bloque entero por
--    INSTAGRAM, WEBINAR, LANDING IG y YOUTUBE.
-- ---------------------------------------------------------------------
create or replace view fin_v_metricas_booking
with (security_invoker = true) as
select
  cliente_id,
  periodo,
  upper(tipo_booking)                                      as fuente,
  count(*) filter (where es_agendada)                      as agendadas,
  count(*) filter (where es_presentada)                    as presentadas,
  round(100.0 * count(*) filter (where es_presentada)
        / nullif(count(*) filter (where es_presentada or es_no_show), 0), 1)
                                                           as show_up_rate,
  count(*) filter (where es_cerrada)                       as cerradas,
  round(100.0 * count(*) filter (where es_cerrada)
        / nullif(count(*) filter (where es_presentada), 0), 1)
                                                           as tasa_cierre,
  round(sum(cc_total) filter (where es_agendada), 2)       as cc
from fin_v_llamadas_clasificadas
group by cliente_id, periodo, upper(tipo_booking)
order by periodo desc, cliente_id, cc desc nulls last;

-- ---------------------------------------------------------------------
-- 5. Conciliacion: el cash de Data contra el cash de Pagos
--    Regla del contrato: el cash real sale SIEMPRE de fin_pagos.
--    Lo de Data sirve para atribuir, no para facturar. Esta vista
--    muestra la diferencia para que nadie confunda los dos numeros.
-- ---------------------------------------------------------------------
create or replace view fin_v_conciliacion_cc
with (security_invoker = true) as
with d as (
  select cliente_id, periodo, sum(cc_total) as cc_data
  from fin_v_llamadas_clasificadas
  where es_agendada
  group by cliente_id, periodo
),
p as (
  select cliente_id, to_char(fecha, 'YYYY-MM') as periodo,
         sum(monto_usd) as cc_pagos
  from fin_pagos
  group by cliente_id, to_char(fecha, 'YYYY-MM')
)
select
  coalesce(d.cliente_id, p.cliente_id)                     as cliente_id,
  coalesce(d.periodo, p.periodo)                           as periodo,
  round(coalesce(d.cc_data, 0), 2)                         as cc_data,
  round(coalesce(p.cc_pagos, 0), 2)                        as cc_pagos,
  round(coalesce(p.cc_pagos, 0) - coalesce(d.cc_data, 0), 2) as diferencia
from d full outer join p
  on p.cliente_id = d.cliente_id and p.periodo = d.periodo
order by 2 desc, 1;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================

-- Ninguna llamada puede estar cerrada en llamada Y en seguimiento
select 'doble clasificacion de cierre' as control, count(*) as valor_esperado_0
from fin_v_llamadas_clasificadas
where es_cerrada_en_llamada and es_cerrada_en_seguimiento;

-- Las cerradas tienen que ser la suma de los dos tipos, o mas
-- (teo y mauro pueden tener estados que cierran sin tipo definido)
select 'cerradas < suma de tipos' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where cerradas < cerradas_en_llamada + cerradas_en_seguimiento;

-- Ninguna tasa puede pasar de 100
select 'tasas fuera de rango' as control, count(*) as valor_esperado_0
from fin_v_metricas_ventas
where show_up_rate > 100 or tasa_cierre_total > 100
   or tasa_cierre_calificadas > 100 or pct_calificados > 100;

-- Todas las llamadas pasadas tienen que estar en una sola categoria
-- de show up: presentada, no show, o regenda/cancelada
select 'llamadas pasadas sin categoria de show up' as control,
       count(*) as informativo
from fin_v_llamadas_clasificadas
where not es_futura
  and not es_presentada and not es_no_show and not es_regenda_o_cancelada;

-- El maestro, ultimos 3 meses
select cliente_id, periodo, agendadas, presentadas, show_up_rate,
       cerradas, tasa_cierre_total, tasa_cierre_calificadas, cc_mes,
       llamadas_sin_estado
from fin_v_metricas_ventas
where periodo >= to_char(current_date - interval '3 months', 'YYYY-MM')
order by periodo desc, cliente_id;

commit;

-- =====================================================================
-- PENDIENTE CON LA AGENCIA
--
-- 1. FEE: hoy NO cuenta como venta cerrada, pero su cash suma al CC del
--    mes. Son 139 llamadas entre teo y mauro. Si la agencia define que
--    si es venta, se cambia una linea en fin_v_llamadas_clasificadas.
--
-- 2. liam y lucas no tienen la columna "Estado de la llamada", asi que
--    su cierre se estima por cash. La columna llamadas_sin_estado
--    lo marca. Pedirles que agreguen esa columna.
--
-- 3. AOV: la agencia no definio el denominador. Aca es
--    suma del cash / unidades cerradas, que es lo estandar. Los numeros
--    NO van a coincidir con los del Maestro de la planilla.
--
-- 4. Sin metricas de setter: Data no tiene columna de setter en ninguno
--    de los 4 clientes.
-- =====================================================================
