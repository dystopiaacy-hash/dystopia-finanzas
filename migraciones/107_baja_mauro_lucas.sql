-- =====================================================================
-- 107_baja_mauro_lucas.sql   (COPIA CORREGIDA por la revision del 13/10/2026)
-- Finanzas / base compartida de Dystopia. Baja de los clientes mauro y lucas
-- (Dystopia queda con liam, agus y teo). CON respaldo. SIN CORRER (la corre el
-- jefe despues del banco de pruebas: jefe\banco-pruebas\pglite-107).
--
-- Cambios respecto del original de dystopia-finanzas\migraciones (detalle en
-- jefe\insumos\107\informe-107.md):
--   R0. BUG que impedia correr: `v_tab || 'cs_maestro_columnas'` (text[] || literal
--       sin tipo) da "malformed array literal" y aborta siempre. Ahora con ::text.
--   R1. cs_programas ('mauro' y 'lucas') SI se borra, con respaldo
--       cs_programas_bak_baja_107 (decision del dueño: de todos lados).
--   R2. Vista fin_v_alias_pendientes: Postgres la guarda como
--       "WHERE cliente_id <> 'mauro'" SIN alias; el original exigia alias y la
--       dejaba sin tocar (con un WARNING que por el conector no se ve).
--   R3. Hijas de hijas: fin_filas_rechazadas tambien cuelga de fin_sync_corridas
--       (corrida_id, cascade). El original solo miraba fuente_id (que admite null).
--   R4. Guarda nueva 2e: aborta si una fila de OTRO cliente apunta a una fila de
--       mauro/lucas con FK set null / cascade (el original la pisaba sin avisar).
--   R5. Solo se respaldan y bloquean tablas que pueden tener filas: columnas
--       cliente_id de texto, y respaldo solo si hay filas (sin respaldos vacios).
--   R6. Los respaldos tambien se le sacan a service_role (quedan solo postgres).
--
-- Que hace (todo en UN solo bloque `do`, atomico: si algo falla no queda nada):
--   0. Bloquea escrituras en las tablas afectadas (lock_timeout 10 s).
--   1. Descubre las tablas: todas las de public con columna cliente_id de texto
--      (information_schema), mas las FK a crm_clients con otro nombre de
--      columna, mas las hijas sin cliente_id que cuelgan de fin_fuentes y de
--      fin_liquidaciones y las hijas de esas hijas (se respaldan por join), mas
--      cs_maestro_columnas (por programa_id) y cs_programas (por id). Excluye los
--      respaldos viejos (cs_bak_*, fin_respaldo_*, crm_respaldo_*, *_bak_*,
--      fin_import_*, fin_ctl_*), salvo crm_publicaciones_bak_053.
--   2. Guardas: aborta si <nombre>_bak_baja_107 ya existe, si hay triggers de
--      DELETE en las tablas que va a borrar (no mira otras tablas: el trigger de
--      cs_renovaciones no la frena), si el borrado arrastraria por cascada filas
--      de tablas que no estan en la lista, si otra tabla cs_* tiene filas de esos
--      programas, o si filas de otro cliente apuntan a filas de mauro/lucas.
--   3. Respaldo ANTES de borrar: create table <tabla>_bak_baja_107 as select * ...
--      (RLS activada sin policies, revoke a public/anon/authenticated/service_role).
--      Tambien guarda las definiciones de funciones y vistas que se reemplazan,
--      en fin_funciones_bak_baja_107.
--   4. Borrado explicito por grupos: hijas de fuentes/liquidaciones, tablas con
--      cliente_id, fin_fuentes, otras FK y cs_maestro_columnas, y al final
--      crm_clients y cs_programas. No se cambia ninguna FK. Dentro de cada grupo
--      reintenta en pasadas si una FK `no action` bloquea.
--   5. Verifica: cero filas de mauro/lucas, y para cada tabla
--      total_despues = total_antes - filas_borradas (liam, agus y teo intactos).
--   6. B3: saca los nombres escritos a mano de fin_pagos_resolver,
--      fin_clientes_carga, fin_data_admite_nuevas, fin_v_alias_pendientes y
--      fin_v_pago_vendedores. Parte de la definicion VIGENTE en la base
--      (pg_get_functiondef / pg_get_viewdef), le saca solo ese texto y la vuelve a
--      crear: firma, security definer, search_path, dueño y permisos no cambian.
--      Guarda: si el texto esperado no esta, avisa con WARNING y NO la toca (los
--      datos se borran igual). El WARNING no se ve por el conector: mirar C8.
--      NO toca crm_dashboard (es de Marketing) ni fin_data_closers_de ("Lucas
--      Deza" es un closer de liam, no el cliente).
--
-- Correr: no a las :00/:15/:30/:45 ni a las 9:00 (corre la sync).
-- Controles: al final del archivo, comentados, de a uno.
-- Vuelta atras: 107_baja_mauro_lucas_REVERTIR.sql (no se corre).
-- =====================================================================

do $m107$
declare
  v_ids     text[] := array['mauro', 'lucas'];
  v_arr     text;
  v_viejos  text := '(_bak_|_bak$|_respaldo_|^fin_respaldo|^crm_respaldo|^cs_bak|^fin_import_|^fin_ctl_)';
  v_tab     text[] := '{}';   -- tabla
  v_whe     text[] := '{}';   -- condicion SQL (con la lista de ids inline)
  v_gru     int[]  := '{}';   -- 1 hijas por join, 2 cliente_id, 3 fin_fuentes, 4 otras FK y cs_maestro_columnas, 5 crm_clients y cs_programas
  v_nm      bigint[];         -- filas a borrar
  v_tot     bigint[];         -- total antes
  v_ok      boolean[];
  v_omitidas text[] := '{}';
  v_fks     oid[] := '{}';    -- FK ya recorridas en 1c
  r         record;
  i         int;
  j         int;
  g         int;
  pasada    int;
  prog      boolean;
  cambio    boolean;
  pend      int;
  n         bigint;
  v_txt     text;
  v_bak     text;
  v_def     text;
  v_new     text;
  v_opt     text;
  v_err     text;
begin
  perform set_config('lock_timeout', '10s', true);
  v_arr := format('%L::text[]', v_ids::text);

  -- ---------------------------------------------------------------
  -- 1. Descubrimiento
  -- ---------------------------------------------------------------
  -- 1a. Tablas con cliente_id de texto (un cliente_id uuid/numerico es otra cosa: alumnos de Producto)
  for r in
    select c.table_name::text as t
    from information_schema.columns c
    join information_schema.tables x
      on x.table_schema = c.table_schema and x.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'cliente_id' and x.table_type = 'BASE TABLE'
      and c.data_type not in ('uuid', 'bigint', 'integer', 'smallint', 'numeric')
    order by c.table_name
  loop
    if r.t ~ '_bak_baja_107$' then continue; end if;
    if r.t ~ v_viejos and r.t <> 'crm_publicaciones_bak_053' then
      v_omitidas := v_omitidas || r.t;
      continue;
    end if;
    v_tab := v_tab || r.t;
    v_whe := v_whe || ('cliente_id::text = any(' || v_arr || ')');
    v_gru := v_gru || (case when r.t = 'fin_fuentes' then 3 else 2 end);
  end loop;

  -- 1b. FK a crm_clients con otro nombre de columna
  for r in
    select c.relname::text as t, a.attname::text as col
    from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
    where k.contype = 'f' and k.confrelid = 'public.crm_clients'::regclass
      and array_length(k.conkey, 1) = 1 and a.attname <> 'cliente_id'
      and c.relkind in ('r', 'p')
    order by 1, 2
  loop
    if r.t ~ '_bak_baja_107$' or r.t = any(v_tab) then continue; end if;
    if r.t ~ v_viejos and r.t <> 'crm_publicaciones_bak_053' then v_omitidas := v_omitidas || r.t; continue; end if;
    v_tab := v_tab || r.t;
    v_whe := v_whe || (format('%I::text = any(', r.col) || v_arr || ')');
    v_gru := v_gru || 4;
  end loop;

  -- 1c. Hijas sin cliente_id que cuelgan de fin_fuentes / fin_liquidaciones, y las hijas de esas hijas
  --     (fin_filas_rechazadas cuelga de fin_fuentes Y de fin_sync_corridas). Solo FK cascade / no action /
  --     restrict: una hija con set null que no este en la lista la frena la guarda 2c.
  loop
    cambio := false;
    for r in
      select k.oid as fk, c.relname::text as t, a.attname::text as col, p.relname::text as padre, pa.attname::text as colpadre
      from pg_constraint k
      join pg_class c on c.oid = k.conrelid
      join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
      join pg_class p on p.oid = k.confrelid
      join pg_namespace sp on sp.oid = p.relnamespace and sp.nspname = 'public'
      join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
      join pg_attribute pa on pa.attrelid = k.confrelid and pa.attnum = k.confkey[1]
      where k.contype = 'f' and k.confdeltype in ('c', 'a', 'r')
        and array_length(k.conkey, 1) = 1 and c.relkind in ('r', 'p') and c.oid <> p.oid
        and not (k.oid = any(v_fks))
        and (p.relname in ('fin_fuentes', 'fin_liquidaciones')
             or p.relname in (select v_tab[q] from generate_subscripts(v_tab, 1) q where v_gru[q] = 1))
      order by (c.relname = any(v_tab)) desc, 2, 3
    loop
      v_fks := v_fks || r.fk;
      if r.t ~ '_bak_baja_107$' then continue; end if;
      if r.t ~ v_viejos then v_omitidas := v_omitidas || r.t; continue; end if;
      j := array_position(v_tab, r.padre);
      if j is null then continue; end if;
      v_txt := format('%I in (select %I from public.%I where %s)', r.col, r.colpadre, r.padre, v_whe[j]);
      i := array_position(v_tab, r.t);
      if i is null then
        v_tab := v_tab || r.t; v_whe := v_whe || v_txt; v_gru := v_gru || 1;
        cambio := true;
      elsif v_gru[i] = 1 then
        v_whe[i] := v_whe[i] || ' or ' || v_txt;
        cambio := true;
      end if;   -- si ya estaba por cliente_id, esa condicion ya lo cubre (y la guarda 2e mira que no haya cruces)
    end loop;
    exit when not cambio;
  end loop;

  -- 1d. cs_maestro_columnas (por programa_id; confirmado por el jefe: 1 y 1)
  if to_regclass('public.cs_maestro_columnas') is not null and not ('cs_maestro_columnas' = any(v_tab)) then
    v_tab := v_tab || 'cs_maestro_columnas'::text;
    v_whe := v_whe || ('programa_id::text = any(' || v_arr || ')');
    v_gru := v_gru || 4;
  end if;

  -- 1e. crm_clients y cs_programas al final
  v_tab := v_tab || 'crm_clients'::text;
  v_whe := v_whe || ('id::text = any(' || v_arr || ')');
  v_gru := v_gru || 5;
  if to_regclass('public.cs_programas') is not null then
    v_tab := v_tab || 'cs_programas'::text;
    v_whe := v_whe || ('id::text = any(' || v_arr || ')');
    v_gru := v_gru || 5;
  end if;

  -- ---------------------------------------------------------------
  -- 0. Bloqueo de escrituras (una sola sentencia, orden alfabetico: sin deadlock)
  -- ---------------------------------------------------------------
  select string_agg(format('public.%I', t), ', ' order by t) into v_txt from unnest(v_tab) t;
  execute 'lock table ' || v_txt || ' in share row exclusive mode';

  -- ---------------------------------------------------------------
  -- Conteos antes
  -- ---------------------------------------------------------------
  v_nm  := array_fill(0::bigint, array[array_length(v_tab, 1)]);
  v_tot := array_fill(0::bigint, array[array_length(v_tab, 1)]);
  v_ok  := array_fill(false, array[array_length(v_tab, 1)]);
  for i in 1 .. array_length(v_tab, 1) loop
    execute format('select count(*) from public.%I where %s', v_tab[i], v_whe[i]) into n;
    v_nm[i] := n;
    execute format('select count(*) from public.%I', v_tab[i]) into n;
    v_tot[i] := n;
  end loop;

  -- ---------------------------------------------------------------
  -- 2. Guardas
  -- ---------------------------------------------------------------
  -- 2a. respaldos que ya existen
  select string_agg(t || '_bak_baja_107', ', ') into v_txt
  from unnest(v_tab) t
  where to_regclass(format('public.%I', t || '_bak_baja_107')) is not null;
  if v_txt is not null then
    raise exception '107 ABORTADA: ya existen tablas de respaldo: %', v_txt;
  end if;
  if to_regclass('public.fin_funciones_bak_baja_107') is not null then
    raise exception '107 ABORTADA: ya existe fin_funciones_bak_baja_107';
  end if;
  select string_agg(v_tab[q], ', ') into v_txt from generate_subscripts(v_tab, 1) q
  where v_nm[q] > 0 and length(v_tab[q] || '_bak_baja_107') > 63;
  if v_txt is not null then
    raise exception '107 ABORTADA: nombre de respaldo de mas de 63 caracteres para: %', v_txt;
  end if;

  -- 2b. triggers de DELETE no internos en las tablas que se van a borrar (solo esas)
  select string_agg(c.relname || '.' || tg.tgname, ', ') into v_txt
  from pg_trigger tg
  join pg_class c on c.oid = tg.tgrelid
  join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
  where not tg.tgisinternal and (tg.tgtype & 8) <> 0
    and c.relname in (select v_tab[q] from generate_subscripts(v_tab, 1) q where v_nm[q] > 0);
  if v_txt is not null then
    raise exception '107 ABORTADA: hay triggers de DELETE en tablas afectadas (revisar a mano): %', v_txt;
  end if;

  -- 2c. cascadas hacia tablas fuera de la lista (perderian filas sin respaldo)
  v_txt := null;
  for r in
    select c.relname::text as t, a.attname::text as col, p.relname::text as padre, pa.attname::text as colpadre
    from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
    join pg_class p on p.oid = k.confrelid
    join pg_namespace sp on sp.oid = p.relnamespace and sp.nspname = 'public'
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
    join pg_attribute pa on pa.attrelid = k.confrelid and pa.attnum = k.confkey[1]
    where k.contype = 'f' and k.confdeltype in ('c', 'n', 'd')
      and array_length(k.conkey, 1) = 1 and p.relname = any(v_tab)
      and c.relkind in ('r', 'p')
  loop
    if r.t = any(v_tab) or r.t ~ '_bak_baja_107$' then continue; end if;
    i := array_position(v_tab, r.padre);
    execute format('select count(*) from public.%I where %I in (select %I from public.%I where %s)',
                   r.t, r.col, r.colpadre, r.padre, v_whe[i]) into n;
    if n > 0 then v_txt := coalesce(v_txt || ', ', '') || format('%s.%s (%s filas)', r.t, r.col, n); end if;
  end loop;
  if v_txt is not null then
    raise exception '107 ABORTADA: el borrado arrastraria filas de tablas fuera de la lista: %', v_txt;
  end if;

  -- 2d. otras tablas cs_* colgadas de cs_programas con filas de estos programas
  if to_regclass('public.cs_programas') is not null then
    v_txt := null;
    for r in
      select c.relname::text as t, a.attname::text as col
      from pg_constraint k
      join pg_class c on c.oid = k.conrelid
      join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
      join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
      where k.contype = 'f' and k.confrelid = 'public.cs_programas'::regclass
        and array_length(k.conkey, 1) = 1 and c.relname <> 'cs_maestro_columnas'
        and c.relkind in ('r', 'p')
    loop
      if r.t ~ '_bak_baja_107$' then continue; end if;
      execute format('select count(*) from public.%I where %I::text = any(%s)', r.t, r.col, v_arr) into n;
      if n > 0 then v_txt := coalesce(v_txt || ', ', '') || format('%s.%s (%s filas)', r.t, r.col, n); end if;
    end loop;
    if v_txt is not null then
      raise exception '107 ABORTADA: tablas de Producto (cs_*) con filas de mauro/lucas que esta migracion no cubre: %', v_txt;
    end if;
  end if;

  -- 2e. referencias cruzadas: filas que NO son de mauro/lucas pero apuntan (FK cascade / set null / set default)
  --     a una fila de mauro/lucas. Borrarlas o vaciarles la columna seria tocar datos de otro cliente.
  v_txt := null;
  for r in
    select c.relname::text as t, a.attname::text as col, p.relname::text as padre, pa.attname::text as colpadre
    from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
    join pg_class p on p.oid = k.confrelid
    join pg_namespace sp on sp.oid = p.relnamespace and sp.nspname = 'public'
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = k.conkey[1]
    join pg_attribute pa on pa.attrelid = k.confrelid and pa.attnum = k.confkey[1]
    where k.contype = 'f' and k.confdeltype in ('c', 'n', 'd')
      and array_length(k.conkey, 1) = 1 and p.relname = any(v_tab) and c.relname = any(v_tab)
      and c.relkind in ('r', 'p')
  loop
    i := array_position(v_tab, r.padre);
    j := array_position(v_tab, r.t);
    if v_nm[i] = 0 then continue; end if;
    execute format('select count(*) from public.%I where %I in (select %I from public.%I where %s) and (%s) is not true',
                   r.t, r.col, r.colpadre, r.padre, v_whe[i], v_whe[j]) into n;
    if n > 0 then v_txt := coalesce(v_txt || ', ', '') || format('%s.%s -> %s (%s filas)', r.t, r.col, r.padre, n); end if;
  end loop;
  if v_txt is not null then
    raise exception '107 ABORTADA: filas de otros clientes apuntan a filas de mauro/lucas (revisar a mano): %', v_txt;
  end if;

  raise notice '107 tablas: %', (
    select string_agg(format('%s[%s]=%s', t, v_gru[o], v_nm[o]), ', ' order by v_gru[o], t)
    from unnest(v_tab) with ordinality as u(t, o) where v_nm[o] > 0);
  raise notice '107 tablas revisadas sin filas de mauro/lucas (sin respaldo, no se tocan): %', (
    select string_agg(t, ', ' order by t) from unnest(v_tab) with ordinality as u(t, o) where v_nm[o] = 0);
  raise notice '107 respaldos viejos omitidos (no se tocan): %', v_omitidas;

  -- ---------------------------------------------------------------
  -- 3. Respaldo (antes de borrar nada; solo tablas con filas)
  -- ---------------------------------------------------------------
  create table public.fin_funciones_bak_baja_107 (
    objeto     text primary key,
    tipo       text not null,        -- 'function' | 'view'
    definicion text not null,        -- create or replace function ... | cuerpo de la vista
    opciones   text                  -- reloptions de la vista, ej. security_invoker=true
  );
  alter table public.fin_funciones_bak_baja_107 enable row level security;
  revoke all on table public.fin_funciones_bak_baja_107 from public, anon, authenticated, service_role;

  for i in 1 .. array_length(v_tab, 1) loop
    if v_nm[i] = 0 then
      v_ok[i] := true;      -- nada que respaldar ni borrar
      continue;
    end if;
    v_bak := v_tab[i] || '_bak_baja_107';
    execute format('create table public.%I as select * from public.%I where %s', v_bak, v_tab[i], v_whe[i]);
    execute format('alter table public.%I enable row level security', v_bak);
    execute format('revoke all on table public.%I from public, anon, authenticated, service_role', v_bak);
    execute format('comment on table public.%I is %L', v_bak,
                   '107: respaldo de ' || v_tab[i] || ' (filas de mauro y lucas) antes de la baja. Solo postgres.');
    execute format('select count(*) from public.%I', v_bak) into n;
    if n <> v_nm[i] then
      raise exception '107 ABORTADA: respaldo % tiene % filas y se esperaban %', v_bak, n, v_nm[i];
    end if;
  end loop;

  insert into public.fin_funciones_bak_baja_107 (objeto, tipo, definicion)
  select p.oid::regprocedure::text, 'function', pg_get_functiondef(p.oid)
  from pg_proc p
  where p.oid = any (array[
    to_regprocedure('public.fin_pagos_resolver()'),
    to_regprocedure('public.fin_clientes_carga()'),
    to_regprocedure('public.fin_data_admite_nuevas(text)')]::oid[]);
  insert into public.fin_funciones_bak_baja_107 (objeto, tipo, definicion, opciones)
  select 'public.' || c.relname, 'view', pg_get_viewdef(c.oid, true),
         array_to_string(c.reloptions, ', ')
  from pg_class c
  where c.oid = any (array[
    to_regclass('public.fin_v_alias_pendientes'),
    to_regclass('public.fin_v_pago_vendedores')]::oid[]);

  -- ---------------------------------------------------------------
  -- 4. Borrado: grupos 1..5, reintentando dentro de cada grupo
  -- ---------------------------------------------------------------
  for g in 1 .. 5 loop
    pasada := 0;
    loop
      pasada := pasada + 1;
      prog := false;
      pend := 0;
      for i in 1 .. array_length(v_tab, 1) loop
        if v_gru[i] <> g or v_ok[i] then continue; end if;
        begin
          execute format('delete from public.%I where %s', v_tab[i], v_whe[i]);
          v_ok[i] := true;
          prog := true;
        exception when foreign_key_violation then
          pend := pend + 1;
          v_err := sqlerrm;
        end;
      end loop;
      exit when pend = 0;
      if not prog or pasada >= 8 then
        raise exception '107 ABORTADA: no se pudo borrar por FK (grupo %): % (ultimo error: %)', g,
          (select string_agg(v_tab[k], ', ') from generate_subscripts(v_tab, 1) k where v_gru[k] = g and not v_ok[k]),
          v_err;
      end if;
    end loop;
  end loop;

  -- ---------------------------------------------------------------
  -- 5. Verificacion
  -- ---------------------------------------------------------------
  for i in 1 .. array_length(v_tab, 1) loop
    execute format('select count(*) from public.%I where %s', v_tab[i], v_whe[i]) into n;
    if n <> 0 then
      raise exception '107 ABORTADA: % todavia tiene % filas de mauro/lucas', v_tab[i], n;
    end if;
    execute format('select count(*) from public.%I', v_tab[i]) into n;
    if n <> v_tot[i] - v_nm[i] then
      raise exception '107 ABORTADA: % quedo con % filas y se esperaban % (antes %, borradas %)',
        v_tab[i], n, v_tot[i] - v_nm[i], v_tot[i], v_nm[i];
    end if;
  end loop;

  -- ---------------------------------------------------------------
  -- 6. B3: funciones y vistas con los nombres escritos a mano
  -- ---------------------------------------------------------------
  -- 6a. fin_pagos_resolver: sacar el return temprano para mauro
  begin
    v_def := pg_get_functiondef('public.fin_pagos_resolver()'::regprocedure);
    v_new := regexp_replace(v_def,
      '\s*if new\.cliente_id = ''mauro'' then\s+return new;\s+end if;', '', 'i');
    if v_new = v_def then
      raise warning '107: fin_pagos_resolver no tiene el texto esperado; no se toca';
    else
      execute v_new;
    end if;
  exception when others then
    raise warning '107: fin_pagos_resolver no se pudo reemplazar (%); queda como estaba', sqlerrm;
  end;

  -- 6b. fin_clientes_carga: sacar el filtro c.id <> 'mauro'
  begin
    v_def := pg_get_functiondef('public.fin_clientes_carga()'::regprocedure);
    v_new := regexp_replace(v_def, 'c\.id <> ''mauro'' and ', '', 'i');
    if v_new = v_def then
      raise warning '107: fin_clientes_carga no tiene el texto esperado; no se toca';
    else
      execute v_new;
    end if;
  exception when others then
    raise warning '107: fin_clientes_carga no se pudo reemplazar (%); queda como estaba', sqlerrm;
  end;

  -- 6c. fin_data_admite_nuevas: ('liam','lucas','teo') -> ('liam','teo')
  begin
    v_def := pg_get_functiondef('public.fin_data_admite_nuevas(text)'::regprocedure);
    v_new := regexp_replace(v_def, '''liam''\s*,\s*''lucas''\s*,\s*''teo''', '''liam'', ''teo''', 'i');
    if v_new = v_def then
      raise warning '107: fin_data_admite_nuevas no tiene el texto esperado; no se toca';
    else
      execute v_new;
    end if;
  exception when others then
    raise warning '107: fin_data_admite_nuevas no se pudo reemplazar (%); queda como estaba', sqlerrm;
  end;

  -- 6d. vistas: sacar "where [<alias>.]cliente_id <> 'mauro'" conservando reloptions.
  --     El alias es opcional: con una sola tabla en el FROM, Postgres guarda la columna sin alias.
  for r in select unnest(array['fin_v_alias_pendientes', 'fin_v_pago_vendedores']) as v loop
    begin
      v_def := pg_get_viewdef(format('public.%I', r.v)::regclass, true);
      v_new := regexp_replace(v_def,
        '\sWHERE\s+\(?(\w+\.)?cliente_id\s*<>\s*''mauro''(::text)?\)?', '', 'i');
      if v_new = v_def or v_new ~* 'mauro' then
        raise warning '107: la vista % no tiene el texto esperado; no se toca', r.v;
      else
        select array_to_string(c.reloptions, ', ') into v_opt
        from pg_class c where c.oid = format('public.%I', r.v)::regclass;
        execute format('create or replace view public.%I %s as %s', r.v,
                       case when v_opt is not null then 'with (' || v_opt || ')' else '' end,
                       regexp_replace(v_new, ';\s*$', ''));
      end if;
    exception when others then
      raise warning '107: la vista % no se pudo reemplazar (%); queda como estaba', r.v, sqlerrm;
    end;
  end loop;

  raise notice '107 OK: baja de mauro y lucas aplicada con respaldo en *_bak_baja_107';
end
$m107$;


-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- Probados en el banco pglite-107 (antes y despues). Solo lectura.
-- =====================================================================

-- ---------------------------------------------------------------------
-- C0  ANTES. cs_maestro_columnas y cs_programas: las filas EXACTAS que va a
--     borrar la 107. Esperado: 2 filas de cs_maestro_columnas (1 mauro, 1 lucas)
--     y 2 de cs_programas (mauro, lucas). Si no son esas, no correr.
-- ---------------------------------------------------------------------
-- select m.id, m.programa_id, m.clave, m.sistema, m.etiqueta, m.orden, m.visible, m.archivada
-- from public.cs_maestro_columnas m
-- where m.programa_id in ('mauro', 'lucas')
-- order by m.programa_id, m.clave;
--
-- select id, nombre, activo from public.cs_programas where id in ('mauro', 'lucas') order by id;

-- ---------------------------------------------------------------------
-- C0b ANTES. Tablas con programa_id que tengan filas de mauro/lucas. Esperado:
--     SOLO cs_maestro_columnas (1 / 1). Cualquier otra fila = la 107 aborta sola.
-- ---------------------------------------------------------------------
-- select t.table_name,
--        (xpath('/row/m/text()', t.x))[1]::text::int as mauro,
--        (xpath('/row/l/text()', t.x))[1]::text::int as lucas
-- from (
--   select c.table_name::text as table_name,
--          query_to_xml(format('select count(*) filter (where programa_id::text = %L) as m, count(*) filter (where programa_id::text = %L) as l from public.%I', 'mauro', 'lucas', c.table_name), false, true, '') as x
--   from information_schema.columns c
--   join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
--   where c.table_schema = 'public' and c.column_name = 'programa_id' and x.table_type = 'BASE TABLE'
--     and c.data_type in ('text', 'character varying')
-- ) t
-- where (xpath('/row/m/text()', t.x))[1]::text::int + (xpath('/row/l/text()', t.x))[1]::text::int > 0
-- order by 1;

-- ---------------------------------------------------------------------
-- C1  ANTES. Conteo por tabla de filas a borrar (todas las tablas de public con
--     cliente_id de texto; "toca" = si la 107 la toca). Esperado, segun el
--     inventario del 13/10 (mauro / lucas): fin_pagos 809/229, fin_llamadas 988/557,
--     fin_pnl 144/82, fin_cuotas 15/0, fin_fuentes 5/4, fin_fuentes_mapa 8/2,
--     fin_personas 5/15, fin_vendedor_asignaciones 5/9, fin_setter_periodo 7/7,
--     fin_pnl_saldos 1/1, fin_catalogos 0/43, fin_catalogo_alias 0/31,
--     fin_formulario_preguntas 0/3, fin_liquidaciones 0/1, fin_alertas_cobros_config 1/0,
--     crm_publicaciones 717/343, crm_historias_hist 31/30, crm_angulos_mapa 26/12,
--     crm_formatos_mapa 44/23, crm_catalogos 0/60, crm_manychat_cuentas 1/1,
--     crm_publicaciones_bak_053 75/114.  (22 tablas con toca = true)
--     Las tablas de respaldos viejos (toca = false) pueden aparecer: no se tocan.
--     Los numeros pueden subir un poco si la sync corrio despues del inventario
--     (fin_pagos, fin_llamadas): lo que importa es que no aparezca una tabla nueva.
-- ---------------------------------------------------------------------
-- select t.table_name,
--        (xpath('/row/m/text()', t.x))[1]::text::int as mauro,
--        (xpath('/row/l/text()', t.x))[1]::text::int as lucas,
--        not (t.table_name ~ '(_bak_|_bak$|_respaldo_|^fin_respaldo|^crm_respaldo|^cs_bak|^fin_import_|^fin_ctl_)'
--             and t.table_name <> 'crm_publicaciones_bak_053') as toca
-- from (
--   select c.table_name::text as table_name,
--          query_to_xml(format('select count(*) filter (where cliente_id::text = %L) as m, count(*) filter (where cliente_id::text = %L) as l from public.%I', 'mauro', 'lucas', c.table_name), false, true, '') as x
--   from information_schema.columns c
--   join information_schema.tables x on x.table_schema = c.table_schema and x.table_name = c.table_name
--   where c.table_schema = 'public' and c.column_name = 'cliente_id' and x.table_type = 'BASE TABLE'
--     and c.data_type not in ('uuid', 'bigint', 'integer', 'smallint', 'numeric')
-- ) t
-- where (xpath('/row/m/text()', t.x))[1]::text::int + (xpath('/row/l/text()', t.x))[1]::text::int > 0
-- order by 1;

-- ---------------------------------------------------------------------
-- C2  ANTES. Hijas sin cliente_id (caen por cascada) y crm_clients.
--     Esperado (mauro / lucas): fin_sync_corridas 8418/6281 (sube con cada sync),
--     fin_alias_columnas 30/31, fin_filas_rechazadas 72/24, fin_alertas_estado 4/3,
--     fin_liquidacion_items 0/62, crm_clients 1/1.
--     fin_filas_rechazadas se cuenta por corrida (la FK que nunca es null).
-- ---------------------------------------------------------------------
-- select 'fin_sync_corridas' as tabla,
--        count(*) filter (where f.cliente_id = 'mauro') as mauro, count(*) filter (where f.cliente_id = 'lucas') as lucas
-- from public.fin_sync_corridas x join public.fin_fuentes f on f.id = x.fuente_id
-- union all select 'fin_alias_columnas', count(*) filter (where f.cliente_id = 'mauro'), count(*) filter (where f.cliente_id = 'lucas')
-- from public.fin_alias_columnas x join public.fin_fuentes f on f.id = x.fuente_id
-- union all select 'fin_filas_rechazadas', count(*) filter (where f.cliente_id = 'mauro'), count(*) filter (where f.cliente_id = 'lucas')
-- from public.fin_filas_rechazadas x join public.fin_sync_corridas s on s.id = x.corrida_id join public.fin_fuentes f on f.id = s.fuente_id
-- union all select 'fin_alertas_estado', count(*) filter (where f.cliente_id = 'mauro'), count(*) filter (where f.cliente_id = 'lucas')
-- from public.fin_alertas_estado x join public.fin_fuentes f on f.id = x.fuente_id
-- union all select 'fin_liquidacion_items', count(*) filter (where l.cliente_id = 'mauro'), count(*) filter (where l.cliente_id = 'lucas')
-- from public.fin_liquidacion_items x join public.fin_liquidaciones l on l.id = x.liquidacion_id
-- union all select 'crm_clients', count(*) filter (where id = 'mauro'), count(*) filter (where id = 'lucas')
-- from public.crm_clients;

-- ---------------------------------------------------------------------
-- C3  ANTES (guardar el resultado para comparar). Conteos de liam, agus y teo.
--     Tiene que dar IGUAL despues (C7).
-- ---------------------------------------------------------------------
-- select 'fin_pagos' as tabla, cliente_id, count(*) from public.fin_pagos where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_llamadas', cliente_id, count(*) from public.fin_llamadas where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_pnl', cliente_id, count(*) from public.fin_pnl where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_cuotas', cliente_id, count(*) from public.fin_cuotas where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_fuentes', cliente_id, count(*) from public.fin_fuentes where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_personas', cliente_id, count(*) from public.fin_personas where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'fin_catalogos', cliente_id, count(*) from public.fin_catalogos where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'crm_publicaciones', cliente_id, count(*) from public.crm_publicaciones where cliente_id in ('liam','agus','teo') group by 2
-- union all select 'cs_maestro_columnas', programa_id, count(*) from public.cs_maestro_columnas where programa_id in ('liam','agus','teo') group by 2
-- union all select 'fin_pagos con catalogo', cliente_id, count(*) from public.fin_pagos where cliente_id in ('liam','agus','teo') and (programa_id is not null or concepto_id is not null or metodo_pago_id is not null or quien_recibe_id is not null) group by 2
-- order by 1, 2;

-- ---------------------------------------------------------------------
-- C4  DESPUES. Repetir la consulta C1. Esperado: solo aparecen las tablas
--     *_bak_baja_107 (con los numeros de C1, toca = false) y los respaldos viejos
--     que ya aparecian (sin cambios). Ninguna fila con toca = true.
--     Repetir C0b: esperado solo cs_maestro_columnas_bak_baja_107 (1 / 1).
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- C5  DESPUES. Respaldos: 31 tablas (30 de datos + fin_funciones_bak_baja_107 con
--     5 filas) si el inventario no cambio; filas = suma mauro + lucas de C1/C2
--     (crm_clients 2, cs_maestro_columnas 2, cs_programas 2).
--     Esperado en todas: rls = true, policies = 0, anon_lee = false, auth_lee = false.
-- ---------------------------------------------------------------------
-- select c.relname as respaldo,
--        (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::int as filas,
--        c.relrowsecurity as rls,
--        (select count(*) from pg_policy p where p.polrelid = c.oid) as policies,
--        has_table_privilege('anon', c.oid, 'select') as anon_lee,
--        has_table_privilege('authenticated', c.oid, 'select') as auth_lee
-- from pg_class c join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
-- where c.relname like '%\_bak\_baja\_107' and c.relkind = 'r'
-- order by 1;

-- ---------------------------------------------------------------------
-- C6  DESPUES. crm_clients devuelve solo liam, agus y teo; cs_programas y
--     cs_maestro_columnas sin mauro/lucas (0 y 0); hijas en 0.
-- ---------------------------------------------------------------------
-- select id, nombre from public.crm_clients order by orden;
--
-- select (select count(*) from public.cs_maestro_columnas where programa_id in ('mauro','lucas')) as cs_maestro_columnas,
--        (select count(*) from public.cs_programas where id in ('mauro','lucas')) as cs_programas,
--        (select count(*) from public.fin_sync_corridas x where not exists (select 1 from public.fin_fuentes f where f.id = x.fuente_id)) as corridas_huerfanas,
--        (select count(*) from public.fin_liquidacion_items x where not exists (select 1 from public.fin_liquidaciones l where l.id = x.liquidacion_id)) as items_huerfanos;

-- ---------------------------------------------------------------------
-- C7  DESPUES. Repetir C3: mismos numeros que antes, fila por fila.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- C8  DESPUES. Funciones y vistas: ya no mencionan 'mauro'/'lucas' a mano.
--     Esperado: menciona = false en fin_pagos_resolver, fin_clientes_carga,
--     fin_data_admite_nuevas, fin_v_alias_pendientes y fin_v_pago_vendedores;
--     menciona = true en fin_data_closers_de ("Lucas Deza", closer de liam: correcto).
--     Si alguna de las 5 da true, la guarda no encontro el texto esperado y la dejo
--     como estaba (no rompe nada: ya no hay filas de mauro/lucas). Avisar al jefe.
-- ---------------------------------------------------------------------
-- select p.proname as objeto, 'function' as tipo, p.prosrc ~* '(mauro|lucas)' as menciona, p.prosecdef as security_definer, p.proconfig as config
-- from pg_proc p join pg_namespace s on s.oid = p.pronamespace and s.nspname = 'public'
-- where p.proname in ('fin_pagos_resolver','fin_clientes_carga','fin_data_admite_nuevas','fin_data_closers_de')
-- union all
-- select c.relname, 'view', pg_get_viewdef(c.oid) ~* '(mauro|lucas)', null, c.reloptions
-- from pg_class c join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
-- where c.relname in ('fin_v_alias_pendientes','fin_v_pago_vendedores')
-- order by 2, 1;
