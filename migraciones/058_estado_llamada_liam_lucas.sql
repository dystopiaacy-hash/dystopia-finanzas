-- =====================================================================
-- 058_estado_llamada_liam_lucas.sql
-- Ventas. La columna F de la hoja Data de liam y lucas se llama "Contexto"
-- pero es el ESTADO DE LA LLAMADA (mismo desplegable que teo y mauro).
--   liam:  estaba mapeada a contexto_setter -> pasa a estado_llamada
--   lucas: no estaba mapeada                -> se agrega como estado_llamada
-- Ademas la vista base normaliza el estado:
--   'NO CALIFICA' -> 'NO CALIFICADO' (variante de liam)
--   'Contexto' y vacio -> NULL (es el encabezado usado como opcion vacia)
--
-- Efecto: liam y lucas dejan de decidir el cierre por cash y pasan a
-- decidirlo por estado, como teo y mauro. Los FEE de lucas dejan de contar
-- como cerradas. El cash sigue como respaldo solo para filas sin estado.
--
-- No toca datos de fin_llamadas: los corrige la proxima sincronizacion
-- (reemplazo completo por fuente cada 15 min) usando el alias nuevo.
--
-- Idempotente. Sin begin/commit (el SQL Editor). Corre las 3 partes
-- juntas; los controles van abajo, de a uno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. liam: "Contexto" pasa de contexto_setter a estado_llamada
-- ---------------------------------------------------------------------
update fin_alias_columnas a
   set campo_canonico = 'estado_llamada'
  from fin_fuentes f
 where f.id = a.fuente_id
   and f.tipo = 'data'
   and f.cliente_id = 'liam'
   and a.alias = 'Contexto'
   and a.campo_canonico = 'contexto_setter';

-- ---------------------------------------------------------------------
-- 2. lucas: agregar "Contexto" como estado_llamada
-- ---------------------------------------------------------------------
insert into fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio)
select f.id, 'estado_llamada', 'Contexto', false
  from fin_fuentes f
 where f.tipo = 'data'
   and f.cliente_id = 'lucas'
   and not exists (
         select 1 from fin_alias_columnas a
          where a.fuente_id = f.id
            and a.campo_canonico = 'estado_llamada');

-- ---------------------------------------------------------------------
-- 3. Vista base: estado normalizado en un solo lugar
--    Mismas columnas, mismo orden y mismos tipos que la version actual,
--    asi las vistas que cuelgan de esta no se rompen.
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
     LEFT JOIN fin_vendedores v ON v.id = ven.vendedor_id;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Alias de estado: tienen que salir 4 filas.
--     liam Contexto | lucas Contexto | mauro Estado de la llamada | teo Estado de la llamada
-- select f.cliente_id, a.campo_canonico, a.alias
--   from fin_alias_columnas a join fin_fuentes f on f.id = a.fuente_id
--  where f.tipo = 'data' and a.campo_canonico = 'estado_llamada'
--  order by 1;

-- C2. liam ya no tiene contexto_setter: tiene que dar 0.
-- select count(*) from fin_alias_columnas a join fin_fuentes f on f.id = a.fuente_id
--  where f.tipo = 'data' and f.cliente_id = 'liam' and a.campo_canonico = 'contexto_setter';

-- C3. La vista sigue con security_invoker: tiene que dar true.
-- select coalesce('security_invoker=true' = any(reloptions), false)
--   from pg_class where relname = 'fin_v_llamadas_clasificadas';

-- C4. La cadena de vistas sigue viva: tiene que devolver un numero, sin error.
-- select count(*) from fin_v_metricas_ventas;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================

-- C5. Estado cargado: liam ~505 y lucas ~500 en con_estado.
-- select cliente_id, count(*) as filas,
--        count(*) filter (where estado_llamada is not null) as con_estado
--   from fin_llamadas group by 1 order by 1;

-- C6. Cerradas "despues", para comparar con la foto de antes (consulta D).
--     liam casi igual. lucas baja a la mitad y aparecen los fee.
-- select cliente_id, periodo,
--        count(*) filter (where es_cerrada) as cerradas,
--        count(*) filter (where es_fee) as fee
--   from fin_v_llamadas_clasificadas
--  where cliente_id in ('liam', 'lucas')
--  group by 1, 2 order by 1, 2;
