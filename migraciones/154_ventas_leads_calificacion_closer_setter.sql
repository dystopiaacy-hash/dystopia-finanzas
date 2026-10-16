-- =====================================================================
-- 154_ventas_leads_calificacion_closer_setter.sql
-- Ventas: closers y setters ven la "Calificacion IA" de SUS leads en la
-- pantalla Llamadas (opcion A, decision de Joaquin 16/10). Requiere la 147.
--
-- QUE HACE
--   Agrega UNA politica de lectura a fin_leads_calificacion, solo para los
--   roles 'closer' y 'setter':
--     una calificacion (cliente, fecha, clave_lead) se ve si el usuario ve,
--     por la RLS de fin_llamadas (politica fin_llamadas_lectura, 029), alguna
--     llamada del mismo cliente y fecha con esa misma clave de lead
--     (fin_lead_clave(email, telefono, nombre)).
--   El subselect sobre fin_llamadas corre con los permisos de quien consulta
--   (la funcion NO es security definer), asi que el alcance es EXACTAMENTE el
--   de la 029 hoy y se mantiene solo si esa politica cambia: no hay una
--   segunda regla que mantener. Closer = sus llamadas (alias); setter = las
--   atribuidas a el por fuente y mes.
--
-- NO CAMBIA
--   - La politica fin_leads_calificacion_lectura (147: fundador, cliente, ventas,
--     finanzas) queda igual. La nueva es ADITIVA (las politicas se suman con OR).
--   - closer/setter siguen SIN grilla Data y SIN fin_data_puede_ver.
--   - Solo lectura: no hay grants nuevos, escribe service_role.
--   - La vista fin_v_llamadas_calificadas no se toca (security_invoker: hereda).
--
-- LIMITE CONOCIDO
--   La clave es por lead, no por fila: si el mismo lead (mismo mail/telefono/
--   nombre) tiene dos llamadas el mismo dia y el closer ve solo una, ve la
--   calificacion de ese lead (que es del lead, calculada con sus respuestas
--   del formulario y la nota del setter). No expone filas de llamadas ajenas.
--
-- Sin begin/commit (SQL Editor). Idempotente. Correr los bloques de a uno,
-- fuera de :00/:15/:30/:45.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas
-- ---------------------------------------------------------------------
do $g$
begin
  if to_regclass('public.fin_leads_calificacion') is null
     or to_regclass('public.fin_v_llamadas_calificadas') is null then
    raise exception '154: falta fin_leads_calificacion / fin_v_llamadas_calificadas (primero la 147)';
  end if;
  if to_regprocedure('public.fin_lead_clave(text,text,text)') is null
     or to_regprocedure('public.rol_actual()') is null then
    raise exception '154: faltan fin_lead_clave (147) / rol_actual';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'fin_llamadas' and policyname = 'fin_llamadas_lectura') then
    raise exception '154: no existe la politica fin_llamadas_lectura de fin_llamadas (029); sin ella el alcance de closer/setter no esta definido';
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'fin_leads_calificacion' and policyname = 'fin_leads_calificacion_lectura') then
    raise exception '154: no existe fin_leads_calificacion_lectura (147)';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Politica aditiva (se puede correr dos veces)
-- ---------------------------------------------------------------------
drop policy if exists fin_leads_calificacion_lectura_closer_setter on public.fin_leads_calificacion;
create policy fin_leads_calificacion_lectura_closer_setter on public.fin_leads_calificacion
  for select to authenticated
  using (
    public.rol_actual() in ('closer', 'setter')
    and exists (
      select 1 from public.fin_llamadas l          -- con la RLS de quien consulta (029)
       where l.cliente_id    = fin_leads_calificacion.cliente_id
         and l.fecha_llamada = fin_leads_calificacion.fecha_llamada
         and public.fin_lead_clave(l.email, l.telefono, l.nombre) = fin_leads_calificacion.clave_lead
    )
  );

