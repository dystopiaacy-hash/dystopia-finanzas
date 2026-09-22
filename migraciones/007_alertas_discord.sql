-- 007_alertas_discord.sql — Dystopia Finanzas, Fase 7: alertas a Discord (logs-tecnicos).
--
-- Salen DESDE LA BASE, con un cron propio 5 minutos despues de cada sync
-- (:05 :20 :35 :50). Asi tambien avisa cuando la Edge Function NO corrio:
-- eso la funcion nunca lo puede reportar sola.
--
-- Solo por CAMBIOS, comparando contra el ultimo estado avisado (fin_alertas_estado):
--   - empeora: ok < revisar < parcial < error / sin_sync
--   - corte de la funcion (memoria, CPU, tiempo), una vez por corrida cortada
--   - mas de 45 min sin sync (en un solo renglon para todas las fuentes)
--   - payload grande, la PRIMERA vez (se rearma cuando baja del umbral)
--   - recuperado: vuelve a un estado mejor que el avisado
-- Sin menciones (allowed_mentions vacio: ni aunque el texto tuviera un @).
-- Sin nombres ni montos: el motivo sale de una LISTA BLANCA
-- (fin_alertas_motivo), nunca del texto libre de la corrida; los controles
-- traen comprobantes con nombres de alumnos.
-- La primera corrida no avisa nada viejo: toma el estado actual como base y
-- manda un unico mensaje "alertas activadas" con los conteos.
-- Entrega: cada mensaje queda en fin_alertas_log con su request de pg_net; la
-- corrida siguiente mira net._http_response y reintenta (hasta 3 intentos) lo
-- que Discord no acepto.
--
-- Requiere 001, 003, 006 y en Vault: fin_discord_webhook_logs (obligatorio) y
-- fin_app_url (opcional; sin ella el mensaje va sin link).
-- Idempotente.

begin;

do $$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'fin_discord_webhook_logs') then
    raise exception 'falta el secreto fin_discord_webhook_logs en Vault';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------
create table if not exists public.fin_alertas_estado (
  fuente_id       bigint primary key references public.fin_fuentes(id) on delete cascade,
  clave           text        not null check (clave in ('ok', 'revisar', 'parcial', 'error', 'sin_sync')),
  payload_grande  boolean     not null default false,
  ultimo_corte_id bigint,
  actualizado     timestamptz not null default now()
);
comment on table public.fin_alertas_estado is 'Ultimo estado AVISADO por fuente. Las alertas salen solo cuando el estado actual difiere de este.';

create table if not exists public.fin_alertas_log (
  id          bigint generated always as identity primary key,
  creado      timestamptz not null default now(),
  tipo        text        not null check (tipo in ('inicio', 'alerta')),
  eventos     int         not null,
  contenido   text        not null,
  request_id  bigint,
  intentos    int         not null default 0,
  status_code int,
  entregado   boolean
);
comment on table public.fin_alertas_log is 'Cada mensaje a Discord. entregado: null = esperando respuesta, true = Discord 2xx, false = fallo tras 3 intentos o sin webhook.';

