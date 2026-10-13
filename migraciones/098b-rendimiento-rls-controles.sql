-- =====================================================================
-- 098b-rendimiento-rls-controles.sql
-- Controles de la 098 (rendimiento RLS de Finanzas). Consultas sueltas:
-- correr DE A UNO (el SQL Editor muestra solo el ultimo resultado).
-- NO cambian datos ni politicas. Solo crean 2 funciones de control y una
-- tabla con la foto del ANTES.
--
-- ORDEN:
--   C0  crear las 2 funciones de control (una vez).
--   C1  ANTES: foto de lo que ve cada usuario (correr ANTES de la 098).
--   C1b mirar la foto (opcional).
--   -- ... correr la 098 (bloque DO) ...
--   C3  DESPUES: compara contra el ANTES. Tiene que decir IDENTICO.
--   C4  Tiempos (explain analyze) de las 4 vistas lentas para finanzas@ y ventas@.
--       Correrla tambien ANTES de la 098 para tener con que comparar.
--   C5  Politicas que siguen llamando a las funciones por fila (2da tanda).
--   C6  Politicas tocadas por la 098 (texto original y nuevo).
--   C7  Limpieza: sacar las funciones de control y la foto cuando ya no hagan falta.
--
-- Usuarios simulados (set local role authenticated + request.jwt.claims):
--   cliente@, ventas@, finanzas@, producto@, contenido@ (@liam.dystopia),
--   todos los fundadores de crm_members, un closer y un setter (el primero
--   de cada rol, si existen), un usuario sin rol y anonimo.
-- Por cada usuario y objeto: filas, hash_ids (md5 de los ids ordenados) y
-- hash_contenido (md5 del contenido sin id ni fechas de sync). La
-- comparacion usa filas + hash_contenido: la sync reescribe pagos 'sheet'
-- cada 15 min con ids nuevos, hash_ids es solo informativo.
-- =====================================================================


-- ---------------------------------------------------------------------
-- C0. Funciones de control. Corren como postgres y simulan usuarios:
-- por eso se les quita el permiso a anon y authenticated (si no, cualquier
-- usuario podria leer como otro). Correr las dos juntas.
-- ---------------------------------------------------------------------
create or replace function public.fin_ctl_098_visibilidad(p_usuario text default null, p_vistas boolean default true)
returns table (usuario text, rol text, objeto text, tipo text, filas bigint, hash_ids text, hash_contenido text, error text)
language plpgsql
set search_path = public, pg_catalog
as $f$
declare
  c_tablas constant text[] := array[
    'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_cuotas', 'fin_llamadas', 'fin_personas',
    'fin_vendedores', 'fin_vendedor_asignaciones', 'fin_liquidaciones', 'fin_liquidacion_items',
    'fin_fuentes_mapa', 'fin_catalogos', 'fin_formulario_preguntas', 'fin_pagos_anulados',
    'fin_columnas', 'fin_pagos_extra', 'fin_data_columnas'];
  c_vistas constant text[] := array[
    'fin_v_periodos', 'fin_v_comisiones_bloqueos', 'fin_v_pnl_mensual', 'fin_v_comisiones_mensual',
    'fin_v_llamadas_setter', 'fin_v_metricas_ventas', 'fin_v_cash_collected_concepto', 'fin_v_ranking_closers'];
  v_u    record;
  v_o    text;
  v_tipo text;
  v_f    bigint;
  v_h1   text;
  v_h2   text;
