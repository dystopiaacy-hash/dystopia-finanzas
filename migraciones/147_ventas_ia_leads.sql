-- =====================================================================
-- 147_ventas_ia_leads.sql
-- Ventas, IA: calificacion de leads (caliente / tibio / frio) con claude-haiku-5-5.
--
-- QUE HACE
--   1. fin_lead_clave(email, telefono, nombre): CLAVE ESTABLE de un lead. La sync
--      de Sheets borra y recrea las filas origen 'sheet' de fin_llamadas cada
--      15 min (ids nuevos), asi que la calificacion NO cuelga de fin_llamadas.id.
--      Clave = email en minuscula ('m:...'); si no hay, ultimos 10 digitos del
--      telefono ('t:...'); si no hay, nombre en minuscula y espacios colapsados
--      ('n:...'). Mismo criterio que la 115 (duplicadas). Va junto a cliente y
--      fecha_llamada: cada agenda es una calificacion.
--   2. fin_leads_calificacion: una fila por (cliente, fecha_llamada, clave_lead)
--      con nivel, puntaje 0-100 y motivo de una linea. Guarda la "huella" de las
--      respuestas que se le dieron al modelo: si cambian (formulario, nota del
--      setter, fuente) el lead se vuelve a calificar solo. Escribe solo
--      service_role (la Edge Function ventas-ia-leads).
--      Niveles: caliente 70-100, tibio 40-69, frio 0-39 (los fija un CHECK).
--   3. fin_ia_leads_candidatos / fin_ia_leads_pendientes: lo que lee la Edge
--      Function (solo service_role). Candidato = lead de los ultimos 45 dias, no
--      cancelado, con al menos una respuesta del formulario o nota del setter.
--      A la IA van SOLO datos de ANTES de la llamada: fuente, respuestas del
--      formulario y nota del setter. NO van estado, show up, cash, programa,
--      calificacion humana ni contexto del closer (serian filtrar el resultado).
--   4. fin_v_llamadas_calificadas: fin_llamadas + nivel / puntaje / motivo.
--      security_invoker: valen las politicas de fin_llamadas (la grilla Data
--      sigue viendo lo mismo que hoy) y las de fin_leads_calificacion.
--      La grilla la usa para la columna, el tooltip y el filtro.
--   5. Cron ventas_ia_leads: minutos 13 y 44 de cada hora (ART = UTC-3 fijo, sin
--      horario de verano: los minutos son los mismos en UTC). URL de la funcion
--      en Vault (ventas_ia_leads_url); clave: fin_sync_service_key.
--
-- QUIEN VE QUE: igual que la grilla Data (fin_data_puede_ver, 077): fundador,
--   cliente (solo el suyo), ventas y finanzas asignados. Escribe solo service_role.
--
-- NO TOCA fin_llamadas, la sync ni vistas de metricas. NO toca la 148.
--
-- ORDEN: bloques de a uno, fuera de :00/:15/:30/:45. El 3 (cron) solo DESPUES
-- de desplegar la Edge Function ventas-ia-leads:
--   supabase functions deploy ventas-ia-leads --no-verify-jwt
-- Sin begin/commit (SQL Editor). Idempotente.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (si algo falta, corta con un mensaje claro)
-- ---------------------------------------------------------------------
do $g$
declare v_falta text;
begin
  select string_agg(t, ', ') into v_falta
  from unnest(array['crm_clients', 'fin_llamadas', 'fin_formulario_preguntas', 'fin_fuentes', 'ia_uso']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception '147: faltan tablas: % (ia_uso es la migracion 137)', v_falta;
  end if;
  if to_regprocedure('public.fin_data_puede_ver(text)') is null then
    raise exception '147: falta fin_data_puede_ver(text) (migracion 077)';
  end if;
  select string_agg(c, ', ') into v_falta
  from unnest(array['fin_llamadas.email', 'fin_llamadas.telefono', 'fin_llamadas.nombre', 'fin_llamadas.tipo_booking',
                    'fin_llamadas.contexto_setter', 'fin_llamadas.formulario', 'fin_llamadas.campos_extra',
                    'fin_llamadas.origen', 'fin_llamadas.estado_agenda', 'fin_llamadas.hora_llamada',
                    'fin_formulario_preguntas.etiqueta', 'fin_formulario_preguntas.orden']) c
  where not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = split_part(c, '.', 1)
                       and column_name = split_part(c, '.', 2));
  if v_falta is not null then
    raise exception '147: faltan columnas: % (estado_agenda es de la 131)', v_falta;
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Clave, tabla, permisos, funciones y vista
-- ---------------------------------------------------------------------

