-- =====================================================================
-- 115_ventas_duplicados.sql
-- Ventas. Leads duplicados: se detectan, se marcan en Data y NO se suman
-- dos veces en las metricas. No borra ni modifica ninguna fila de
-- fin_llamadas.
--
-- CRITERIO DE DUPLICADO (una fila es duplicada de otra si, en el MISMO
-- cliente y con la MISMA fecha_llamada, comparte al menos uno de):
--   a) telefono: los ultimos 10 digitos (con 8 o mas digitos; "#ERROR!" y
--      telefonos cortos no cuentan)
--   b) email en minuscula y sin espacios (con arroba)
--   c) nombre en minuscula, espacios colapsados (4 o mas caracteres, con
--      al menos una letra)
-- La fuente (tipo_booking) NO entra en la comparacion: el mismo lead con
-- dos fuentes el mismo dia es justamente el caso a resolver.
-- Se conserva UNA fila por grupo. Prioridad de la que queda: la que tiene
-- estado de llamada, despues la que tiene show up cargado, despues la que
-- tiene cash, despues la de menor id. Las demas son es_duplicada = true.
-- No hay ventana de varios dias a proposito: una reagenda en otra fecha
-- es otra agenda. Ver C3 para medir cuantas habria con una ventana corta.
--
-- BLOQUE 1: crea la vista fin_v_llamadas_duplicadas (solo lectura, no
--           cambia ninguna metrica). Es lo que usa Data para marcar filas.
-- BLOQUE 2: fin_v_llamadas_clasificadas deja afuera las duplicadas. Esa
--           vista alimenta fin_v_metricas_ventas, metricas por booking,
--           closer y setter, Llamadas y el calculo de cierre. Correrlo
--           DESPUES de mirar los controles C1 a C4.
--
-- Sin begin/commit (SQL Editor). Correr cada bloque entero. Evitar
-- :00/:15/:30/:45 (la sync lee estas tablas). Controles abajo, de a uno.
-- Idempotente. Vuelta atras al final.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Vista de duplicadas
-- ---------------------------------------------------------------------
create or replace view fin_v_llamadas_duplicadas
with (security_invoker = true) as
with base as (
  select
    l.id,
    l.cliente_id,
    l.fecha_llamada,
    case when length(regexp_replace(coalesce(l.telefono::text, ''), '\D', '', 'g')) >= 8
         then right(regexp_replace(l.telefono::text, '\D', '', 'g'), 10) end as k_tel,
    case when position('@' in btrim(coalesce(l.email::text, ''))) > 1
         then lower(btrim(l.email::text)) end                                  as k_mail,
    case when length(lower(regexp_replace(btrim(coalesce(l.nombre, '')), '\s+', ' ', 'g'))) >= 4
          and btrim(coalesce(l.nombre, '')) ~ '[[:alpha:]]'
         then lower(regexp_replace(btrim(l.nombre), '\s+', ' ', 'g')) end      as k_nom,
    -- orden de prioridad: false antes que true
    (nullif(btrim(coalesce(l.estado_llamada, '')), '') is null)                as sin_estado,
    (l.show_up is null)                                                        as sin_show_up,
    (coalesce(l.cc_dia1, 0) + coalesce(l.cc_cerrado, 0) + coalesce(l.cc_seguimiento, 0) = 0) as sin_cash
  from fin_llamadas l
  where l.fecha_llamada is not null
),
r as (
  select b.*,
    row_number() over w_tel  as rn_tel,  first_value(b.id) over w_tel  as de_tel,
    row_number() over w_mail as rn_mail, first_value(b.id) over w_mail as de_mail,
    row_number() over w_nom  as rn_nom,  first_value(b.id) over w_nom  as de_nom
  from base b
  -- una clave nula queda en una particion propia (con el id): no agrupa
  window
    w_tel  as (partition by b.cliente_id, b.fecha_llamada, coalesce(b.k_tel,  'id:' || b.id::text)
               order by b.sin_estado, b.sin_show_up, b.sin_cash, b.id),
    w_mail as (partition by b.cliente_id, b.fecha_llamada, coalesce(b.k_mail, 'id:' || b.id::text)
               order by b.sin_estado, b.sin_show_up, b.sin_cash, b.id),
    w_nom  as (partition by b.cliente_id, b.fecha_llamada, coalesce(b.k_nom,  'id:' || b.id::text)
               order by b.sin_estado, b.sin_show_up, b.sin_cash, b.id)
)
select
  r.id,
  r.cliente_id,
  r.fecha_llamada,
  (r.rn_tel > 1 or r.rn_mail > 1 or r.rn_nom > 1) as es_duplicada,
  case when r.rn_tel  > 1 then r.de_tel
       when r.rn_mail > 1 then r.de_mail
       when r.rn_nom  > 1 then r.de_nom end       as duplicada_de,
  case when r.rn_tel  > 1 then U&'mismo tel\00E9fono el mismo d\00EDa'
       when r.rn_mail > 1 then U&'mismo email el mismo d\00EDa'
       when r.rn_nom  > 1 then U&'mismo nombre el mismo d\00EDa' end as motivo