do $$
declare t text;
begin
  foreach t in array array['fin_alertas_estado', 'fin_alertas_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, public', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_fundador', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.es_fundador())', t || '_fundador', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Motivo por lista blanca. Nunca devuelve texto de la corrida.
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_motivo(p_estado text, p_corte text, p_mensaje text, p_controles jsonb)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_m text := lower(coalesce(p_mensaje, ''));
  v_lista text[];
begin
  if p_corte is not null then
    return 'se cortó la función (' || case p_corte
      when 'memory' then 'memoria' when 'cpu' then 'CPU' when 'wall_clock' then 'tiempo máximo'
      when 'early_drop' then 'el runtime la soltó' when 'termination' then 'apagado del runtime'
      when 'sin_cierre' then 'sin cierre, motivo desconocido' else 'motivo desconocido' end || ')';
  end if;
  if p_estado = 'error' then
    return case
      when v_m like '%encabezado de la hoja%'                                   then 'cambió el encabezado de la hoja'
      when v_m like '%columnas obligatorias%'                                   then 'faltan columnas obligatorias'
      when v_m like '%fila de encabezado%' or v_m like '%filas de encabezado%'  then 'no se encontró la fila de encabezado'
      when v_m like '%meses repetidos%'                                         then 'meses repetidos en Opps'
      when v_m like '%ninguna fila valida%'                                     then 'la hoja no dio ninguna fila válida'
      when v_m like '%permiso de lector%' or v_m like '%(403)%' or v_m like '%http 403%' then 'Google: la service account no tiene permiso'
      when v_m like '%no esta compartida%' or v_m like '%no existe la hoja%'    then 'Google: planilla u hoja no encontrada'
      when v_m like '%(429)%' or v_m like '%limito las lecturas%'               then 'Google limitó las lecturas'
      when v_m like '%autenticar con google%' or v_m like '%token de google%' or v_m like '%google_sa_json%' then 'Google: falló la autenticación'
      when v_m like '%escribiendo%'                                             then 'falló la escritura en la base'
      when v_m like '%red:%'                                                    then 'error de red'
      else 'error (ver Salud)'
    end;
  end if;
  if p_estado in ('revisar', 'parcial') then
    select array_agg(distinct m order by m) into v_lista
    from (
      select case
        when c ->> 'motivo' = 'descuadre'                                    then 'un total de la planilla no cuadra'
        when c ->> 'motivo' like 'falta ''Total%'                            then 'falta un total en Opps'
        when c ->> 'motivo' like 'fecha en celda de monto%'                  then 'fecha en celda de monto'
        when c ->> 'motivo' like 'monto ambiguo con formato de fecha%'       then 'monto ambiguo con formato de fecha'
        when c ->> 'motivo' like 'posible serial de fecha%'                  then 'posible serial de fecha en ingresos'
        when c ->> 'motivo' = 'payload grande'                               then 'payload grande'
        when c ->> 'motivo' in ('vacia', 'sin_datos')                        then 'hoja sin datos'
        else 'otro control'
      end as m
      from jsonb_array_elements(case when jsonb_typeof(p_controles) = 'array' then p_controles else '[]'::jsonb end) as c
    ) x;
    if p_estado = 'parcial' then v_lista := array_prepend('más del 20% de las filas rechazadas', coalesce(v_lista, '{}')); end if;
    return coalesce(array_to_string(v_lista[1:3], ', ') || case when cardinality(v_lista) > 3 then ' y otros' else '' end, 'ver Salud');
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Envio: registra en el log y, si p_enviar, manda por pg_net.
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_enviar(p_tipo text, p_eventos int, p_texto text, p_enviar boolean default true)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_url  text;
  v_req  bigint;
  v_log  bigint;
begin
  insert into public.fin_alertas_log (tipo, eventos, contenido) values (p_tipo, p_eventos, p_texto) returning id into v_log;
  if not p_enviar then return v_log; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'fin_discord_webhook_logs';
  if v_url is null then
    update public.fin_alertas_log set entregado = false where id = v_log;
    raise warning 'fin_alertas: falta fin_discord_webhook_logs en Vault; el mensaje % quedo sin enviar', v_log;
    return v_log;
  end if;
  v_req := public.fin_alertas_post(v_url, p_texto);
  update public.fin_alertas_log set request_id = v_req, intentos = 1 where id = v_log;
  return v_log;
end $$;

-- El POST en si. allowed_mentions vacio: Discord no notifica a nadie aunque
-- el texto tuviera @everyone o un <@id>. wait=true: Discord responde con el
-- mensaje creado (200) en vez de 204, y queda en net._http_response.
create or replace function public.fin_alertas_post(p_url text, p_texto text)
returns bigint
language sql
security invoker
set search_path = ''
as $$
  select net.http_post(
    url     := p_url || case when p_url like '%?%' then '&' else '?' end || 'wait=true',
    headers := jsonb_build_object('content-type', 'application/json'),
    body    := jsonb_build_object('username', 'Dystopia Finanzas', 'content', p_texto,
                                  'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
    timeout_milliseconds := 10000);
$$;

-- Revisa la entrega de lo enviado antes y reintenta lo que fallo (maximo 3 intentos).
create or replace function public.fin_alertas_reintentar(p_enviar boolean default true)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  r      record;
  v_url  text;
  v_n    int := 0;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'fin_discord_webhook_logs';
  for r in
    select l.id, l.contenido, l.intentos, l.creado, h.status_code, h.timed_out, h.id as hid
    from public.fin_alertas_log l
    left join net._http_response h on h.id = l.request_id
    where l.entregado is null and l.request_id is not null
    order by l.id
  loop
    if r.hid is null and r.creado > now() - interval '10 minutes' then
      continue; -- pg_net todavia no respondio
    end if;
    if r.status_code between 200 and 299 then
      update public.fin_alertas_log set entregado = true, status_code = r.status_code where id = r.id;
    elsif r.intentos >= 3 or v_url is null or not p_enviar then
      update public.fin_alertas_log set entregado = false, status_code = r.status_code where id = r.id;
    else
      update public.fin_alertas_log
      set request_id = public.fin_alertas_post(v_url, r.contenido), intentos = r.intentos + 1, status_code = r.status_code
      where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Evaluacion: lo que corre el cron.
-- ---------------------------------------------------------------------------
create or replace function public.fin_alertas_evaluar(p_ahora timestamptz default now(), p_enviar boolean default true)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  c_sin_sync constant interval := interval '45 minutes';
  c_max      constant int := 1900; -- Discord corta en 2000
  v_primera  boolean := not exists (select 1 from public.fin_alertas_estado);
  v_url_app  text;
  v_hora     text := to_char(p_ahora at time zone 'America/Argentina/Buenos_Aires', 'DD/MM HH24:MI');
  r          record;
  v_sev      int;
  v_sev_prev int;
  v_corte    boolean;
  v_pg       boolean;
  v_fuente   text;
  v_lineas   text[] := '{}';
  v_sin_sync text[] := '{}';
  v_activas  int := 0;
  v_conteo   jsonb := '{}'::jsonb;
  v_texto    text;
  v_log      bigint;
  v_reint    int;
begin
  v_reint := public.fin_alertas_reintentar(p_enviar);
  select nullif(btrim(decrypted_secret), '') into v_url_app from vault.decrypted_secrets where name = 'fin_app_url';

  for r in
    with ult as (
      -- ultima corrida TERMINADA de cada fuente (pendiente, en_curso y omitida no cuentan)
      select distinct on (fuente_id) fuente_id, id, estado, inicio, corte, mensaje, controles
      from public.fin_sync_corridas
      where estado in ('ok', 'revisar', 'parcial', 'error')
      order by fuente_id, inicio desc, id desc
    ), cortes as (
      select fuente_id, max(id) as corte_id, (array_agg(corte order by id desc))[1] as corte
      from public.fin_sync_corridas
      where estado = 'error' and corte is not null
      group by fuente_id
    )
    select f.id, f.cliente_id, f.tipo,
           case when u.id is null or u.inicio < p_ahora - c_sin_sync then 'sin_sync' else u.estado end as clave,
           u.estado, u.corte, u.mensaje, u.controles,
           coalesce(u.controles @> '[{"motivo": "payload grande"}]'::jsonb, false) as payload_grande,
           (select c ->> 'payload_bytes' from jsonb_array_elements(case when jsonb_typeof(u.controles) = 'array' then u.controles else '[]'::jsonb end) c
             where c ->> 'motivo' = 'payload grande' limit 1) as pg_bytes,
           (select c ->> 'umbral_bytes' from jsonb_array_elements(case when jsonb_typeof(u.controles) = 'array' then u.controles else '[]'::jsonb end) c
             where c ->> 'motivo' = 'payload grande' limit 1) as pg_umbral,
           k.corte_id, k.corte as ultimo_corte,
           e.fuente_id is not null as conocida, e.clave as clave_prev, e.payload_grande as pg_prev, e.ultimo_corte_id
    from public.fin_fuentes f
    left join ult u on u.fuente_id = f.id
    left join cortes k on k.fuente_id = f.id
    left join public.fin_alertas_estado e on e.fuente_id = f.id
    where f.activo
    order by f.id
  loop
    v_activas := v_activas + 1;
    v_conteo := jsonb_set(v_conteo, array[r.clave], to_jsonb(coalesce((v_conteo ->> r.clave)::int, 0) + 1));
    v_fuente := r.cliente_id || ' · ' || case r.tipo when 'pagos' then 'Pagos' when 'opps' then 'Opps' when 'cuotas' then 'Cuotas' else r.tipo end;

    if r.conocida then
      v_sev      := case r.clave      when 'ok' then 0 when 'revisar' then 1 when 'parcial' then 2 else 3 end;
      v_sev_prev := case r.clave_prev when 'ok' then 0 when 'revisar' then 1 when 'parcial' then 2 else 3 end;
      v_corte := r.corte_id is not null and r.corte_id > coalesce(r.ultimo_corte_id, 0);
      v_pg    := r.payload_grande and not r.pg_prev;

      if r.clave = 'sin_sync' then
        if r.clave_prev <> 'sin_sync' then v_sin_sync := v_sin_sync || v_fuente; end if;
      elsif v_corte then
        v_lineas := v_lineas || ('🔴 ' || v_fuente || ' — ' || public.fin_alertas_motivo(null, r.ultimo_corte, null, null)
          || case when r.clave <> r.clave_prev then ' · ' || public.fin_alertas_etiqueta(r.clave_prev) || ' → ' || public.fin_alertas_etiqueta(r.clave) else '' end);
      elsif v_sev > v_sev_prev or (v_sev = v_sev_prev and r.clave <> r.clave_prev) then
        v_lineas := v_lineas || (case when v_sev >= 2 then '🔴 ' else '🟠 ' end || v_fuente || ' — empeoró: '
          || public.fin_alertas_etiqueta(r.clave_prev) || ' → ' || public.fin_alertas_etiqueta(r.clave)
          || coalesce(' · ' || public.fin_alertas_motivo(r.estado, r.corte, r.mensaje, r.controles), '')
          || case when v_pg then ' (' || public.fin_alertas_mb(r.pg_bytes) || ', umbral ' || public.fin_alertas_mb(r.pg_umbral) || ')' else '' end);
      elsif v_sev < v_sev_prev then
        v_lineas := v_lineas || ('🟢 ' || v_fuente || ' — recuperado: '
          || public.fin_alertas_etiqueta(r.clave_prev) || ' → ' || public.fin_alertas_etiqueta(r.clave));
      elsif v_pg then
        -- Payload grande la primera vez sin cambio de estado (ya estaba en Revisar por otra cosa).
        v_lineas := v_lineas || ('🟠 ' || v_fuente || ' — payload grande por primera vez: '
          || public.fin_alertas_mb(r.pg_bytes) || ' (umbral ' || public.fin_alertas_mb(r.pg_umbral) || ')');
      end if;
    end if;

    insert into public.fin_alertas_estado (fuente_id, clave, payload_grande, ultimo_corte_id, actualizado)
    values (r.id, r.clave, r.payload_grande, r.corte_id, p_ahora)
    on conflict (fuente_id) do update set
      clave = excluded.clave,
      -- en sin_sync no hay dato nuevo: se conserva la marca de payload
      payload_grande = case when excluded.clave = 'sin_sync' then public.fin_alertas_estado.payload_grande else excluded.payload_grande end,
      ultimo_corte_id = greatest(public.fin_alertas_estado.ultimo_corte_id, excluded.ultimo_corte_id),
      actualizado = excluded.actualizado;
  end loop;

  -- Fuentes que ya no estan activas: se olvidan (si vuelven, entran como base).
  delete from public.fin_alertas_estado e
  where not exists (select 1 from public.fin_fuentes f where f.id = e.fuente_id and f.activo);

  if cardinality(v_sin_sync) > 0 then
    v_lineas := v_lineas || ('⏱ ' || case
      when cardinality(v_sin_sync) = v_activas then
        'Ninguna fuente sincronizó en los últimos 45 min (' || v_activas || '). ¿Está corriendo el cron fin_sincronizar?'
      else 'Sin sincronizar hace más de 45 min: ' || array_to_string(v_sin_sync, ', ') end);
  end if;

  if v_primera then
    v_texto := '**Finanzas** · ' || v_hora || E'\nAlertas activadas: vigilo ' || v_activas || ' fuentes ('
      || coalesce((select string_agg(public.fin_alertas_etiqueta(k) || ' ' || v, ', ' order by case k when 'ok' then 0 when 'revisar' then 1 when 'parcial' then 2 when 'error' then 3 else 4 end)
                   from jsonb_each_text(v_conteo) as x(k, v)), 'ninguna') || ').'
      || E'\nSolo aviso cuando algo cambia: empeora, se corta, deja de sincronizar o se recupera.'
      || coalesce(E'\nSalud: ' || v_url_app || '/#/salud', '');
    v_log := public.fin_alertas_enviar('inicio', 0, v_texto, p_enviar);
    return jsonb_build_object('tipo', 'inicio', 'fuentes', v_activas, 'conteo', v_conteo, 'log_id', v_log, 'reintentos', v_reint, 'texto', v_texto);
  end if;

  if cardinality(v_lineas) = 0 then
    return jsonb_build_object('tipo', 'sin_cambios', 'fuentes', v_activas, 'reintentos', v_reint);
  end if;

  v_texto := '**Finanzas** · ' || v_hora;
  for i in 1 .. cardinality(v_lineas) loop
    if length(v_texto) + length(v_lineas[i]) + 80 > c_max then
      v_texto := v_texto || E'\n… y ' || (cardinality(v_lineas) - i + 1) || ' más (ver Salud)';
      exit;
    end if;
    v_texto := v_texto || E'\n' || v_lineas[i];
  end loop;
  v_texto := v_texto || coalesce(E'\nSalud: ' || v_url_app || '/#/salud', '');
  v_log := public.fin_alertas_enviar('alerta', cardinality(v_lineas), v_texto, p_enviar);
  return jsonb_build_object('tipo', 'alerta', 'eventos', cardinality(v_lineas), 'log_id', v_log, 'reintentos', v_reint, 'texto', v_texto);
end $$;

create or replace function public.fin_alertas_etiqueta(p_clave text)
returns text language sql immutable set search_path = '' as $$
  select case p_clave when 'ok' then 'OK' when 'revisar' then 'Revisar' when 'parcial' then 'Parcial'
    when 'error' then 'Error' when 'sin_sync' then 'sin sincronizar' else coalesce(p_clave, '?') end;
$$;

create or replace function public.fin_alertas_mb(p_bytes text)
returns text language sql immutable set search_path = '' as $$
  select case when p_bytes is null or p_bytes !~ '^[0-9]+$' then '?'
    else replace(to_char(p_bytes::numeric / 1e6, 'FM999990.0'), '.', ',') || ' MB' end;
$$;

-- Solo la base (cron, como postgres) ejecuta estas funciones.
do $$
declare f text;
begin
  foreach f in array array[
    'fin_alertas_motivo(text, text, text, jsonb)', 'fin_alertas_enviar(text, int, text, boolean)',
    'fin_alertas_post(text, text)', 'fin_alertas_reintentar(boolean)',
    'fin_alertas_evaluar(timestamptz, boolean)', 'fin_alertas_etiqueta(text)', 'fin_alertas_mb(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Prueba de humo (se autorrevierte, NO manda nada: p_enviar = false).
-- Una fuente de prueba: base -> corte por memoria -> recuperado -> 1 h sin
-- sync. Y el motivo nunca filtra el comprobante (nombre) de un control.
-- ---------------------------------------------------------------------------
do $$
declare
  v_f   bigint;
  v_r   jsonb;
  v_t   text;
begin
  begin
    delete from public.fin_alertas_estado;  -- dentro del bloque: se revierte
    delete from public.fin_alertas_log;
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('liam', 'SMOKE_007', 1, 'Smoke', 'pagos', 10000) returning id into v_f;
    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado)
    values (v_f, now() - interval '3 minutes', now() - interval '3 minutes', 'ok');

    v_r := public.fin_alertas_evaluar(now(), false);
    if v_r ->> 'tipo' <> 'inicio' then raise exception 'smoke 007: la primera corrida dio % y no inicio', v_r; end if;

    v_r := public.fin_alertas_evaluar(now(), false);
    if v_r ->> 'tipo' <> 'sin_cambios' then raise exception 'smoke 007: sin cambios dio %', v_r; end if;

    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado, corte, controles)
    values (v_f, now() - interval '2 minutes', now() - interval '2 minutes', 'error', 'memory',
            '[{"motivo": "monto ambiguo con formato de fecha", "comprobante": "Juana Perez - 1.321,9 - pif.jpg"}]');
    v_r := public.fin_alertas_evaluar(now(), false);
    v_t := v_r ->> 'texto';
    if v_t not like '%liam · Pagos — se cortó la función (memoria)%' then raise exception 'smoke 007: corte no avisado: %', v_t; end if;
    if v_t like '%Juana%' or v_t like '%1.321%' then raise exception 'smoke 007: el texto filtra un nombre o un monto: %', v_t; end if;

    v_r := public.fin_alertas_evaluar(now(), false);
    if v_r ->> 'tipo' <> 'sin_cambios' then raise exception 'smoke 007: el mismo corte se aviso dos veces: %', v_r; end if;

    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado, controles)
    values (v_f, now() - interval '1 minute', now() - interval '1 minute', 'revisar',
            '[{"motivo": "monto ambiguo con formato de fecha", "comprobante": "Juana Perez - 1.321,9 - pif.jpg"}]');
    v_t := public.fin_alertas_evaluar(now(), false) ->> 'texto';
    if v_t not like '%liam · Pagos — recuperado: Error → Revisar%' then raise exception 'smoke 007: recuperado no avisado: %', v_t; end if;
    if v_t like '%Juana%' then raise exception 'smoke 007: filtra un nombre: %', v_t; end if;

    v_t := public.fin_alertas_evaluar(now() + interval '1 hour', false) ->> 'texto';
    if v_t not like '%⏱ %' then raise exception 'smoke 007: 1 h sin sync no avisado: %', v_t; end if;

    if public.fin_alertas_motivo('revisar', null, null, '[{"motivo": "descuadre", "item": "Sueldo Juana", "diferencia": 516.45}]') <> 'un total de la planilla no cuadra' then
      raise exception 'smoke 007: motivo de descuadre';
    end if;
    v_t := public.fin_alertas_motivo('parcial', null, 'Juana Perez 1.321,9',
      '[{"motivo": "monto ambiguo con formato de fecha", "comprobante": "Juana Perez - 1.321,9 - pif.jpg", "valor": "1324.07"}, {"motivo": "algo nuevo: Juana"}]');
    if v_t like '%Juana%' or v_t like '%1.321%' or v_t like '%1324%' then raise exception 'smoke 007: el motivo filtra datos de la fila: %', v_t; end if;
    if v_t <> 'más del 20% de las filas rechazadas, monto ambiguo con formato de fecha, otro control' then raise exception 'smoke 007: motivo parcial = %', v_t; end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then raise notice 'prueba de humo 007: OK (revertida, no se envio nada)';
    else raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Cron: 5 minutos despues de cada sync de 004 (*/15).
-- ---------------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'fin_alertas';
select cron.schedule('fin_alertas', '5,20,35,50 * * * *', $cron$ select public.fin_alertas_evaluar(); $cron$);

-- ---------------------------------------------------------------------------
-- Query de control
-- ---------------------------------------------------------------------------
select jobname, schedule, active::text as activo from cron.job where jobname in ('fin_sincronizar', 'fin_alertas') order by jobname;

commit;

-- Despues del primer :05/:20/:35/:50, en logs-tecnicos tiene que aparecer
-- "Alertas activadas: vigilo 12 fuentes (...)". Para ver la entrega:
--   select id, creado, tipo, eventos, intentos, status_code, entregado, left(contenido, 120)
--   from fin_alertas_log order by id desc limit 10;
