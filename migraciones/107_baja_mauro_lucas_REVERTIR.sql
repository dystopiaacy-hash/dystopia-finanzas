-- =====================================================================
-- 107_baja_mauro_lucas_REVERTIR.sql   (COPIA CORREGIDA por la revision del 13/10/2026)
-- Vuelta atras de la 107: restaura filas y definiciones desde los respaldos
-- *_bak_baja_107. NO SE CORRE salvo pedido expreso del jefe. Sin correr.
--
-- Cambios respecto del original (detalle en jefe\insumos\107\informe-107.md):
--   V1. Apaga los triggers de usuario de las tablas que restaura mientras
--       inserta y los vuelve a prender (solo los que estaban prendidos). El
--       original los dejaba correr: fin_pagos_clave_trg recalculaba huella/clave
--       (cambia las claves historicas y rompe fin_liquidacion_items.pago_clave) y
--       fin_pagos_resolver_trg, ya sin la excepcion de mauro, le completaba
--       catalogos a los pagos de mauro. Las FK se siguen controlando.
--   V2. Aborta con mensaje claro si ya se revirtio (crm_clients ya tiene esos
--       ids), antes de tocar nada. El original abortaba igual, pero recien por
--       la clave repetida de crm_clients y con un error crudo.
--   V3. Verifica tabla por tabla que se insertaron tantas filas como tiene el respaldo.
--   V4. Restaura tambien cs_programas (sale solo: tiene su *_bak_baja_107).
--
-- Que hace (un solo bloque `do`, atomico):
--   1. Verifica que existan fin_funciones_bak_baja_107 y los respaldos, y que
--      no se haya revertido ya.
--   2. Restaura las filas: crm_clients primero, despues el resto reintentando
--      por pasadas si una FK todavia no tiene a su padre (cs_programas antes que
--      cs_maestro_columnas, fin_fuentes antes que fin_pagos, etc.). Inserta solo
--      las columnas no generadas; usa OVERRIDING SYSTEM VALUE si la tabla tiene
--      identidad GENERATED ALWAYS (los ids vuelven a ser los mismos). Si una fila
--      ya existe (PK repetida) aborta y no queda nada.
--   3. Restaura las definiciones de funciones y vistas guardadas por la 107.
--
-- NO borra los respaldos (se borran a mano cuando ya no hagan falta). Mientras
-- existan, la 107 no se puede volver a correr (aborta sola).
-- Las filas vuelven EXACTAMENTE como estaban (fin_fuentes con su valor de activo:
-- la sync las vuelve a tomar sola si estaban activas).
-- Lo que la sync o la app hayan creado para liam/agus/teo despues de la 107 no se toca.
-- =====================================================================

do $r107$
declare
  v_tab    text[] := '{}';
  v_ok     boolean[];
  v_ttab   text[] := '{}';   -- triggers apagados: tabla
  v_tnom   text[] := '{}';   -- triggers apagados: nombre
  r        record;
  i        int;
  pasada   int;
  prog     boolean;
  pend     int;
  v_cols   text;
  v_over   text;
  v_err    text;
  n        bigint;
  m        bigint;
