-- =====================================================================
-- 084_ventas_liam_ajustes_equipo.sql  -  VENTAS: tres ajustes para el equipo de Liam
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), DESPUES
-- de la 075 y la 077. Es un unico bloque DO: o queda todo o no queda nada.
-- Re-ejecutable (no pisa los closers que se agreguen desde la app).
-- No toca la sync de Sheets, ni otros clientes, ni crm_members/crm_asignaciones.
-- Archivo ASCII. Evitar :00, :15, :30 y :45.
--
-- Los controles NO van aca: estan en 084b_ventas_liam_ajustes_control.sql,
-- una consulta suelta por vez.
--
-- Que hace:
--   0. Diagnostico de solo lectura (RAISE NOTICE) y guardas por CONJUNTOS.
--   1. "SEGUIMIENTO CUOTAS" cuenta como seguimiento (EN SEGUIMIENTO, abierto),
--      NO como cerrada. La 077 lo habia llevado a ADENTRO EN SEGUIMIENTO, que
--      la vista fin_v_llamadas_clasificadas cuenta como cerrada. La
--      clasificacion vive SOLO en esa vista (todos los conteos, la tasa de
--      cierre, el Dashboard y las Comisiones salen de ella): no hace falta
--      tocarla, solo corregir el dato. Las filas de liam que hoy dicen
--      SEGUIMIENTO CUOTAS pasan a EN SEGUIMIENTO.
--      OJO: las filas que la 077/078 ya convirtieron a ADENTRO EN SEGUIMIENTO
--      no se pueden distinguir de las que eran ADENTRO EN CHAT. Se recuperan
--      regenerando y corriendo la 078 con el script corregido
--      (npm run liam:ventas).
--   2. Closers de liam: la lista ofrece "Ivan" y "Lucas Deza". Un closer
--      nuevo se agrega desde la app con fin_data_closer_agregar (solo
--      fundador y ventas). Es por cliente. Las filas con otro nombre
--      (p. ej. "Ivan Binsztein") siguen validas y se leen como "Ivan".
--   3. El rol ventas LEE lo que necesitan Dashboard y Comisiones (pagos,
--      vendedores, liquidaciones, etc., solo de sus clientes asignados).
--      Solo lectura: no se da ninguna politica de escritura.
-- =====================================================================

do $m084$
declare
  c_roles    constant text[] := array['fundador', 'cliente', 'finanzas', 'ventas', 'producto', 'contenido'];
  c_vistas   constant text[] := array['fin_v_metricas_ventas', 'fin_v_metricas_booking', 'fin_v_metricas_closer',
                                      'fin_v_metricas_setter', 'fin_v_llamadas_clasificadas', 'fin_v_llamadas_setter',
                                      'fin_v_comisiones_mensual', 'fin_v_comisiones_bloqueos', 'fin_v_periodos',
                                      'fin_v_liquidacion_vendedor'];
  c_ya_cubiertas constant text[] := array['fin_llamadas', 'fin_catalogos', 'fin_formulario_preguntas'];
  v_def      text;
  v_roles    text[];
  v_n        bigint;
  v_n2       bigint;
  v_ivan     bigint;
  v_ivan_nom text;
  v_base     text[];
  v_t        text;
  v_cond     text;
  v_nulable  boolean;
  v_creadas  text[] := '{}';
  v_sin_cond text[] := '{}';
  v_listados text[];
