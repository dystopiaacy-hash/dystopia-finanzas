-- 109_alertas_cobros_dos_horarios.sql — Dystopia Finanzas: la alerta de cobros sale DOS veces por dia.
--
-- Hoy (103): un solo aviso por cliente y por dia, a la hora fin_alertas_cobros_config.hora_envio (9).
-- Ahora: un segundo horario opcional por cliente, hora_envio_2 (null = sin segundo aviso). liam, agus y teo
-- quedan con 9 y 21 (hora de Argentina). No cambia activo ni mostrar_montos.
--
-- Turnos: turno 1 = hora_envio, turno 2 = hora_envio_2. Cada turno se controla aparte en
-- fin_alertas_cobros_log (columna nueva turno; las filas que ya existian quedan como turno 1):
--   - un turno entregado (o esperando respuesta de Discord) no se vuelve a mandar el mismo dia;
--   - los reintentos (maximo 3 fallidos) se cuentan por turno;
--   - si el de las 9 salio, el de las 21 sale igual (son turnos distintos).
-- Regla "uno solo": en cada pasada del cron el cliente tiene como mucho UN turno a mandar: el ultimo cuya
-- hora ya paso. Si a las 21:05 el turno 1 nunca salio, NO se manda tarde junto con el 2: sale solo el 2.
-- (fin_alertas_cobros_turno() es esa regla.) Es sin estado: no escribe filas "salteadas" en el log.
--
-- Pisa (con respaldo de la definicion vieja en fin_funciones_bak_109, solo postgres):
--   fin_alertas_cobros_enviar, fin_alertas_cobros_confirmar, fin_alertas_cobros_estado,
--   fin_alertas_cobros_vista_previa y fin_alertas_cobros_config_guardar (la firma de 4 argumentos se borra
--   y queda la de 5, con p_hora_2). NO toca fin_alertas_cobros_armar (texto), el cron, Vault ni el resto.
-- Agrega: columnas hora_envio_2, ultimo_envio_2, ultimo_resultado_2 (config) y turno (log), la funcion
--   fin_alertas_cobros_turno y un indice. No borra datos.
--
-- Orden de despliegue: correr esta migracion ANTES de publicar el front (el front nuevo llama a
-- config_guardar con p_hora_2). Con el front viejo y esta migracion, guardar desde Alertas deja el segundo
-- horario en null (apagado). No correr a las :00/:15/:30/:45 ni a las 9:00 (sync) ni a las :05 (cron).
--
-- Requiere 103. Idempotente (el respaldo se toma una sola vez, de lo que dejo la 103; el "9 y 21" se carga una
-- sola vez, cuando se crea la columna hora_envio_2).
-- OJO con la hora: si se corre un dia despues de las 21:00, en el :05 siguiente sale el turno 2 de ESE dia para
-- los clientes activos (el log viejo es todo turno 1). Para que no salga nada esa noche: correr entre 23:06 y 23:59.

begin;

do $$
begin
  if to_regclass('public.fin_alertas_cobros_config') is null or to_regclass('public.fin_alertas_cobros_log') is null then
    raise exception '109 ABORTADA: falta la 103 (fin_alertas_cobros_config / fin_alertas_cobros_log)';
  end if;
  if to_regprocedure('public.fin_alertas_cobros_armar(text, timestamptz, boolean, boolean)') is null
     or to_regprocedure('public.fin_alertas_cobros_enviar(timestamptz, boolean)') is null then
    raise exception '109 ABORTADA: faltan funciones de la 103';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Respaldo de las definiciones que se pisan (una sola vez)
-- ---------------------------------------------------------------------------
create table if not exists public.fin_funciones_bak_109 (
  objeto     text primary key,
  definicion text not null,
  creado     timestamptz not null default now()
);
alter table public.fin_funciones_bak_109 enable row level security;
revoke all on table public.fin_funciones_bak_109 from public, anon, authenticated, service_role;
comment on table public.fin_funciones_bak_109 is
  '109: definiciones de las funciones de alertas de cobros tal como las dejo la 103, antes de pasar a dos horarios. Solo postgres.';