-- 1. Clave estable del lead (misma idea que la 115).
create or replace function public.fin_lead_clave(p_email text, p_telefono text, p_nombre text)
returns text
language sql immutable
as $fn$
  select case
    when position('@' in btrim(coalesce(p_email, ''))) > 1
      then 'm:' || lower(btrim(p_email))
    when length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) >= 8
      then 't:' || right(regexp_replace(p_telefono, '\D', '', 'g'), 10)
    when length(regexp_replace(btrim(coalesce(p_nombre, '')), '\s+', ' ', 'g')) >= 4
         and btrim(p_nombre) ~ '[[:alpha:]]'
      then 'n:' || lower(regexp_replace(btrim(p_nombre), '\s+', ' ', 'g'))
  end
$fn$;
revoke all on function public.fin_lead_clave(text, text, text) from public, anon;
grant execute on function public.fin_lead_clave(text, text, text) to authenticated, service_role;

-- Quien puede ver una calificacion: igual que la grilla Data. Envoltura SECURITY
-- DEFINER para no depender de que authenticated tenga execute sobre fin_data_puede_ver.
create or replace function public.fin_leads_puede_ver(p_cliente text)
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.fin_data_puede_ver(p_cliente), false)
$fn$;
revoke all on function public.fin_leads_puede_ver(text) from public, anon;
grant execute on function public.fin_leads_puede_ver(text) to authenticated, service_role;

-- 2. Tabla propia: NO es una fila de fin_llamadas (la sync las recrea).
create table if not exists public.fin_leads_calificacion (
  cliente_id      text     not null references public.crm_clients(id) on delete cascade,
  fecha_llamada   date     not null,
  clave_lead      text     not null check (char_length(clave_lead) between 3 and 300),
  estado          text     not null check (estado in ('ok', 'error')),
  nivel           text     check (nivel is null or nivel in ('caliente', 'tibio', 'frio')),
  puntaje         smallint check (puntaje is null or puntaje between 0 and 100),
  motivo          text     check (motivo is null or char_length(motivo) <= 300),   -- ok: la razon; error: que fallo
  huella          text,                    -- md5 de lo que se le dio al modelo para el puntaje vigente
  huella_error    text,                    -- huella del ultimo intento fallido
  intentos        smallint not null default 0,   -- fallos seguidos con huella_error
  ultimo_intento  timestamptz,
  modelo          text,
  tokens_entrada  int,                     -- prorrateado del lote (el total exacto esta en ia_uso)
  tokens_salida   int,
  costo_usd       numeric(10,6),
  calificado_en   timestamptz,
  calificado_por  uuid,                    -- null = cron
  primary key (cliente_id, fecha_llamada, clave_lead),
  constraint fin_leads_calif_coherente_ck check (
    (estado = 'error' and nivel is null and puntaje is null)
    or (estado = 'ok' and huella is not null and nivel is not null and puntaje is not null and (
          (nivel = 'caliente' and puntaje >= 70)
       or (nivel = 'tibio'    and puntaje between 40 and 69)
       or (nivel = 'frio'     and puntaje <= 39)))
  )
);
create index if not exists fin_leads_calificacion_cliente_idx
  on public.fin_leads_calificacion (cliente_id, fecha_llamada desc);