-- ---------------------------------------------------------------------
-- BLOQUE 2. PRUEBA DE HUMO (se revierte sola: termina en una excepcion
--           "HUMO OK ..."; si algo falla dice "HUMO FALLO ..." y tambien
--           revierte). Hoy (16/10) en prod NO hay usuarios closer ni setter,
--           asi que la humo crea los suyos (auth.users + crm_members +
--           fin_personas), un mapeo de fuente y un periodo de setter propios
--           (2099-01, que no existe), y 6 leads:
--             A  del closer de prueba (hoy)
--             B  de otro closer del mismo cliente (hoy)
--             C  de OTRO cliente con el MISMO alias del closer (hoy)
--             D  calificacion con la clave de A pero OTRA fecha, sin llamada
--             S  atribuido al setter de prueba (fuente setter, periodo 2099-01)
--             N  mismo dia que S pero con una fuente que no es de setter
--           y mira lo que ve cada uno con la RLS real. No pisa nada: si el
--           mapeo o el periodo de prueba ya existieran, frena antes de insertar.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_uc     uuid := gen_random_uuid();          -- closer de prueba
  v_us     uuid := gen_random_uuid();          -- setter de prueba
  v_alias  text := 'HUMO154 CLOSER';
  v_fs     date := date '2099-01-15';          -- fecha de los leads del setter
  v_cli    text;
  v_ajeno  text;
  v_fuente bigint;
  v_fuente2 bigint;
  v_vend   bigint;
  v_n      integer;
