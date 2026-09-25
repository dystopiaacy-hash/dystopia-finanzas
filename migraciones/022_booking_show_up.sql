-- =====================================================================
-- 022_booking_show_up.sql
-- Reconstruye fin_v_metricas_booking con el desglose completo de show up,
-- igual que la 021 hizo con fin_v_metricas_ventas.
--
-- POR QUE: la vista actual solo expone show_up_rate, que divide por las
-- filas que tienen el dato cargado. Sin saber cuantas faltan, el numero
-- por fuente es ilegible. Liam septiembre 2026:
--
--   fuente       agendadas  presentadas  show_up_rate
--   INSTAGRAM       67          46           97,9      <-- 46/67 = 68,7
--   LANDING          8           2          100,0      <-- 2/8   = 25,0
--
-- El 97,9 sale de dividir por 47. Las otras 20 filas quedan afuera del
-- denominador: son reagendas o filas sin cargar, y la vista no dice
-- cuales. En LANDING son 6 de 8, y muestra 100 %.
--
-- La cuenta de liam septiembre cierra exacto: las 6 fuentes suman 153
-- agendadas, y las filas fuera del denominador suman 28 = 4 reagendas
-- + 24 sin cargar. Instagram se lleva 20 de esas 28.
--
-- Sin este desglose, la pantalla de fuente de trafico diria que
-- Instagram convierte al 97,9 y el webinar al 83,8. La conclusion seria
-- poner plata en Instagram, y el numero real de Instagram esta entre
-- 68,7 y 97,9 segun cuantas de esas 20 sean reagendas.
--
-- QUE NO ARREGLA: los nombres de fuente no estan normalizados entre
-- clientes (teo: TT y TT SETTER; mauro: TIKTOK; liam: YOUTUBE y YOUTUBE
-- VENTAS; lucas: LANDING INSTAGRAM contra LANDING de liam). Comparar
-- clientes entre si sigue sin ser valido. Eso necesita una tabla de
-- mapeo y una definicion de la agencia, no se resuelve en SQL.
-- =====================================================================

begin;

drop view if exists fin_v_metricas_booking;

create view fin_v_metricas_booking
with (security_invoker = true) as
select
  m.cliente_id,
  m.periodo,
  upper(m.tipo_booking)                                    as fuente,

  -- VOLUMEN
  count(*) filter (where m.es_agendada)                    as agendadas,

  -- SHOW UP: las cuatro categorias suman agendadas, siempre.
  -- "is not true" y no "not", porque los flags son NULL cuando la
  -- columna Show up de la planilla viene vacia.
  count(*) filter (where m.es_presentada)                  as presentadas,
  count(*) filter (where m.es_no_show)                     as no_show,
  count(*) filter (where m.es_regenda_o_cancelada)         as regendas_canceladas,
  count(*) filter (where m.es_agendada
                     and m.es_presentada          is not true
                     and m.es_no_show             is not true
                     and m.es_regenda_o_cancelada is not true) as sin_show_up,

  -- Efectivo: mide al closer. Es el que ya existia.
  round(100.0 * count(*) filter (where m.es_presentada)
        / nullif(count(*) filter (where m.es_presentada or m.es_no_show), 0), 1)
                                                           as show_up_rate,

  -- Sobre agendadas: mide la fuente. Cuantos de los que esta fuente
  -- trajo llegaron a la llamada.
  round(100.0 * count(*) filter (where m.es_presentada)
        / nullif(count(*) filter (where m.es_agendada), 0), 1)
                                                           as show_up_rate_agendadas,

  -- VENTAS
  count(*) filter (where m.es_cerrada)                     as cerradas,
  round(100.0 * count(*) filter (where m.es_cerrada)
        / nullif(count(*) filter (where m.es_presentada), 0), 1)
                                                           as tasa_cierre,

  -- CASH declarado en el CRM, no facturacion.
  round(sum(m.cc_cobrado) filter (where m.es_agendada), 2) as cc_cobrado_data,

  -- Explica las filas con agendadas = 0: son llamadas que todavia no
  -- ocurrieron. La pantalla las muestra aparte o las esconde.
  count(*) filter (where m.es_futura)                      as agendadas_a_futuro

from fin_v_llamadas_clasificadas m
group by m.cliente_id, m.periodo, upper(m.tipo_booking)
order by m.periodo desc, m.cliente_id, cc_cobrado_data desc nulls last;

commit;


-- =====================================================================
-- CONTROLES (correlos de a uno, el editor solo muestra el ultimo)
-- =====================================================================

-- 1. Las cuatro categorias suman agendadas, en cada fuente.
select 'categorias no suman agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_booking
where agendadas <> presentadas + no_show + regendas_canceladas + sin_show_up;

-- 2. EL CONTROL FUERTE: la suma de todas las fuentes de un cliente y mes
--    tiene que dar identica a fin_v_metricas_ventas del mismo cliente y
--    mes. Si no da, hay filas que se pierden o se duplican al agrupar
--    por fuente, y toda la pantalla queda mal.
select 'booking no cuadra con ventas' as control, count(*) as valor_esperado_0
from (
  select cliente_id, periodo,
         sum(agendadas) as ag, sum(presentadas) as pr,
         sum(cerradas) as ce, sum(sin_show_up) as ss
  from fin_v_metricas_booking
  group by cliente_id, periodo
) b
join fin_v_metricas_ventas v using (cliente_id, periodo)
where b.ag <> v.agendadas
   or b.pr <> v.presentadas
   or b.ce <> v.cerradas
   or b.ss <> v.sin_show_up;

-- 3. Ninguna tasa pasa de 100.
select 'tasas fuera de rango' as control, count(*) as valor_esperado_0
from fin_v_metricas_booking
where show_up_rate > 100 or show_up_rate_agendadas > 100 or tasa_cierre > 100;

-- 4. El efectivo nunca puede ser menor que el de agendadas.
select 'efectivo menor que sobre agendadas' as control, count(*) as valor_esperado_0
from fin_v_metricas_booking
where show_up_rate < show_up_rate_agendadas;

-- 5. Liam septiembre, el caso que motivo la migracion.
--    INSTAGRAM tiene que mostrar 67 agendadas, 46 presentadas y un
--    sobre agendadas de 68,7 al lado del 97,9.
select fuente, agendadas, presentadas, no_show, regendas_canceladas,
       sin_show_up, show_up_rate, show_up_rate_agendadas,
       cerradas, tasa_cierre, cc_cobrado_data, agendadas_a_futuro
from fin_v_metricas_booking
where cliente_id = 'liam' and periodo = '2026-09'
order by agendadas desc;

-- 6. Donde mas se separan las dos formulas por fuente. Estas son las
--    filas donde el numero de hoy engaña mas.
select cliente_id, periodo, fuente, agendadas, sin_show_up,
       show_up_rate, show_up_rate_agendadas,
       round(show_up_rate - show_up_rate_agendadas, 1) as brecha
from fin_v_metricas_booking
where periodo >= '2026-08' and agendadas >= 5
order by brecha desc nulls last
limit 15;

-- 7. Inventario de nombres de fuente por cliente. Es el insumo del
--    pedido a la agencia: decidir cuales son la misma fuente.
select fuente, count(distinct cliente_id) as clientes,
       string_agg(distinct cliente_id, ', ' order by cliente_id) as cuales,
       sum(agendadas) as agendadas
from fin_v_metricas_booking
group by fuente
order by agendadas desc;
