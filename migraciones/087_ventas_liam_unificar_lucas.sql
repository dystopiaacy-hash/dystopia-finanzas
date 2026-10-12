-- =====================================================================
-- 087_ventas_liam_unificar_lucas.sql  -  VENTAS: "LUCAS" = "Lucas Deza" en liam
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), DESPUES
-- de la 084 y la 085. Es un unico bloque DO: o queda todo o no queda nada.
-- Re-ejecutable. No toca la sync de Sheets, ni otros clientes, ni filas de
-- fin_llamadas, ni fin_vendedores. Archivo ASCII. Evitar :00, :15, :30, :45.
--
-- Los controles NO van aca: estan en 087b_ventas_liam_unificar_lucas_control.sql,
-- una consulta suelta por vez.
--
-- Que hace (mismo mecanismo que Ivan en la 084: alias de una misma persona =
-- mismo vendedor_id, y fin_data_closer_canonico devuelve el alias listado):
--   0. Diagnostico de solo lectura (RAISE NOTICE) y guardas por conjuntos.
--   1. "LUCAS" y "LUCAS DEZA" quedan como alias del MISMO vendedor
--      (Lucas Deza). Si "LUCAS" no tenia vendedor, se lo enlaza.
--   2. Un solo alias listado para esa persona: "Lucas Deza" (se le cambia
--      solo el texto de mayusculas; todas las comparaciones del sistema son
--      lower(btrim(alias)), asi que no cambia ninguna atribucion).
--      "LUCAS" sigue existiendo (atribuye cierres y comisiones) pero no se
--      ofrece (lista_closers = false).
--   3. Autoverificacion: los demas alias de liam conservan su vendedor.
-- Las filas de fin_llamadas con closer "LUCAS" NO se reescriben: igual que
-- "Ivan Binsztein", al guardarlas desde la app pasan a "Lucas Deza".
-- =====================================================================

do $m087$
declare
  v_lucas   bigint;
  v_nom     text;
  v_pid     bigint;
  v_r       record;
  v_n       bigint;
  v_antes   jsonb;
  v_despues jsonb;
  v_lista   text[];