comment on table public.fin_leads_calificacion is
  'Calificacion de IA de un lead (147): caliente/tibio/frio, puntaje 0-100 y motivo. Clave estable (cliente, fecha, fin_lead_clave): la sync de Sheets recrea fin_llamadas y no la toca.';

alter table public.fin_leads_calificacion enable row level security;
revoke all on table public.fin_leads_calificacion from anon, authenticated;
grant select on table public.fin_leads_calificacion to authenticated;
grant select, insert, update, delete on table public.fin_leads_calificacion to service_role;

drop policy if exists fin_leads_calificacion_lectura on public.fin_leads_calificacion;
create policy fin_leads_calificacion_lectura on public.fin_leads_calificacion for select to authenticated
  using (public.fin_leads_puede_ver(cliente_id));

-- 3. Candidatos: un lead por (cliente, fecha, clave) con lo que se le da al modelo.
--    p_llamada <> null: solo ese lead, sin filtro de fecha ni de respuestas (boton "Recalcular").
create or replace function public.fin_ia_leads_candidatos(p_dias integer default 45, p_llamada bigint default null)
returns table (cliente_id text, fecha_llamada date, clave_lead text, llamada_id bigint, datos jsonb, huella text)
language sql stable security definer set search_path = public
as $fn$
  with base as (
    select l.id, l.cliente_id, l.fecha_llamada,
           public.fin_lead_clave(l.email, l.telefono, l.nombre) as clave,
           nullif(btrim(coalesce(l.tipo_booking, '')), '') as fuente,
           nullif(btrim(coalesce(l.contexto_setter, '')), '') as ctx,
           l.formulario
      from public.fin_llamadas l
     where case when p_llamada is not null then l.id = p_llamada
                else l.fecha_llamada >= current_date - greatest(coalesce(p_dias, 45), 1)
                     and coalesce(l.estado_agenda, '') <> 'cancelada' end
  ), resp as (
    select b.id,
           coalesce(jsonb_agg(jsonb_build_object('pregunta', coalesce(q.etiqueta, e.k), 'respuesta', left(e.v, 500))
                              order by coalesce(q.orden, 9999), e.k)
                    filter (where e.v is not null and e.v not in ('', 'null')), '[]'::jsonb) as respuestas
      from base b
      left join lateral (
        select x.key as k,
               btrim(case when jsonb_typeof(x.value) = 'string' then x.value #>> '{}' else x.value::text end) as v
          from jsonb_each(case when jsonb_typeof(b.formulario) = 'object' then b.formulario else '{}'::jsonb end) x
      ) e on true
      left join public.fin_formulario_preguntas q on q.cliente_id = b.cliente_id and q.clave = e.k
     group by b.id
  ), listo as (
    select b.id, b.cliente_id, b.fecha_llamada, b.clave,
           jsonb_strip_nulls(jsonb_build_object('fuente', b.fuente, 'contexto_setter', left(b.ctx, 600),
                                                'respuestas', r.respuestas)) as datos,
           (jsonb_array_length(r.respuestas) + (b.ctx is not null)::int) as cuanto
      from base b join resp r on r.id = b.id
  )
  select distinct on (x.cliente_id, x.fecha_llamada, x.clave)
         x.cliente_id, x.fecha_llamada, x.clave, x.id, x.datos, md5(x.datos::text)
    from listo x
   where x.clave is not null and (p_llamada is not null or x.cuanto > 0)
   order by x.cliente_id, x.fecha_llamada, x.clave, x.cuanto desc, x.id desc
$fn$;

-- Pendientes: sin calificacion, o con respuestas distintas a las del puntaje vigente.
-- Un fallo con las mismas respuestas se reintenta a la hora y hasta 3 veces seguidas.
-- Los mas nuevos primero.
create or replace function public.fin_ia_leads_pendientes(p_max integer default 20, p_dias integer default 45)
returns table (cliente_id text, fecha_llamada date, clave_lead text, llamada_id bigint, datos jsonb, huella text)
language sql stable security definer set search_path = public
as $fn$
  select k.cliente_id, k.fecha_llamada, k.clave_lead, k.llamada_id, k.datos, k.huella
    from public.fin_ia_leads_candidatos(p_dias, null) k
    left join public.fin_leads_calificacion c
      on c.cliente_id = k.cliente_id and c.fecha_llamada = k.fecha_llamada and c.clave_lead = k.clave_lead
   where c.cliente_id is null
      or (c.huella is distinct from k.huella
          and (c.huella_error is distinct from k.huella
               or (c.intentos < 3 and c.ultimo_intento < now() - interval '1 hour')))
   order by k.fecha_llamada desc, k.cliente_id, k.clave_lead
   limit greatest(coalesce(p_max, 20), 1)
$fn$;

do $perm$
declare f text;
begin
  foreach f in array array['fin_ia_leads_candidatos(integer,bigint)', 'fin_ia_leads_pendientes(integer,integer)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end
$perm$;

-- 4. Vista para la grilla: fin_llamadas + calificacion. Columnas EXPLICITAS (las de
--    DATA_COLS del front) para que una columna nueva de fin_llamadas no cambie la vista sola.
create or replace view public.fin_v_llamadas_calificadas with (security_invoker = true) as
select l.id, l.cliente_id, l.fecha_llamada, l.hora_llamada, l.nombre, l.closer, l.tipo_booking, l.show_up,
       l.calificacion, l.estado_llamada, l.programa, l.cc_dia1, l.cc_cerrado, l.cc_seguimiento, l.monto_restante,
       l.telefono, l.instagram, l.email, l.contexto_setter, l.contexto_closer, l.formulario, l.campos_extra,
       l.origen, l.estado_agenda,
       c.nivel as cal_nivel, c.puntaje as cal_puntaje, c.motivo as cal_motivo, c.calificado_en as cal_en
  from public.fin_llamadas l
  left join public.fin_leads_calificacion c
    on c.cliente_id = l.cliente_id and c.fecha_llamada = l.fecha_llamada
   and c.clave_lead = public.fin_lead_clave(l.email, l.telefono, l.nombre)
   and c.nivel is not null;

revoke all on public.fin_v_llamadas_calificadas from anon, authenticated;
grant select on public.fin_v_llamadas_calificadas to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. PRUEBA DE HUMO (se revierte sola: termina en una excepcion
--           "HUMO OK ..."; si algo falla dice "HUMO FALLO ..." y tambien
--           revierte). Usa el cliente liam y mails @example.com.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_fuente bigint;
  v_a      bigint;
  v_b      bigint;
  v_c      bigint;
  v_h1     text;
  v_h2     text;
  v_n      integer;
  v_r      jsonb;
  v_niv    text;
  v_clave  text := 'm:humo147a@example.com';
begin
  select id into v_fuente from public.fin_fuentes where cliente_id = 'liam' and tipo = 'data' limit 1;
  if v_fuente is null then raise exception 'HUMO FALLO: liam no tiene fuente data'; end if;

  -- clave estable
  if public.fin_lead_clave('  HUMO147@Example.com ', null, null) is distinct from 'm:humo147@example.com' then
    raise exception 'HUMO FALLO 1: clave por mail'; end if;
  if public.fin_lead_clave(null, '+54 9 11 5555-1234', null) is distinct from 't:1155551234' then
    raise exception 'HUMO FALLO 2: clave por telefono'; end if;
  if public.fin_lead_clave(null, '#ERROR!', 'Juan  Perez') is distinct from 'n:juan perez' then
    raise exception 'HUMO FALLO 3: clave por nombre'; end if;
  if public.fin_lead_clave(null, '123', 'Jo') is not null then raise exception 'HUMO FALLO 4: clave de un lead sin datos'; end if;

  -- A: con respuestas y nota del setter. A2: la misma persona, sin respuestas. B: sin respuestas. C: con respuestas pero cancelada.
  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, email, origen, formulario, contexto_setter, tipo_booking)
  values ('liam', v_fuente, null, current_date, 'PRUEBA CLOSER', 'PRUEBA 147 A', 'humo147a@example.com', 'app',
          '{"edad":"30","objetivo_consultoria":"Invertir mejor"}'::jsonb, 'Muy interesado', 'INSTAGRAM')
  returning id into v_a;
  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, email, origen)
  values ('liam', v_fuente, null, current_date, 'PRUEBA CLOSER', 'PRUEBA 147 A', 'humo147a@example.com', 'app');
  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, email, origen)
  values ('liam', v_fuente, null, current_date, 'PRUEBA CLOSER', 'PRUEBA 147 B', 'humo147b@example.com', 'app')
  returning id into v_b;
  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, email, origen, formulario, estado_agenda)
  values ('liam', v_fuente, null, current_date, 'PRUEBA CLOSER', 'PRUEBA 147 C', 'humo147c@example.com', 'app',
          '{"edad":"40"}'::jsonb, 'cancelada')
  returning id into v_c;

  -- candidatos: solo A, una vez, con 2 respuestas
  select count(*) into v_n from public.fin_ia_leads_candidatos(45, null) where clave_lead like 'm:humo147%';
  if v_n <> 1 then raise exception 'HUMO FALLO 5: se esperaba 1 candidato (A) y hay %', v_n; end if;
  select datos, huella into v_r, v_h1 from public.fin_ia_leads_candidatos(45, null) where clave_lead = v_clave;
  if jsonb_array_length(v_r -> 'respuestas') <> 2 or v_r ->> 'contexto_setter' is distinct from 'Muy interesado'
     or v_r ->> 'fuente' is distinct from 'INSTAGRAM' then
    raise exception 'HUMO FALLO 6: datos de A mal armados (%)', v_r; end if;
  if v_r::text ~* 'closer|show_up|cc_|programa|estado' then raise exception 'HUMO FALLO 7: los datos de A traen campos de despues de la llamada'; end if;
  -- forzado: B (sin respuestas) y C (cancelada) salen si se piden por id
  if (select count(*) from public.fin_ia_leads_candidatos(null, v_b)) <> 1
     or (select count(*) from public.fin_ia_leads_candidatos(null, v_c)) <> 1 then
    raise exception 'HUMO FALLO 8: el pedido por llamada_id no devolvio B y C'; end if;

  -- pendientes: A esta; calificado y con las mismas respuestas, ya no
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 1 then raise exception 'HUMO FALLO 9: A deberia estar pendiente (%)', v_n; end if;
  insert into public.fin_leads_calificacion (cliente_id, fecha_llamada, clave_lead, estado, nivel, puntaje, motivo, huella, calificado_en)
  values ('liam', current_date, v_clave, 'ok', 'caliente', 82, 'prueba', v_h1, now());
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 0 then raise exception 'HUMO FALLO 10: A calificado sigue pendiente'; end if;

  -- la vista encuentra la calificacion por la clave, no por el id
  select cal_nivel into v_niv from public.fin_v_llamadas_calificadas where id = v_a;
  if v_niv is distinct from 'caliente' then raise exception 'HUMO FALLO 11: la vista no trajo el nivel de A (%)', v_niv; end if;
  if (select cal_nivel from public.fin_v_llamadas_calificadas where id = v_b) is not null then
    raise exception 'HUMO FALLO 12: B no deberia tener nivel'; end if;

  -- cambian las respuestas: huella nueva y vuelve a quedar pendiente
  update public.fin_llamadas set formulario = formulario || '{"profesion":"Medico"}'::jsonb where id = v_a;
  select huella into v_h2 from public.fin_ia_leads_candidatos(45, null) where clave_lead = v_clave;
  if v_h2 is not distinct from v_h1 then raise exception 'HUMO FALLO 13: la huella no cambio'; end if;
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 1 then raise exception 'HUMO FALLO 14: A con respuestas nuevas deberia estar pendiente'; end if;

  -- reintentos: un fallo reciente espera 1 hora; a las 3 fallas seguidas con las mismas respuestas, no reintenta
  update public.fin_leads_calificacion set huella_error = v_h2, intentos = 1, ultimo_intento = now()
   where cliente_id = 'liam' and fecha_llamada = current_date and clave_lead = v_clave;
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 0 then raise exception 'HUMO FALLO 15: un fallo de recien no deberia reintentarse'; end if;
  update public.fin_leads_calificacion set ultimo_intento = now() - interval '2 hours'
   where cliente_id = 'liam' and fecha_llamada = current_date and clave_lead = v_clave;
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 1 then raise exception 'HUMO FALLO 16: un fallo de hace 2 horas deberia reintentarse'; end if;
  update public.fin_leads_calificacion set intentos = 3
   where cliente_id = 'liam' and fecha_llamada = current_date and clave_lead = v_clave;
  select count(*) into v_n from public.fin_ia_leads_pendientes(1000, 45) where clave_lead = v_clave;
  if v_n <> 0 then raise exception 'HUMO FALLO 17: 3 fallos seguidos no deberian reintentarse'; end if;

  -- CHECKs: nivel incoherente con el puntaje y "ok" sin nivel se rechazan
  begin
    insert into public.fin_leads_calificacion (cliente_id, fecha_llamada, clave_lead, estado, nivel, puntaje, huella)
    values ('liam', current_date, 'm:humo147x@example.com', 'ok', 'caliente', 30, 'x');
    raise exception 'HUMO FALLO 18: acepto caliente con puntaje 30';
  exception when check_violation then null;
  end;
  begin
    insert into public.fin_leads_calificacion (cliente_id, fecha_llamada, clave_lead, estado, huella)
    values ('liam', current_date, 'm:humo147y@example.com', 'ok', 'x');
    raise exception 'HUMO FALLO 19: acepto ok sin nivel';
  exception when check_violation then null;
  end;

  -- sin sesion nadie ve nada
  if public.fin_leads_puede_ver('liam') then raise exception 'HUMO FALLO 20: fin_leads_puede_ver da true sin sesion'; end if;

  raise exception 'HUMO OK: 20 pruebas pasaron (clave estable, candidatos, datos sin resultado, pendientes, huella, reintentos, vista, CHECKs, permisos). Se revirtio todo.';
