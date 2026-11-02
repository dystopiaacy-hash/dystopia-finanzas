-- =====================================================================
-- 276 · Los pagos "SIN IDENTIFICAR" no cuentan como alumno
-- Numero asignado por el jefe. ESCRITA, SIN correr, SQL NO probado.
--
-- Decision de Joaquin (2/11): un pago cuyo alumno es vacio, "-" o EMPIEZA con "SIN IDENTIFICAR" (con o sin texto entre
-- parentesis: "SIN IDENTIFICAR (Liam: Alejandro Abriola)", "SIN IDENTIFICAR (jmacff@hotmail.com)") NO es un alumno.
-- Se normaliza: mayusculas, tildes, espacios y signos.
--
-- Que cambia:
--   - No cuenta como alumno (ni como alumno nuevo) donde se cuentan alumnos: regla de fuente Webinar (273), cierres del
--     ranking de closers (fin_v_ranking_closers), lista y resumen de "Vincular alumnos" (fin_cs_alumnos) y "Mis numeros" (JS).
--   - Regla de webinar (273): el pago no tiene "primer pago" propio ni hereda de otros SIN IDENTIFICAR. Su fuente es la que
--     diga la planilla para ESE pago, tal cual (si no dice nada, queda sin fuente aunque caiga en una ventana).
--   - No aparece en el control de duplicados (C5 de esta migracion reemplaza al C6 de la 273).
--   - El pago SIGUE sumando a facturacion, ganancia y comisiones: no se toca fin_pagos, ni fin_v_dys_ganancia_mes, ni
--     fin_v_cierre_ventas, ni la sync, ni porcentajes. No cierra octubre.
--   - La regla vive en un solo lugar: fin_es_sin_alumno(texto) (como fin_es_sin_persona de la 275).
--
-- BLOQUES (correr de a uno, en orden; cada uno tiene su comentario BLOQUE):
--   0. Guardas (solo lectura)
--   1. fin_es_sin_alumno(texto)
--   2. Humo informativo (se revierte solo: termina SIEMPRE en ERROR "HUMO 276 OK ...") con pagos SIN IDENTIFICAR por cliente
--      y mes, y webinars de octubre antes/despues, y alumnos nuevos de octubre antes/despues
--   3. La migracion real: foto del antes + vistas/funciones nuevas
--   4. Humo con filas de prueba (se revierte solo: termina SIEMPRE en ERROR "HUMO 276 OK")
--   Controles C1-C6 al final, de a uno. No correr a las :00/:15/:30/:45 ni a las 9:00.
-- Despues (lo corre el jefe): en Cierre de mes, "Calcular transferencias" de octubre. La pantalla Webinars ya lee la vista.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (solo lectura)
-- ---------------------------------------------------------------------
do $g$
declare v text;
begin
  if to_regclass('public.fin_pago_fuente_calc') is null or to_regclass('public.fin_v_pago_fuente') is null then
    raise exception 'GUARDA 276: falta la 271/273 (fin_pago_fuente_calc, fin_v_pago_fuente). No se toca nada.';
  end if;
  v := pg_get_viewdef('public.fin_pago_fuente_calc'::regclass);
  if v not like '%marca_webinar_descartada%' then
    raise exception 'GUARDA 276: fin_pago_fuente_calc no es la de la 273. No se toca nada.';
  end if;
  if to_regclass('public.fin_pago_fuente_antes_273') is null then
    raise exception 'GUARDA 276: falta la foto fin_pago_fuente_antes_273 de la 273. No se toca nada.';
  end if;
  if to_regclass('public.fin_webinars') is null or to_regclass('public.fin_v_webinar_resultado') is null then
    raise exception 'GUARDA 276: falta la 267 (fin_webinars, fin_v_webinar_resultado).';
  end if;
  if to_regprocedure('public.fin_es_sin_persona(text)') is null then
    raise exception 'GUARDA 276: falta la 275 (fin_es_sin_persona).';
  end if;
  if to_regclass('public.fin_v_ranking_closers') is null
     or pg_get_viewdef('public.fin_v_ranking_closers'::regclass) not like '%cierres%' then
    raise exception 'GUARDA 276: fin_v_ranking_closers no es la de la 003.';
  end if;
  if to_regprocedure('public.fin_cs_alumnos(text)') is null or to_regprocedure('public.fin_cs_norm_nombre(text)') is null then
    raise exception 'GUARDA 276: falta la 129 (fin_cs_alumnos).';
  end if;
  v := pg_get_functiondef('public.fin_cs_alumnos(text)'::regprocedure);
  if v not like '%fin_cuotas%' then
    raise exception 'GUARDA 276: fin_cs_alumnos no es la de la 129. No se toca nada.';
  end if;
  if to_regclass('public.fin_pago_fuente_antes_276') is null
     and pg_get_viewdef('public.fin_pago_fuente_calc'::regclass) like '%sin_alumno%' then
    raise exception 'GUARDA 276: la vista ya es la nueva y no hay foto del antes (fin_pago_fuente_antes_276).';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. La regla en un solo lugar