begin
  perform set_config('lock_timeout', '8s', true);

  -- ===================================================================
  -- 0. DIAGNOSTICO (solo lectura) Y GUARDAS
  -- ===================================================================
  if to_regclass('public.fin_personas') is null
     or to_regclass('public.fin_vendedores') is null
     or to_regclass('public.fin_vendedor_asignaciones') is null
     or to_regclass('public.fin_llamadas') is null
     or to_regprocedure('public.fin_data_closer_canonico(text, text)') is null
     or to_regprocedure('public.fin_data_closers_de(text)') is null
     or to_regprocedure('public.fin_normalizar_nombre(text)') is null then
    raise exception '087 ABORTADA: faltan tablas o funciones de la 077/084/085. Correr primero la 084 y la 085.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_personas' and column_name = 'lista_closers') then
    raise exception '087 ABORTADA: fin_personas.lista_closers no existe (falta la 077).';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception '087 ABORTADA: el cliente liam no existe en crm_clients.';
  end if;
  if public.fin_data_closer_canonico('liam', 'Ivan Binsztein') is distinct from 'Ivan' then
    raise exception '087 ABORTADA: "Ivan Binsztein" no se lee como "Ivan": falta correr la 084/085.';
  end if;

  select v.id, v.nombre into v_lucas, v_nom
    from public.fin_vendedores v
   where v.nombre_norm = public.fin_normalizar_nombre('Lucas Deza')
   limit 1;
  if v_lucas is null then
    raise exception '087 ABORTADA: no existe el vendedor Lucas Deza en fin_vendedores.';
  end if;
  if not exists (select 1 from public.fin_vendedor_asignaciones a
                  where a.vendedor_id = v_lucas and a.cliente_id = 'liam') then
    raise exception '087 ABORTADA: el vendedor Lucas Deza (id %) no esta asignado a liam.', v_lucas;
  end if;
  raise notice '087 diag: vendedor Lucas Deza = id % (%)', v_lucas, v_nom;

  for v_r in
    select p.id, p.cliente_id, p.alias, p.campo, p.lista_closers, p.vendedor_id, p.user_id
      from public.fin_personas p
     where lower(btrim(p.alias)) in ('lucas', 'lucas deza') or p.vendedor_id = v_lucas
     order by p.cliente_id nulls first, p.id
  loop
    raise notice '087 diag: persona id=% cliente=% alias=[%] campo=% listado=% vendedor=% login=%',
      v_r.id, coalesce(v_r.cliente_id, '(todos)'), v_r.alias, coalesce(v_r.campo, '(null)'),
      v_r.lista_closers, coalesce(v_r.vendedor_id::text, '(null)'), (v_r.user_id is not null);
  end loop;

  for v_r in
    select l.closer, count(*) as n
      from public.fin_llamadas l
     where l.cliente_id = 'liam' and lower(btrim(l.closer)) in ('lucas', 'lucas deza')
     group by l.closer order by l.closer
  loop
    raise notice '087 diag: fin_llamadas liam closer=[%] filas=%', v_r.closer, v_r.n;
  end loop;

  -- Guardas por conjuntos: ningun alias de Lucas en liam apunta a otra persona
  -- ni es solo setter.
  select count(*) into v_n
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) in ('lucas', 'lucas deza')
     and p.vendedor_id is not null and p.vendedor_id <> v_lucas;
  if v_n > 0 then
    raise exception '087 ABORTADA: % alias de Lucas en liam apuntan a OTRO vendedor (ver diag). Decidir a mano.', v_n;
  end if;
  select count(*) into v_n
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) in ('lucas', 'lucas deza') and p.campo = 'setter';
  if v_n > 0 then
    raise exception '087 ABORTADA: % alias de Lucas en liam estan como setter (ver diag).', v_n;
  end if;

  -- Foto de la atribucion de TODOS los demas alias de liam (alias -> vendedor).
  select coalesce(jsonb_object_agg(lower(btrim(p.alias)), p.vendedor_id), '{}'::jsonb) into v_antes
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) not in ('lucas', 'lucas deza');

  -- ===================================================================
  -- 1. MISMO VENDEDOR PARA "LUCAS" Y "LUCAS DEZA"
  -- ===================================================================
  update public.fin_personas
     set vendedor_id = v_lucas
   where cliente_id = 'liam' and lower(btrim(alias)) in ('lucas', 'lucas deza') and vendedor_id is null;
  get diagnostics v_n = row_count;
  raise notice '087: % alias de Lucas sin vendedor quedaron enlazados a Lucas Deza', v_n;

  -- Tiene que haber un alias "Lucas Deza" de closer (lo crea la 077/010; por
  -- si falta, se agrega).
  insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo, lista_closers)
  values (null, 'liam', 'Lucas Deza', v_lucas, 'closer', true)
  on conflict do nothing;

  select p.id into v_pid
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) = 'lucas deza'
   order by p.id limit 1;
  if v_pid is null then
    raise exception '087 ABORTADA: no se pudo obtener el alias "Lucas Deza" de liam.';
  end if;

  -- ===================================================================
  -- 2. UN SOLO ALIAS LISTADO: "Lucas Deza"
  -- ===================================================================
  update public.fin_personas
     set alias = 'Lucas Deza'
   where id = v_pid and alias is distinct from 'Lucas Deza';

  update public.fin_personas
     set lista_closers = (id = v_pid)
   where cliente_id = 'liam' and vendedor_id = v_lucas
     and lista_closers is distinct from (id = v_pid);
  get diagnostics v_n = row_count;
  raise notice '087: % alias de Lucas Deza cambiaron su estado en la lista de closers', v_n;

  -- ===================================================================
  -- 3. AUTOVERIFICACION (si algo no cierra, aborta y no queda nada)
  -- ===================================================================
  select coalesce(jsonb_object_agg(lower(btrim(p.alias)), p.vendedor_id), '{}'::jsonb) into v_despues
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) not in ('lucas', 'lucas deza');
  if v_antes is distinct from v_despues then
    raise exception '087 ABORTADA: cambio la atribucion de otros alias de liam (antes %, despues %)', v_antes, v_despues;
  end if;

  select count(*) into v_n
    from public.fin_personas p
   where p.cliente_id = 'liam' and lower(btrim(p.alias)) in ('lucas', 'lucas deza')
     and p.vendedor_id is distinct from v_lucas;
  if v_n > 0 then
    raise exception '087 ABORTADA: % alias de Lucas no quedaron con el vendedor Lucas Deza', v_n;
  end if;

  select count(*) into v_n
    from public.fin_personas p
   where p.cliente_id = 'liam' and p.vendedor_id = v_lucas
     and p.lista_closers and (p.campo is null or p.campo in ('closer', 'ambos'));
  if v_n <> 1 then
    raise exception '087 ABORTADA: Lucas Deza tiene % alias listados en liam (tiene que ser 1)', v_n;
  end if;

  select array_agg(public.fin_normalizar_nombre(p.alias)) into v_lista
    from public.fin_personas p
   where p.cliente_id = 'liam' and p.lista_closers and (p.campo is null or p.campo in ('closer', 'ambos'));
  if not (array['ivan', 'lucas deza']::text[] <@ coalesce(v_lista, '{}'::text[])) then
    raise exception '087 ABORTADA: la lista de closers de liam no tiene a Ivan y Lucas Deza (tiene: %)', v_lista;
  end if;
  if 'lucas' = any (coalesce(v_lista, '{}'::text[])) then
    raise exception '087 ABORTADA: "LUCAS" sigue en la lista de closers de liam';
  end if;

  if public.fin_data_closer_canonico('liam', 'LUCAS') is distinct from 'Lucas Deza'
     or public.fin_data_closer_canonico('liam', 'LUCAS DEZA') is distinct from 'Lucas Deza'
     or public.fin_data_closer_canonico('liam', 'Ivan Binsztein') is distinct from 'Ivan' then
    raise exception '087 ABORTADA: lectura de closers incorrecta (LUCAS=%, LUCAS DEZA=%, Ivan Binsztein=%)',
      public.fin_data_closer_canonico('liam', 'LUCAS'),
      public.fin_data_closer_canonico('liam', 'LUCAS DEZA'),
      public.fin_data_closer_canonico('liam', 'Ivan Binsztein');
  end if;

  raise notice '087 OK';
end
$m087$;
