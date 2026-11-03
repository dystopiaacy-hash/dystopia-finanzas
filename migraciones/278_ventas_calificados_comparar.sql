-- =====================================================================
-- 278_ventas_calificados_comparar.sql
-- Ventas > Comparar. Calificados por fuente, por closer y por setter.
-- Hoy Comparar solo muestra "Calificados" como total del mes (las vistas
-- fin_v_metricas_booking y fin_v_metricas_closer no traen la columna).
--
-- QUE HACE: crea UNA vista de solo lectura, fin_v_calificados_comparar, con
-- una fila por cliente, mes, dimension y clave:
--   dimension = 'fuente'  -> clave = upper(tipo_booking) (igual que la vista
--                            de booking; el front la normaliza como Comparar:
--                            TT = TIKTOK, sin tildes ni mayusculas; vacia =
--                            "(SIN FUENTE)". Si la clave es null viene null.)
--   dimension = 'closer'  -> clave = coalesce(vendedor, closer_crudo), igual
--                            que fin_v_metricas_closer.
--   dimension = 'setter'  -> clave = setter de fin_v_llamadas_setter, solo las
--                            llamadas con setter atribuido (igual que
--                            fin_v_metricas_setter).
--   calificadas = count(es_agendada y es_calificada): la MISMA definicion de
--   fin_v_metricas_ventas (016+), setter (117) y closer.
--
-- PERMISOS: security_invoker (como las vistas que Comparar ya lee): manda la
-- RLS de fin_llamadas. Grant solo a authenticated (no anon). Comparar es de
-- fundador, cliente y ventas; closer y setter no entran a esa pantalla.
-- No toca datos, tablas, politicas ni otras vistas.
--
-- Requiere: fin_v_llamadas_clasificadas, fin_v_llamadas_setter.
-- Sin begin/commit (SQL Editor). Correr los BLOQUES EN ORDEN, cada uno
-- entero, fuera de :00/:15/:30/:45. Controles y vuelta atras al final.
-- Orden: BLOQUE 1 (crea) -> BLOQUE 2 (humo: DEBE terminar en ERROR
-- "HUMO 278 OK"; se revierte solo) -> controles C1..C5 de a uno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas + vista
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.fin_v_llamadas_clasificadas') is null then
    raise exception '278: falta fin_v_llamadas_clasificadas';
  end if;
  if to_regclass('public.fin_v_llamadas_setter') is null then
    raise exception '278: falta fin_v_llamadas_setter';
  end if;
  if to_regclass('public.fin_v_calificados_comparar') is not null then
    raise exception '278: ya existe fin_v_calificados_comparar (para rehacerla, ver la vuelta atras)';
  end if;
end $$;

create view public.fin_v_calificados_comparar
with (security_invoker = true) as
select l.cliente_id, l.periodo, 'fuente'::text as dimension,
       upper(l.tipo_booking)::text as clave,
       count(*) filter (where l.es_agendada and l.es_calificada) as calificadas
from public.fin_v_llamadas_clasificadas l
group by l.cliente_id, l.periodo, upper(l.tipo_booking)
union all
select l.cliente_id, l.periodo, 'closer'::text,
       coalesce(l.vendedor, l.closer_crudo)::text,
       count(*) filter (where l.es_agendada and l.es_calificada)
from public.fin_v_llamadas_clasificadas l
group by l.cliente_id, l.periodo, coalesce(l.vendedor, l.closer_crudo)
union all
select l.cliente_id, l.periodo, 'setter'::text,
       s.setter::text,
       count(*) filter (where l.es_agendada and l.es_calificada)
from public.fin_v_llamadas_clasificadas l
join public.fin_v_llamadas_setter s on s.llamada_id = l.id
where s.setter_vendedor_id is not null
group by l.cliente_id, l.periodo, s.setter_vendedor_id, s.setter;

comment on view public.fin_v_calificados_comparar is
  'Calificados (agendada y calificada) por cliente, mes y dimension (fuente, closer, setter). Solo lectura; para Ventas > Comparar (278).';

revoke all on public.fin_v_calificados_comparar from public, anon;
grant select on public.fin_v_calificados_comparar to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. HUMO (no modifica nada: termina SIEMPRE en ERROR).
-- Correr despues del bloque 1. Resultado correcto: ERROR "HUMO 278 OK".
-- Cualquier otro mensaje = algo no cierra; pasarlo.
-- ---------------------------------------------------------------------
do $$
declare
  n_cols int;
  n_dif int;
  n_set int;
  n_anon boolean;
  n_inv boolean;