begin
  perform set_config('lock_timeout', '8s', true);

  -- ===================================================================
  -- 0. DIAGNOSTICO (solo lectura) Y GUARDAS (por conjuntos)
  -- ===================================================================
  if to_regclass('public.fin_personas') is null
     or to_regclass('public.fin_catalogos') is null
     or to_regclass('public.fin_llamadas') is null
     or to_regprocedure('public.fin_asignado(text)') is null
     or to_regprocedure('public.rol_actual()') is null
     or to_regprocedure('public.fin_data_es_ventas(text)') is null
     or to_regprocedure('public.fin_data_closers_de(text)') is null
     or to_regprocedure('public.fin_data_cliente_ok(text)') is null
     or to_regprocedure('public.fin_normalizar_nombre(text)') is null then
    raise exception '084 ABORTADA: faltan funciones de la 075/077. Correr primero la 075 y la 077.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_personas' and column_name = 'lista_closers') then
    raise exception '084 ABORTADA: fin_personas.lista_closers no existe (falta la 077).';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception '084 ABORTADA: el cliente liam no existe en crm_clients.';
  end if;

  -- Roles admitidos por crm_members.rol: se comparan CONJUNTOS (los literales
  -- del CHECK contra los 6 roles requeridos), no el texto de la definicion.
  select string_agg(pg_get_constraintdef(oid), ' ') into v_def
    from pg_constraint
   where conrelid = 'public.crm_members'::regclass and contype = 'c'
     and pg_get_constraintdef(oid) ~* '\mrol\M';
  select coalesce(array_agg(distinct m[1]), '{}') into v_roles
    from regexp_matches(coalesce(v_def, ''), '''([a-z_]+)''', 'g') as m;
  if not (c_roles <@ v_roles) then
    raise exception '084 ABORTADA: crm_members.rol no admite todos los roles de area. Faltan: %',
      (select array_agg(r order by r) from unnest(c_roles) r where r <> all (v_roles));
  end if;

  select count(*) into v_n from public.fin_llamadas where cliente_id = 'liam';
  raise notice '084 diag: liam tiene % llamadas', v_n;
  for v_t, v_n in
    select coalesce(upper(btrim(estado_llamada)), '(vacio)'), count(*)
      from public.fin_llamadas
     where cliente_id = 'liam'
       and upper(btrim(coalesce(estado_llamada, ''))) in
           ('SEGUIMIENTO CUOTAS', 'EN SEGUIMIENTO', 'ADENTRO EN SEGUIMIENTO', 'ADENTRO EN CHAT')
     group by 1 order by 1
  loop
    raise notice '084 diag: estado % = % filas', v_t, v_n;
  end loop;
  select array_agg(btrim(alias) order by alias) into v_listados
    from public.fin_personas
   where cliente_id = 'liam' and lista_closers and (campo is null or campo in ('closer', 'ambos'));
  raise notice '084 diag: closers listados hoy en liam: %', coalesce(v_listados::text, '{}');

  -- ===================================================================
  -- 1. "SEGUIMIENTO CUOTAS" = seguimiento, no cerrada
  -- ===================================================================
  -- "EN SEGUIMIENTO" tiene que ser opcion activa de liam.
  insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
  select 'liam', 'estado', 'EN SEGUIMIENTO',
         coalesce((select max(orden) from public.fin_catalogos
                    where cliente_id = 'liam' and dimension = 'estado'), 0) + 1
  on conflict (cliente_id, dimension, valor) do update set activo = true, updated_at = now();

  update public.fin_llamadas set estado_llamada = 'EN SEGUIMIENTO'
   where cliente_id = 'liam' and upper(btrim(estado_llamada)) = 'SEGUIMIENTO CUOTAS';
  get diagnostics v_n = row_count;
  raise notice '084: % filas de liam pasaron de SEGUIMIENTO CUOTAS a EN SEGUIMIENTO', v_n;

  -- ===================================================================
  -- 2. CLOSERS DE LIAM
  -- ===================================================================
  -- Alias "Ivan" (display) para el vendedor Ivan Binsztein.
  select v.id, v.nombre into v_ivan, v_ivan_nom
    from public.fin_vendedores v
   where v.nombre_norm = public.fin_normalizar_nombre('Ivan Binsztein')
   limit 1;
  if v_ivan is null then
    raise exception '084 ABORTADA: no existe el vendedor Ivan Binsztein (lo crea la 077).';
  end if;

  insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo, lista_closers)
  values (null, 'liam', 'Ivan', v_ivan, 'closer', true)
  on conflict do nothing;

  -- Una sola entrada por persona en el desplegable: "Ivan". Los demas alias
  -- de Ivan siguen existiendo (atribuyen cierres y comisiones) pero no salen.
  update public.fin_personas
     set lista_closers = (lower(btrim(alias)) = 'ivan')
   where cliente_id = 'liam' and vendedor_id = v_ivan
     and lista_closers is distinct from (lower(btrim(alias)) = 'ivan');

  -- Lucas Deza: tiene que haber un alias listado.
  update public.fin_personas p set lista_closers = true
   where p.cliente_id = 'liam'
     and lower(btrim(p.alias)) = 'lucas deza'
     and not p.lista_closers;

  -- Alias canonico de un closer de la lista. Cambio frente a la 077: el texto
  -- que llega puede ser CUALQUIER alias de una persona de la lista (una fila
  -- vieja dice "Ivan Binsztein"); devuelve el alias listado de esa persona
  -- ("Ivan"). null = no es un closer de la lista de ese cliente.
  execute $q$
    create or replace function public.fin_data_closer_canonico(p_cliente text, p_texto text)
    returns text
    language sql stable security definer set search_path = public
    as $fn$
      select (
        select btrim(c.alias)
          from public.fin_personas c
          left join public.fin_vendedores cv on cv.id = c.vendedor_id
         where c.cliente_id = p_cliente
           and (c.campo is null or c.campo in ('closer', 'ambos'))
           and c.lista_closers
           and (c.id = p.id or (p.vendedor_id is not null and c.vendedor_id = p.vendedor_id))
         order by (public.fin_normalizar_nombre(c.alias) = cv.nombre_norm) desc,
                  char_length(btrim(c.alias)) desc, c.id
         limit 1)
        from public.fin_personas p
       where p.cliente_id = p_cliente
         and (p.campo is null or p.campo in ('closer', 'ambos'))
         and lower(btrim(p.alias)) = lower(btrim(coalesce(p_texto, '')))
       order by p.id
       limit 1
    $fn$
  $q$;

  -- Agregar un closer a la lista de UN cliente. Solo fundador y ventas
  -- (del cliente). Si el nombre ya existe en ese cliente, lo reutiliza.
  execute $q$
    create or replace function public.fin_data_closer_agregar(p_cliente text, p_nombre text)
    returns text
    language plpgsql security definer set search_path = public
    as $fn$
    declare
      v_nombre text := regexp_replace(btrim(coalesce(p_nombre, '')), '\s+', ' ', 'g');
      v_p      public.fin_personas%rowtype;
      v_vend   bigint;
      v_res    text;
    begin
      if not (coalesce(public.es_fundador(), false) or public.fin_data_es_ventas(p_cliente)) then
        raise exception 'ventas: solo el fundador y el equipo de ventas agregan closers' using errcode = '42501';
      end if;
      perform public.fin_data_cliente_ok(p_cliente);

      if char_length(v_nombre) < 2 or char_length(v_nombre) > 60 or v_nombre ~ '[<>"/\\;@0-9]' then
        raise exception 'ventas: el nombre del closer va entre 2 y 60 letras' using errcode = '22023';
      end if;

      -- ya existe (mismo nombre sin tildes ni mayusculas) en este cliente
      select * into v_p from public.fin_personas
       where cliente_id = p_cliente
         and public.fin_normalizar_nombre(alias) = public.fin_normalizar_nombre(v_nombre)
       order by id limit 1;
      if v_p.id is not null then
        if v_p.campo = 'setter' then
          raise exception 'ventas: "%" ya existe como setter en %; avisale al fundador', v_nombre, p_cliente
            using errcode = '22023';
        end if;
        if not v_p.lista_closers then
          update public.fin_personas set lista_closers = true where id = v_p.id;
        end if;
        v_res := public.fin_data_closer_canonico(p_cliente, v_p.alias);
        return coalesce(v_res, btrim(v_p.alias));
      end if;

      -- si el nombre coincide con un vendedor del cliente, se enlaza (comisiones)
      select v.id into v_vend
        from public.fin_vendedores v
        join public.fin_vendedor_asignaciones a on a.vendedor_id = v.id and a.cliente_id = p_cliente
       where v.nombre_norm = public.fin_normalizar_nombre(v_nombre)
       limit 1;

      insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo, lista_closers)
      values (null, p_cliente, v_nombre, v_vend, 'closer', true);
      return v_nombre;
    end;
    $fn$
  $q$;

  execute 'revoke all on function public.fin_data_closer_canonico(text, text) from public, anon, authenticated';
  execute 'revoke all on function public.fin_data_closer_agregar(text, text) from public, anon';
  execute 'grant execute on function public.fin_data_closer_agregar(text, text) to authenticated';

  -- ===================================================================
  -- 3. ROL ventas: LECTURA PARA DASHBOARD Y COMISIONES (aditiva, solo select)
  -- ===================================================================
  -- Tablas base de las vistas que leen Dashboard y Comisiones (se calcula
  -- desde pg_depend: no se adivina).
  with recursive dep(oid) as (
    select c.oid
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = any (c_vistas)
    union
    select d.refobjid
      from dep
      join pg_rewrite r on r.ev_class = dep.oid
      join pg_depend d on d.objid = r.oid and d.classid = 'pg_rewrite'::regclass
                      and d.refclassid = 'pg_class'::regclass and d.refobjid <> dep.oid
  )
  select coalesce(array_agg(distinct c.relname::text order by c.relname::text), '{}') into v_base
    from dep
    join pg_class c on c.oid = dep.oid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p');

  -- Los padres de las tablas que se filtran por relacion tienen que estar.
  if 'fin_liquidacion_items' = any (v_base) and to_regclass('public.fin_liquidaciones') is not null then
    v_base := v_base || 'fin_liquidaciones';
  end if;
  if 'fin_vendedores' = any (v_base) and to_regclass('public.fin_vendedor_asignaciones') is not null then
    v_base := v_base || 'fin_vendedor_asignaciones';
  end if;
  raise notice '084 diag: tablas base de Dashboard/Comisiones: %', v_base;

  for v_t in select distinct x from unnest(v_base) x order by x loop
    continue when v_t = any (c_ya_cubiertas);
    continue when not (select c.relrowsecurity from pg_class c
                        where c.oid = ('public.' || quote_ident(v_t))::regclass);

    if v_t = 'fin_liquidacion_items' then
      v_cond := 'public.rol_actual() = ''ventas'' and exists (select 1 from public.fin_liquidaciones l '
             || 'where l.id = fin_liquidacion_items.liquidacion_id and public.fin_asignado(l.cliente_id))';
    elsif v_t = 'fin_vendedores' then
      v_cond := 'public.rol_actual() = ''ventas'' and exists (select 1 from public.fin_vendedor_asignaciones a '
             || 'where a.vendedor_id = fin_vendedores.id and public.fin_asignado(a.cliente_id))';
    elsif exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = v_t and column_name = 'cliente_id') then
      select (is_nullable = 'YES') into v_nulable from information_schema.columns
       where table_schema = 'public' and table_name = v_t and column_name = 'cliente_id';
      v_cond := 'public.rol_actual() = ''ventas'' and ('
             || case when v_nulable then 'cliente_id is null or ' else '' end
             || 'public.fin_asignado(cliente_id))';
    else
      v_sin_cond := v_sin_cond || v_t;
      continue;
    end if;

    execute format('drop policy if exists %I on public.%I', v_t || '_lectura_ventas_dash', v_t);
    execute format('create policy %I on public.%I for select to authenticated using (%s)',
                   v_t || '_lectura_ventas_dash', v_t, v_cond);
    v_creadas := v_creadas || v_t;
  end loop;
  raise notice '084: politicas de lectura para ventas en: %', v_creadas;
  if array_length(v_sin_cond, 1) is not null then
    raise notice '084 ATENCION: sin cliente_id (no se abrio a ventas, revisar): %', v_sin_cond;
  end if;

  -- ===================================================================
  -- 4. AUTOVERIFICACION (si algo no cierra, aborta y no queda nada)
  -- ===================================================================
  if exists (select 1 from public.fin_llamadas
              where cliente_id = 'liam' and upper(btrim(estado_llamada)) = 'SEGUIMIENTO CUOTAS') then
    raise exception '084 ABORTADA: quedaron filas de liam en SEGUIMIENTO CUOTAS';
  end if;

  select array_agg(public.fin_normalizar_nombre(alias)) into v_listados
    from public.fin_personas
   where cliente_id = 'liam' and lista_closers and (campo is null or campo in ('closer', 'ambos'));
  if not (array['ivan', 'lucas deza'] <@ coalesce(v_listados, '{}')) then
    raise exception '084 ABORTADA: la lista de closers de liam no tiene a Ivan y Lucas Deza (tiene: %)', v_listados;
  end if;
  if 'ivan binsztein' = any (v_listados) then
    raise exception '084 ABORTADA: Ivan sale dos veces en la lista de closers de liam';
  end if;
  if public.fin_data_closer_canonico('liam', 'Ivan Binsztein') is distinct from 'Ivan' then
    raise exception '084 ABORTADA: "Ivan Binsztein" no se lee como "Ivan" (da %)',
      public.fin_data_closer_canonico('liam', 'Ivan Binsztein');
  end if;

  raise notice '084 OK';
end
$m084$;