end
$humo$;
-- Resultado esperado: ERROR "HUMO OK: ...". Cualquier "HUMO FALLO" = avisar.

-- ---------------------------------------------------------------------
-- BLOQUE 3. Cron. Correr DESPUES de desplegar ventas-ia-leads
--           (supabase functions deploy ventas-ia-leads --no-verify-jwt)
--   ventas_ia_leads : minutos 13 y 44 de cada hora (13,44 * * * *). pg_cron corre en UTC;
--                     Argentina es UTC-3 fijo, asi que los minutos son los mismos.
--                     No choca con 131 (11,26,43,56) ni con 142 (24,38,52).
-- ---------------------------------------------------------------------
do $v$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'fin_sync_service_key') then
    raise exception '147: falta el secreto fin_sync_service_key en Vault (ver 004_cron.sql, paso 0)';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'ventas_ia_leads_url') then
    perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ventas-ia-leads', 'ventas_ia_leads_url');
  end if;
end
$v$;

select cron.unschedule(jobid) from cron.job where jobname = 'ventas_ia_leads';

select cron.schedule('ventas_ia_leads', '13,44 * * * *',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'ventas_ia_leads_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_service_key')),
      body    := '{"accion":"procesar"}'::jsonb,
      timeout_milliseconds := 150000
    );
  $cron$);

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. La tabla (con RLS), la vista y las 4 funciones existen: 6 filas.
-- select c.relname, c.relkind::text as tipo, c.relrowsecurity as rls
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public' and c.relname in ('fin_leads_calificacion', 'fin_v_llamadas_calificadas') order by 1;
-- select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('fin_lead_clave','fin_leads_puede_ver','fin_ia_leads_candidatos','fin_ia_leads_pendientes') order by 1;

