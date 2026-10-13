-- 103_alertas_cobros_discord.sql — Dystopia Finanzas: alerta diaria de cobros a Discord.
--
-- Un mensaje por cliente, todos los dias a las 9:05 (Argentina), con tres bloques:
--   Cobros de los proximos 7 dias (solo lunes), Atrasadas (mas de N dias aparte) y Hoy toca cobrar.
-- Sin montos y sin telefonos (el canal lo ve mas gente). Montos opcionales por cliente
-- (fin_alertas_cobros_config.mostrar_montos o el parametro p_montos de la funcion que arma).
-- Si no hay nada que avisar no se manda nada. Si el texto pasa de ~1900 caracteres se parte en varios mensajes.
--
-- De donde sale cada bloque: fin_v_cobranzas (003: cuotas pendientes = estado vacio o distinto de
-- pagado/pagada/cuota pagada/churn/pausado/cancelado) + fin_cuotas (fuente) + fin_fuentes (solo fuentes activas:
-- una fuente cortada deja cuotas congeladas que no se pueden cobrar sin dato fresco).
--   vencimiento = fin_cuotas.fecha_pago  |  producto = programa  |  numero = tipo_cuota o "Cuota n"
--   Hoy = fecha_pago = hoy  |  Atrasadas = fecha_pago < hoy  |  Proximos 7 dias = hoy < fecha_pago <= hoy + 7
-- Las cuotas sin fecha_pago no entran en ningun bloque.
--
-- Webhook: en Vault (no en la tabla ni en el codigo), como fin_discord_webhook_logs de la 007.
--   fin_discord_webhook_cobros_<cliente>   canal propio del cliente (ej. fin_discord_webhook_cobros_liam)
--   fin_discord_webhook_cobros             canal general (se usa si el cliente no tiene el suyo)
-- Un cliente sin ningun webhook no recibe nada aunque este activo.
--
-- Cron: fin_alertas_cobros, minuto :05 de cada hora (fuera de :00/:15/:30/:45 de la sync). Manda cuando la
-- hora de Argentina ya paso hora_envio (por defecto 9) y hoy no hubo envio entregado: si Discord falla o el
-- cron estuvo caido, reintenta en la hora siguiente (hasta 3 intentos por dia).
--
-- Cliente nuevo con alerta: queda en fin_alertas_cobros_config con activo = false (se siembra con los clientes
-- que tienen fuente de cuotas). Se prende desde la app (Alertas, solo fundador) o con el UPDATE comentado abajo.
--
-- No toca ninguna tabla existente. No requiere la 007 (trae su propia funcion de POST).
-- Requiere 001, 003, pg_net, pg_cron y Vault. Idempotente.

begin;

do $$
begin
  if to_regclass('public.fin_cuotas') is null or to_regclass('public.fin_v_cobranzas') is null
     or to_regclass('public.fin_fuentes') is null or to_regclass('public.crm_clients') is null then
    raise exception 'falta fin_cuotas, fin_v_cobranzas, fin_fuentes o crm_clients (001 y 003)';
  end if;
  if to_regprocedure('public.es_fundador()') is null then
    raise exception 'falta public.es_fundador()';
  end if;
  if to_regclass('vault.decrypted_secrets') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'net' and p.proname = 'http_post') then
    raise exception 'falta Vault o pg_net (net.http_post)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------
create table if not exists public.fin_alertas_cobros_config (
  cliente_id       text primary key references public.crm_clients(id) on delete cascade,
  activo           boolean     not null default false,
  hora_envio       smallint    not null default 9 check (hora_envio between 6 and 22),
  dias_atraso_alto smallint    not null default 14 check (dias_atraso_alto between 1 and 365),
  mostrar_montos   boolean     not null default false,
  ultimo_envio     timestamptz,
  ultimo_resultado text,
  actualizado      timestamptz not null default now()
);
comment on table public.fin_alertas_cobros_config is
  '103: alerta diaria de cobros a Discord por cliente. El webhook NO esta aca: vive en Vault (fin_discord_webhook_cobros_<cliente> o fin_discord_webhook_cobros).';

create table if not exists public.fin_alertas_cobros_log (
  id          bigint generated always as identity primary key,
  creado      timestamptz not null default now(),
  cliente_id  text        not null,
  fecha       date        not null,
  cuentas     jsonb       not null,
  mensajes    int         not null,
  textos      jsonb       not null default '[]'::jsonb,
  request_ids bigint[]    not null default '{}',
  entregado   boolean
);
comment on table public.fin_alertas_cobros_log is
  '103: un renglon por intento diario y cliente. entregado: null = esperando respuesta de Discord, true = 2xx (o nada para avisar), false = fallo.';