insert into public.fin_funciones_bak_109 (objeto, definicion)
select p.oid::regprocedure::text, pg_get_functiondef(p.oid)
from pg_proc p
where p.oid in (
  to_regprocedure('public.fin_alertas_cobros_enviar(timestamptz, boolean)'),
  to_regprocedure('public.fin_alertas_cobros_confirmar(timestamptz)'),
  to_regprocedure('public.fin_alertas_cobros_estado()'),
  to_regprocedure('public.fin_alertas_cobros_vista_previa(text, boolean)'),
  to_regprocedure('public.fin_alertas_cobros_config_guardar(text, boolean, integer, boolean)'))
on conflict (objeto) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Columnas
-- ---------------------------------------------------------------------------
-- CORRECCION (revision del 13/10): el "9 y 21" de liam, agus y teo se carga SOLO la vez que se crea la columna
-- hora_envio_2. Antes era un UPDATE suelto (hora_envio_2 is null and hora_envio = 9) que en una re-corrida
-- posterior volvia a prender el segundo aviso de un cliente al que el fundador se lo habia apagado desde la app.
do $$
declare
  v_nueva boolean := not exists (select 1 from pg_attribute
                                 where attrelid = 'public.fin_alertas_cobros_config'::regclass
                                   and attname = 'hora_envio_2' and not attisdropped);
begin
  alter table public.fin_alertas_cobros_config
    add column if not exists hora_envio_2       smallint,
    add column if not exists ultimo_envio_2     timestamptz,
    add column if not exists ultimo_resultado_2 text;
  if v_nueva then
    -- Los tres clientes con alerta: 9 y 21. No cambia activo ni mostrar_montos.
    update public.fin_alertas_cobros_config
    set hora_envio_2 = 21, actualizado = now()
    where cliente_id in ('liam', 'agus', 'teo') and hora_envio_2 is null and hora_envio = 9;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.fin_alertas_cobros_config'::regclass
                 and conname = 'fin_alertas_cobros_config_hora2_chk') then
    alter table public.fin_alertas_cobros_config add constraint fin_alertas_cobros_config_hora2_chk
      check (hora_envio_2 is null or (hora_envio_2 between 6 and 22 and hora_envio_2 <> hora_envio));
  end if;
end $$;
comment on column public.fin_alertas_cobros_config.hora_envio_2 is
  '109: segundo horario del dia (hora de Argentina, 6 a 22, distinto de hora_envio). null = sin segundo aviso.';

-- Filas existentes: turno 1 (el default las cubre).
alter table public.fin_alertas_cobros_log add column if not exists turno smallint not null default 1;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.fin_alertas_cobros_log'::regclass
                 and conname = 'fin_alertas_cobros_log_turno_chk') then
    alter table public.fin_alertas_cobros_log add constraint fin_alertas_cobros_log_turno_chk
      check (turno in (1, 2));
  end if;
end $$;
comment on column public.fin_alertas_cobros_log.turno is
  '109: 1 = hora_envio, 2 = hora_envio_2. Las filas anteriores a la 109 son turno 1.';
create index if not exists fin_alertas_cobros_log_cliente_fecha_turno_idx
  on public.fin_alertas_cobros_log (cliente_id, fecha, turno);

-- ---------------------------------------------------------------------------
-- 3. Que turno toca en una hora dada (la regla "uno solo")
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_cobros_turno(p_h1 int, p_h2 int, p_hora int)
returns smallint
language sql
immutable
set search_path = ''
as $$
  select case
    when p_h2 is not null and p_h2 <= p_hora and (p_h1 > p_hora or p_h2 > p_h1) then 2::smallint
    when p_h1 <= p_hora then 1::smallint
  end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Confirmacion (mira la respuesta de Discord) y envio, por turno
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_cobros_confirmar(p_ahora timestamptz default now())
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r      record;
  v_ok   int;
  v_resp int;
  v_n    int := 0;
begin
  for r in
    select l.id, l.cliente_id, l.turno, l.creado, l.request_ids
    from public.fin_alertas_cobros_log l
    where l.entregado is null and cardinality(l.request_ids) > 0
    order by l.id
  loop
    select count(*) filter (where h.status_code between 200 and 299), count(*)
      into v_ok, v_resp
    from net._http_response h where h.id = any (r.request_ids);

    if v_ok = cardinality(r.request_ids) then
      update public.fin_alertas_cobros_log set entregado = true where id = r.id;
      update public.fin_alertas_cobros_config
      set ultimo_resultado   = case when r.turno = 1 then 'enviado' else ultimo_resultado end,
          ultimo_resultado_2 = case when r.turno = 2 then 'enviado' else ultimo_resultado_2 end,
          actualizado = p_ahora
      where cliente_id = r.cliente_id;
      v_n := v_n + 1;
    elsif v_resp = cardinality(r.request_ids) or r.creado < p_ahora - interval '30 minutes' then
      update public.fin_alertas_cobros_log set entregado = false where id = r.id;
      update public.fin_alertas_cobros_config
      set ultimo_resultado   = case when r.turno = 1 then 'falló, se reintenta' else ultimo_resultado end,
          ultimo_resultado_2 = case when r.turno = 2 then 'falló, se reintenta' else ultimo_resultado_2 end,
          actualizado = p_ahora
      where cliente_id = r.cliente_id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- p_enviar = false: arma lo que se mandaria (con el turno) y lo devuelve, sin postear ni escribir el log.