begin
  select count(*) into n_cols from information_schema.columns
   where table_schema = 'public' and table_name = 'fin_v_calificados_comparar';
  if n_cols <> 5 then
    raise exception 'HUMO 278 FALLA: columnas esperadas 5, hay %', n_cols;
  end if;

  -- Por fuente y por closer suman lo mismo que fin_v_metricas_ventas, por cliente y mes.
  select count(*) into n_dif from (
    select v.cliente_id, v.periodo, v.calificadas,
           coalesce(sum(c.calificadas) filter (where c.dimension = 'fuente'), 0) as por_fuente,
           coalesce(sum(c.calificadas) filter (where c.dimension = 'closer'), 0) as por_closer
      from public.fin_v_metricas_ventas v
      left join public.fin_v_calificados_comparar c
             on c.cliente_id = v.cliente_id and c.periodo = v.periodo
     group by v.cliente_id, v.periodo, v.calificadas
  ) t where t.calificadas <> t.por_fuente or t.calificadas <> t.por_closer;
  if n_dif <> 0 then
    raise exception 'HUMO 278 FALLA: % meses donde fuente o closer no suman el total de fin_v_metricas_ventas', n_dif;
  end if;

  -- Setter nunca pasa del total del mes.
  select count(*) into n_set from (
    select c.cliente_id, c.periodo, sum(c.calificadas) as s
      from public.fin_v_calificados_comparar c where c.dimension = 'setter'
     group by 1, 2
  ) x join public.fin_v_metricas_ventas v using (cliente_id, periodo)
  where x.s > v.calificadas;
  if n_set <> 0 then
    raise exception 'HUMO 278 FALLA: % meses donde setter supera el total', n_set;
  end if;

  select has_table_privilege('anon', 'public.fin_v_calificados_comparar', 'select') into n_anon;
  if n_anon then
    raise exception 'HUMO 278 FALLA: anon puede leer la vista';
  end if;

  select coalesce('security_invoker=true' = any(reloptions), false) into n_inv
    from pg_class where oid = 'public.fin_v_calificados_comparar'::regclass;
  if not n_inv then
    raise exception 'HUMO 278 FALLA: la vista no es security_invoker';
  end if;

  raise exception 'HUMO 278 OK';
end $$;

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno; no modifican nada)
-- =====================================================================

-- C1. La vista existe, es security_invoker y anon no la lee.
-- select c.relname, coalesce('security_invoker=true' = any(c.reloptions), false) as invoker,
--        has_table_privilege('anon', c.oid, 'select') as anon,
--        has_table_privilege('authenticated', c.oid, 'select') as auth
--   from pg_class c where c.relname = 'fin_v_calificados_comparar';
--   -- esperado: invoker = true, anon = false, auth = true

-- C2. Liam, ultimo mes con datos: calificados por dimension.
-- select dimension, clave, calificadas from fin_v_calificados_comparar
--  where cliente_id = 'liam' and periodo = (select max(periodo) from fin_v_metricas_ventas where cliente_id = 'liam')
--  order by dimension, calificadas desc;

-- C3. Por fuente y por closer suman el total de la vista de ventas (esperado: 0 filas).
-- select v.cliente_id, v.periodo, v.calificadas as total,
--        sum(c.calificadas) filter (where c.dimension = 'fuente') as fuente,
--        sum(c.calificadas) filter (where c.dimension = 'closer') as closer
--   from fin_v_metricas_ventas v
--   join fin_v_calificados_comparar c using (cliente_id, periodo)
--  group by 1, 2, 3
-- having v.calificadas <> sum(c.calificadas) filter (where c.dimension = 'fuente')
--     or v.calificadas <> sum(c.calificadas) filter (where c.dimension = 'closer');

-- C4. Setter coincide con la vista de setters (esperado: 0 filas).
-- select s.cliente_id, s.periodo, s.vendedor, s.calificadas as vista_setter, c.calificadas as nueva
--   from fin_v_metricas_setter s
--   left join fin_v_calificados_comparar c
--          on c.cliente_id = s.cliente_id and c.periodo = s.periodo
--         and c.dimension = 'setter' and c.clave = s.vendedor
--  where c.calificadas is distinct from s.calificadas;

-- C5. Tiempo: tiene que contestar en pocos segundos.
-- select count(*) from fin_v_calificados_comparar;

-- =====================================================================
-- VUELTA ATRAS
-- =====================================================================
--   drop view if exists public.fin_v_calificados_comparar;