-- C2. Permisos: las dos de la Edge Function solo para service_role (authenticated = false); 4 filas.
-- select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('fin_lead_clave','fin_leads_puede_ver','fin_ia_leads_candidatos','fin_ia_leads_pendientes')
--  order by 1;

-- C3. El humo no dejo nada: 0 | 0.
-- select (select count(*) from fin_llamadas where nombre like 'PRUEBA 147%') as llamadas_prueba,
--        (select count(*) from fin_leads_calificacion where clave_lead like 'm:humo147%') as calificaciones_prueba;

-- C4. La grilla sigue igual: la vista devuelve las mismas filas que la tabla (diferencia 0).
-- select (select count(*) from fin_llamadas) - (select count(*) from fin_v_llamadas_calificadas) as diferencia;

-- C5. Cuantos leads hay por calificar (ultimos 45 dias) y de que clientes; la primera pasada del cron
--     califica hasta 30 por corrida, asi que 200 pendientes son unas 7 corridas (3 horas y media).
-- select cliente_id, count(*) as pendientes from fin_ia_leads_pendientes(100000, 45) group by 1 order by 1;

-- C6. Cron programado: 1 fila, activo = true, schedule 13,44 * * * *; y el secreto de la URL.
-- select jobname, schedule, active from cron.job where jobname = 'ventas_ia_leads';
-- select name from vault.decrypted_secrets where name = 'ventas_ia_leads_url';