create or replace function public.fin_alertas_cobros_enviar(p_ahora timestamptz default now(), p_enviar boolean default true)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_hoy  date := (p_ahora at time zone 'America/Argentina/Buenos_Aires')::date;
  v_hora int  := extract(hour from (p_ahora at time zone 'America/Argentina/Buenos_Aires'))::int;
  r      record;
  v_a    jsonb;
  v_url  text;
  v_ids  bigint[];
  v_m    text;
  v_res  jsonb := '[]'::jsonb;
begin
  if p_enviar then perform public.fin_alertas_cobros_confirmar(p_ahora); end if;

  for r in
    select c.cliente_id, t.turno
    from public.fin_alertas_cobros_config c
    cross join lateral (select public.fin_alertas_cobros_turno(c.hora_envio, c.hora_envio_2, v_hora) as turno) t
    where c.activo
      and t.turno is not null
      and not exists (select 1 from public.fin_alertas_cobros_log l
                      where l.cliente_id = c.cliente_id and l.fecha = v_hoy and l.turno = t.turno
                        and l.entregado is not false)
      and (select count(*) from public.fin_alertas_cobros_log l
           where l.cliente_id = c.cliente_id and l.fecha = v_hoy and l.turno = t.turno
             and l.entregado is false) < 3
    order by c.cliente_id
  loop
    select s.decrypted_secret into v_url
    from vault.decrypted_secrets s
    where s.name in ('fin_discord_webhook_cobros_' || r.cliente_id, 'fin_discord_webhook_cobros')
      and nullif(btrim(s.decrypted_secret), '') is not null
    order by (s.name = 'fin_discord_webhook_cobros') limit 1;

    if v_url is null then
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'turno', r.turno, 'resultado', 'sin_webhook');
      if p_enviar then
        update public.fin_alertas_cobros_config
        set ultimo_resultado   = case when r.turno = 1 then 'sin webhook en Vault' else ultimo_resultado end,
            ultimo_resultado_2 = case when r.turno = 2 then 'sin webhook en Vault' else ultimo_resultado_2 end,
            actualizado = p_ahora
        where cliente_id = r.cliente_id;
      end if;
      continue;
    end if;

    v_a := public.fin_alertas_cobros_armar(r.cliente_id, p_ahora);

    if not p_enviar then
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'turno', r.turno, 'resultado', 'vista previa',
        'cuentas', v_a -> 'cuentas', 'mensajes', v_a -> 'mensajes');
      continue;
    end if;

    if jsonb_array_length(v_a -> 'mensajes') = 0 then
      insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
      values (r.cliente_id, v_hoy, r.turno, v_a -> 'cuentas', 0, true);
      update public.fin_alertas_cobros_config
      set ultimo_resultado   = case when r.turno = 1 then 'sin cobros para avisar' else ultimo_resultado end,
          ultimo_resultado_2 = case when r.turno = 2 then 'sin cobros para avisar' else ultimo_resultado_2 end,
          actualizado = p_ahora
      where cliente_id = r.cliente_id;
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'turno', r.turno, 'resultado', 'sin_cobros');
      continue;
    end if;

    v_ids := '{}';
    for v_m in select jsonb_array_elements_text(v_a -> 'mensajes') loop
      v_ids := v_ids || public.fin_cobros_post(v_url, v_m);
    end loop;
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, textos, request_ids)
    values (r.cliente_id, v_hoy, r.turno, v_a -> 'cuentas', jsonb_array_length(v_a -> 'mensajes'), v_a -> 'mensajes', v_ids);
    update public.fin_alertas_cobros_config
    set ultimo_envio       = case when r.turno = 1 then p_ahora else ultimo_envio end,
        ultimo_resultado   = case when r.turno = 1 then 'enviado, esperando confirmación' else ultimo_resultado end,
        ultimo_envio_2     = case when r.turno = 2 then p_ahora else ultimo_envio_2 end,
        ultimo_resultado_2 = case when r.turno = 2 then 'enviado, esperando confirmación' else ultimo_resultado_2 end,
        actualizado = p_ahora
    where cliente_id = r.cliente_id;
    v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'turno', r.turno, 'resultado', 'enviado',
      'mensajes', jsonb_array_length(v_a -> 'mensajes'));
  end loop;
  return v_res;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Funciones para la app (solo fundador)
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_cobros_estado()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.es_fundador()) then raise exception 'Solo el fundador ve las alertas.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'cliente_id', c.cliente_id,
             'nombre', k.nombre,
             'activo', c.activo,
             'hora_envio', c.hora_envio,
             'hora_envio_2', c.hora_envio_2,
             'dias_atraso_alto', c.dias_atraso_alto,
             'mostrar_montos', c.mostrar_montos,
             'ultimo_envio', c.ultimo_envio,
             'ultimo_resultado', c.ultimo_resultado,
             'ultimo_envio_2', c.ultimo_envio_2,
             'ultimo_resultado_2', c.ultimo_resultado_2,
             'tiene_webhook', exists (select 1 from vault.decrypted_secrets s
                                      where s.name in ('fin_discord_webhook_cobros_' || c.cliente_id, 'fin_discord_webhook_cobros')))
           order by c.cliente_id)
    from public.fin_alertas_cobros_config c
    left join public.crm_clients k on k.id = c.cliente_id), '[]'::jsonb);