begin
  select f.cliente_id into v_cli from public.fin_fuentes f
   order by (f.cliente_id = 'liam') desc, f.cliente_id limit 1;
  if v_cli is null then raise exception 'HUMO FALLO: no hay ningun cliente con fuente'; end if;
  select c.id into v_ajeno from public.crm_clients c
   where c.id <> v_cli and exists (select 1 from public.fin_fuentes f where f.cliente_id = c.id)
   order by c.id limit 1;
  if v_ajeno is null then raise exception 'HUMO FALLO: no hay otro cliente con fuente para probar el cruce entre clientes'; end if;
  select id into v_fuente  from public.fin_fuentes where cliente_id = v_cli   order by (tipo = 'data') desc, id limit 1;
  select id into v_fuente2 from public.fin_fuentes where cliente_id = v_ajeno order by (tipo = 'data') desc, id limit 1;
  select id into v_vend from public.fin_vendedores order by id limit 1;
  if v_vend is null then raise exception 'HUMO FALLO: no hay ningun vendedor para el setter de prueba'; end if;
  if exists (select 1 from public.fin_setter_periodo where cliente_id in (v_cli, v_ajeno) and periodo = to_char(v_fs, 'YYYY-MM'))
     or exists (select 1 from public.fin_fuentes_mapa where cliente_id in (v_cli, v_ajeno) and fuente_cruda in ('HUMO154 SETTER', 'HUMO154 NO SETTER')) then
    raise exception 'HUMO FALLO: ya existe el periodo 2099-01 o el mapeo HUMO154 (no se pisan)';
  end if;

  -- usuarios de prueba
  insert into auth.users (id, email) values (v_uc, 'humo154-closer@example.invalid'), (v_us, 'humo154-setter@example.invalid');
  insert into public.crm_members (user_id, rol, nombre) values (v_uc, 'closer', 'HUMO 154 closer'), (v_us, 'setter', 'HUMO 154 setter');
  insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
  values (v_uc, v_cli, v_alias, null, 'closer'),
         (v_us, v_cli, 'HUMO154 SETTER', v_vend, 'setter');
  insert into public.fin_fuentes_mapa (cliente_id, fuente_cruda, fuente, atribucion) values (v_cli, 'HUMO154 SETTER', 'HUMO154', 'setter');
  insert into public.fin_setter_periodo (cliente_id, periodo, vendedor_id, origen) values (v_cli, to_char(v_fs, 'YYYY-MM'), v_vend, 'manual');

  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, tipo_booking, nombre, email, origen)
  values (v_cli,   v_fuente,  null, current_date, v_alias,           null,                'PRUEBA 154 A', 'humo154a@example.com', 'app'),
         (v_cli,   v_fuente,  null, current_date, 'OTRO CLOSER 154', null,                'PRUEBA 154 B', 'humo154b@example.com', 'app'),
         (v_ajeno, v_fuente2, null, current_date, v_alias,           null,                'PRUEBA 154 C', 'humo154c@example.com', 'app'),
         (v_cli,   v_fuente,  null, v_fs,         'OTRO CLOSER 154', 'HUMO154 SETTER',    'PRUEBA 154 S', 'humo154s@example.com', 'app'),
         (v_cli,   v_fuente,  null, v_fs,         'OTRO CLOSER 154', 'HUMO154 NO SETTER', 'PRUEBA 154 N', 'humo154n@example.com', 'app');
  insert into public.fin_leads_calificacion (cliente_id, fecha_llamada, clave_lead, estado, nivel, puntaje, motivo, huella, calificado_en)
  values (v_cli,   current_date,     'm:humo154a@example.com', 'ok', 'caliente', 80, 'prueba A', 'h', now()),
         (v_cli,   current_date,     'm:humo154b@example.com', 'ok', 'tibio',    50, 'prueba B', 'h', now()),
         (v_ajeno, current_date,     'm:humo154c@example.com', 'ok', 'frio',     10, 'prueba C', 'h', now()),
         (v_cli,   current_date - 1, 'm:humo154a@example.com', 'ok', 'frio',     20, 'prueba D', 'h', now()),
         (v_cli,   v_fs,             'm:humo154s@example.com', 'ok', 'tibio',    60, 'prueba S', 'h', now()),
         (v_cli,   v_fs,             'm:humo154n@example.com', 'ok', 'frio',     30, 'prueba N', 'h', now());

  -- sin sesion: nada
  perform set_config('request.jwt.claim.sub', '', true);
  set local role authenticated;
  select count(*) into v_n from public.fin_leads_calificacion where clave_lead like 'm:humo154%';
  if v_n <> 0 then raise exception 'HUMO FALLO 1: sin sesion se ven % calificaciones', v_n; end if;
  reset role;

  -- como el closer, con las politicas reales
  perform set_config('request.jwt.claim.sub', v_uc::text, true);
  set local role authenticated;
  select count(*) into v_n from public.fin_leads_calificacion where clave_lead like 'm:humo154%';
  if v_n <> 1 then raise exception 'HUMO FALLO 2: el closer ve % calificaciones de prueba (esperado 1, solo la suya)', v_n; end if;
  if not exists (select 1 from public.fin_leads_calificacion where clave_lead = 'm:humo154a@example.com' and cliente_id = v_cli and fecha_llamada = current_date) then
    raise exception 'HUMO FALLO 3: el closer no ve la calificacion de su propio lead'; end if;
  if exists (select 1 from public.fin_leads_calificacion where clave_lead = 'm:humo154b@example.com') then
    raise exception 'HUMO FALLO 4: el closer ve el lead de OTRO closer'; end if;
  if exists (select 1 from public.fin_leads_calificacion where clave_lead = 'm:humo154c@example.com') then
    raise exception 'HUMO FALLO 5: el closer ve un lead de OTRO CLIENTE'; end if;
  if exists (select 1 from public.fin_leads_calificacion where clave_lead = 'm:humo154a@example.com' and fecha_llamada <> current_date) then
    raise exception 'HUMO FALLO 6: el closer ve la calificacion de su lead de OTRA fecha (sin llamada)'; end if;
  if exists (select 1 from public.fin_leads_calificacion where clave_lead in ('m:humo154s@example.com', 'm:humo154n@example.com')) then
    raise exception 'HUMO FALLO 7: el closer ve leads del setter'; end if;
  select count(*) into v_n from public.fin_v_llamadas_calificadas where email like 'humo154%@example.com';
  if v_n <> 1 then raise exception 'HUMO FALLO 8: la vista le muestra al closer % filas de prueba (esperado 1)', v_n; end if;
  select count(*) into v_n from public.fin_v_llamadas_calificadas where email = 'humo154a@example.com' and cal_nivel = 'caliente' and cal_puntaje = 80;
  if v_n <> 1 then raise exception 'HUMO FALLO 9: la vista no le trae al closer la calificacion de su lead'; end if;
  begin
    update public.fin_leads_calificacion set puntaje = 99 where clave_lead = 'm:humo154a@example.com';
    get diagnostics v_n = row_count;
    if v_n > 0 then raise exception 'HUMO FALLO 10: el closer pudo modificar una calificacion'; end if;
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- como el setter
  perform set_config('request.jwt.claim.sub', v_us::text, true);
  set local role authenticated;
  select count(*) into v_n from public.fin_leads_calificacion where clave_lead like 'm:humo154%';
  if v_n <> 1 then raise exception 'HUMO FALLO 11: el setter ve % calificaciones de prueba (esperado 1, solo la atribuida a el)', v_n; end if;
  if not exists (select 1 from public.fin_leads_calificacion where clave_lead = 'm:humo154s@example.com' and cliente_id = v_cli and fecha_llamada = v_fs) then
    raise exception 'HUMO FALLO 12: el setter no ve la calificacion de su lead'; end if;
  if exists (select 1 from public.fin_leads_calificacion where clave_lead in ('m:humo154a@example.com', 'm:humo154b@example.com', 'm:humo154c@example.com', 'm:humo154n@example.com')) then
    raise exception 'HUMO FALLO 13: el setter ve leads que no le estan atribuidos'; end if;
  select count(*) into v_n from public.fin_v_llamadas_calificadas where email like 'humo154%@example.com';
  if v_n <> 1 then raise exception 'HUMO FALLO 14: la vista le muestra al setter % filas de prueba (esperado 1)', v_n; end if;
  select count(*) into v_n from public.fin_v_llamadas_calificadas where email = 'humo154s@example.com' and cal_nivel = 'tibio' and cal_puntaje = 60;
  if v_n <> 1 then raise exception 'HUMO FALLO 15: la vista no le trae al setter la calificacion de su lead'; end if;
  begin
    update public.fin_leads_calificacion set puntaje = 99 where clave_lead = 'm:humo154s@example.com';
    get diagnostics v_n = row_count;
    if v_n > 0 then raise exception 'HUMO FALLO 16: el setter pudo modificar una calificacion'; end if;
  exception when insufficient_privilege then null;
  end;
  reset role;

  -- la politica de la 147 sigue: closer y setter siguen sin fin_leads_puede_ver (grilla Data)
  perform set_config('request.jwt.claim.sub', v_uc::text, true);
  if public.fin_leads_puede_ver(v_cli) then raise exception 'HUMO FALLO 17: el closer paso a poder ver Data (fin_leads_puede_ver)'; end if;
  perform set_config('request.jwt.claim.sub', v_us::text, true);
  if public.fin_leads_puede_ver(v_cli) then raise exception 'HUMO FALLO 18: el setter paso a poder ver Data (fin_leads_puede_ver)'; end if;

  raise exception 'HUMO OK: 18 pruebas pasaron (closer y setter de prueba, cliente %, ajeno %). Se revirtio todo.', v_cli, v_ajeno;
