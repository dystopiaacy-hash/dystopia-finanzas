-- =====================================================================
-- 089_ventas_liam_closer_lectura_canonica.sql  -  VENTAS: leer el closer ya unificado
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), DESPUES
-- de la 087. Es un unico bloque DO: o queda todo o no queda nada.
-- Re-ejecutable. SOLO crea dos funciones de lectura. No reescribe
-- fin_llamadas, ni fin_personas, ni vistas, ni politicas. No toca la sync de
-- Sheets ni otros clientes. Archivo ASCII. Evitar :00, :15, :30 y :45.
--
-- Los controles NO van aca: estan en 089b_ventas_liam_closer_lectura_control.sql,
-- una consulta suelta por vez.
--
-- Para que sirve: las filas viejas de fin_llamadas dicen "LUCAS", "LUCAS DEZA"
-- o "Ivan Binsztein". La app las muestra con el nombre canonico ("Lucas Deza",
-- "Ivan") leyendo este mapa; el texto guardado NO cambia, asi que ninguna
-- vista, conteo ni comision cambia (todas se unen por alias -> vendedor_id).
--
-- Que crea:
--   fin_data_closer_mapa_base(p_cliente text) -> jsonb   (sin permisos de app)
--     { "<alias en minuscula y sin espacios de mas>": "<alias listado>" } para
--     cada alias de closer del cliente que tiene canonico. Usa
--     fin_data_closer_canonico: mismo criterio que al guardar. Un closer
--     historico sin alias listado (Valentin Morello, BPF) NO aparece.
--   fin_data_closer_mapa(p_cliente text) -> jsonb        (authenticated)
--     Lo mismo, pero solo si quien llama puede ver Data de ese cliente
--     (fin_data_puede_ver); si no, '{}'.
-- =====================================================================

do $m089$
declare
  v_n        bigint;
  v_r        record;
  v_foto_a   text;
  v_foto_d   text;
  v_llam_a   bigint;
  v_llam_d   bigint;
  v_mapa     jsonb;
  v_valores  text[];
  v_listados text[];