end $$;

-- La firma de 4 argumentos de la 103 se reemplaza por la de 5 (p_hora_2 null = segundo aviso apagado).
drop function if exists public.fin_alertas_cobros_config_guardar(text, boolean, int, boolean);

create or replace function public.fin_alertas_cobros_config_guardar(
  p_cliente text, p_activo boolean, p_hora int, p_montos boolean, p_hora_2 int default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select public.es_fundador()) then raise exception 'Solo el fundador cambia las alertas.'; end if;
  if p_hora is null or p_hora not between 6 and 22 then
    raise exception 'La hora del primer aviso tiene que estar entre 6 y 22.';
  end if;
  if p_hora_2 is not null and p_hora_2 not between 6 and 22 then
    raise exception 'La hora del segundo aviso tiene que estar entre 6 y 22.';
  end if;
  if p_hora_2 is not null and p_hora_2 = p_hora then
    raise exception 'Los dos avisos no pueden tener la misma hora.';
  end if;
  update public.fin_alertas_cobros_config
  set activo = p_activo, hora_envio = p_hora, hora_envio_2 = p_hora_2, mostrar_montos = p_montos, actualizado = now()
  where cliente_id = p_cliente;
  if not found then raise exception 'El cliente % no tiene alerta de cobros configurada.', p_cliente; end if;
end $$;