create index if not exists fin_alertas_cobros_log_cliente_fecha_idx on public.fin_alertas_cobros_log (cliente_id, fecha);

-- Permisos y RLS (estilo 098: el permiso se evalua una vez por consulta). anon: nada.
-- Solo lectura para el fundador; la escritura va por la funcion fin_alertas_cobros_config_guardar.
do $$
declare t text;
begin
  foreach t in array array['fin_alertas_cobros_config', 'fin_alertas_cobros_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, public', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_fundador', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.es_fundador()))', t || '_fundador', t);
  end loop;
end $$;

-- Siembra: una fila por cliente con fuente de cuotas, apagada. No pisa filas existentes.
insert into public.fin_alertas_cobros_config (cliente_id)
select distinct f.cliente_id from public.fin_fuentes f where f.tipo = 'cuotas'
on conflict (cliente_id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Armado del mensaje (no envia nada, no escribe nada)
-- ---------------------------------------------------------------------------
-- Texto de planilla a texto de Discord: sin saltos de linea ni caracteres de formato/mencion, max 60.
create or replace function public.fin_cobros_limpiar(p_texto text)
returns text
language sql immutable
set search_path = ''
as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(p_texto, ''), '[\r\n\t]+', ' ', 'g'), '[*_~`|>\\<@]', '', 'g')), 60);
$$;