end
$humo$;
-- Resultado esperado: ERROR "HUMO OK: ...". Cualquier "HUMO FALLO" = avisar.

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. Las dos politicas de lectura existen (la de la 147 y la nueva): 2 filas.
-- select policyname, roles::text, cmd from pg_policies
--  where schemaname = 'public' and tablename = 'fin_leads_calificacion' order by 1;

-- C2. El humo no dejo nada: 0 | 0 | 0 | 0 | 0.
-- select (select count(*) from fin_llamadas where nombre like 'PRUEBA 154%') as llamadas_prueba,
--        (select count(*) from fin_leads_calificacion where clave_lead like 'm:humo154%') as calificaciones_prueba,
--        (select count(*) from auth.users where email like 'humo154-%') as usuarios_prueba,
--        (select count(*) from fin_fuentes_mapa where fuente_cruda like 'HUMO154%') as mapa_prueba,
--        (select count(*) from fin_setter_periodo where periodo = '2099-01') as periodo_prueba;

-- C3. Quienes son los closers y setters (revisar a ojo contra la app). Al 16/10 da 0 filas:
--     en prod todavia no hay usuarios con rol closer o setter.
-- select m.rol, u.email, p.cliente_id, p.alias, p.campo
--   from crm_members m join auth.users u on u.id = m.user_id
--   left join fin_personas p on p.user_id = m.user_id
--  where m.rol in ('closer', 'setter') order by 1, 2, 3;

-- C4. FUGA, lo que ve de verdad un closer o setter (cambiar el mail). Esperado: las dos
--     columnas iguales, y los clientes solo los suyos. calificaciones = filas que le llegan de
--     la tabla; en_sus_llamadas = las que cruzan con una llamada que ya ve.
--     Solo sirve cuando exista un usuario closer/setter real (ver C3); mientras tanto, C4b.
-- begin;
--   select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = '<MAIL_CLOSER_O_SETTER>'), true);
--   set local role authenticated;
--   select c.cliente_id, count(*) as calificaciones,
--          count(*) filter (where exists (select 1 from fin_llamadas l
--            where l.cliente_id = c.cliente_id and l.fecha_llamada = c.fecha_llamada
--              and fin_lead_clave(l.email, l.telefono, l.nombre) = c.clave_lead)) as en_sus_llamadas
--     from fin_leads_calificacion c group by 1 order by 1;
--   select cliente_id, count(*) as llamadas_con_calificacion from fin_v_llamadas_calificadas where cal_nivel is not null group by 1;
-- rollback;

