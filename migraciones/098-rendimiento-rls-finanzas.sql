-- =====================================================================
-- 098-rendimiento-rls-finanzas.sql
-- RENDIMIENTO: las politicas RLS de las tablas fin_* evaluan el permiso UNA
-- vez por consulta y no una vez por fila. NO cambia quien ve que.
--
-- PROBLEMA (medido en produccion el 13/10/2026): las politicas llaman por
-- fila a es_fundador(), rol_actual(), tiene_acceso(cliente_id),
-- fin_asignado(cliente_id), fin_ve_plata(cliente_id) y auth.uid(). Son
-- funciones sql security definer: Postgres no las puede inlinar y las corre
-- una vez por fila, y las vistas de comisiones las multiplican (cada pago
-- lee fin_personas y fin_vendedor_asignaciones, que tambien tienen RLS).
-- Resultado: fin_v_periodos 56 ms sin RLS contra 2668 ms con RLS.
--
-- TECNICA (solo reescribe el TEXTO de las politicas existentes):
--   es_fundador()          -> (select public.es_fundador())            InitPlan, 1 vez
--   rol_actual()           -> (select public.rol_actual())             InitPlan, 1 vez
--   auth.uid()             -> (select auth.uid())                      InitPlan, 1 vez
--   fin_asignado(X)        -> coalesce(X = any((select public.fin_clientes_asignados())::text[]), false)
--   tiene_acceso(X)        -> (coalesce((select es_fundador()), false)
--                              or coalesce(X = any((select fin_clientes_asignados())::text[]), false))
--   fin_ve_plata(X)        -> (coalesce((select es_fundador()), false)
--                              or ((select rol_actual()) in ('cliente','finanzas')
--                                  and coalesce(X = any((select fin_clientes_asignados())::text[]), false)))
--   (el ::text[] es obligatorio: sin el, Postgres lee la subconsulta como filas y da
--   "operator does not exist: text = text[]".)
--   Funcion NUEVA public.fin_clientes_asignados() -> text[] con los
--   cliente_id de crm_asignaciones del usuario (vacio si no hay sesion).
--   No se cambia NINGUNA funcion existente (Marketing y Producto las usan).
--
-- COMO SE GARANTIZA QUE NO CAMBIA NADA (todo adentro del mismo bloque, y si
-- algo no cierra el bloque aborta y no queda nada):
--   G1. La politica se lee de pg_policies tal como esta HOY en produccion
--       (no de estos archivos) y se reescribe con ALTER POLICY: roles,
--       comando y permissive no se tocan.
--   G2. Antes de tocar, para cada usuario de crm_members + un usuario sin
--       rol + anonimo, y para cada cliente (y null y uno inexistente), se
--       compara tiene_acceso / fin_asignado / fin_ve_plata contra el TEXTO
--       exacto de la expresion nueva (el mismo que se escribe en la
--       politica, evaluado con execute). Si una sola combinacion difiere, aborta.
--   G3. Antes y despues, para cada usuario (idem) y cada tabla tocada, se
--       compara cantidad de filas + md5 del contenido de lo que ve con
--       set local role authenticated/anon. Si difiere en algo, aborta.
--   G4. Una politica con una forma no reconocida (argumento que no es una
--       columna, NOT, llamada sin envolver que quedo) NO se toca y queda
--       en la lista de la 098b. No se corrige ninguna politica "rara".
--
-- QUE TOCA: politicas de las tablas de c_tablas (abajo) que llaman a esas
-- funciones; indices que falten (create index if not exists); la funcion
-- nueva; la tabla de respaldo fin_respaldo_098_policies. Las vistas fin_v_*
-- NO se tocan: son security_invoker y su filtro de rol propio
-- (es_fundador() or rol_actual() = ...) no tiene columnas, Postgres lo
-- evalua una sola vez (One-Time Filter). Las cs_* y Marketing: no.
--
-- COMO SE CORRE (de a uno, en este orden):
--   0. 098b: crear las funciones de control y guardar el ANTES (C1 y C2).
--   1. Diagnostico Dx1 y Dx2 de abajo (solo lectura).
--   2. El bloque DO (UNA sola sentencia). No correr a las :00/:15/:30/:45
--      ni a las 9:00 (corre la sync; el bloque toma lock a las tablas).
--   3. 098b C3 (DESPUES, debe decir IDENTICO) y C4/C5 (tiempos y lista).
-- Re-ejecutable: sobre politicas ya reescritas no cambia nada.
-- Si hay que volver atras: bloque comentado al final.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Dx1. DIAGNOSTICO (solo lectura): politicas de las tablas del alcance y
-- si hoy llaman a las funciones por fila (llama_por_fila = true).
-- ---------------------------------------------------------------------
select p.tablename as tabla, p.policyname as politica, p.cmd,
       ((coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
          ~* '(?<!select )(?<![\w.])(es_fundador|rol_actual|auth\.uid)\(\)|\m(tiene_acceso|fin_asignado|fin_ve_plata)\('
       ) as llama_por_fila,
       p.qual, p.with_check
from pg_policies p
where p.schemaname = 'public'
  and p.tablename = any (array[
    'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_cuotas', 'fin_llamadas', 'fin_personas',
    'fin_vendedores', 'fin_vendedor_asignaciones', 'fin_liquidaciones', 'fin_liquidacion_items',
    'fin_fuentes_mapa', 'fin_catalogos', 'fin_formulario_preguntas', 'fin_pagos_anulados',
    'fin_columnas', 'fin_pagos_extra', 'fin_data_columnas'])
order by 1, 2;

-- ---------------------------------------------------------------------
-- Dx2. DIAGNOSTICO (solo lectura): estado. Una fila.
--   funciones_base        = 5 (es_fundador, rol_actual, tiene_acceso, fin_asignado, fin_ve_plata)
--   funcion_nueva         = true si ya se corrio la 098
--   politicas_a_reescribir = cuantas toca el bloque (si es 0 y funcion_nueva: YA APLICADA)
--   respaldadas           = filas en fin_respaldo_098_policies (null = no existe)
-- ---------------------------------------------------------------------
select
  (select count(*) from (values ('public.es_fundador()'), ('public.rol_actual()'), ('public.tiene_acceso(text)'),
                                 ('public.fin_asignado(text)'), ('public.fin_ve_plata(text)')) f(n)
    where to_regprocedure(f.n) is not null) as funciones_base,
  (to_regprocedure('public.fin_clientes_asignados()') is not null) as funcion_nueva,
  (select count(*) from pg_policies p
    where p.schemaname = 'public'
      and p.tablename = any (array[
        'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_cuotas', 'fin_llamadas', 'fin_personas',
        'fin_vendedores', 'fin_vendedor_asignaciones', 'fin_liquidaciones', 'fin_liquidacion_items',
        'fin_fuentes_mapa', 'fin_catalogos', 'fin_formulario_preguntas', 'fin_pagos_anulados',
        'fin_columnas', 'fin_pagos_extra', 'fin_data_columnas'])
      and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
          ~* '(?<!select )(?<![\w.])(es_fundador|rol_actual|auth\.uid)\(\)|\m(tiene_acceso|fin_asignado|fin_ve_plata)\('
  ) as politicas_a_reescribir,
  -- sin referencia estatica a la tabla (si no existe, Postgres falla al parsear): query_to_xml
  -- recibe el SQL como texto y la subconsulta no devuelve fila si la tabla no existe.
  (select (xpath('/row/c/text()',
                 query_to_xml('select count(*) as c from public.fin_respaldo_098_policies', false, true, '')))[1]::text::int
     from pg_class c
    where c.oid = to_regclass('public.fin_respaldo_098_policies')) as respaldadas;


-- =====================================================================
-- BLOQUE UNICO. Una sola sentencia (el SQL Editor pasa por un pooler: sin
-- begin/commit ni temporales). Atomico: o queda todo o no queda nada.
-- =====================================================================
do $m098$
declare
  c_tablas constant text[] := array[
    'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_cuotas', 'fin_llamadas', 'fin_personas',
    'fin_vendedores', 'fin_vendedor_asignaciones', 'fin_liquidaciones', 'fin_liquidacion_items',
    'fin_fuentes_mapa', 'fin_catalogos', 'fin_formulario_preguntas', 'fin_pagos_anulados',
    'fin_columnas', 'fin_pagos_extra', 'fin_data_columnas'];
  c_nucleo constant text[] := array['fin_pagos', 'fin_llamadas', 'fin_personas', 'fin_vendedores', 'fin_vendedor_asignaciones'];
  v_esperado_funciones     constant int := 5;
  v_esperado_nucleo        constant int := 5;
  v_esperado_max_politicas constant int := 45;   -- si hay mas, se corre por tandas (editar c_tablas)

  c_F constant text := '(select public.es_fundador())';
  c_R constant text := '(select public.rol_actual())';
  -- el cast a text[] es obligatorio: sin el, "x = any((select f()))" se lee como subconsulta de filas
  c_A constant text := '(select public.fin_clientes_asignados())::text[]';
  c_U constant text := '(select auth.uid())';
  -- Plantillas de las expresiones nuevas ({X} = la columna / el parametro). Las usan tanto G2
  -- (con $1) como la reescritura (con la columna): se prueba exactamente lo que se escribe.
  c_e_tiene constant text :=
    '(coalesce(' || c_F || ', false) or coalesce({X} = any(' || c_A || '), false))';
  c_e_asig  constant text :=
    'coalesce({X} = any(' || c_A || '), false)';
  c_e_plata constant text :=
    '(coalesce(' || c_F || ', false) or (' || c_R || ' in (''cliente'', ''finanzas'') and coalesce({X} = any(' || c_A || '), false)))';
  c_detecta constant text :=
    '(?<!select )(?<![\w.])(es_fundador|rol_actual|auth\.uid)\(\)|\m(tiene_acceso|fin_asignado|fin_ve_plata)\(';

  v_tablas   text[];
  v_t        text;
  v_n        int;
  v_uid      uuid;
  v_users    uuid[];
  v_sin_rol  uuid := gen_random_uuid();
  v_cli      text;
  v_clis     text[];
  r          record;
  v_pase     int;
  v_snap     jsonb;
  v_antes    jsonb;
  v_despues  jsonb;
  v_filas    bigint;
  v_hash     text;
  v_txt      text[];
  v_new      text[];
  v_k        int;
  v_x        text;
  v_att      smallint[];
  v_tocadas  int := 0;
  v_iguales  int := 0;
  v_saltadas text[] := '{}';
  v_dif      text;
  v_b        boolean;
begin
  -- 0. Lock (regla de la casa) y tiempos
  perform set_config('lock_timeout', '10s', true);
  perform set_config('search_path', 'public, pg_catalog', true);

  -- 1. Guardas v_esperado_*
  select count(*) into v_n from (values ('public.es_fundador()'), ('public.rol_actual()'), ('public.tiene_acceso(text)'),
                                        ('public.fin_asignado(text)'), ('public.fin_ve_plata(text)')) f(n)
   where to_regprocedure(f.n) is not null;
  if v_n <> v_esperado_funciones then
    raise exception 'GUARDA 098: faltan funciones base (% de %). Falta la 075 u otra migracion. No se aplica nada.', v_n, v_esperado_funciones;
  end if;
  if to_regclass('public.crm_asignaciones') is null or to_regclass('public.crm_members') is null
     or to_regclass('public.crm_clients') is null then
    raise exception 'GUARDA 098: faltan crm_asignaciones / crm_members / crm_clients. No se aplica nada.';
  end if;

  select coalesce(array_agg(t order by t), '{}') into v_tablas
    from unnest(c_tablas) t where to_regclass('public.' || t) is not null;
  select count(*) into v_n from unnest(c_nucleo) t where t = any (v_tablas);
  if v_n <> v_esperado_nucleo then
    raise exception 'GUARDA 098: faltan tablas nucleo (% de %). No se aplica nada.', v_n, v_esperado_nucleo;
  end if;

  foreach v_t in array v_tablas loop
    execute format('lock table public.%I in access exclusive mode', v_t);
  end loop;

  select count(*) into v_n
    from pg_policies p
   where p.schemaname = 'public' and p.tablename = any (v_tablas)
     and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '')) ~* c_detecta;
  if v_n > v_esperado_max_politicas then
    raise exception 'GUARDA 098: % politicas a reescribir (maximo % por tanda). Achicar c_tablas y correr por tandas.', v_n, v_esperado_max_politicas;
  end if;

  -- 2. Funcion nueva: clientes asignados al usuario (mismo criterio que fin_asignado)
  execute $f$
    create or replace function public.fin_clientes_asignados()
    returns text[]
    language sql stable security definer set search_path = ''
    as $b$
      select coalesce(array_agg(a.cliente_id::text), '{}'::text[])
        from public.crm_asignaciones a
       where a.user_id = auth.uid();
    $b$
  $f$;
  -- Sin REVOKE a PUBLIC: devuelve solo las asignaciones del propio usuario (vacio sin sesion) y
  -- varias politicas son para {public}; asi ningun rol de base pasa de ver 0 filas a "permission denied".
  execute 'grant execute on function public.fin_clientes_asignados() to public';
  execute $c$comment on function public.fin_clientes_asignados() is
    '098: cliente_id de crm_asignaciones del usuario actual (text[], vacio sin sesion). Lo usan las politicas RLS de fin_* una vez por consulta.'$c$;

  -- 3. Usuarios a simular: miembros + uno sin rol + anonimo (null)
  select coalesce(array_agg(u order by u), '{}') into v_users
    from (select distinct user_id as u from public.crm_members where user_id is not null) q;
  v_users := v_users || v_sin_rol || null::uuid;
  select coalesce(array_agg(id order by id), '{}') into v_clis from public.crm_clients;
  v_clis := v_clis || 'zz_inexistente'::text || null::text;

  -- 4. G2: la expresion nueva equivale a la funcion vieja, por usuario y cliente.
  --    Se evalua el TEXTO exacto que despues se escribe en las politicas (c_e_*, con $1 = cliente).
  foreach v_uid in array v_users loop
    perform set_config('request.jwt.claim.sub', coalesce(v_uid::text, ''), true);
    perform set_config('request.jwt.claims',
      case when v_uid is null then '' else json_build_object('sub', v_uid, 'role', 'authenticated')::text end, true);
    foreach v_cli in array v_clis loop
      execute 'select ' || replace(c_e_tiene, '{X}', '$1') into v_b using v_cli;
      if coalesce(public.tiene_acceso(v_cli), false) is distinct from coalesce(v_b, false) then
        raise exception 'GUARDA 098 (G2): tiene_acceso(%) no equivale a la expresion nueva para el usuario %. No se aplica nada.', v_cli, v_uid;
      end if;
      execute 'select ' || replace(c_e_asig, '{X}', '$1') into v_b using v_cli;
      if coalesce(public.fin_asignado(v_cli), false) is distinct from coalesce(v_b, false) then
        raise exception 'GUARDA 098 (G2): fin_asignado(%) no equivale a la expresion nueva para el usuario %. No se aplica nada.', v_cli, v_uid;
      end if;
      execute 'select ' || replace(c_e_plata, '{X}', '$1') into v_b using v_cli;
      if coalesce(public.fin_ve_plata(v_cli), false) is distinct from coalesce(v_b, false) then
        raise exception 'GUARDA 098 (G2): fin_ve_plata(%) no equivale a la expresion nueva para el usuario %. No se aplica nada.', v_cli, v_uid;
      end if;
    end loop;
  end loop;

  -- 5. Respaldo de las politicas (una vez: en una re-ejecucion no se pisa el original)
  execute $t$
    create table if not exists public.fin_respaldo_098_policies (
      tabla        text not null,
      politica     text not null,
      cmd          text,
      permissive   text,
      roles        text[],
      qual         text,
      with_check   text,
      respaldado_en timestamptz not null default now(),
      primary key (tabla, politica)
    )
  $t$;
  execute 'alter table public.fin_respaldo_098_policies enable row level security';
  execute 'revoke all on public.fin_respaldo_098_policies from anon, authenticated';

  -- 6. Pase 1 (ANTES), reescritura, pase 2 (DESPUES)
  for v_pase in 1..2 loop

    if v_pase = 2 then
      for r in
        select p.*
          from pg_policies p
         where p.schemaname = 'public' and p.tablename = any (v_tablas)
           and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, '')) ~* c_detecta
         order by p.tablename, p.policyname
      loop
        v_txt := array[r.qual, r.with_check];
        v_new := array[null, null]::text[];
        for v_k in 1..2 loop
          v_x := v_txt[v_k];
          continue when v_x is null;
          -- nombres sin esquema
          v_x := regexp_replace(v_x, '\mpublic\.(es_fundador|rol_actual|tiene_acceso|fin_asignado|fin_ve_plata)\(', '\1(', 'g');
          -- con argumento (el argumento tiene que ser una columna)
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])fin_ve_plata\(([a-z_][a-z0-9_.]*)\)',
                   replace(c_e_plata, '{X}', '\1'), 'g');
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])tiene_acceso\(([a-z_][a-z0-9_.]*)\)',
                   replace(c_e_tiene, '{X}', '\1'), 'g');
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])fin_asignado\(([a-z_][a-z0-9_.]*)\)',
                   replace(c_e_asig, '{X}', '\1'), 'g');
          -- sin argumento
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])es_fundador\(\)', c_F, 'g');
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])rol_actual\(\)', c_R, 'g');
          v_x := regexp_replace(v_x, '(?i)(?<!select )(?<![\w.])auth\.uid\(\)', c_U, 'g');
          v_new[v_k] := v_x;
        end loop;

        -- G4: forma no reconocida -> no se toca
        if coalesce(v_new[1], '') ~* c_detecta or coalesce(v_new[2], '') ~* c_detecta then
          v_saltadas := v_saltadas || (r.tablename || '.' || r.policyname || ' (llamada con argumento no reconocido)');
          continue;
        end if;
        if (coalesce(v_txt[1], '') || coalesce(v_txt[2], '')) ~* '(?<!is )\mnot\M' then
          v_saltadas := v_saltadas || (r.tablename || '.' || r.policyname || ' (usa NOT)');
          continue;
        end if;
        if v_new[1] is not distinct from v_txt[1] and v_new[2] is not distinct from v_txt[2] then
          v_iguales := v_iguales + 1;
          continue;
        end if;

        insert into public.fin_respaldo_098_policies (tabla, politica, cmd, permissive, roles, qual, with_check)
        values (r.tablename, r.policyname, r.cmd, r.permissive, r.roles::text[], r.qual, r.with_check)
        on conflict (tabla, politica) do nothing;

        execute format('alter policy %I on public.%I%s%s', r.policyname, r.tablename,
          case when v_new[1] is not null then ' using (' || v_new[1] || ')' else '' end,
          case when v_new[2] is not null then ' with check (' || v_new[2] || ')' else '' end);
        v_tocadas := v_tocadas + 1;
      end loop;
    end if;

    -- Foto de lo que ve cada usuario en cada tabla (filas + md5 del contenido)
    v_snap := '{}'::jsonb;
    foreach v_uid in array v_users loop
      execute 'reset role';
      if v_uid is null then
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '', true);
        execute 'set local role anon';
      else
        perform set_config('request.jwt.claim.sub', v_uid::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
      end if;
      foreach v_t in array v_tablas loop
        begin
          execute format(
            'select count(*), md5(coalesce(string_agg(to_jsonb(x)::text, '','' order by to_jsonb(x)::text), '''')) from public.%I x', v_t)
            into v_filas, v_hash;
          v_snap := v_snap || jsonb_build_object(coalesce(v_uid::text, 'anon') || '|' || v_t, v_filas::text || '|' || v_hash);
        exception when others then
          v_snap := v_snap || jsonb_build_object(coalesce(v_uid::text, 'anon') || '|' || v_t, 'ERR ' || sqlstate);
        end;
      end loop;
      execute 'reset role';
    end loop;
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);

    if v_pase = 1 then v_antes := v_snap; else v_despues := v_snap; end if;
  end loop;

  -- 7. G3: lo que ve cada usuario es identico
  select string_agg(k, ', ') into v_dif
    from (select coalesce(a.key, d.key) as k
            from jsonb_each_text(v_antes) a
            full join jsonb_each_text(v_despues) d on d.key = a.key
           where a.value is distinct from d.value
           limit 10) q;
  if v_dif is not null then
    raise exception 'GUARDA 098 (G3): cambio lo que ve un usuario (usuario|tabla: %). Se revierte todo.', v_dif;
  end if;

  -- 8. Indices que faltan (si ya hay uno con esas columnas al principio, no se crea otro)
  for r in
    select * from (values
      ('crm_members',               array['user_id']),
      ('crm_asignaciones',          array['user_id', 'cliente_id']),
      ('fin_personas',              array['user_id']),
      ('fin_pagos',                 array['cliente_id']),
      ('fin_llamadas',              array['cliente_id']),
      ('fin_pnl',                   array['cliente_id']),
      ('fin_pnl_saldos',            array['cliente_id']),
      ('fin_cuotas',                array['cliente_id']),
      ('fin_liquidaciones',         array['cliente_id']),
      ('fin_vendedor_asignaciones', array['cliente_id']),
      ('fin_pagos_extra',           array['cliente_id']),
      ('fin_columnas',              array['cliente_id'])
    ) as t(tabla, cols)
  loop
    continue when to_regclass('public.' || r.tabla) is null;
    select count(*) into v_n from information_schema.columns
     where table_schema = 'public' and table_name = r.tabla and column_name = any (r.cols);
    continue when v_n <> cardinality(r.cols);
    select array_agg(a.attnum order by u.ord) into v_att
      from unnest(r.cols) with ordinality u(col, ord)
      join pg_attribute a on a.attrelid = to_regclass('public.' || r.tabla) and a.attname = u.col;
    continue when exists (
      select 1 from pg_index i
       where i.indrelid = to_regclass('public.' || r.tabla)
         and i.indisvalid and i.indpred is null and i.indexprs is null
         and (string_to_array(i.indkey::text, ' ')::smallint[])[1:cardinality(r.cols)] = v_att);
    execute format('create index if not exists %I on public.%I (%s)',
      r.tabla || '_' || array_to_string(r.cols, '_') || '_098_idx', r.tabla,
      (select string_agg(quote_ident(c), ', ') from unnest(r.cols) c));
  end loop;

  raise notice '098 OK: % politicas reescritas, % ya estaban, % sin tocar: %', v_tocadas, v_iguales, coalesce(cardinality(v_saltadas), 0), v_saltadas;
end
$m098$;


-- =====================================================================
-- CONTROLES: ver 098b-rendimiento-rls-controles.sql (de a uno).
--   C3 debe decir IDENTICO. C5 lista lo que quedo llamando por fila.
-- Resumen rapido de lo reescrito (solo lectura):
-- select r.tabla, r.politica, r.cmd from public.fin_respaldo_098_policies r order by 1, 2;
-- =====================================================================


-- =====================================================================
-- VUELTA ATRAS (comentada; NO correr salvo decision de Joaquin).
-- Restaura el texto original de cada politica desde el respaldo, despues
-- saca la funcion nueva y los indices de la 098. Un bloque, en este orden.
-- =====================================================================
-- do $rb$
-- declare r record; i record;
-- begin
--   for r in select * from public.fin_respaldo_098_policies order by tabla, politica loop
--     execute format('alter policy %I on public.%I%s%s', r.politica, r.tabla,
--       case when r.qual is not null then ' using (' || r.qual || ')' else '' end,
--       case when r.with_check is not null then ' with check (' || r.with_check || ')' else '' end);
--   end loop;
--   -- recien con las politicas restauradas se puede sacar la funcion
--   drop function if exists public.fin_clientes_asignados();
--   for i in select indexname from pg_indexes where schemaname = 'public' and indexname like '%\_098\_idx' loop
--     execute format('drop index if exists public.%I', i.indexname);
--   end loop;
-- end
-- $rb$;
-- -- Despues, si ya no hace falta el respaldo:
-- -- drop table public.fin_respaldo_098_policies;