-- p_semana: null = solo los lunes (regla normal), true = incluye "proximos 7 dias", false = lo omite.
-- p_montos: null = lo que diga la config del cliente (por defecto sin montos).
create or replace function public.fin_alertas_cobros_armar(
  p_cliente text,
  p_ahora   timestamptz default now(),
  p_semana  boolean default null,
  p_montos  boolean default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  c_max    constant int := 1850;  -- Discord corta en 2000; queda margen para el encabezado y el "parte i/n"
  c_dias   constant text[] := array['lun', 'mar', 'mié', 'jue', 'vie', 'sáb', 'dom'];
  v_hoy    date := (p_ahora at time zone 'America/Argentina/Buenos_Aires')::date;
  v_lunes  boolean;
  v_semana boolean;
  v_montos boolean;
  v_alto   int;
  v_nombre text;
  l_hoy    text[] := '{}';
  l_alto   text[] := '{}';
  l_atr    text[] := '{}';
  l_prox   text[] := '{}';
  s_hoy    numeric := 0;
  s_atr    numeric := 0;
  s_prox   numeric := 0;
  r        record;
  v_item   text;
  v_monto  text;
  v_n_atr  int;
  v_lineas text[] := '{}';
  v_cuerpos text[] := '{}';
  v_cur    text := '';
  v_cab    text;
  v_msgs   text[] := '{}';
  v_total  int;
  i        int;
begin
  v_lunes := extract(isodow from v_hoy) = 1;
  v_semana := coalesce(p_semana, v_lunes);

  select c.dias_atraso_alto, c.mostrar_montos into v_alto, v_montos
  from public.fin_alertas_cobros_config c where c.cliente_id = p_cliente;
  v_alto := coalesce(v_alto, 14);
  v_montos := coalesce(p_montos, v_montos, false);

  select k.nombre into v_nombre from public.crm_clients k where k.id = p_cliente;
  v_nombre := public.fin_cobros_limpiar(coalesce(v_nombre, p_cliente));

  for r in
    select public.fin_cobros_limpiar(v.alumno)   as alumno,
           public.fin_cobros_limpiar(v.programa) as programa,
           public.fin_cobros_limpiar(coalesce(nullif(btrim(v.tipo_cuota), ''),
             case when v.numero_cuota is not null then 'Cuota ' || v.numero_cuota end)) as cuota,
           v.fecha_pago,
           (v.fecha_pago - v_hoy) as dias,
           greatest(coalesce(v.monto, 0) - coalesce(v.monto_cobrado, 0), 0) as pendiente
    from public.fin_v_cobranzas v
    join public.fin_cuotas q on q.id = v.id
    join public.fin_fuentes f on f.id = q.fuente_id
    where v.cliente_id = p_cliente
      and f.activo
      and v.fecha_pago is not null
      and v.fecha_pago <= v_hoy + 7
    order by v.fecha_pago, v.alumno, v.numero_cuota, v.id
  loop
    v_item := '• ' || r.alumno
      || coalesce(' — ' || nullif(r.programa, ''), '')
      || coalesce(' · ' || nullif(r.cuota, ''), '');
    v_monto := case when v_montos then ' · USD ' || round(r.pendiente)::text else '' end;

    if r.dias = 0 then
      l_hoy := l_hoy || (v_item || v_monto);
      s_hoy := s_hoy + r.pendiente;
    elsif r.dias < 0 then
      v_item := v_item || ' · venció ' || to_char(r.fecha_pago, 'DD/MM') || ' (' || (-r.dias) || ' d)' || v_monto;
      s_atr := s_atr + r.pendiente;
      if -r.dias > v_alto then l_alto := l_alto || v_item; else l_atr := l_atr || v_item; end if;
    elsif v_semana then
      l_prox := l_prox || (v_item || ' · vence ' || c_dias[extract(isodow from r.fecha_pago)::int]
        || ' ' || to_char(r.fecha_pago, 'DD/MM') || v_monto);
      s_prox := s_prox + r.pendiente;
    end if;
  end loop;

  v_n_atr := cardinality(l_alto) + cardinality(l_atr);

  -- Orden pedido: proximos 7 dias, atrasadas, hoy.
  if v_semana and cardinality(l_prox) > 0 then
    v_lineas := v_lineas || ('**Cobros de los próximos 7 días** (' || cardinality(l_prox) || ')'
      || case when v_montos then ' · total USD ' || round(s_prox)::text else '' end) || l_prox;
  end if;
  if v_n_atr > 0 then
    if cardinality(v_lineas) > 0 then v_lineas := v_lineas || ''::text; end if;
    v_lineas := v_lineas || ('**Atrasadas** (' || v_n_atr || ')'
      || case when v_montos then ' · total USD ' || round(s_atr)::text else '' end);
    if cardinality(l_alto) > 0 then
      v_lineas := v_lineas || ('🔴 **Más de ' || v_alto || ' días** (' || cardinality(l_alto) || ')') || l_alto;
    end if;
    if cardinality(l_atr) > 0 then
      if cardinality(l_alto) > 0 then
        v_lineas := v_lineas || ('**Hasta ' || v_alto || ' días** (' || cardinality(l_atr) || ')');
      end if;
      v_lineas := v_lineas || l_atr;
    end if;
  end if;
  if cardinality(l_hoy) > 0 then
    if cardinality(v_lineas) > 0 then v_lineas := v_lineas || ''::text; end if;
    v_lineas := v_lineas || ('**Hoy toca cobrar** (' || cardinality(l_hoy) || ')'
      || case when v_montos then ' · total USD ' || round(s_hoy)::text else '' end) || l_hoy;
  end if;

  -- Partir en mensajes de hasta c_max caracteres, siempre entre lineas.
  for i in 1 .. cardinality(v_lineas) loop
    if v_cur = '' and v_lineas[i] = '' then continue; end if;
    if v_cur <> '' and length(v_cur) + 1 + length(v_lineas[i]) > c_max then
      v_cuerpos := v_cuerpos || v_cur;
      v_cur := '';
      if v_lineas[i] = '' then continue; end if;
    end if;
    v_cur := case when v_cur = '' then v_lineas[i] else v_cur || E'\n' || v_lineas[i] end;
  end loop;
  if v_cur <> '' then v_cuerpos := v_cuerpos || v_cur; end if;

  v_total := cardinality(v_cuerpos);
  v_cab := '**Cobros · ' || v_nombre || '** · ' || c_dias[extract(isodow from v_hoy)::int] || ' ' || to_char(v_hoy, 'DD/MM');
  for i in 1 .. v_total loop
    v_msgs := v_msgs || (v_cab || case when v_total > 1 then ' · parte ' || i || '/' || v_total else '' end
      || E'\n' || v_cuerpos[i]);
  end loop;

  return jsonb_build_object(
    'cliente', p_cliente,
    'fecha', v_hoy,
    'es_lunes', v_lunes,
    'incluye_semana', v_semana,
    'montos', v_montos,
    'cuentas', jsonb_build_object(
      'proximos', case when v_semana then cardinality(l_prox) else 0 end,
      'atrasadas', v_n_atr,
      'atrasadas_altas', cardinality(l_alto),
      'hoy', cardinality(l_hoy)),
    'mensajes', to_jsonb(v_msgs));
end $$;

-- ---------------------------------------------------------------------------
-- 3. Envio (lo que corre el cron)
-- ---------------------------------------------------------------------------
-- POST a Discord por pg_net. allowed_mentions vacio: no notifica a nadie aunque el texto traiga un @.
create or replace function public.fin_cobros_post(p_url text, p_texto text)
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

-- Mira la respuesta de Discord de lo enviado antes y marca entregado true/false.
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
    select l.id, l.cliente_id, l.creado, l.request_ids
    from public.fin_alertas_cobros_log l
    where l.entregado is null and cardinality(l.request_ids) > 0
    order by l.id
  loop
    select count(*) filter (where h.status_code between 200 and 299), count(*)
      into v_ok, v_resp
    from net._http_response h where h.id = any (r.request_ids);

    if v_ok = cardinality(r.request_ids) then
      update public.fin_alertas_cobros_log set entregado = true where id = r.id;
      update public.fin_alertas_cobros_config set ultimo_resultado = 'enviado', actualizado = p_ahora where cliente_id = r.cliente_id;
      v_n := v_n + 1;
    elsif v_resp = cardinality(r.request_ids) or r.creado < p_ahora - interval '30 minutes' then
      update public.fin_alertas_cobros_log set entregado = false where id = r.id;
      update public.fin_alertas_cobros_config set ultimo_resultado = 'falló, se reintenta', actualizado = p_ahora where cliente_id = r.cliente_id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- p_enviar = false: arma lo que se mandaria y lo devuelve, sin postear ni escribir el log.
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
    select c.cliente_id
    from public.fin_alertas_cobros_config c
    where c.activo
      and c.hora_envio <= v_hora
      and not exists (select 1 from public.fin_alertas_cobros_log l
                      where l.cliente_id = c.cliente_id and l.fecha = v_hoy and l.entregado is not false)
      and (select count(*) from public.fin_alertas_cobros_log l
           where l.cliente_id = c.cliente_id and l.fecha = v_hoy and l.entregado is false) < 3
    order by c.cliente_id
  loop
    select s.decrypted_secret into v_url
    from vault.decrypted_secrets s
    where s.name in ('fin_discord_webhook_cobros_' || r.cliente_id, 'fin_discord_webhook_cobros')
      and nullif(btrim(s.decrypted_secret), '') is not null
    order by (s.name = 'fin_discord_webhook_cobros') limit 1;

    if v_url is null then
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'resultado', 'sin_webhook');
      if p_enviar then
        update public.fin_alertas_cobros_config set ultimo_resultado = 'sin webhook en Vault', actualizado = p_ahora
        where cliente_id = r.cliente_id;
      end if;
      continue;
    end if;

    v_a := public.fin_alertas_cobros_armar(r.cliente_id, p_ahora);

    if not p_enviar then
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'resultado', 'vista previa',
        'cuentas', v_a -> 'cuentas', 'mensajes', v_a -> 'mensajes');
      continue;
    end if;

    if jsonb_array_length(v_a -> 'mensajes') = 0 then
      insert into public.fin_alertas_cobros_log (cliente_id, fecha, cuentas, mensajes, entregado)
      values (r.cliente_id, v_hoy, v_a -> 'cuentas', 0, true);
      update public.fin_alertas_cobros_config set ultimo_resultado = 'sin cobros para avisar', actualizado = p_ahora
      where cliente_id = r.cliente_id;
      v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'resultado', 'sin_cobros');
      continue;
    end if;

    v_ids := '{}';
    for v_m in select jsonb_array_elements_text(v_a -> 'mensajes') loop
      v_ids := v_ids || public.fin_cobros_post(v_url, v_m);
    end loop;
    insert into public.fin_alertas_cobros_log (cliente_id, fecha, cuentas, mensajes, textos, request_ids)
    values (r.cliente_id, v_hoy, v_a -> 'cuentas', jsonb_array_length(v_a -> 'mensajes'), v_a -> 'mensajes', v_ids);
    update public.fin_alertas_cobros_config
    set ultimo_envio = p_ahora, ultimo_resultado = 'enviado, esperando confirmación', actualizado = p_ahora
    where cliente_id = r.cliente_id;
    v_res := v_res || jsonb_build_object('cliente', r.cliente_id, 'resultado', 'enviado',
      'mensajes', jsonb_array_length(v_a -> 'mensajes'));
  end loop;
  return v_res;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Funciones para la app (solo fundador): estado, guardar, vista previa
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
             'dias_atraso_alto', c.dias_atraso_alto,
             'mostrar_montos', c.mostrar_montos,
             'ultimo_envio', c.ultimo_envio,
             'ultimo_resultado', c.ultimo_resultado,
             'tiene_webhook', exists (select 1 from vault.decrypted_secrets s
                                      where s.name in ('fin_discord_webhook_cobros_' || c.cliente_id, 'fin_discord_webhook_cobros')))
           order by c.cliente_id)
    from public.fin_alertas_cobros_config c
    left join public.crm_clients k on k.id = c.cliente_id), '[]'::jsonb);