from r;

comment on view fin_v_llamadas_duplicadas is
  'Llamadas repetidas del mismo cliente y fecha (telefono, email o nombre). es_duplicada=true: no suma en metricas (115).';

-- ---------------------------------------------------------------------
-- BLOQUE 2. Las metricas dejan afuera las duplicadas
--   Es la definicion de la 058 (mismas 29 columnas, mismo orden y tipos)
--   mas un WHERE NOT EXISTS al final. Antes de correrlo comparar con
--   produccion (C0): si la vista fue tocada despues de la 058, avisar.
-- ---------------------------------------------------------------------
create or replace view fin_v_llamadas_clasificadas
with (security_invoker = true) as
 SELECT l.id,
    l.cliente_id,
    l.fecha_llamada,
    to_char(l.fecha_llamada::timestamp with time zone, 'YYYY-MM'::text) AS periodo,
    l.nombre,
    l.programa,
    btrim(l.closer) AS closer_crudo,
    ven.vendedor_id,
    v.nombre AS vendedor,
    COALESCE(NULLIF(btrim(l.tipo_booking), ''::text), '(sin fuente)'::text) AS tipo_booking,
    l.show_up,
    l.calificacion,
    n.estado AS estado_llamada,
    COALESCE(l.cc_dia1, 0::numeric) AS cc_dia1,
    COALESCE(l.cc_cerrado, 0::numeric) AS cc_cerrado,
    COALESCE(l.cc_seguimiento, 0::numeric) AS cc_seguimiento,
    COALESCE(l.cc_dia1, 0::numeric) + COALESCE(l.cc_seguimiento, 0::numeric) AS cc_cobrado,
    COALESCE(l.cc_cerrado, 0::numeric) AS cc_valor_trato,
    l.fecha_llamada > CURRENT_DATE AS es_futura,
    l.fecha_llamada <= CURRENT_DATE AS es_agendada,
    l.fecha_llamada <= CURRENT_DATE AND l.show_up = 'si'::text AS es_presentada,
    l.fecha_llamada <= CURRENT_DATE AND l.show_up = 'no'::text AS es_no_show,
    l.fecha_llamada <= CURRENT_DATE AND (l.show_up = ANY (ARRAY['regenda'::text, 'cancelado por closer'::text])) AS es_regenda_o_cancelada,
    l.calificacion = 'calificado'::text AS es_calificada,
        CASE
            WHEN n.estado IS NOT NULL THEN n.estado = ANY (ARRAY['ADENTRO EN LLAMADA'::text, 'ADENTRO EN SEGUIMIENTO'::text])
            ELSE (COALESCE(l.cc_dia1, 0::numeric) + COALESCE(l.cc_cerrado, 0::numeric) + COALESCE(l.cc_seguimiento, 0::numeric)) > 0::numeric
        END AND l.fecha_llamada <= CURRENT_DATE AS es_cerrada,
        CASE
            WHEN n.estado IS NOT NULL THEN n.estado = 'ADENTRO EN LLAMADA'::text
            ELSE COALESCE(l.cc_dia1, 0::numeric) > 0::numeric
        END AND l.fecha_llamada <= CURRENT_DATE AS es_cerrada_en_llamada,
        CASE
            WHEN n.estado IS NOT NULL THEN n.estado = 'ADENTRO EN SEGUIMIENTO'::text
            ELSE COALESCE(l.cc_dia1, 0::numeric) = 0::numeric AND (COALESCE(l.cc_cerrado, 0::numeric) + COALESCE(l.cc_seguimiento, 0::numeric)) > 0::numeric
        END AND l.fecha_llamada <= CURRENT_DATE AS es_cerrada_en_seguimiento,
    COALESCE(n.estado, ''::text) = 'FEE'::text AND l.fecha_llamada <= CURRENT_DATE AS es_fee,
    n.estado IS NULL AS cierre_por_cash
   FROM fin_llamadas l
     CROSS JOIN LATERAL ( SELECT
            CASE
                WHEN upper(btrim(COALESCE(l.estado_llamada, ''::text))) = ANY (ARRAY[''::text, 'CONTEXTO'::text]) THEN NULL::text
                WHEN upper(btrim(l.estado_llamada)) = 'NO CALIFICA'::text THEN 'NO CALIFICADO'::text
                ELSE upper(btrim(l.estado_llamada))
            END AS estado) n
     LEFT JOIN LATERAL ( SELECT a.vendedor_id
           FROM fin_personas x
             JOIN fin_vendedor_asignaciones a ON a.vendedor_id = x.vendedor_id AND a.cliente_id = l.cliente_id
          WHERE lower(btrim(x.alias)) = lower(btrim(l.closer)) AND (x.cliente_id IS NULL OR x.cliente_id = l.cliente_id) AND (x.campo IS NULL OR (x.campo = ANY (ARRAY['closer'::text, 'ambos'::text])))
          ORDER BY (x.cliente_id IS NOT NULL) DESC
         LIMIT 1) ven ON true
     LEFT JOIN fin_vendedores v ON v.id = ven.vendedor_id
  WHERE NOT EXISTS (
          SELECT 1 FROM fin_v_llamadas_duplicadas d
           WHERE d.id = l.id AND d.es_duplicada);

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C0. ANTES del bloque 2: la vista en produccion tiene que ser la de la 058
--     (29 columnas, la ultima es cierre_por_cash). Si da otro
--     numero, NO correr el bloque 2.
-- select count(*) as columnas_esperado_29
--   from information_schema.columns where table_name = 'fin_v_llamadas_clasificadas';