begin
  perform set_config('lock_timeout', '8s', true);

  -- ===================================================================
  -- 0. DIAGNOSTICO (solo lectura) Y GUARDAS
  -- ===================================================================
  if to_regclass('public.fin_personas') is null
     or to_regclass('public.fin_llamadas') is null
     or to_regprocedure('public.fin_data_closer_canonico(text, text)') is null
     or to_regprocedure('public.fin_data_puede_ver(text)') is null then
    raise exception '089 ABORTADA: faltan fin_personas, fin_llamadas o funciones de la 077/084. Correr primero la 087.';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception '089 ABORTADA: el cliente liam no existe en crm_clients.';
  end if;
  if public.fin_data_closer_canonico('liam', 'LUCAS') is distinct from 'Lucas Deza'
     or public.fin_data_closer_canonico('liam', 'LUCAS DEZA') is distinct from 'Lucas Deza'
     or public.fin_data_closer_canonico('liam', 'Ivan Binsztein') is distinct from 'Ivan' then
    raise exception '089 ABORTADA: LUCAS / LUCAS DEZA / Ivan Binsztein no se leen como Lucas Deza / Ivan: falta la 087.';
  end if;

  -- No puede haber otra funcion con esos nombres y otra firma (seria una sobrecarga).
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('fin_data_closer_mapa', 'fin_data_closer_mapa_base')
     and pg_get_function_identity_arguments(p.oid) <> 'p_cliente text';
  if v_n > 0 then
    raise exception '089 ABORTADA: ya hay % funcion(es) fin_data_closer_mapa* con otra firma (ver pg_proc).', v_n;
  end if;

  select count(*) into v_llam_a from public.fin_llamadas;
  select coalesce(md5(string_agg(p.id::text || '|' || coalesce(p.cliente_id, '') || '|' || coalesce(p.alias, '')
                                 || '|' || coalesce(p.vendedor_id::text, '') || '|' || p.lista_closers::text
                                 || '|' || coalesce(p.campo, ''), ',' order by p.id)), '')
    into v_foto_a
    from public.fin_personas p;
  raise notice '089 diag: fin_llamadas % filas', v_llam_a;

  for v_r in
    select l.closer, count(*) as n,
           coalesce(public.fin_data_closer_canonico('liam', l.closer), '(sin canonico: se muestra tal cual)') as se_lee_como
      from public.fin_llamadas l
     where l.cliente_id = 'liam' and btrim(coalesce(l.closer, '')) <> ''
     group by l.closer order by l.closer
  loop
    raise notice '089 diag: liam closer=[%] filas=% -> %', v_r.closer, v_r.n, v_r.se_lee_como;
  end loop;

  -- ===================================================================
  -- 1. FUNCIONES DE LECTURA
  -- ===================================================================
  -- Una entrada por alias de closer del cliente con canonico. Si dos filas de
  -- fin_personas tienen el mismo alias (sin mayusculas ni espacios), el
  -- canonico es el mismo (la funcion compara lower(btrim(alias))).
  execute $q$
    create or replace function public.fin_data_closer_mapa_base(p_cliente text)
    returns jsonb
    language sql stable security definer set search_path = public
    as $fn$
      select coalesce(jsonb_object_agg(x.k, x.c), '{}'::jsonb)
        from (
          select distinct lower(btrim(p.alias)) as k,
                 public.fin_data_closer_canonico(p_cliente, p.alias) as c
            from public.fin_personas p
           where p.cliente_id = p_cliente
             and (p.campo is null or p.campo in ('closer', 'ambos'))
             and btrim(coalesce(p.alias, '')) <> ''
        ) x
       where x.c is not null
    $fn$
  $q$;

  execute $q$
    create or replace function public.fin_data_closer_mapa(p_cliente text)
    returns jsonb
    language sql stable security definer set search_path = public
    as $fn$
      select case when coalesce(public.fin_data_puede_ver(p_cliente), false)
                  then public.fin_data_closer_mapa_base(p_cliente)
                  else '{}'::jsonb end
    $fn$
  $q$;

  execute 'revoke all on function public.fin_data_closer_mapa_base(text) from public, anon, authenticated';
  execute 'revoke all on function public.fin_data_closer_mapa(text) from public, anon';
  execute 'grant execute on function public.fin_data_closer_mapa(text) to authenticated';

  -- ===================================================================
  -- 2. AUTOVERIFICACION (si algo no cierra, aborta y no queda nada)
  -- ===================================================================
  -- 2a. Nada de datos cambio.
  select count(*) into v_llam_d from public.fin_llamadas;
  select coalesce(md5(string_agg(p.id::text || '|' || coalesce(p.cliente_id, '') || '|' || coalesce(p.alias, '')
                                 || '|' || coalesce(p.vendedor_id::text, '') || '|' || p.lista_closers::text
                                 || '|' || coalesce(p.campo, ''), ',' order by p.id)), '')
    into v_foto_d
    from public.fin_personas p;
  if v_llam_a <> v_llam_d or v_foto_a is distinct from v_foto_d then
    raise exception '089 ABORTADA: cambiaron fin_llamadas o fin_personas (no deberia pasar).';
  end if;

  -- 2b. El mapa de liam.
  v_mapa := public.fin_data_closer_mapa_base('liam');
  if v_mapa ->> 'lucas' is distinct from 'Lucas Deza'
     or v_mapa ->> 'lucas deza' is distinct from 'Lucas Deza'
     or v_mapa ->> 'ivan binsztein' is distinct from 'Ivan'
     or v_mapa ->> 'ivan' is distinct from 'Ivan' then
    raise exception '089 ABORTADA: el mapa de liam no lee LUCAS/LUCAS DEZA como Lucas Deza e Ivan Binsztein/Ivan como Ivan (mapa: %)', v_mapa;
  end if;

  -- 2c. Los valores del mapa son alias LISTADOS del cliente (conjuntos).
  select coalesce(array_agg(distinct j.value), '{}'::text[]) into v_valores
    from jsonb_each_text(v_mapa) j;
  select coalesce(array_agg(distinct btrim(p.alias)), '{}'::text[]) into v_listados
    from public.fin_personas p
   where p.cliente_id = 'liam' and p.lista_closers and (p.campo is null or p.campo in ('closer', 'ambos'));
  if not (v_valores <@ v_listados) then
    raise exception '089 ABORTADA: el mapa devuelve nombres que no estan en la lista de closers (mapa: %, lista: %)',
      v_valores, v_listados;
  end if;

  -- 2d. Cada entrada coincide con fin_data_closer_canonico (mismo criterio).
  select count(*) into v_n
    from jsonb_each_text(v_mapa) j
   where public.fin_data_closer_canonico('liam', j.key) is distinct from j.value;
  if v_n > 0 then
    raise exception '089 ABORTADA: % entradas del mapa difieren de fin_data_closer_canonico', v_n;
  end if;

  -- 2e. Permisos: el mapa lo ve authenticated; la base no.
  if not has_function_privilege('authenticated', 'public.fin_data_closer_mapa(text)', 'execute')
     or has_function_privilege('authenticated', 'public.fin_data_closer_mapa_base(text)', 'execute')
     or has_function_privilege('anon', 'public.fin_data_closer_mapa(text)', 'execute') then
    raise exception '089 ABORTADA: permisos de las funciones incorrectos';
  end if;

  raise notice '089 OK: mapa de liam = %', v_mapa;
end
$m089$;