end $$;

create or replace function public.fin_alertas_cobros_config_guardar(
  p_cliente text, p_activo boolean, p_hora int, p_montos boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (select public.es_fundador()) then raise exception 'Solo el fundador cambia las alertas.'; end if;
  update public.fin_alertas_cobros_config
  set activo = p_activo, hora_envio = p_hora, mostrar_montos = p_montos, actualizado = now()
  where cliente_id = p_cliente;
  if not found then raise exception 'El cliente % no tiene alerta de cobros configurada.', p_cliente; end if;
end $$;

-- Lo que se mandaria hoy, SIN enviar y sin escribir nada. p_semana = true muestra tambien el bloque del lunes.
create or replace function public.fin_alertas_cobros_vista_previa(p_cliente text, p_semana boolean default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (select public.es_fundador()) then raise exception 'Solo el fundador ve la vista previa.'; end if;
  return public.fin_alertas_cobros_armar(p_cliente, now(), p_semana, null);
end $$;

do $$
declare f text;
begin
  -- Internas: solo la base (cron, como postgres) y service_role.
  foreach f in array array[
    'fin_cobros_limpiar(text)',
    'fin_alertas_cobros_armar(text, timestamptz, boolean, boolean)',
    'fin_cobros_post(text, text)',
    'fin_alertas_cobros_confirmar(timestamptz)',
    'fin_alertas_cobros_enviar(timestamptz, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  -- De la app: authenticated, y cada una verifica es_fundador() adentro.
  foreach f in array array[
    'fin_alertas_cobros_estado()',
    'fin_alertas_cobros_config_guardar(text, boolean, int, boolean)',
    'fin_alertas_cobros_vista_previa(text, boolean)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Prueba de humo (se autorrevierte, NO manda nada)
-- Usa cliente liam con alumnos "Zz ..." y mira solo esos textos (el resto de liam puede tener datos reales).
-- Lunes de referencia: 12/10/2026 09:05; martes: 13/10/2026 09:05 (hora de Argentina).
-- ---------------------------------------------------------------------------
do $$
declare
  v_f    bigint;
  v_mar  timestamptz := timestamptz '2026-10-13 09:05:00-03';
  v_lun  timestamptz := timestamptz '2026-10-12 09:05:00-03';
  v_j    jsonb;
  v_t    text;
  v_m    text;
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('liam', 'SMOKE_103', 1, 'Smoke', 'cuotas', 10000) returning id into v_f;

    insert into public.fin_cuotas (cliente_id, fuente_id, alumno, telefono, programa, numero_cuota, monto, monto_cobrado, fecha_pago, estado, fila_planilla) values
      ('liam', v_f, 'Zz Hoy',        '+54 9 11 5555-5555', 'Prog Z', 2, 500,  0, date '2026-10-13', 'Pendiente', 1),
      ('liam', v_f, 'Zz Atraso20',   null,                 'Prog Z', 1, 300,  0, date '2026-09-23', null,        2),
      ('liam', v_f, 'Zz Atraso3',    null,                 'Prog Z', 3, 200, 50, date '2026-10-10', 'Pendiente', 3),
      ('liam', v_f, 'Zz Prox',       null,                 'Prog Z', 2, 100,  0, date '2026-10-16', 'Pendiente', 4),
      ('liam', v_f, 'Zz Lejos',      null,                 'Prog Z', 2, 100,  0, date '2026-10-23', 'Pendiente', 5),
      ('liam', v_f, 'Zz Pagada',     null,                 'Prog Z', 1, 100,100, date '2026-10-13', 'Pagado',    6),
      ('liam', v_f, 'Zz SinFecha',   null,                 'Prog Z', 1, 100,  0, null,               'Pendiente', 7);

    -- martes, sin forzar: hoy + atrasadas, sin proximos
    v_j := public.fin_alertas_cobros_armar('liam', v_mar);
    v_t := array_to_string(array(select jsonb_array_elements_text(v_j -> 'mensajes')), E'\n');
    if v_t not like '%Zz Hoy%' then raise exception 'smoke 103: falta la cuota de hoy: %', v_t; end if;
    if v_t not like '%Zz Atraso20%' or v_t not like '%Zz Atraso3%' then raise exception 'smoke 103: faltan atrasadas: %', v_t; end if;
    if v_t not like '%Más de 14 días%' then raise exception 'smoke 103: falta el bloque de mas de 14 dias: %', v_t; end if;
    if position('Zz Atraso20' in v_t) > position('Zz Atraso3' in v_t) then raise exception 'smoke 103: atrasadas mal ordenadas'; end if;
    if v_t like '%Zz Prox%' then raise exception 'smoke 103: un martes no van los proximos 7 dias: %', v_t; end if;
    if v_t like '%Zz Lejos%' or v_t like '%Zz Pagada%' or v_t like '%Zz SinFecha%' then raise exception 'smoke 103: entro una cuota que no corresponde: %', v_t; end if;
    if v_t like '%5555%' then raise exception 'smoke 103: el mensaje filtra un telefono: %', v_t; end if;
    if v_t like '%USD %' then raise exception 'smoke 103: el mensaje trae montos sin pedirlos: %', v_t; end if;
    if (v_j -> 'incluye_semana')::text <> 'false' then raise exception 'smoke 103: martes incluye_semana = %', v_j -> 'incluye_semana'; end if;

    -- forzando la semana: aparece el proximo, no el lejano
    v_t := array_to_string(array(select jsonb_array_elements_text(public.fin_alertas_cobros_armar('liam', v_mar, true) -> 'mensajes')), E'\n');
    if v_t not like '%Zz Prox%' or v_t like '%Zz Lejos%' then raise exception 'smoke 103: bloque de proximos mal: %', v_t; end if;

    -- lunes: incluye la semana sin forzar
    if (public.fin_alertas_cobros_armar('liam', v_lun) -> 'incluye_semana')::text <> 'true' then
      raise exception 'smoke 103: el lunes no incluye proximos 7 dias';
    end if;

    -- montos pedidos: 500 (hoy), 150 (200 - 50)
    v_t := array_to_string(array(select jsonb_array_elements_text(public.fin_alertas_cobros_armar('liam', v_mar, null, true) -> 'mensajes')), E'\n');
    if v_t not like '%USD 500%' or v_t not like '%USD 150%' then raise exception 'smoke 103: montos mal: %', v_t; end if;

    -- partir en varios mensajes (<= 2000 cada uno)
    insert into public.fin_cuotas (cliente_id, fuente_id, alumno, programa, numero_cuota, monto, fecha_pago, estado, fila_planilla)
    select 'liam', v_f, 'Zz Masivo ' || lpad(g::text, 3, '0') || ' con un nombre bastante largo para ocupar lugar', 'Programa de nombre largo', 1, 100,
           date '2026-09-01' + (g % 20), 'Pendiente', 100 + g
    from generate_series(1, 150) g;
    v_j := public.fin_alertas_cobros_armar('liam', v_mar);
    if jsonb_array_length(v_j -> 'mensajes') < 2 then raise exception 'smoke 103: no partio en varios mensajes'; end if;
    for v_m in select jsonb_array_elements_text(v_j -> 'mensajes') loop
      if length(v_m) > 2000 then raise exception 'smoke 103: un mensaje pasa de 2000 caracteres (%)', length(v_m); end if;
      if v_m not like '%parte %/%' then raise exception 'smoke 103: falta el "parte i/n"'; end if;
    end loop;

    -- sin nada que avisar: cliente sin cuotas -> lista vacia
    if jsonb_array_length(public.fin_alertas_cobros_armar('zz_inexistente', v_mar) -> 'mensajes') <> 0 then
      raise exception 'smoke 103: un cliente sin cuotas devolvio mensajes';
    end if;

    -- el limpiador saca menciones y formato
    if public.fin_cobros_limpiar(E'@everyone *Ana*\n_x_') <> 'everyone Ana x' then
      raise exception 'smoke 103: limpiar = %', public.fin_cobros_limpiar(E'@everyone *Ana*\n_x_');
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then raise notice 'prueba de humo 103: OK (revertida, no se envio nada)';
    else raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Cron: minuto :05 de cada hora; la funcion decide con hora_envio (por defecto 9:05 Argentina).
-- ---------------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'fin_alertas_cobros';
select cron.schedule('fin_alertas_cobros', '5 * * * *', $cron$ select public.fin_alertas_cobros_enviar(); $cron$);

-- ---------------------------------------------------------------------------
-- Query de control (la ultima sentencia antes del commit)
-- ---------------------------------------------------------------------------
select jobname, schedule, active::text as activo from cron.job where jobname = 'fin_alertas_cobros';

commit;

-- ===========================================================================
-- CONTROLES: correr DE A UNO, despues del commit.
-- ===========================================================================
-- C1. Configuracion por cliente (todos apagados hasta que Joaquin los prenda):
--   select cliente_id, activo, hora_envio, dias_atraso_alto, mostrar_montos, ultimo_envio, ultimo_resultado
--   from public.fin_alertas_cobros_config order by 1;
--
-- C2. Texto del mensaje de HOY para un cliente, SIN enviarlo (una fila por mensaje; cambiar 'liam'):
--   select m.ord as parte, m.texto
--   from jsonb_array_elements_text(public.fin_alertas_cobros_armar('liam') -> 'mensajes') with ordinality as m(texto, ord)
--   order by 1;
--   -- sin filas = hoy no se manda nada para ese cliente.
--
-- C3. Conteos de hoy por bloque, y la misma alerta como si fuera lunes (incluye proximos 7 dias):
--   select public.fin_alertas_cobros_armar('liam') -> 'cuentas' as hoy;
--   select m.ord, m.texto from jsonb_array_elements_text(public.fin_alertas_cobros_armar('liam', now(), true) -> 'mensajes')
--     with ordinality as m(texto, ord) order by 1;
--
-- C4. Que webhooks cargados hay (solo nombres, nunca la URL):
--   select name from vault.decrypted_secrets where name like 'fin_discord_webhook_cobros%' order by 1;
--
-- C5. Simulacro del cron SIN enviar (devuelve a quien le mandaria hoy y con cuantos mensajes):
--   select public.fin_alertas_cobros_enviar(now(), false);
--   -- solo lista clientes activos, con webhook, cuya hora_envio ya paso y sin envio entregado hoy.
--
-- C6. Ultimos envios y su entrega:
--   select id, creado, cliente_id, fecha, mensajes, cuentas, entregado
--   from public.fin_alertas_cobros_log order by id desc limit 10;
--
-- C7. El cron:
--   select status::text, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'fin_alertas_cobros') order by start_time desc limit 5;
--
-- ---------------------------------------------------------------------------
-- A MANO, una sola vez por cliente (Joaquin; fuera del repo):
--   select vault.create_secret('<URL del webhook de Discord>', 'fin_discord_webhook_cobros_liam');
--   -- o un canal general para todos:  select vault.create_secret('<URL>', 'fin_discord_webhook_cobros');
-- Prender la alerta (o desde la app: seccion Alertas, que usa fin_alertas_cobros_config_guardar):
--   update public.fin_alertas_cobros_config set activo = true where cliente_id = 'liam';
-- Mostrar montos para un cliente:
--   update public.fin_alertas_cobros_config set mostrar_montos = true where cliente_id = 'liam';
--
-- VUELTA ATRAS (no toca ninguna tabla anterior):
--   select cron.unschedule(jobid) from cron.job where jobname = 'fin_alertas_cobros';
--   drop function if exists public.fin_alertas_cobros_vista_previa(text, boolean);
--   drop function if exists public.fin_alertas_cobros_config_guardar(text, boolean, int, boolean);
--   drop function if exists public.fin_alertas_cobros_estado();
--   drop function if exists public.fin_alertas_cobros_enviar(timestamptz, boolean);
--   drop function if exists public.fin_alertas_cobros_confirmar(timestamptz);
--   drop function if exists public.fin_cobros_post(text, text);
--   drop function if exists public.fin_alertas_cobros_armar(text, timestamptz, boolean, boolean);
--   drop function if exists public.fin_cobros_limpiar(text);
--   drop table if exists public.fin_alertas_cobros_log;
--   drop table if exists public.fin_alertas_cobros_config;