begin
  for v_u in
    select q.label, q.uid, q.rol
      from (
        select lower(a.email) as label, a.id as uid,
               (select m.rol from public.crm_members m where m.user_id = a.id limit 1) as rol, 1 as ord
          from auth.users a
         where lower(a.email) in ('cliente@liam.dystopia', 'ventas@liam.dystopia', 'finanzas@liam.dystopia',
                                  'producto@liam.dystopia', 'contenido@liam.dystopia')
        union all
        select 'fundador:' || coalesce(lower(a.email), m.user_id::text), m.user_id, m.rol, 2
          from public.crm_members m left join auth.users a on a.id = m.user_id
         where m.rol = 'fundador' and m.user_id is not null
        union all
        select * from (
          select 'closer:' || coalesce(lower(a.email), m.user_id::text), m.user_id, m.rol, 3
            from public.crm_members m left join auth.users a on a.id = m.user_id
           where m.rol = 'closer' and m.user_id is not null order by m.user_id limit 1) c
        union all
        select * from (
          select 'setter:' || coalesce(lower(a.email), m.user_id::text), m.user_id, m.rol, 4
            from public.crm_members m left join auth.users a on a.id = m.user_id
           where m.rol = 'setter' and m.user_id is not null order by m.user_id limit 1) s
        union all
        select * from (
          select 'sin_rol:' || coalesce(lower(a.email), a.id::text), a.id, null::text, 5
            from auth.users a
           where not exists (select 1 from public.crm_members m where m.user_id = a.id)
           order by a.id limit 1) n
        union all
        select 'anon', null::uuid, null::text, 6
      ) q
     where p_usuario is null or q.label = lower(p_usuario)
     order by q.ord, q.label
  loop
    execute 'reset role';
    if v_u.uid is null then
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '', true);
      execute 'set local role anon';
    else
      perform set_config('request.jwt.claim.sub', v_u.uid::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', v_u.uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
    end if;

    foreach v_o in array (case when p_vistas then c_tablas || c_vistas else c_tablas end) loop
      v_tipo := case when v_o = any (c_tablas) then 'tabla' else 'vista' end;
      usuario := v_u.label; rol := v_u.rol; objeto := v_o; tipo := v_tipo;
      filas := null; hash_ids := null; hash_contenido := null; error := null;
      begin
        execute format($q$
          select count(*),
                 md5(coalesce(string_agg(to_jsonb(x) ->> 'id', ',' order by to_jsonb(x) ->> 'id'), 'sin id')),
                 md5(coalesce(string_agg(j.t, ',' order by j.t), ''))
            from public.%I x
            cross join lateral (select (to_jsonb(x) - array['id', 'creado_en', 'actualizado_en', 'sincronizado_en',
                                                              'corrida_id', 'created_at', 'updated_at'])::text as t) j
        $q$, v_o) into v_f, v_h1, v_h2;
        filas := v_f; hash_ids := v_h1; hash_contenido := v_h2;
      exception when others then
        error := 'ERR ' || sqlstate;
      end;
      return next;
    end loop;
    execute 'reset role';
  end loop;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return;
end
$f$;

-- Plan de ejecucion (explain analyze, buffers) de una vista simulando a un usuario.
-- p_usuario = el mail; p_vista = una de las 8 vistas de la lista.
create or replace function public.fin_ctl_098_explain(p_usuario text, p_vista text)
returns setof text
language plpgsql
set search_path = public, pg_catalog
as $f$
declare
  v_uid uuid;
  v_l   text;
begin
  if p_vista <> all (array['fin_v_periodos', 'fin_v_comisiones_bloqueos', 'fin_v_pnl_mensual', 'fin_v_comisiones_mensual',
                           'fin_v_llamadas_setter', 'fin_v_metricas_ventas', 'fin_v_cash_collected_concepto',
                           'fin_v_ranking_closers']) then
    raise exception 'vista no permitida: %', p_vista;
  end if;
  select a.id into v_uid from auth.users a where lower(a.email) = lower(p_usuario);
  if v_uid is null then
    raise exception 'usuario no encontrado: %', p_usuario;
  end if;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', v_uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  for v_l in execute format('explain (analyze, buffers) select * from public.%I', p_vista) loop
    return next v_l;
  end loop;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return;
end
$f$;

revoke all on function public.fin_ctl_098_visibilidad(text, boolean) from public, anon, authenticated;
revoke all on function public.fin_ctl_098_explain(text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- C1. ANTES (correr ANTES de la 098; guarda la foto en una tabla).
-- Si da timeout en el editor: correrla por usuario, cambiando el
-- "select * from fn()" por  fn('finanzas@liam.dystopia')  con insert en la
-- tabla, o con  fn(null, false)  (solo tablas, sin vistas).
-- ---------------------------------------------------------------------
drop table if exists public.fin_ctl_098_antes;
create table public.fin_ctl_098_antes as
select now() as tomada_en, * from public.fin_ctl_098_visibilidad();
alter table public.fin_ctl_098_antes enable row level security;
revoke all on public.fin_ctl_098_antes from anon, authenticated;

-- C1b. Mirar la foto: una fila por usuario y objeto. 'error' distinto de null
-- es normal para anon o para un rol sin permiso de lectura (tiene que dar lo
-- mismo antes y despues).
-- select usuario, rol, objeto, tipo, filas, hash_ids, hash_contenido, error
--   from public.fin_ctl_098_antes order by usuario, tipo, objeto;


-- ---------------------------------------------------------------------
-- C3. DESPUES: compara contra el ANTES (correr despues de la 098).
-- Primera fila: resultado IDENTICO o DIFIERE; en esa fila "antes" =
-- cantidad de comparaciones y "despues" = cantidad de diferencias.
-- Las filas siguientes (si las hay) son las diferencias.
-- ---------------------------------------------------------------------
-- with d as (select * from public.fin_ctl_098_visibilidad()),
-- cmp as (
--   select coalesce(a.usuario, d.usuario) as usuario, coalesce(a.objeto, d.objeto) as objeto,
--          a.filas as filas_antes, d.filas as filas_despues,
--          (a.filas is distinct from d.filas
--           or a.hash_contenido is distinct from d.hash_contenido
--           or a.error is distinct from d.error) as dif
--     from public.fin_ctl_098_antes a
--     full join d on d.usuario = a.usuario and d.objeto = a.objeto
-- )
-- select 0 as orden,
--        case when count(*) filter (where dif) = 0 and count(*) > 0 then 'IDENTICO' else 'DIFIERE' end as resultado,
--        null::text as usuario, null::text as objeto,
--        count(*) as antes, count(*) filter (where dif) as despues
--   from cmp
-- union all
-- select 1, 'DIFIERE', usuario, objeto, filas_antes, filas_despues from cmp where dif
-- order by 1, 3, 4;


-- ---------------------------------------------------------------------
-- C4. Tiempos. Una consulta por usuario (4 vistas lentas). La linea que
-- importa es "Execution Time" de cada caso. Correr antes y despues.
-- ---------------------------------------------------------------------
-- finanzas@liam.dystopia
-- select c.caso, l.n, l.linea
--   from (values ('fin_v_periodos'), ('fin_v_comisiones_bloqueos'), ('fin_v_pnl_mensual'), ('fin_v_comisiones_mensual')) c(caso),
--   lateral (select t.linea, t.n from public.fin_ctl_098_explain('finanzas@liam.dystopia', c.caso) with ordinality t(linea, n)) l
--  order by c.caso, l.n;

-- ventas@liam.dystopia
-- select c.caso, l.n, l.linea
--   from (values ('fin_v_periodos'), ('fin_v_comisiones_bloqueos'), ('fin_v_pnl_mensual'), ('fin_v_comisiones_mensual')) c(caso),
--   lateral (select t.linea, t.n from public.fin_ctl_098_explain('ventas@liam.dystopia', c.caso) with ordinality t(linea, n)) l
--  order by c.caso, l.n;

-- Solo los tiempos totales, para pegar antes/despues lado a lado:
-- select u.usuario, c.caso,
--        (select t.linea from public.fin_ctl_098_explain(u.usuario, c.caso) t(linea) where t.linea like 'Execution Time%') as tiempo
--   from (values ('finanzas@liam.dystopia'), ('ventas@liam.dystopia')) u(usuario),
--        (values ('fin_v_periodos'), ('fin_v_comisiones_bloqueos'), ('fin_v_pnl_mensual'), ('fin_v_comisiones_mensual')) c(caso)
--  order by 1, 2;


-- ---------------------------------------------------------------------
-- C5. Politicas que SIGUEN llamando a las funciones por fila (segunda
-- tanda). grupo:
--   'alcance 098 (no reconocida)' = estaba en la lista de la 098 y se salteo
--   'cs_* (fuera de esta tanda)'
--   'segunda tanda'              = otras tablas (Marketing, Producto, etc.)
-- ---------------------------------------------------------------------
-- select case when p.tablename like 'cs\_%' then 'cs_* (fuera de esta tanda)'
--             when p.tablename = any (array[
--               'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_cuotas', 'fin_llamadas', 'fin_personas',
--               'fin_vendedores', 'fin_vendedor_asignaciones', 'fin_liquidaciones', 'fin_liquidacion_items',
--               'fin_fuentes_mapa', 'fin_catalogos', 'fin_formulario_preguntas', 'fin_pagos_anulados',
--               'fin_columnas', 'fin_pagos_extra', 'fin_data_columnas']) then 'alcance 098 (no reconocida)'
--             else 'segunda tanda' end as grupo,
--        p.tablename as tabla, p.policyname as politica, p.cmd, p.roles,
--        (select reltuples::bigint from pg_class c where c.oid = to_regclass('public.' || quote_ident(p.tablename))) as filas_aprox,
--        p.qual, p.with_check
--   from pg_policies p
--  where p.schemaname = 'public'
--    and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
--        ~* '(?<!select )(?<![\w.])(es_fundador|rol_actual|auth\.uid)\(\)|\m(tiene_acceso|fin_asignado|fin_ve_plata)\('
--  order by 1, 2, 3;


-- ---------------------------------------------------------------------
-- C6. Politicas tocadas por la 098: texto original (respaldo) contra el
-- actual. cambio = false significa que no esta reescrita.
-- ---------------------------------------------------------------------
-- select r.tabla, r.politica, r.cmd, (p.qual is distinct from r.qual or p.with_check is distinct from r.with_check) as cambio,
--        r.qual as qual_original, p.qual as qual_nueva
--   from public.fin_respaldo_098_policies r
--   left join pg_policies p on p.schemaname = 'public' and p.tablename = r.tabla and p.policyname = r.politica
--  order by 1, 2;


-- ---------------------------------------------------------------------
-- C7. Limpieza (cuando se haya verificado todo):
-- ---------------------------------------------------------------------
-- drop function if exists public.fin_ctl_098_visibilidad(text, boolean);
-- drop function if exists public.fin_ctl_098_explain(text, text);
-- drop table if exists public.fin_ctl_098_antes;
