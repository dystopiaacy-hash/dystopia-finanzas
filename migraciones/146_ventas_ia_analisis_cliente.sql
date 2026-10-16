-- =====================================================================
-- 146_ventas_ia_analisis_cliente.sql
-- Ventas, IA fase 3: el rol CLIENTE (ej. Agus, Liam) ve el analisis de las
-- llamadas de venta de SU cliente. Decision de Joaquin (16/10).
--
-- QUE HACE
--   Reemplaza fin_ia_puede_ver(cliente, closer) de la 142 agregando una rama:
--     rol_actual() = 'cliente' y tiene_acceso(cliente)  (crm_asignaciones,
--     el mismo criterio de fin_data_puede_ver / 077).
--   Esa funcion es la que usan las politicas de lectura de fin_llamadas_fathom,
--   fin_llamadas_analisis y fin_devoluciones_closer. Las vistas
--   fin_v_llamada_analisis y fin_v_analisis_llamadas son security_invoker: heredan
--   la regla sin tocarlas (la primera tambien cruza fin_llamadas, que el cliente
--   ya lee por su politica de siempre).
--
-- NO CAMBIA
--   - Solo lectura: el cliente sigue sin escribir nada (escribe service_role).
--   - fin_cliente_config (estructura de venta) sigue SIN verla el cliente.
--   - Fundador, ventas y closer: igual que en la 142.
--   - Otro cliente: aunque pase el id a mano, tiene_acceso da false y la RLS
--     no devuelve filas.
--
-- REQUIERE la 142 corrida. Sin begin/commit (SQL Editor). Idempotente.
-- Correr los bloques de a uno, fuera de :00/:15/:30/:45.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas
-- ---------------------------------------------------------------------
do $g$
declare v_falta text;
begin
  select string_agg(t, ', ') into v_falta
  from unnest(array['fin_llamadas_fathom', 'fin_llamadas_analisis', 'fin_devoluciones_closer',
                    'fin_cliente_config', 'crm_asignaciones', 'crm_members']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception '146: faltan tablas: % (primero la 142)', v_falta;
  end if;
  if to_regprocedure('public.fin_ia_puede_ver(text,text)') is null
     or to_regprocedure('public.tiene_acceso(text)') is null
     or to_regprocedure('public.rol_actual()') is null
     or to_regprocedure('public.es_fundador()') is null
     or to_regprocedure('public.fin_asignado(text)') is null then
    raise exception '146: faltan funciones fin_ia_puede_ver (142) / tiene_acceso / rol_actual / es_fundador / fin_asignado';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. fin_ia_puede_ver con la rama del rol cliente
-- ---------------------------------------------------------------------
create or replace function public.fin_ia_puede_ver(p_cliente text, p_closer text)
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.es_fundador(), false)
      or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
      or (public.rol_actual() = 'ventas' and public.fin_asignado(p_cliente))
      or (public.rol_actual() = 'closer' and p_closer is not null and exists (
            select 1 from public.fin_personas p
             where p.user_id = auth.uid() and p.cliente_id = p_cliente
               and p.campo in ('closer', 'ambos')
               and (lower(btrim(p.alias)) = lower(btrim(p_closer))
                    or (p.vendedor_id is not null and exists (
                          select 1 from public.fin_personas q
                           where q.cliente_id = p_cliente and q.vendedor_id = p.vendedor_id
                             and lower(btrim(q.alias)) = lower(btrim(p_closer)))))))