-- C1. Cuantas duplicadas hay por cliente y mes (despues del bloque 1).
--     Septiembre de liam deberia bajar fuerte (hoy 172 agendadas).
-- select cliente_id, to_char(fecha_llamada, 'YYYY-MM') as periodo,
--        count(*) as filas, count(*) filter (where es_duplicada) as duplicadas
--   from fin_v_llamadas_duplicadas group by 1, 2 order by 1, 2;

-- C2. Revisar a ojo: pares duplicada / conservada de octubre y septiembre.
-- select d.fecha_llamada, d.motivo, a.nombre, a.tipo_booking as fuente_duplicada,
--        b.tipo_booking as fuente_conservada, d.id as id_dup, d.duplicada_de
--   from fin_v_llamadas_duplicadas d
--   join fin_llamadas a on a.id = d.id
--   join fin_llamadas b on b.id = d.duplicada_de
--  where d.es_duplicada and d.fecha_llamada >= '2026-09-01'
--  order by d.fecha_llamada, a.nombre;

-- C3. Cuantas mas serian duplicadas con una ventana de 3 dias (mismo
--     telefono/email, otra fecha). Si es mucho, decidir antes de ampliar.
-- select a.cliente_id, count(distinct a.id) as filas_con_gemela_en_3_dias
--   from fin_llamadas a
--   join fin_llamadas b
--     on b.cliente_id = a.cliente_id and b.id <> a.id
--    and b.fecha_llamada between a.fecha_llamada - 3 and a.fecha_llamada + 3
--    and b.fecha_llamada <> a.fecha_llamada
--    and ( (length(regexp_replace(coalesce(a.telefono::text,''),'\D','','g')) >= 8
--           and right(regexp_replace(a.telefono::text,'\D','','g'),10) = right(regexp_replace(coalesce(b.telefono::text,''),'\D','','g'),10))
--       or (position('@' in coalesce(a.email::text,'')) > 1 and lower(btrim(a.email::text)) = lower(btrim(coalesce(b.email::text,'')))) )
--  group by 1 order by 1;

-- C4. Despues del bloque 2: el total de la vista de metricas baja justo
--     por las duplicadas (diferencia contra fin_llamadas = duplicadas).
-- select (select count(*) from fin_llamadas)                     as filas,
--        (select count(*) from fin_v_llamadas_clasificadas)      as en_metricas,
--        (select count(*) from fin_v_llamadas_duplicadas where es_duplicada) as duplicadas;

-- C5. La vista conserva security_invoker: tiene que dar true en las dos.
-- select relname, coalesce('security_invoker=true' = any(reloptions), false)
--   from pg_class where relname in ('fin_v_llamadas_clasificadas', 'fin_v_llamadas_duplicadas');

-- C6. La cadena de vistas sigue viva: tiene que devolver filas, sin error.
-- select cliente_id, periodo, agendadas, presentadas, sin_show_up, cerradas
--   from fin_v_metricas_ventas where cliente_id = 'liam' order by periodo desc limit 6;

-- =====================================================================
-- VUELTA ATRAS (correr en este orden)
-- =====================================================================
-- 1) Volver a correr la seccion 3 de 058_estado_llamada_liam_lucas.sql
--    (create or replace view fin_v_llamadas_clasificadas, sin el WHERE).
--    Es el mismo texto del bloque 2 de este archivo SIN las ultimas 3
--    lineas (WHERE NOT EXISTS ...).
-- 2) drop view if exists fin_v_llamadas_duplicadas;
-- Los datos de fin_llamadas no se tocan en ningun paso, asi que no hay
-- nada que restaurar.