-- Lo que se mandaria hoy, SIN enviar y sin escribir nada. Suma los horarios y el turno que tocaria a esta hora.
create or replace function public.fin_alertas_cobros_vista_previa(p_cliente text, p_semana boolean default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_h1   smallint;
  v_h2   smallint;
  v_hora int := extract(hour from (now() at time zone 'America/Argentina/Buenos_Aires'))::int;
begin
  if not (select public.es_fundador()) then raise exception 'Solo el fundador ve la vista previa.'; end if;
  select c.hora_envio, c.hora_envio_2 into v_h1, v_h2
  from public.fin_alertas_cobros_config c where c.cliente_id = p_cliente;
  return public.fin_alertas_cobros_armar(p_cliente, now(), p_semana, null)
    || jsonb_build_object('hora_envio', v_h1, 'hora_envio_2', v_h2,
                          'turno_ahora', public.fin_alertas_cobros_turno(v_h1, v_h2, v_hora));
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'fin_alertas_cobros_turno(integer, integer, integer)',
    'fin_alertas_cobros_confirmar(timestamptz)',
    'fin_alertas_cobros_enviar(timestamptz, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array[
    'fin_alertas_cobros_estado()',
    'fin_alertas_cobros_config_guardar(text, boolean, integer, boolean, integer)',
    'fin_alertas_cobros_vista_previa(text, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Prueba de humo (se autorrevierte, NO manda nada ni deja filas)
-- Usa liam con fechas de 2030 (sin filas reales) y p_enviar = false.
-- ---------------------------------------------------------------------------
do $$
declare
  v_t text;
  v_d date;
begin
  begin
    if not exists (select 1 from public.fin_alertas_cobros_config where cliente_id = 'liam') then
      raise exception 'smoke 109: liam no tiene fila en fin_alertas_cobros_config';
    end if;
    update public.fin_alertas_cobros_config
    set activo = true, hora_envio = 9, hora_envio_2 = 21 where cliente_id = 'liam';

    -- la regla pura
    if public.fin_alertas_cobros_turno(9, 21, 8) is not null then raise exception 'smoke 109: 8h deberia no tocar'; end if;
    if public.fin_alertas_cobros_turno(9, 21, 10) <> 1 then raise exception 'smoke 109: 10h deberia ser turno 1'; end if;
    if public.fin_alertas_cobros_turno(9, 21, 21) <> 2 then raise exception 'smoke 109: 21h deberia ser turno 2'; end if;
    if public.fin_alertas_cobros_turno(9, null, 21) <> 1 then raise exception 'smoke 109: sin segundo horario es turno 1'; end if;
    if public.fin_alertas_cobros_turno(21, 9, 22) <> 1 then raise exception 'smoke 109: horas cruzadas, 22h es el de hora_envio=21'; end if;

    -- dia limpio (15/01/2030)
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 08:00:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is not null then raise exception 'smoke 109: a las 8 no toca nada, dio %', v_t; end if;
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 10:00:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '1' then raise exception 'smoke 109: a las 10 toca el turno 1, dio %', v_t; end if;
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '2' then raise exception 'smoke 109: a las 21:30 sin turno 1 sale SOLO el 2, dio %', v_t; end if;

    -- el turno 1 ya entregado: a las 10 nada, a las 21:30 sale el 2
    v_d := date '2030-01-15';
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
    values ('liam', v_d, 1, '{}'::jsonb, 1, true);
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 10:00:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is not null then raise exception 'smoke 109: turno 1 ya entregado no se repite, dio %', v_t; end if;
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '2' then raise exception 'smoke 109: con el 1 entregado el 2 sale igual, dio %', v_t; end if;

    -- el turno 2 esperando respuesta de Discord (entregado null) tampoco se repite
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
    values ('liam', v_d, 2, '{}'::jsonb, 1, null);
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-15 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is not null then raise exception 'smoke 109: turno 2 pendiente no se repite, dio %', v_t; end if;

    -- reintentos por turno (16/01): 3 fallidos del turno 1 lo frenan, el 2 sigue libre
    v_d := date '2030-01-16';
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
    select 'liam', v_d, 1, '{}'::jsonb, 1, false from generate_series(1, 3);
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-16 10:00:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is not null then raise exception 'smoke 109: 3 fallidos del turno 1 lo frenan, dio %', v_t; end if;
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-16 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '2' then raise exception 'smoke 109: el turno 2 no hereda los fallidos del 1, dio %', v_t; end if;
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
    select 'liam', v_d, 2, '{}'::jsonb, 1, false from generate_series(1, 3);
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-16 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is not null then raise exception 'smoke 109: 3 fallidos del turno 2 lo frenan, dio %', v_t; end if;

    -- 2 fallidos todavia reintenta (17/01)
    v_d := date '2030-01-17';
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, turno, cuentas, mensajes, entregado)
    select 'liam', v_d, 1, '{}'::jsonb, 1, false from generate_series(1, 2);
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-17 10:00:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '1' then raise exception 'smoke 109: con 2 fallidos reintenta, dio %', v_t; end if;

    -- sin segundo horario: a las 21:30 sale el turno 1 (18/01)
    update public.fin_alertas_cobros_config set hora_envio_2 = null where cliente_id = 'liam';
    v_t := (select string_agg(e ->> 'turno', ',') from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2030-01-18 21:30:00-03', false)) e where e ->> 'cliente' = 'liam');
    if v_t is distinct from '1' then raise exception 'smoke 109: sin segundo horario sale el turno 1, dio %', v_t; end if;

    -- el check: segundo horario igual al primero se rechaza
    begin
      update public.fin_alertas_cobros_config set hora_envio_2 = 9 where cliente_id = 'liam';
      raise exception 'smoke 109: el check dejo pasar hora_envio_2 = hora_envio';
    exception when check_violation then null;
    end;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then raise notice 'prueba de humo 109: OK (revertida, no se envio nada)';
    else raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control (la ultima sentencia antes del commit): los tres clientes
-- ---------------------------------------------------------------------------
select cliente_id, activo, hora_envio, hora_envio_2, mostrar_montos
from public.fin_alertas_cobros_config
where cliente_id in ('liam', 'agus', 'teo') order by 1;

commit;

-- ===========================================================================
-- CONTROLES: correr DE A UNO, despues del commit.
-- ===========================================================================
-- C1. Config de los tres clientes (esperado: hora_envio 9, hora_envio_2 21; activo y mostrar_montos como estaban):
--   select cliente_id, activo, hora_envio, hora_envio_2, mostrar_montos, ultimo_envio, ultimo_resultado,
--          ultimo_envio_2, ultimo_resultado_2
--   from public.fin_alertas_cobros_config order by 1;
--
-- C2. El cron sigue igual (esperado: '5 * * * *' y el comando select public.fin_alertas_cobros_enviar();, activo true):
--   select jobname, schedule, command, active::text as activo from cron.job where jobname = 'fin_alertas_cobros';
--
-- C3. Simulacion SIN enviar, 10:00 de un dia sin envios (esperado: un renglon por cliente activo con turno 1):
--   select e ->> 'cliente' as cliente, e ->> 'turno' as turno, e ->> 'resultado' as resultado, e -> 'cuentas' as cuentas
--   from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2026-10-14 10:00:00-03', false)) e;
--
-- C4. Idem 21:30 (esperado: turno 2 y UN solo renglon por cliente, aunque el turno 1 de ese dia nunca saliera):
--   select e ->> 'cliente' as cliente, e ->> 'turno' as turno, e ->> 'resultado' as resultado, e -> 'cuentas' as cuentas
--   from jsonb_array_elements(public.fin_alertas_cobros_enviar(timestamptz '2026-10-14 21:30:00-03', false)) e;
--   -- Con fechas de hoy (13/10) los resultados dependen de los envios ya hechos: el turno 1 de hoy ya esta en el
--   -- log, asi que 10:00 de hoy no muestra nada y 21:30 de hoy muestra solo el turno 2.
--
-- C5. Log de los ultimos envios con su turno (las filas anteriores a la 109 deben decir turno 1):
--   select id, creado, cliente_id, fecha, turno, mensajes, entregado from public.fin_alertas_cobros_log order by id desc limit 12;
--
-- C6. Respaldo de las funciones viejas (esperado: 5 filas):
--   select objeto, length(definicion) as largo, creado from public.fin_funciones_bak_109 order by 1;
--
-- C7. Firmas vigentes de config_guardar (esperado: una sola, de 5 argumentos):
--   select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'fin_alertas_cobros_config_guardar';
--
-- ---------------------------------------------------------------------------
-- VUELTA ATRAS (las definiciones viejas estan en fin_funciones_bak_109; no se corre salvo pedido):
--   -- 1. apagar el segundo aviso:  update public.fin_alertas_cobros_config set hora_envio_2 = null;
--   -- 2. restaurar cada funcion: select definicion from public.fin_funciones_bak_109 where objeto like '%enviar%';
--   --    y correr ese texto (idem confirmar, estado, vista_previa, config_guardar de 4 argumentos).
--   --    Antes: drop function public.fin_alertas_cobros_config_guardar(text, boolean, int, boolean, int);
--   -- 3. CORRECCION (revision del 13/10): la config_guardar de 4 argumentos restaurada nace con los permisos por
--   --    defecto (public y anon con EXECUTE). Dejarla como en la 103:
--   --    revoke all on function public.fin_alertas_cobros_config_guardar(text, boolean, int, boolean) from public, anon;
--   --    grant execute on function public.fin_alertas_cobros_config_guardar(text, boolean, int, boolean) to authenticated, service_role;
--   -- Las columnas nuevas (hora_envio_2, ultimo_*_2, turno) pueden quedar: la 103 las ignora.
--   -- Si despues de una vuelta atras se vuelve a aplicar la 109, el "9 y 21" NO se recarga solo (la columna ya
--   -- existe): update public.fin_alertas_cobros_config set hora_envio_2 = 21 where cliente_id in ('liam','agus','teo') and hora_envio = 9;