$fn$;
revoke all on function public.fin_ia_puede_ver(text, text) from public, anon;
grant execute on function public.fin_ia_puede_ver(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. PRUEBA DE HUMO (se revierte sola: termina en una excepcion
--           "HUMO OK ..."; si algo falla dice "HUMO FALLO ...").
--           Toma un usuario con rol cliente y un cliente que SI tiene
--           asignado y otro que NO; crea un analisis de prueba en cada uno.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_user  uuid;
  v_mio   text;
  v_ajeno text;
  v_n     integer;
begin
  select m.user_id, a.cliente_id into v_user, v_mio
    from public.crm_members m
    join public.crm_asignaciones a on a.user_id = m.user_id
   where m.rol = 'cliente'
   order by m.user_id, a.cliente_id
   limit 1;
  if v_user is null then raise exception 'HUMO FALLO: no hay ningun usuario con rol cliente y cliente asignado'; end if;

  select c.id into v_ajeno from public.crm_clients c
   where c.id <> all (select a.cliente_id from public.crm_asignaciones a where a.user_id = v_user)
   order by c.id limit 1;
  if v_ajeno is null then raise exception 'HUMO FALLO: el usuario % tiene asignados todos los clientes, no hay un ajeno para probar', v_user; end if;

  -- datos de prueba (los borra la excepcion final)
  insert into public.fin_llamadas_fathom (externo_id, cliente_id, fecha_llamada, email, origen)
  values ('fathom:HUMO146A', v_mio,   current_date, 'humo146a@example.com', 'sin_asignar'),
         ('fathom:HUMO146B', v_ajeno, current_date, 'humo146b@example.com', 'sin_asignar');
  insert into public.fin_llamadas_analisis (externo_id, cliente_id, closer, estado)
  values ('fathom:HUMO146A', v_mio,   'PRUEBA CLOSER', 'ok'),
         ('fathom:HUMO146B', v_ajeno, 'PRUEBA CLOSER', 'ok');
  insert into public.fin_devoluciones_closer (cliente_id, closer, semana_inicio, n_llamadas)
  values (v_mio,   'PRUEBA CLOSER', date '2000-01-03', 1),
         (v_ajeno, 'PRUEBA CLOSER', date '2000-01-03', 1);

  -- sin sesion: nadie
  perform set_config('request.jwt.claim.sub', '', true);
  if public.fin_ia_puede_ver(v_mio, 'PRUEBA CLOSER') then raise exception 'HUMO FALLO 1: da true sin sesion'; end if;

  -- como el usuario cliente
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  if not public.fin_ia_puede_ver(v_mio, 'PRUEBA CLOSER') then raise exception 'HUMO FALLO 2: el cliente no ve lo suyo (%)', v_mio; end if;
  if public.fin_ia_puede_ver(v_ajeno, 'PRUEBA CLOSER') then raise exception 'HUMO FALLO 3: el cliente ve un cliente ajeno (%)', v_ajeno; end if;

  -- por las politicas reales (rol authenticated)
  set local role authenticated;
  select count(*) into v_n from public.fin_llamadas_analisis   where externo_id like 'fathom:HUMO146%';
  if v_n <> 1 then raise exception 'HUMO FALLO 4: analisis visibles % (esperado 1, solo el propio)', v_n; end if;
  select count(*) into v_n from public.fin_llamadas_fathom     where externo_id like 'fathom:HUMO146%';
  if v_n <> 1 then raise exception 'HUMO FALLO 5: vinculos visibles % (esperado 1)', v_n; end if;
  select count(*) into v_n from public.fin_devoluciones_closer where semana_inicio = date '2000-01-03';
  if v_n <> 1 then raise exception 'HUMO FALLO 6: devoluciones visibles % (esperado 1)', v_n; end if;
  select count(*) into v_n from public.fin_v_analisis_llamadas where externo_id like 'fathom:HUMO146%';
  if v_n <> 1 then raise exception 'HUMO FALLO 7: fin_v_analisis_llamadas muestra % (esperado 1)', v_n; end if;
  -- el cliente sigue sin ver la estructura de venta (tabla fin_cliente_config)
  select count(*) into v_n from public.fin_cliente_config;
  if v_n <> 0 then raise exception 'HUMO FALLO 8: el cliente ve fin_cliente_config (% filas)', v_n; end if;
  -- y no escribe
  begin
    update public.fin_llamadas_analisis set closer = 'X' where externo_id = 'fathom:HUMO146A';
    get diagnostics v_n = row_count;
    if v_n > 0 then raise exception 'HUMO FALLO 9: el cliente pudo actualizar un analisis'; end if;
  exception when insufficient_privilege then null;
  end;
  reset role;

  raise exception 'HUMO OK: 9 pruebas pasaron (usuario %, propio %, ajeno %). Se revirtio todo.', v_user, v_mio, v_ajeno;
end
$humo$;
-- Resultado esperado: ERROR "HUMO OK: ...". Cualquier "HUMO FALLO" = avisar.

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. La funcion quedo con la rama cliente y sigue ejecutable solo por authenticated/service_role:
--     tiene_cliente = true | authenticated = true | anon = false
-- select pg_get_functiondef(p.oid) like '%''cliente''%' as tiene_cliente,
--        has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('anon', p.oid, 'execute') as anon
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname = 'fin_ia_puede_ver';

-- C2. El humo no dejo nada: 0 | 0 | 0.
-- select (select count(*) from fin_llamadas_fathom where externo_id like 'fathom:HUMO146%') as vinculos,
--        (select count(*) from fin_llamadas_analisis where externo_id like 'fathom:HUMO146%') as analisis,
--        (select count(*) from fin_devoluciones_closer where semana_inicio = date '2000-01-03') as devoluciones;

-- C3. Quien deberia ver cada cliente (usuarios cliente y sus asignaciones; revisar a ojo):
-- select m.rol, u.email, a.cliente_id
--   from crm_members m join auth.users u on u.id = m.user_id
--   left join crm_asignaciones a on a.user_id = m.user_id
--  where m.rol = 'cliente' order by 2, 3;

-- C4. Lo que el CLIENTE ve de verdad (cambiar el mail; debe listar solo sus clientes):
-- begin;
--   select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = '<MAIL_CLIENTE>'), true);
--   set local role authenticated;
--   select cliente_id, count(*) from fin_llamadas_analisis group by 1;
--   select cliente_id, count(*) from fin_v_analisis_llamadas group by 1;
-- rollback;

-- =====================================================================
-- VUELTA ATRAS (deja la funcion como la 142: sin la rama cliente)
-- =====================================================================
-- create or replace function public.fin_ia_puede_ver(p_cliente text, p_closer text)
-- returns boolean language sql stable security definer set search_path = public
-- as $fn$
--   select coalesce(public.es_fundador(), false)
--       or (public.rol_actual() = 'ventas' and public.fin_asignado(p_cliente))
--       or (public.rol_actual() = 'closer' and p_closer is not null and exists (
--             select 1 from public.fin_personas p
--              where p.user_id = auth.uid() and p.cliente_id = p_cliente
--                and p.campo in ('closer', 'ambos')
--                and (lower(btrim(p.alias)) = lower(btrim(p_closer))
--                     or (p.vendedor_id is not null and exists (
--                           select 1 from public.fin_personas q
--                            where q.cliente_id = p_cliente and q.vendedor_id = p.vendedor_id
--                              and lower(btrim(q.alias)) = lower(btrim(p_closer)))))))
-- $fn$;