-- C4b. Lo mismo con datos reales y usuarios TEMPORALES (se revierte: termina en excepcion "C4b ...").
--      Crea un closer con el alias real de liam que mas llamadas calificadas tiene, y un setter con
--      el vendedor real del periodo de setter con mas llamadas calificadas atribuidas. Esperado, para
--      cada uno: calificaciones = en_sus_llamadas, y llamadas_vista_con_cal >= calificaciones.
-- do $c4b$
-- declare
--   v_uc uuid := gen_random_uuid(); v_us uuid := gen_random_uuid();
--   v_cli_c text; v_alias text; v_cli_s text; v_vend bigint;
--   c_cal int; c_cruza int; c_llam int; c_vista int; s_cal int; s_cruza int; s_llam int; s_vista int;
-- begin
--   select l.cliente_id, max(btrim(p.alias)) into v_cli_c, v_alias
--     from fin_llamadas l join fin_personas p on p.cliente_id = l.cliente_id and p.campo in ('closer', 'ambos')
--          and lower(btrim(p.alias)) = lower(btrim(l.closer)) and p.user_id is null
--    where exists (select 1 from fin_leads_calificacion c where c.cliente_id = l.cliente_id and c.fecha_llamada = l.fecha_llamada
--                    and c.clave_lead = fin_lead_clave(l.email, l.telefono, l.nombre))
--    group by l.cliente_id, lower(btrim(p.alias)) order by count(*) desc limit 1;
--   select l.cliente_id, fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking) into v_cli_s, v_vend
--     from fin_llamadas l
--    where l.fecha_llamada is not null and fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking) is not null
--      and exists (select 1 from fin_leads_calificacion c where c.cliente_id = l.cliente_id and c.fecha_llamada = l.fecha_llamada
--                    and c.clave_lead = fin_lead_clave(l.email, l.telefono, l.nombre))
--    group by 1, 2 order by count(*) desc limit 1;
--   insert into auth.users (id, email) values (v_uc, 'c4b154-closer@example.invalid'), (v_us, 'c4b154-setter@example.invalid');
--   insert into crm_members (user_id, rol, nombre) values (v_uc, 'closer', 'C4b closer'), (v_us, 'setter', 'C4b setter');
--   -- el alias es unico por cliente (fin_personas_alias_cliente_uq): se le cuelga el usuario temporal a la fila real
--   -- (solo si no tiene usuario); el update se revierte con la excepcion del final
--   update fin_personas set user_id = v_uc
--    where id = (select id from fin_personas where cliente_id = v_cli_c and lower(btrim(alias)) = lower(v_alias)
--                   and campo in ('closer', 'ambos') and user_id is null order by id limit 1);
--   if not found then raise exception 'C4b: la fila de % (%) ya tiene usuario o no existe', v_alias, v_cli_c; end if;
--   insert into fin_personas (user_id, cliente_id, alias, vendedor_id, campo) values (v_us, v_cli_s, 'C4B SETTER', v_vend, 'setter');
--   perform set_config('request.jwt.claim.sub', v_uc::text, true);
--   set local role authenticated;
--   select count(*), count(*) filter (where exists (select 1 from fin_llamadas l where l.cliente_id = c.cliente_id and l.fecha_llamada = c.fecha_llamada
--            and fin_lead_clave(l.email, l.telefono, l.nombre) = c.clave_lead)) into c_cal, c_cruza from fin_leads_calificacion c;
--   select count(*) into c_llam from fin_llamadas;
--   select count(*) into c_vista from fin_v_llamadas_calificadas where cal_nivel is not null;
--   reset role;
--   perform set_config('request.jwt.claim.sub', v_us::text, true);
--   set local role authenticated;
--   select count(*), count(*) filter (where exists (select 1 from fin_llamadas l where l.cliente_id = c.cliente_id and l.fecha_llamada = c.fecha_llamada
--            and fin_lead_clave(l.email, l.telefono, l.nombre) = c.clave_lead)) into s_cal, s_cruza from fin_leads_calificacion c;
--   select count(*) into s_llam from fin_llamadas;
--   select count(*) into s_vista from fin_v_llamadas_calificadas where cal_nivel is not null;
--   reset role;
--   raise exception 'C4b closer % (%): calificaciones %, en_sus_llamadas %, llamadas %, llamadas_vista_con_cal % | setter vendedor % (%): calificaciones %, en_sus_llamadas %, llamadas %, llamadas_vista_con_cal % (revertido)',
--     v_alias, v_cli_c, c_cal, c_cruza, c_llam, c_vista, v_vend, v_cli_s, s_cal, s_cruza, s_llam, s_vista;
-- end
-- $c4b$;

-- C5. Lo mismo como cliente/ventas/finanzas no cambio: ver los mismos numeros que antes
--     (fundador: total por cliente).
-- select cliente_id, count(*) filter (where estado = 'ok') as ok, count(*) filter (where estado = 'error') as error
--   from fin_leads_calificacion group by 1 order by 1;

-- =====================================================================
-- VUELTA ATRAS (borra solo la politica nueva; el front sin ella no ve columna)
-- =====================================================================
-- drop policy if exists fin_leads_calificacion_lectura_closer_setter on public.fin_leads_calificacion;