-- ---------------------------------------------------------------------
create or replace function public.fin_es_sin_alumno(p text)
returns boolean language sql immutable as $f$
  select btrim(regexp_replace(lower(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) = ''
      or btrim(regexp_replace(lower(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g'))
         like 'sin identificar%'
$f$;

comment on function public.fin_es_sin_alumno(text) is
  '276: true si el alumno del pago es vacio, "-" o empieza con SIN IDENTIFICAR (con o sin texto despues). Ese pago no es un alumno: no cuenta como alumno ni como alumno nuevo, pero sigue sumando plata.';

revoke all on function public.fin_es_sin_alumno(text) from public, anon;
grant execute on function public.fin_es_sin_alumno(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Humo informativo (se revierte solo: termina SIEMPRE en ERROR "HUMO 276 OK: ...")
--   Prueba la regla, y en el mensaje trae: pagos SIN IDENTIFICAR por cliente y mes; webinars de octubre por cliente
--   (pagos / USD) ANTES (vista 273) y DESPUES (vista nueva, aplicada solo dentro de este bloque); alumnos nuevos de
--   octubre por cliente antes y despues. Todo se deshace al terminar. Hay que correr antes el BLOQUE 1.
-- ---------------------------------------------------------------------
do $h$
declare
  r record; t text; v_txt text := '';
begin
  -- la regla: tiene que decir que si
  foreach t in array array['SIN IDENTIFICAR', 'sin identificar', 'Sin  Identificar (Liam: Alejandro Abriola)',
                           'SIN IDENTIFICAR (jmacff@hotmail.com)', 'Sín Identificár', '  sin identificar - efectivo',
                           '-', '--', '', '   '] loop
    if not public.fin_es_sin_alumno(t) then
      raise exception 'HUMO 276: la regla no reconoce [%]', t;
    end if;
  end loop;
  if public.fin_es_sin_alumno(null) is not true then raise exception 'HUMO 276: null tiene que ser sin alumno'; end if;
  -- y tiene que decir que no a alumnos reales
  foreach t in array array['Juan Perez', 'Leonel Abella', 'Maria sin identificar', 'Sinai Identificar', 'Identificar Sin',
                           'Matias German Bosio', 'Nahuel Smerdel Bruno Díaz'] loop
    if public.fin_es_sin_alumno(t) then raise exception 'HUMO 276: la regla toma por sin alumno a [%]', t; end if;
  end loop;

  -- A. pagos SIN IDENTIFICAR (o sin alumno) por cliente y mes
  for r in
    select p.cliente_id, to_char(date_trunc('month', p.fecha), 'YYYY-MM') as mes, count(*) as n, coalesce(sum(p.monto_usd), 0) as usd
      from public.fin_pagos p
     where public.fin_es_sin_alumno(p.alumno)
     group by 1, 2 order by 1, 2
  loop
    v_txt := v_txt || format(' [%s %s: %s pagos, USD %s]', r.cliente_id, r.mes, r.n, r.usd);
  end loop;
  v_txt := 'SIN IDENTIFICAR por cliente y mes:' || coalesce(nullif(v_txt, ''), ' ninguno') || ' || ';

  -- B. webinars de octubre ANTES (vista 273)
  create temp table _h276 as
  select w.id, w.cliente_id, w.nombre, w.fecha,
         (select count(*) from public.fin_pago_fuente_calc c
           where c.cliente_id = w.cliente_id and c.es_webinar
             and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as n0,
         (select coalesce(sum(c.monto_usd), 0) from public.fin_pago_fuente_calc c
           where c.cliente_id = w.cliente_id and c.es_webinar
             and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as usd0,
         0::bigint as n1, 0::numeric as usd1
    from public.fin_webinars w
   where w.activo and w.fecha >= date '2026-10-01' and w.fecha < date '2026-11-01';

  -- vista nueva (solo dentro de este bloque: se deshace con el ERROR final)
  execute $q$
create or replace view public.fin_pago_fuente_calc as
with base as (
  select p.id, p.cliente_id, p.clave, p.fecha, p.alumno, p.monto_usd, p.concepto, p.fila_planilla,
         nullif(btrim(p.fuente_lead), '') as lead_crudo,
         nullif(btrim(p.fuente_ingreso), '') as ingreso,
         (coalesce(p.nota, '') ilike '%fuente inferida%') as nota_inferida,
         -- 276: un pago "SIN IDENTIFICAR" (o sin alumno) no es un alumno: k vacio => no tiene primer pago ni hereda
         public.fin_es_sin_alumno(p.alumno) as sin_alumno,
         case when public.fin_es_sin_alumno(p.alumno) then ''
              else btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) end as k
    from public.fin_pagos p
), ex as (
  select b.*,
         -- Webinar escrito por la regla vieja (nota "Fuente inferida"): no cuenta como marca explicita (igual que la 271).
         case when b.lead_crudo is not null and b.nota_inferida
                   and (b.lead_crudo ilike '%webinar%' or b.lead_crudo ilike '%replay%') then null
              else b.lead_crudo end as lead_valido
    from base b
), prop as (
  select e.*,
         case when e.ingreso = 'Webinar' then 'Webinar' else coalesce(e.lead_valido, e.ingreso) end as fuente_explicita,
         exists (select 1 from public.fin_webinars w
                  where w.activo and w.cliente_id = e.cliente_id
                    and e.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as en_ventana,
         -- 273 (Joaquin 2/11): inicio del primer webinar cargado del cliente; antes de esa fecha la marca de la planilla se respeta
         (select min(coalesce(w.ventana_desde, w.fecha)) from public.fin_webinars w
           where w.activo and w.cliente_id = e.cliente_id) as min_web
    from ex e
), prop2 as (
  select q.*,
         -- 273: marca Webinar/Replay de la planilla (la unica que la regla nueva puede descartar)
         (coalesce(q.fuente_explicita, '') ilike '%webinar%' or coalesce(q.fuente_explicita, '') ilike '%replay%') as marca_web
    from prop q
), primero as (
  select distinct on (cliente_id, k) cliente_id, k, id as primero_id
    from prop2
   where monto_usd > 0 and k <> ''
   order by cliente_id, k, fecha, fila_planilla nulls last, id
), r as (
  -- una fila por pago con los datos de su primer pago (f) y si la marca Webinar vale
  select q.*,
         f.id as f_id, f.clave as f_clave, f.fecha as f_fecha, f.fuente_explicita as f_expl,
         f.marca_web as f_marca_web, f.en_ventana as f_en_ventana,
         -- el primer pago (o el propio pago si no se identifica el primero) cae en la ventana de algun webinar
         coalesce(f.en_ventana, q.en_ventana) as ref_en_ventana,
         -- el primer pago (o el propio) es anterior al primer webinar cargado del cliente: historico, la marca se respeta
         (q.min_web is null or coalesce(f.fecha, q.fecha) < q.min_web) as ref_previo,
         (q.min_web is null or f.fecha < q.min_web) as f_previo
    from prop2 q
    left join primero pr on pr.cliente_id = q.cliente_id and pr.k = q.k
    left join prop2 f on f.id = pr.primero_id
), s as (
  select r.*,
         -- fuente explicita que VALE: una marca no-Webinar siempre; una marca Webinar solo si el primer pago cae en ventana
         -- 276: sin alumno => vale lo que diga la planilla para ese pago, tal cual
         case when r.sin_alumno then r.fuente_explicita
              when r.fuente_explicita is null then null
              when r.marca_web and not r.ref_en_ventana and not r.ref_previo then null
              else r.fuente_explicita end as expl_vale,
         -- fuente del primer pago (para heredar): su marca si vale (para el, ref = el mismo), o Webinar si cae en ventana
         case when r.f_expl is not null and not (r.f_marca_web and not r.f_en_ventana and not coalesce(r.f_previo, false)) then r.f_expl
              when r.f_en_ventana then 'Webinar' end as f_fuente
    from r
), t as (
  select s.*,
         case when s.sin_alumno then s.fuente_explicita
              when s.expl_vale is not null then s.expl_vale
              when s.f_id is null or s.f_id = s.id then case when s.en_ventana then 'Webinar' end
              else s.f_fuente end as ff
    from s
)
select t.id as pago_id, t.cliente_id, t.clave as pago_clave, t.fecha, t.alumno, t.monto_usd, t.concepto,
       t.lead_crudo as fuente_planilla,
       t.nota_inferida as fuente_inferida_vieja,
       t.fuente_explicita,
       t.f_clave as primer_pago_clave, t.f_fecha as primer_pago_fecha,
       t.ff as fuente_final,
       case when t.sin_alumno then
                 case when t.fuente_explicita is not null then 'pago sin alumno identificado: fuente de la planilla'
                      else 'pago sin alumno identificado: sin dato' end
            when t.expl_vale is not null then 'explicita en la planilla'
            when t.fuente_explicita is not null then
                 'marca Webinar de la planilla no vale (el primer pago del alumno cae fuera de toda ventana): '
                 || case when t.f_id is null or t.f_id = t.id then 'sin dato'
                         when t.f_fuente is not null then 'hereda la fuente del primer pago'
                         else 'hereda del primer pago, que no tiene fuente' end
            when t.f_id is null then case when t.en_ventana then 'sin primer pago identificable: cae en ventana de webinar' else 'sin dato' end
            when t.f_id = t.id then case when t.en_ventana then 'primer pago dentro de la ventana de un webinar' else 'primer pago fuera de toda ventana: sin dato' end
            when t.f_fuente is not null then 'hereda la fuente del primer pago'
            else 'hereda del primer pago, que no tiene fuente' end as criterio,
       (coalesce(t.ff, '') ilike '%webinar%' or coalesce(t.ff, '') ilike '%replay%') as es_webinar,
       -- 273 (al final para no mover las columnas de la 271)
       nullif(btrim(t.ingreso), '') as fuente_ingreso_planilla,
       (t.fuente_explicita is not null and t.expl_vale is null) as marca_webinar_descartada,
       t.ref_en_ventana as primer_pago_en_ventana,
       -- 276 (al final): el pago no tiene alumno identificado
       t.sin_alumno as sin_alumno
  from t;
  $q$;

  -- B. webinars de octubre DESPUES
  update _h276 h set
    n1 = (select count(*) from public.fin_pago_fuente_calc c, public.fin_webinars w
           where w.id = h.id and c.cliente_id = w.cliente_id and c.es_webinar
             and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)),
    usd1 = (select coalesce(sum(c.monto_usd), 0) from public.fin_pago_fuente_calc c, public.fin_webinars w
             where w.id = h.id and c.cliente_id = w.cliente_id and c.es_webinar
               and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias));
  v_txt := v_txt || 'WEBINARS DE OCTUBRE (pagos / USD, antes -> despues):';
  for r in select * from _h276 order by fecha, cliente_id loop
    v_txt := v_txt || format(' [%s %s: %s / %s -> %s / %s]', r.cliente_id, r.nombre, r.n0, r.usd0, r.n1, r.usd1);
  end loop;
  v_txt := v_txt || ' || ';

  -- C. alumnos nuevos de octubre (alumno con su primer pago > 0 en octubre), antes y despues
  v_txt := v_txt || 'ALUMNOS NUEVOS DE OCTUBRE (antes -> despues):';
  for r in
    with p as (
      select pg.cliente_id, public.fin_es_sin_alumno(pg.alumno) as sin, pg.fecha,
             btrim(regexp_replace(lower(translate(coalesce(pg.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k
        from public.fin_pagos pg where pg.monto_usd > 0
    ), pr as (
      select cliente_id, sin, k, min(fecha) as f from p where k <> '' group by 1, 2, 3
    )
    select cliente_id,
           count(*) filter (where f >= date '2026-10-01' and f < date '2026-11-01') as antes,
           count(*) filter (where f >= date '2026-10-01' and f < date '2026-11-01' and not sin) as despues
      from pr group by 1 order by 1
  loop
    v_txt := v_txt || format(' [%s: %s -> %s]', r.cliente_id, r.antes, r.despues);
  end loop;

  raise exception 'HUMO 276 OK: %', v_txt;
end
$h$;

-- ---------------------------------------------------------------------
-- BLOQUE 3. La migracion real (hay que haber corrido el BLOQUE 1)
--   3a. foto del "antes" (solo si no existe: volver a correr no la pisa)
--   3b. fin_pago_fuente_calc y fin_v_pago_fuente (regla de la 273 + SIN IDENTIFICAR no es alumno)
--   3c. fin_v_ranking_closers (los cierres no cuentan SIN IDENTIFICAR)
--   3d. fin_cs_alumnos (Vincular alumnos no lista SIN IDENTIFICAR)
-- ---------------------------------------------------------------------
do $f$
begin
  if to_regprocedure('public.fin_es_sin_alumno(text)') is null then
    raise exception 'GUARDA 276: corre primero el BLOQUE 1 (fin_es_sin_alumno).';
  end if;
  if to_regclass('public.fin_pago_fuente_antes_276') is null then
    if pg_get_viewdef('public.fin_pago_fuente_calc'::regclass) like '%sin_alumno%' then
      raise exception 'GUARDA 276: la vista ya es la nueva y no hay foto del antes. Los controles de "antes" no se pueden armar.';
    end if;
    create table public.fin_pago_fuente_antes_276 as
      select pago_id, cliente_id, pago_clave, fecha, alumno, monto_usd, concepto, fuente_planilla, fuente_final, es_webinar,
             now() as foto_en
        from public.fin_pago_fuente_calc;
    alter table public.fin_pago_fuente_antes_276 enable row level security;
    revoke all on public.fin_pago_fuente_antes_276 from public, anon, authenticated;
    grant select on public.fin_pago_fuente_antes_276 to service_role;
    comment on table public.fin_pago_fuente_antes_276 is
      '276: foto de fin_pago_fuente_calc (regla de la 273) tomada antes de la 276, para comparar antes y despues. Se puede borrar cuando Joaquin lo decida.';
  end if;
end
$f$;

create or replace view public.fin_pago_fuente_calc as
with base as (
  select p.id, p.cliente_id, p.clave, p.fecha, p.alumno, p.monto_usd, p.concepto, p.fila_planilla,
         nullif(btrim(p.fuente_lead), '') as lead_crudo,
         nullif(btrim(p.fuente_ingreso), '') as ingreso,
         (coalesce(p.nota, '') ilike '%fuente inferida%') as nota_inferida,
         -- 276: un pago "SIN IDENTIFICAR" (o sin alumno) no es un alumno: k vacio => no tiene primer pago ni hereda
         public.fin_es_sin_alumno(p.alumno) as sin_alumno,
         case when public.fin_es_sin_alumno(p.alumno) then ''
              else btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) end as k
    from public.fin_pagos p
), ex as (
  select b.*,
         -- Webinar escrito por la regla vieja (nota "Fuente inferida"): no cuenta como marca explicita (igual que la 271).
         case when b.lead_crudo is not null and b.nota_inferida
                   and (b.lead_crudo ilike '%webinar%' or b.lead_crudo ilike '%replay%') then null
              else b.lead_crudo end as lead_valido
    from base b
), prop as (
  select e.*,
         case when e.ingreso = 'Webinar' then 'Webinar' else coalesce(e.lead_valido, e.ingreso) end as fuente_explicita,
         exists (select 1 from public.fin_webinars w
                  where w.activo and w.cliente_id = e.cliente_id
                    and e.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as en_ventana,
         -- 273 (Joaquin 2/11): inicio del primer webinar cargado del cliente; antes de esa fecha la marca de la planilla se respeta
         (select min(coalesce(w.ventana_desde, w.fecha)) from public.fin_webinars w
           where w.activo and w.cliente_id = e.cliente_id) as min_web
    from ex e
), prop2 as (
  select q.*,
         -- 273: marca Webinar/Replay de la planilla (la unica que la regla nueva puede descartar)
         (coalesce(q.fuente_explicita, '') ilike '%webinar%' or coalesce(q.fuente_explicita, '') ilike '%replay%') as marca_web
    from prop q
), primero as (
  select distinct on (cliente_id, k) cliente_id, k, id as primero_id
    from prop2
   where monto_usd > 0 and k <> ''
   order by cliente_id, k, fecha, fila_planilla nulls last, id
), r as (
  -- una fila por pago con los datos de su primer pago (f) y si la marca Webinar vale
  select q.*,
         f.id as f_id, f.clave as f_clave, f.fecha as f_fecha, f.fuente_explicita as f_expl,
         f.marca_web as f_marca_web, f.en_ventana as f_en_ventana,
         -- el primer pago (o el propio pago si no se identifica el primero) cae en la ventana de algun webinar
         coalesce(f.en_ventana, q.en_ventana) as ref_en_ventana,
         -- el primer pago (o el propio) es anterior al primer webinar cargado del cliente: historico, la marca se respeta
         (q.min_web is null or coalesce(f.fecha, q.fecha) < q.min_web) as ref_previo,
         (q.min_web is null or f.fecha < q.min_web) as f_previo
    from prop2 q
    left join primero pr on pr.cliente_id = q.cliente_id and pr.k = q.k
    left join prop2 f on f.id = pr.primero_id
), s as (
  select r.*,
         -- fuente explicita que VALE: una marca no-Webinar siempre; una marca Webinar solo si el primer pago cae en ventana
         -- 276: sin alumno => vale lo que diga la planilla para ese pago, tal cual
         case when r.sin_alumno then r.fuente_explicita
              when r.fuente_explicita is null then null
              when r.marca_web and not r.ref_en_ventana and not r.ref_previo then null
              else r.fuente_explicita end as expl_vale,
         -- fuente del primer pago (para heredar): su marca si vale (para el, ref = el mismo), o Webinar si cae en ventana
         case when r.f_expl is not null and not (r.f_marca_web and not r.f_en_ventana and not coalesce(r.f_previo, false)) then r.f_expl
              when r.f_en_ventana then 'Webinar' end as f_fuente
    from r
), t as (
  select s.*,
         case when s.sin_alumno then s.fuente_explicita
              when s.expl_vale is not null then s.expl_vale
              when s.f_id is null or s.f_id = s.id then case when s.en_ventana then 'Webinar' end
              else s.f_fuente end as ff
    from s
)
select t.id as pago_id, t.cliente_id, t.clave as pago_clave, t.fecha, t.alumno, t.monto_usd, t.concepto,
       t.lead_crudo as fuente_planilla,
       t.nota_inferida as fuente_inferida_vieja,
       t.fuente_explicita,
       t.f_clave as primer_pago_clave, t.f_fecha as primer_pago_fecha,
       t.ff as fuente_final,
       case when t.sin_alumno then
                 case when t.fuente_explicita is not null then 'pago sin alumno identificado: fuente de la planilla'
                      else 'pago sin alumno identificado: sin dato' end
            when t.expl_vale is not null then 'explicita en la planilla'
            when t.fuente_explicita is not null then
                 'marca Webinar de la planilla no vale (el primer pago del alumno cae fuera de toda ventana): '
                 || case when t.f_id is null or t.f_id = t.id then 'sin dato'
                         when t.f_fuente is not null then 'hereda la fuente del primer pago'
                         else 'hereda del primer pago, que no tiene fuente' end
            when t.f_id is null then case when t.en_ventana then 'sin primer pago identificable: cae en ventana de webinar' else 'sin dato' end
            when t.f_id = t.id then case when t.en_ventana then 'primer pago dentro de la ventana de un webinar' else 'primer pago fuera de toda ventana: sin dato' end
            when t.f_fuente is not null then 'hereda la fuente del primer pago'
            else 'hereda del primer pago, que no tiene fuente' end as criterio,
       (coalesce(t.ff, '') ilike '%webinar%' or coalesce(t.ff, '') ilike '%replay%') as es_webinar,
       -- 273 (al final para no mover las columnas de la 271)
       nullif(btrim(t.ingreso), '') as fuente_ingreso_planilla,
       (t.fuente_explicita is not null and t.expl_vale is null) as marca_webinar_descartada,
       t.ref_en_ventana as primer_pago_en_ventana,
       -- 276 (al final): el pago no tiene alumno identificado
       t.sin_alumno as sin_alumno
  from t;

comment on view public.fin_pago_fuente_calc is
  '276: fuente de cada pago (regla de la 273). Un pago sin alumno identificado (SIN IDENTIFICAR, vacio, -) no tiene primer pago ni hereda: vale la fuente que diga la planilla para ese pago. Interna, sin permisos para la app. No toca fin_pagos.';

create or replace view public.fin_v_pago_fuente as
select * from public.fin_pago_fuente_calc
 where public.fin_dys_puede_ver() or public.fin_gastos_puede_ver();

comment on view public.fin_v_pago_fuente is
  '276: igual a fin_pago_fuente_calc pero solo para quien ve Dystopia o Gastos.';

revoke all on public.fin_pago_fuente_calc, public.fin_v_pago_fuente from public, anon, authenticated;
grant select on public.fin_v_pago_fuente to authenticated;
grant select on public.fin_pago_fuente_calc, public.fin_v_pago_fuente to service_role;

-- fin_v_webinar_resultado (271) lee fin_pago_fuente_calc.es_webinar: toma la regla nueva sola, no se toca.

-- 3c. ranking de closers: mismas columnas que la 003; "cierres" ya no cuenta pagos SIN IDENTIFICAR
create or replace view public.fin_v_ranking_closers
with (security_invoker = true) as
select cliente_id,
       extract(year from fecha)::int  as anio,
       extract(month from fecha)::int as mes,
       btrim(closer)                  as closer,
       count(*)                       as pagos,
       count(distinct lower(btrim(alumno))) filter (
         where (concepto ilike '%FEE%' or concepto ilike '%PIF%') and not public.fin_es_sin_alumno(alumno)) as cierres,
       sum(monto_usd)                 as monto_usd
from public.fin_pagos
where closer is not null and btrim(closer) <> ''
group by 1, 2, 3, 4;

-- 3d. alumnos de un cliente (pagos + cuotas): copia exacta de la 129, con el nombre SIN IDENTIFICAR descartado
create or replace function public.fin_cs_alumnos(p_cliente text)
returns table (alumno_norm text, alumno text, telefonos text[], claves text[],
               n_pagos int, n_cuotas int, ultimo_pago date)
language sql stable security definer set search_path = ''
as $$
  with todo as (
    select case when public.fin_es_sin_alumno(p.alumno) then null else public.fin_cs_norm_nombre(p.alumno) end as an,
           p.alumno as nombre, p.telefono as tel,
           p.clave, p.fecha, p.monto_usd, 'p' as o
      from public.fin_pagos p where p.cliente_id = p_cliente
    union all
    select case when public.fin_es_sin_alumno(q.alumno) then null else public.fin_cs_norm_nombre(q.alumno) end,
           q.alumno, q.telefono, null, null, null, 'c'
      from public.fin_cuotas q where q.cliente_id = p_cliente
  )
  select t.an,
         (array_agg(t.nombre order by (t.o = 'p') desc, t.fecha desc nulls last, t.nombre))[1],
         coalesce(array_agg(distinct public.fin_cs_norm_tel(t.tel))
                    filter (where public.fin_cs_norm_tel(t.tel) is not null), '{}'::text[]),
         coalesce(array_agg(distinct t.clave) filter (where t.clave is not null), '{}'::text[]),
         (count(*) filter (where t.o = 'p'))::int,
         (count(*) filter (where t.o = 'c'))::int,
         max(t.fecha) filter (where t.o = 'p' and t.monto_usd > 0)
    from todo t
   where t.an is not null
   group by t.an
$$;

-- ---------------------------------------------------------------------
-- BLOQUE 4. Humo con filas de prueba (se revierte solo: termina SIEMPRE en ERROR "HUMO 276 OK")
-- ---------------------------------------------------------------------
do $h$
declare
  v_f bigint; v_web bigint; r record; v_n int; v_usd numeric;
begin
  select id into v_f from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' order by id limit 1;
  if v_f is null then raise exception 'HUMO 276: liam no tiene fuente de pagos'; end if;

  -- webinar de prueba: ventana 2030-01-01 + ventana_dias (por defecto)
  insert into public.fin_webinars (cliente_id, nombre, fecha) values ('liam', 'HUMO 276', date '2030-01-01') returning id into v_web;

  insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, concepto, monto_usd, monto_origen, moneda_origen,
                                tc_usado, tc_fuente, nota, fuente_lead, origen, importado_en)
  values
    -- Alumno real nuevo: primer pago en ventana -> Webinar
    ('liam', v_f, 990021, date '2030-01-02', 'Humo Real',   'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- SIN IDENTIFICAR en ventana, sin marca -> sin fuente (antes de la 276 era Webinar por "primer pago en ventana")
    ('liam', v_f, 990022, date '2030-01-03', 'SIN IDENTIFICAR (Humo A)', 'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- otro SIN IDENTIFICAR (otro texto) FUERA de ventana, marcado instagram -> instagram (no hereda de los otros)
    ('liam', v_f, 990023, date '2030-03-01', 'sin identificar', 'PIF', 100, 100, 'USD', 1, 'planilla', null, 'instagram', 'app', now()),
    -- SIN IDENTIFICAR con marca webinar, fuera de ventana -> vale lo que dice la planilla: webinar
    ('liam', v_f, 990024, date '2030-03-02', 'Sin Identificar (humo@x.com)', 'PIF', 100, 100, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    -- SIN IDENTIFICAR con el mismo texto que 990022 mas tarde y sin marca: no hereda el "primer pago" de 990022 -> sin fuente
    ('liam', v_f, 990025, date '2030-03-03', 'SIN IDENTIFICAR (Humo A)', 'FEE', 50, 50, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- alumno vacio en ventana, sin marca -> sin fuente
    ('liam', v_f, 990026, date '2030-01-04', '-', 'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now());

  for r in
    select p.fila_planilla, c.es_webinar, c.fuente_final, c.sin_alumno, c.marca_webinar_descartada
      from public.fin_pago_fuente_calc c
      join public.fin_pagos p on p.id = c.pago_id
     where p.fila_planilla between 990021 and 990026 and p.cliente_id = 'liam'
  loop
    if r.sin_alumno is distinct from (r.fila_planilla <> 990021) then
      raise exception 'HUMO 276: la fila % dio sin_alumno % y no era lo esperado', r.fila_planilla, r.sin_alumno;
    end if;
    if r.fila_planilla = 990021 and r.es_webinar is not true then
      raise exception 'HUMO 276: el alumno real nuevo tenia que ser Webinar';
    end if;
    if r.fila_planilla in (990022, 990025, 990026) and r.fuente_final is not null then
      raise exception 'HUMO 276: la fila % tenia que quedar sin fuente y dio %', r.fila_planilla, r.fuente_final;
    end if;
    if r.fila_planilla = 990023 and r.fuente_final is distinct from 'instagram' then
      raise exception 'HUMO 276: la fila 990023 tenia que ser instagram y dio %', coalesce(r.fuente_final, 'nada');
    end if;
    if r.fila_planilla = 990024 and (r.fuente_final is distinct from 'webinar' or r.marca_webinar_descartada) then
      raise exception 'HUMO 276: la fila 990024 tenia que conservar su marca webinar';
    end if;
  end loop;

  -- ventana de prueba (2030-01-01 + ventana_dias): solo entra 990021 (100); los SIN IDENTIFICAR de la ventana no
  select count(*), coalesce(sum(c.monto_usd), 0) into v_n, v_usd
    from public.fin_pago_fuente_calc c
   where c.cliente_id = 'liam' and c.es_webinar and c.fecha between date '2030-01-01' and date '2030-01-15';
  if v_n <> 1 or v_usd <> 100 then
    raise exception 'HUMO 276: la ventana tenia que sumar 1 pago y 100, dio % pagos y %', v_n, v_usd;
  end if;

  -- Vincular alumnos: no lista SIN IDENTIFICAR ni vacio; si al alumno real
  select count(*) into v_n from public.fin_cs_alumnos('liam') a where a.alumno_norm like 'sin identificar%' or a.alumno_norm = '';
  if v_n <> 0 then raise exception 'HUMO 276: fin_cs_alumnos todavia lista % SIN IDENTIFICAR', v_n; end if;
  select count(*) into v_n from public.fin_cs_alumnos('liam') a where a.alumno_norm = 'humo real';
  if v_n <> 1 then raise exception 'HUMO 276: fin_cs_alumnos tenia que listar a Humo Real (dio %)', v_n; end if;

  raise exception 'HUMO 276 OK';
end
$h$;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado). Se corren DESPUES del BLOQUE 3.
-- Los que leen fin_pago_fuente_calc / fin_pago_fuente_antes_276 / fin_cs_alumnos corren sin filtro de fundador.
-- =====================================================================

-- C1. Webinars de octubre por cliente: pagos y USD de la fuente Webinar dentro de la ventana, ANTES (273) y DESPUES (276).
-- select w.cliente_id, w.nombre,
--        (select count(*) from public.fin_pago_fuente_antes_276 a where a.cliente_id = w.cliente_id and a.es_webinar
--            and a.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as antes_n,
--        (select coalesce(sum(a.monto_usd), 0) from public.fin_pago_fuente_antes_276 a where a.cliente_id = w.cliente_id and a.es_webinar
--            and a.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as antes_usd,
--        (select count(*) from public.fin_pago_fuente_calc c where c.cliente_id = w.cliente_id and c.es_webinar
--            and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as despues_n,
--        (select coalesce(sum(c.monto_usd), 0) from public.fin_pago_fuente_calc c where c.cliente_id = w.cliente_id and c.es_webinar
--            and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as despues_usd
--   from public.fin_webinars w
--  where w.activo and w.fecha >= date '2026-10-01' and w.fecha < date '2026-11-01'
--  order by w.fecha, w.cliente_id;

-- C2. Cada pago SIN IDENTIFICAR (o sin alumno) de octubre: la fuente que dice la planilla, la de antes y la de despues.
--     Despues = fuente_planilla (o fuente de ingreso) y nada mas. "antes" distinto de "despues" = el pago salio de un webinar
--     (o entro por marca de la planilla).
-- select c.cliente_id, c.fecha, c.alumno, c.concepto, c.monto_usd, c.fuente_planilla, c.fuente_ingreso_planilla,
--        a.fuente_final as antes, c.fuente_final as despues, c.criterio
--   from public.fin_pago_fuente_calc c
--   left join public.fin_pago_fuente_antes_276 a on a.pago_id = c.pago_id
--  where c.sin_alumno and c.fecha >= date '2026-10-01' and c.fecha < date '2026-11-01'
--  order by c.cliente_id, c.fecha, c.alumno;

-- C3. Alumnos nuevos de octubre por cliente (alumno cuyo primer pago > 0 cae en octubre), antes y despues.
-- with p as (
--   select pg.cliente_id, public.fin_es_sin_alumno(pg.alumno) as sin, pg.fecha,
--          btrim(regexp_replace(lower(translate(coalesce(pg.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k
--     from public.fin_pagos pg where pg.monto_usd > 0
-- ), pr as (
--   select cliente_id, sin, k, min(fecha) as f from p where k <> '' group by 1, 2, 3
-- )
-- select cliente_id,
--        count(*) filter (where f >= date '2026-10-01' and f < date '2026-11-01') as nuevos_antes,
--        count(*) filter (where f >= date '2026-10-01' and f < date '2026-11-01' and not sin) as nuevos_despues
--   from pr group by 1 order by 1;

-- C4. Vincular alumnos: SIN IDENTIFICAR ya no aparece (esperado 0 en los tres). Y los vinculos viejos que quedaron
--     sueltos con ese nombre (no se borran; se listan por si alguno hay que limpiar a mano).
-- select 'liam' as cliente, count(*) as sin_identificar_en_lista from public.fin_cs_alumnos('liam') where alumno_norm like 'sin identificar%'
-- union all select 'agus', count(*) from public.fin_cs_alumnos('agus') where alumno_norm like 'sin identificar%'
-- union all select 'teo', count(*) from public.fin_cs_alumnos('teo') where alumno_norm like 'sin identificar%'
-- union all select 'vinculos_viejos ' || cliente_id || ' ' || estado, count(*) from public.fin_cs_vinculo
--            where alumno_norm like 'sin identificar%' group by cliente_id, estado;

-- C5. POSIBLES ALUMNOS DUPLICADOS (Agus y Liam, septiembre y octubre): el C6 de la 273 SIN los pagos SIN IDENTIFICAR.
--     Tipos: 'mismo nombre, distinta escritura' (la regla ya los une), 'nombre contenido en otro',
--     'mismo primer nombre y apellido'. Revisar a mano; si es la misma persona, corregir el nombre en la hoja.
-- with n as (
--   select p.cliente_id, p.alumno,
--          btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k,
--          bool_or(p.fecha >= date '2026-09-01' and p.fecha < date '2026-11-01') as en_sep_oct,
--          count(*) as pagos, sum(p.monto_usd) as usd
--     from public.fin_pagos p
--    where p.cliente_id in ('agus', 'liam') and not public.fin_es_sin_alumno(p.alumno)
--    group by 1, 2, 3
-- ), nn as (
--   select n.*, string_to_array(n.k, ' ') as t from n where n.k <> ''
-- ), mismo as (
--   select cliente_id, k, 'mismo nombre, distinta escritura'::text as tipo, array_agg(alumno order by alumno) as escrituras,
--          sum(pagos) as pagos, sum(usd) as usd
--     from nn where en_sep_oct group by cliente_id, k having count(*) > 1
-- ), pares as (
--   select a.cliente_id,
--          case when a.t <@ b.t or b.t <@ a.t then 'nombre contenido en otro'
--               else 'mismo primer nombre y apellido' end as tipo,
--          array[a.alumno, b.alumno] as escrituras, a.pagos + b.pagos as pagos, a.usd + b.usd as usd, a.k, b.k as k2
--     from nn a
--     join nn b on b.cliente_id = a.cliente_id and b.k <> a.k and (a.k < b.k or not b.en_sep_oct)
--    where a.en_sep_oct
--      and cardinality(a.t) >= 2 and cardinality(b.t) >= 2
--      and ((a.t <@ b.t or b.t <@ a.t) or (a.t[1] = b.t[1] and a.t[cardinality(a.t)] = b.t[cardinality(b.t)]))
-- )
-- select cliente_id, tipo, escrituras, pagos, usd from mismo
-- union all
-- select cliente_id, tipo, escrituras, pagos, usd from pares
-- order by 1, 2, 3;

-- C6. Todos los pagos que cambiaron de fuente con la 276 (desde septiembre), para auditar uno por uno.
-- select c.cliente_id, c.fecha, c.alumno, c.concepto, c.monto_usd, c.fuente_planilla,
--        a.fuente_final as antes, c.fuente_final as despues, c.criterio
--   from public.fin_pago_fuente_calc c
--   join public.fin_pago_fuente_antes_276 a on a.pago_id = c.pago_id
--  where c.fecha >= date '2026-09-01' and a.fuente_final is distinct from c.fuente_final
--  order by c.cliente_id, c.alumno, c.fecha;

-- C7. Facturacion intacta: los pagos SIN IDENTIFICAR siguen en fin_pagos, por cliente y mes (tiene que dar igual que el
--     humo del BLOQUE 2). Y cierres del ranking que ya no cuentan: pagos FEE/PIF sin alumno con closer, por mes.
-- select p.cliente_id, to_char(date_trunc('month', p.fecha), 'YYYY-MM') as mes, count(*) as pagos, sum(p.monto_usd) as usd,
--        count(*) filter (where (p.concepto ilike '%FEE%' or p.concepto ilike '%PIF%') and p.closer is not null and btrim(p.closer) <> '') as con_closer_fee_pif
--   from public.fin_pagos p
--  where public.fin_es_sin_alumno(p.alumno)
--  group by 1, 2 order by 1, 2;

-- =====================================================================
-- VUELTA ATRAS (en este orden)
--   1. Volver a correr el bloque "create or replace view fin_pago_fuente_calc / fin_v_pago_fuente" de la 273. Como la 276 le
--      agrega una columna al final (sin_alumno), primero: drop view public.fin_v_pago_fuente; drop view public.fin_pago_fuente_calc;
--      y recrear ambas con la 273 (fin_v_webinar_resultado depende de fin_pago_fuente_calc: soltarla con cascade y recrearla
--      con el bloque de la 271).
--   2. fin_v_ranking_closers: volver a correr el create or replace view de la 003.
--   3. fin_cs_alumnos: volver a correr el create or replace function de la 129 (seccion 5).
--   4. drop function public.fin_es_sin_alumno(text);   -- solo despues de 1 a 3 (las usan)
--   5. drop table if exists public.fin_pago_fuente_antes_276;
-- =====================================================================
