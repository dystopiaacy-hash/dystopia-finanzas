-- =====================================================================
-- 273 · La regla de fuente Webinar tambien pisa las marcas "Webinar" / "Replay" de la planilla
-- Asignada por el jefe (2/11). SIN correr. Solo vistas (+ una tabla de respaldo). No toca fin_pagos ni el Sheet.
--
-- Decision de Joaquin (2/11): "aplica la regla nueva" tambien a los pagos que la planilla marca Webinar a mano,
-- aunque sean de clientes que ya pagaban antes del 25/10.
--
-- REGLA (reemplaza el punto "lo explicito no se pisa" de la 271, SOLO para marcas Webinar / Replay):
--   - Una marca Webinar/Replay de la planilla (fuente_lead o fuente_ingreso = 'Webinar') solo vale si el PRIMER pago del
--     alumno (menor fecha, monto > 0, nombre normalizado) cae dentro de la ventana de algun webinar activo de ese cliente.
--     Si el alumno no tiene primer pago identificable, vale si el propio pago cae en una ventana.
--   - Si no vale (el alumno ya pagaba antes de la ventana: es cuota, fee o completa de una venta previa), el pago HEREDA la
--     fuente de su primer pago. Si el primer pago no tiene fuente, queda "sin fuente" (no Webinar, no se inventa).
--   - Las marcas que NO son Webinar/Replay (instagram, tiktok, referido...) se siguen respetando como en la 271.
--   - Cuotas sin marca heredan del primer pago, igual que en la 271.
--   - Alumno = nombre normalizado (sin tildes ni signos, minusculas), como en la 271. Ver el control C6 de posibles duplicados.
--
-- AUDITORIA: fin_pago_fuente_calc sigue trayendo fuente_planilla (lo que dice la hoja, crudo) y fuente_final (la calculada);
--   columnas nuevas al final: fuente_ingreso_planilla, marca_webinar_descartada, primer_pago_en_ventana.
--   fuente_explicita sigue siendo la marca de la planilla ANTES de decidir si vale.
--
-- BLOQUES (correr de a uno, en orden):
--   1. Guarda + respaldo de la regla 271 (tabla fin_pago_fuente_antes_273: foto de la fuente final ANTES, para los controles)
--   2. Vistas fin_pago_fuente_calc y fin_v_pago_fuente con la regla nueva (fin_v_webinar_resultado no se toca: lee es_webinar)
--   3. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 273 OK")
--   Controles C1-C6 al final. No correr a las :00/:15/:30/:45 ni a las 9:00.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guarda y foto del "antes" (la fuente final con la regla de la 271)
-- ---------------------------------------------------------------------
do $g$
declare v text;
begin
  if to_regclass('public.fin_pago_fuente_calc') is null or to_regclass('public.fin_v_pago_fuente') is null then
    raise exception 'GUARDA 273: falta la 271 (fin_pago_fuente_calc, fin_v_pago_fuente).';
  end if;
  v := pg_get_viewdef('public.fin_pago_fuente_calc'::regclass);
  if v not like '%fuente_inferida_vieja%' or v not like '%criterio%' then
    raise exception 'GUARDA 273: fin_pago_fuente_calc no es la de la 271 ni la de la 273. No se toca nada.';
  end if;
  if to_regclass('public.fin_webinars') is null or to_regclass('public.fin_v_webinar_resultado') is null then
    raise exception 'GUARDA 273: falta la 267 (fin_webinars, fin_v_webinar_resultado).';
  end if;
  if to_regprocedure('public.fin_dys_puede_ver()') is null or to_regprocedure('public.fin_gastos_puede_ver()') is null then
    raise exception 'GUARDA 273: faltan fin_dys_puede_ver / fin_gastos_puede_ver (174).';
  end if;
end
$g$;

-- Foto de la 271. Solo se crea si NO existe (volver a correr la 273 no pisa el "antes").
-- Si la vista ya es la de la 273 y la tabla no existe, no se puede reconstruir el antes: se avisa.
do $f$
begin
  if to_regclass('public.fin_pago_fuente_antes_273') is null then
    if pg_get_viewdef('public.fin_pago_fuente_calc'::regclass) like '%marca_webinar_descartada%' then
      raise exception 'GUARDA 273: la vista ya es la nueva y no hay foto del antes. Los controles de "antes" no se pueden armar.';
    end if;
    create table public.fin_pago_fuente_antes_273 as
      select pago_id, cliente_id, pago_clave, fecha, alumno, monto_usd, concepto, fuente_planilla, fuente_final, es_webinar,
             now() as foto_en
        from public.fin_pago_fuente_calc;
    alter table public.fin_pago_fuente_antes_273 enable row level security;
    revoke all on public.fin_pago_fuente_antes_273 from public, anon, authenticated;
    grant select on public.fin_pago_fuente_antes_273 to service_role;
    comment on table public.fin_pago_fuente_antes_273 is
      '273: foto de fin_pago_fuente_calc (regla de la 271) tomada antes de la 273, para comparar antes y despues. Se puede borrar cuando Joaquin lo decida.';
  end if;