begin
  perform set_config('lock_timeout', '10s', true);

  if to_regclass('public.fin_funciones_bak_baja_107') is null then
    raise exception 'REVERTIR 107 ABORTADA: no existe fin_funciones_bak_baja_107 (la 107 no corrio o ya se limpio)';
  end if;
  if to_regclass('public.crm_clients_bak_baja_107') is null then
    raise exception 'REVERTIR 107 ABORTADA: no existe crm_clients_bak_baja_107 (la 107 no corrio o ya se limpio)';
  end if;
  select string_agg(c.id, ', ') into v_err
  from public.crm_clients c where c.id in (select b.id from public.crm_clients_bak_baja_107 b);
  if v_err is not null then
    raise exception 'REVERTIR 107 ABORTADA: crm_clients ya tiene a % (ya se revirtio o se dieron de alta de nuevo)', v_err;
  end if;

  -- tablas respaldadas: crm_clients primero, el resto por nombre
  for r in
    select c.relname::text as bak,
           regexp_replace(c.relname, '_bak_baja_107$', '') as orig
    from pg_class c join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
    where c.relkind = 'r' and c.relname ~ '_bak_baja_107$' and c.relname <> 'fin_funciones_bak_baja_107'
    order by (regexp_replace(c.relname, '_bak_baja_107$', '') <> 'crm_clients'), 1
  loop
    if to_regclass(format('public.%I', r.orig)) is null then
      raise exception 'REVERTIR 107 ABORTADA: falta la tabla original % (respaldo %)', r.orig, r.bak;
    end if;
    v_tab := v_tab || r.orig;
  end loop;

  if array_length(v_tab, 1) is null then
    raise exception 'REVERTIR 107 ABORTADA: no hay tablas *_bak_baja_107';
  end if;
  v_ok := array_fill(false, array[array_length(v_tab, 1)]);

  -- las tablas a restaurar quedan bloqueadas de a una sentencia
  execute 'lock table ' || (select string_agg(format('public.%I', t), ', ' order by t) from unnest(v_tab) t)
          || ' in share row exclusive mode';

  -- triggers de usuario prendidos en esas tablas: se apagan para que las filas vuelvan tal cual
  for r in
    select c.relname::text as t, tg.tgname::text as nom
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
    where not tg.tgisinternal and tg.tgenabled = 'O' and c.relname = any(v_tab)
    order by 1, 2
  loop
    v_ttab := v_ttab || r.t;
    v_tnom := v_tnom || r.nom;
  end loop;
  for i in 1 .. coalesce(array_length(v_ttab, 1), 0) loop
    execute format('alter table public.%I disable trigger %I', v_ttab[i], v_tnom[i]);
  end loop;

  pasada := 0;
  loop
    pasada := pasada + 1;
    prog := false;
    pend := 0;
    for i in 1 .. array_length(v_tab, 1) loop
      if v_ok[i] then continue; end if;
      -- columnas no generadas del original que tambien estan en el respaldo
      select string_agg(format('%I', a.attname), ', ' order by a.attnum) into v_cols
      from pg_attribute a
      where a.attrelid = format('public.%I', v_tab[i])::regclass
        and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
        and exists (select 1 from pg_attribute b
                    where b.attrelid = format('public.%I', v_tab[i] || '_bak_baja_107')::regclass
                      and b.attname = a.attname and b.attnum > 0 and not b.attisdropped);
      select case when exists (select 1 from pg_attribute a
                               where a.attrelid = format('public.%I', v_tab[i])::regclass
                                 and a.attidentity = 'a' and not a.attisdropped)
                  then ' overriding system value' else '' end into v_over;
      begin
        execute format('insert into public.%I (%s)%s select %s from public.%I',
                       v_tab[i], v_cols, v_over, v_cols, v_tab[i] || '_bak_baja_107');
        get diagnostics n = row_count;
        execute format('select count(*) from public.%I', v_tab[i] || '_bak_baja_107') into m;
        if n <> m then
          raise exception 'REVERTIR 107 ABORTADA: en % entraron % filas y el respaldo tiene %', v_tab[i], n, m;
        end if;
        raise notice 'REVERTIR 107: % filas restauradas en %', n, v_tab[i];
        v_ok[i] := true;
        prog := true;
      exception when foreign_key_violation then
        pend := pend + 1;
        v_err := sqlerrm;
      end;
    end loop;
    exit when pend = 0;
    if not prog or pasada >= 8 then
      raise exception 'REVERTIR 107 ABORTADA: no se pudo restaurar por FK: % (ultimo error: %)',
        (select string_agg(v_tab[k], ', ') from generate_subscripts(v_tab, 1) k where not v_ok[k]), v_err;
    end if;
  end loop;

  -- se vuelven a prender los mismos triggers
  for i in 1 .. coalesce(array_length(v_ttab, 1), 0) loop
    execute format('alter table public.%I enable trigger %I', v_ttab[i], v_tnom[i]);
  end loop;

  -- definiciones de funciones y vistas
  for r in select objeto, tipo, definicion, opciones from public.fin_funciones_bak_baja_107 order by tipo desc, objeto loop
    if r.tipo = 'function' then
      execute r.definicion;
    else
      execute format('create or replace view %s %s as %s', r.objeto,
                     case when r.opciones is not null then 'with (' || r.opciones || ')' else '' end,
                     regexp_replace(r.definicion, ';\s*$', ''));
    end if;
  end loop;

  raise notice 'REVERTIR 107 OK: filas y definiciones restauradas';
end
$r107$;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- R1. crm_clients vuelve a tener mauro y lucas:
-- select id, nombre from public.crm_clients order by orden;
--
-- R2. Mismos numeros que el inventario (mauro / lucas), p. ej.:
-- select cliente_id, count(*) from public.fin_pagos where cliente_id in ('mauro','lucas') group by 1;   -- 809 / 229
-- select cliente_id, count(*) from public.fin_llamadas where cliente_id in ('mauro','lucas') group by 1; -- 988 / 557
-- select cliente_id, count(*) from public.crm_publicaciones where cliente_id in ('mauro','lucas') group by 1; -- 717 / 343
-- select programa_id, count(*) from public.cs_maestro_columnas where programa_id in ('mauro','lucas') group by 1; -- 1 / 1
-- select id from public.cs_programas where id in ('mauro','lucas') order by 1; -- lucas, mauro
--
-- R3. Funciones y vistas con la definicion anterior (menciona = true en las 5):
-- select p.proname, p.prosrc ~* '(mauro|lucas)' as menciona from pg_proc p
-- where p.proname in ('fin_pagos_resolver','fin_clientes_carga','fin_data_admite_nuevas');
-- select c.relname, pg_get_viewdef(c.oid) ~* 'mauro' as menciona from pg_class c
-- where c.relname in ('fin_v_alias_pendientes','fin_v_pago_vendedores');
--
-- R4. liam, agus y teo sin cambios (mismos conteos que C3 de la 107).
--
-- R5. Ningun trigger quedo apagado (esperado: 0 filas, salvo los que ya estaban apagados antes):
-- select c.relname, tg.tgname from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
-- join pg_namespace s on s.oid = c.relnamespace and s.nspname = 'public'
-- where not tg.tgisinternal and tg.tgenabled = 'D';
--
-- Limpieza (a mano, cuando ya no haga falta): drop table public.<tabla>_bak_baja_107; y
-- drop table public.fin_funciones_bak_baja_107;