-- C7. Despues de unas horas: reparto de niveles, errores y gasto (ia_uso).
-- select cliente_id, estado, nivel, count(*), round(avg(puntaje)) as puntaje_prom
--   from fin_leads_calificacion group by 1, 2, 3 order by 1, 2, 3;
-- select cliente_id, motivo, intentos, ultimo_intento from fin_leads_calificacion where estado = 'error' order by ultimo_intento desc limit 10;
-- select funcion, count(*) as llamadas, round(sum(costo_usd), 4) as usd, count(*) filter (where not ok) as con_error
--   from ia_uso where app = 'ventas' and funcion = 'calificacion_leads' and creado_en > now() - interval '7 days' group by 1;
-- select status::text, return_message, start_time from cron.job_run_details
--  where jobid in (select jobid from cron.job where jobname = 'ventas_ia_leads') order by start_time desc limit 6;

-- C8. Sanidad de la calificacion: a mano, 10 leads con sus respuestas y lo que puso la IA (revisar que tenga sentido).
-- select c.cliente_id, c.fecha_llamada, c.nivel, c.puntaje, c.motivo, l.formulario, l.contexto_setter
--   from fin_leads_calificacion c
--   join fin_llamadas l on l.cliente_id = c.cliente_id and l.fecha_llamada = c.fecha_llamada
--    and fin_lead_clave(l.email, l.telefono, l.nombre) = c.clave_lead
--  where c.estado = 'ok' order by c.calificado_en desc limit 10;

-- =====================================================================
-- VUELTA ATRAS (en este orden; borra solo las calificaciones, no toca fin_llamadas)
-- =====================================================================
-- select cron.unschedule(jobid) from cron.job where jobname = 'ventas_ia_leads';
-- delete from vault.secrets where name = 'ventas_ia_leads_url';
-- drop view if exists public.fin_v_llamadas_calificadas;
-- drop function if exists public.fin_ia_leads_pendientes(integer, integer);
-- drop function if exists public.fin_ia_leads_candidatos(integer, bigint);
-- drop table if exists public.fin_leads_calificacion;
-- drop function if exists public.fin_leads_puede_ver(text);
-- drop function if exists public.fin_lead_clave(text, text, text);
-- (El front sin la vista vuelve solo a leer fin_llamadas: la columna y el filtro desaparecen.)