end
$f$;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Vistas con la regla nueva
-- ---------------------------------------------------------------------
create or replace view public.fin_pago_fuente_calc as
with base as (
  select p.id, p.cliente_id, p.clave, p.fecha, p.alumno, p.monto_usd, p.concepto, p.fila_planilla,
         nullif(btrim(p.fuente_lead), '') as lead_crudo,
         nullif(btrim(p.fuente_ingreso), '') as ingreso,
         (coalesce(p.nota, '') ilike '%fuente inferida%') as nota_inferida,
         btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k
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
         case when r.fuente_explicita is null then null
              when r.marca_web and not r.ref_en_ventana and not r.ref_previo then null
              else r.fuente_explicita end as expl_vale,
         -- fuente del primer pago (para heredar): su marca si vale (para el, ref = el mismo), o Webinar si cae en ventana
         case when r.f_expl is not null and not (r.f_marca_web and not r.f_en_ventana and not coalesce(r.f_previo, false)) then r.f_expl
              when r.f_en_ventana then 'Webinar' end as f_fuente
    from r
), t as (
  select s.*,
         case when s.expl_vale is not null then s.expl_vale
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
       case when t.expl_vale is not null then 'explicita en la planilla'
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
       t.ref_en_ventana as primer_pago_en_ventana
  from t;

comment on view public.fin_pago_fuente_calc is
  '273: fuente de cada pago. Marca explicita de la planilla (si es Webinar/Replay solo vale si el primer pago del alumno cae en la ventana de un webinar), o primer pago en ventana, o heredada del primer pago. fuente_planilla = lo crudo de la hoja. Interna, sin permisos para la app. No toca fin_pagos.';

create or replace view public.fin_v_pago_fuente as
select * from public.fin_pago_fuente_calc
 where public.fin_dys_puede_ver() or public.fin_gastos_puede_ver();

comment on view public.fin_v_pago_fuente is
  '273: igual a fin_pago_fuente_calc pero solo para quien ve Dystopia o Gastos.';

revoke all on public.fin_pago_fuente_calc, public.fin_v_pago_fuente from public, anon, authenticated;
grant select on public.fin_v_pago_fuente to authenticated;
grant select on public.fin_pago_fuente_calc, public.fin_v_pago_fuente to service_role;

-- fin_v_webinar_resultado (271) lee fin_pago_fuente_calc.es_webinar y fuente de cada pago: toma la regla nueva sola.

-- ---------------------------------------------------------------------
-- BLOQUE 3. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 273 OK")
-- ---------------------------------------------------------------------
do $h$
declare
  v_f bigint; v_web bigint; r record; v_n int; v_usd numeric;
begin
  select id into v_f from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' order by id limit 1;
  if v_f is null then raise exception 'HUMO 273: liam no tiene fuente de pagos'; end if;

  -- webinar de prueba: ventana 2030-01-01 + ventana_dias (por defecto)
  insert into public.fin_webinars (cliente_id, nombre, fecha) values ('liam', 'HUMO 273', date '2030-01-01') returning id into v_web;

  insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, concepto, monto_usd, monto_origen, moneda_origen,
                                tc_usado, tc_fuente, nota, fuente_lead, origen, importado_en)
  values
    -- Nuevo: primer pago en ventana (sin marca) y su cuota fuera de la ventana -> Webinar los dos
    ('liam', v_f, 990001, date '2030-01-02', 'Humo Nuevo',  'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990002, date '2030-03-01', 'Humo Nuevo',  'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- Viejo: primer pago antes de la ventana sin fuente; su fee en ventana SIN marca -> no Webinar
    ('liam', v_f, 990003, date '2029-12-01', 'Humo Viejo',  'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990004, date '2030-01-03', 'Humo Viejo',  'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- Marcado a mano: primer pago viejo sin fuente, fee en ventana MARCADO webinar -> la marca NO vale (cambio de la 273)
    ('liam', v_f, 990007, date '2029-12-03', 'Humo Marc',   'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990008, date '2030-01-06', 'Humo Marc',   'FEE',  50,  50, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    -- Primer pago viejo instagram; su fee en ventana marcado webinar -> hereda instagram
    ('liam', v_f, 990009, date '2029-12-04', 'Humo Insta',  'PIF', 100, 100, 'USD', 1, 'planilla', null, 'instagram', 'app', now()),
    ('liam', v_f, 990010, date '2030-01-07', 'Humo Insta',  'FEE',  50,  50, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    -- Primer pago FUERA de ventana marcado webinar: la marca no vale -> sin fuente, y su cuota tambien
    ('liam', v_f, 990011, date '2029-12-05', 'Humo Pri',    'PIF', 100, 100, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    ('liam', v_f, 990012, date '2030-01-08', 'Humo Pri',    'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now()),
    -- Primer pago EN ventana marcado webinar: vale; su cuota sin marca fuera de ventana hereda Webinar
    ('liam', v_f, 990013, date '2030-01-04', 'Humo Ok',     'PIF', 100, 100, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    ('liam', v_f, 990014, date '2030-03-02', 'Humo Ok',     'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now());

  for r in
    select p.fila_planilla, c.es_webinar, c.fuente_final, c.marca_webinar_descartada
      from public.fin_pago_fuente_calc c
      join public.fin_pagos p on p.id = c.pago_id
     where p.fila_planilla between 990001 and 990014 and p.cliente_id = 'liam'
  loop
    if r.es_webinar is distinct from (r.fila_planilla in (990001, 990002, 990013, 990014)) then
      raise exception 'HUMO 273: la fila % dio es_webinar % y no era lo esperado', r.fila_planilla, r.es_webinar;
    end if;
    if r.fila_planilla = 990010 and r.fuente_final is distinct from 'instagram' then
      raise exception 'HUMO 273: la fee de Humo Insta tenia que heredar instagram y dio %', coalesce(r.fuente_final, 'nada');
    end if;
    if r.fila_planilla in (990008, 990011, 990012) and r.fuente_final is not null then
      raise exception 'HUMO 273: la fila % tenia que quedar sin fuente y dio %', r.fila_planilla, r.fuente_final;
    end if;
    if r.fila_planilla in (990008, 990011) and r.marca_webinar_descartada is distinct from true then
      raise exception 'HUMO 273: la fila % tenia que figurar con la marca descartada', r.fila_planilla;
    end if;
    if r.fila_planilla = 990013 and r.marca_webinar_descartada then
      raise exception 'HUMO 273: la fila 990013 conserva su marca y figura descartada';
    end if;
  end loop;

  -- ventana de prueba (2030-01-01 + ventana_dias): entran 990001 y 990013 (100 cada uno)
  select count(*), coalesce(sum(c.monto_usd), 0) into v_n, v_usd
    from public.fin_pago_fuente_calc c
   where c.cliente_id = 'liam' and c.es_webinar and c.fecha between date '2030-01-01' and date '2030-01-15';
  if v_n <> 2 or v_usd <> 200 then
    raise exception 'HUMO 273: la ventana tenia que sumar 2 pagos y 200, dio % pagos y %', v_n, v_usd;
  end if;

  raise exception 'HUMO 273 OK';
end
$h$;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- Los que leen fin_v_pago_fuente / fin_v_webinar_resultado necesitan el filtro de fundador en la misma ejecucion:
--   select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- Los que leen fin_pago_fuente_calc (sin filtro) corren sin eso.
-- =====================================================================

-- C1. Agus octubre por fuente, ANTES (foto de la 271) y DESPUES (273). Esperado ANTES: Webinar 54 / 52.253 (como dijo la 271).
--     DESPUES: Webinar baja; lo que baja sale como "sin fuente" o con la fuente del primer pago.
-- select coalesce(a.fuente, d.fuente, '(sin fuente)') as fuente, a.n as antes_n, a.usd as antes_usd, d.n as despues_n, d.usd as despues_usd
--   from (select coalesce(fuente_final, '(sin fuente)') as fuente, count(*) as n, sum(monto_usd) as usd
--           from public.fin_pago_fuente_antes_273
--          where cliente_id = 'agus' and fecha >= date '2026-10-01' and fecha < date '2026-11-01' group by 1) a
--   full join (select coalesce(fuente_final, '(sin fuente)') as fuente, count(*) as n, sum(monto_usd) as usd
--                from public.fin_pago_fuente_calc
--               where cliente_id = 'agus' and fecha >= date '2026-10-01' and fecha < date '2026-11-01' group by 1) d on d.fuente = a.fuente
--  order by 1;

-- C2. Webinars AF 25/10, BPF 14/10 (y AF 20/09) antes y despues: pagos y USD de la fuente Webinar dentro de la ventana.
--     Esperado ANTES (271): AF 25/10 47 / 48.214, BPF 14/10 19 / 15.099,36, AF 20/09 48 / 49.301.
-- select w.nombre, w.cliente_id,
--        (select count(*) from public.fin_pago_fuente_antes_273 a where a.cliente_id = w.cliente_id and a.es_webinar
--            and a.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as antes_n,
--        (select coalesce(sum(a.monto_usd), 0) from public.fin_pago_fuente_antes_273 a where a.cliente_id = w.cliente_id and a.es_webinar
--            and a.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as antes_usd,
--        (select count(*) from public.fin_pago_fuente_calc c where c.cliente_id = w.cliente_id and c.es_webinar
--            and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as despues_n,
--        (select coalesce(sum(c.monto_usd), 0) from public.fin_pago_fuente_calc c where c.cliente_id = w.cliente_id and c.es_webinar
--            and c.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as despues_usd
--   from public.fin_webinars w
--  where w.activo and w.nombre in ('AF 25/10', 'BPF 14/10', 'AF 20/09')
--  order by w.fecha;

-- C3. Los pagos que cambiaron de fuente (todos los clientes, desde septiembre), para auditar uno por uno.
--     fuente_planilla = lo que dice la hoja; antes = regla 271; despues = 273.
-- select c.cliente_id, c.fecha, c.alumno, c.concepto, c.monto_usd, c.fuente_planilla,
--        a.fuente_final as antes, c.fuente_final as despues, c.primer_pago_fecha, c.criterio
--   from public.fin_pago_fuente_calc c
--   join public.fin_pago_fuente_antes_273 a on a.pago_id = c.pago_id
--  where c.fecha >= date '2026-09-01' and a.fuente_final is distinct from c.fuente_final
--  order by c.cliente_id, c.alumno, c.fecha;

-- C4. Marcas Webinar de la planilla descartadas, por cliente y mes. Agus octubre esperado: unos 31 marcados a mano menos los
--     que su primer pago si cae en ventana (la diferencia de C1).
-- select cliente_id, date_trunc('month', fecha)::date as mes, count(*) as marcas_descartadas, sum(monto_usd) as usd
--   from public.fin_pago_fuente_calc
--  where marca_webinar_descartada
--  group by 1, 2 order by 1, 2;

-- C5. Pagos de un webinar que quedaron sin fuente (lo que muestra la pantalla Webinars en "Asignar pagos sin fuente"),
--     por webinar. Con el filtro de fundador.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);  -- correr en la misma ejecucion que la query:
-- select w.nombre, count(*) as sin_fuente_n, sum(v.monto_usd) as sin_fuente_usd
--   from public.fin_webinars w
--   join public.fin_v_pago_fuente v on v.cliente_id = w.cliente_id and v.fuente_final is null
--    and v.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)
--  where w.activo
--  group by w.nombre, w.fecha order by w.fecha;

-- C6. POSIBLES ALUMNOS DUPLICADOS (Agus y Liam, pagos de septiembre y octubre). La regla identifica al alumno por nombre
--     normalizado (sin tildes, minusculas, solo letras y numeros): dos escrituras que difieran en otra cosa (segundo nombre,
--     letra de menos) NO se unen y cada una tendria su "primer pago". Revisar a mano; si es la misma persona, corregir el
--     nombre en la hoja. Tipos:
--       'mismo nombre, distinta escritura' = tildes/mayusculas/espacios: la regla YA los une (informativo).
--       'nombre contenido en otro'         = todas las palabras de uno estan en el otro (ej. "matias bosio" / "matias german bosio").
--       'mismo primer nombre y apellido'   = primera y ultima palabra iguales con algo distinto en el medio.
-- with n as (
--   select p.cliente_id, p.alumno,
--          btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k,
--          bool_or(p.fecha >= date '2026-09-01' and p.fecha < date '2026-11-01') as en_sep_oct,
--          count(*) as pagos, sum(p.monto_usd) as usd
--     from public.fin_pagos p
--    where p.cliente_id in ('agus', 'liam') and p.alumno is not null and btrim(p.alumno) <> ''
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

-- =====================================================================
-- VUELTA ATRAS
--   Volver a correr el bloque "create or replace view fin_pago_fuente_calc / fin_v_pago_fuente" de la 271 (hay que sacar
--   las 3 columnas finales: drop view fin_v_pago_fuente; drop view fin_pago_fuente_calc; y recrear ambas con la 271).
--   Despues: drop table if exists public.fin_pago_fuente_antes_273;
-- =====================================================================
