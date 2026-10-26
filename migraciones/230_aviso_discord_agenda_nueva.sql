-- =====================================================================
-- 230_aviso_discord_agenda_nueva.sql
-- Ventas: aviso a Discord cuando entra una agenda NUEVA de GHL y queda
-- procesada OK. Liam, Agus y Teo (Teo hoy sin agendas: funciona igual).
--
-- COMO FUNCIONA
--   * Trigger AFTER UPDATE en fin_agendas_entrantes: cuando fin_procesar_agenda
--     (131) deja la agenda procesada (procesado_en pasa de null a un valor, sin
--     error) y el evento es 'agendada', manda UN mensaje a Discord.
--     fin_procesar_agenda NO se toca (solo se le engancha el aviso por trigger).
--   * Un aviso por cita: fin_agenda_avisos tiene UNIQUE (cliente_id, cita_id).
--     Si GHL manda la misma cita dos veces, o el respaldo reabre y reprocesa la
--     agenda, el segundo intento no inserta y no manda nada.
--   * No avisa reprogramaciones, cancelaciones ni eventos 'superada'.
--   * El aviso NUNCA rompe la carga: todo va dentro de un bloque con
--     exception when others; si algo falla se guarda el error en el log y la
--     agenda se procesa igual.
--   * Mismo mecanismo que las alertas de cobros (103/109): pg_net + webhook en
--     Vault. El webhook NO esta en esta migracion ni en el codigo.
--
-- WEBHOOK (lo carga Joaquin, ver el final del archivo)
--   fin_discord_webhook_agendas_<cliente>   canal propio (liam / agus / teo)
--   fin_discord_webhook_agendas             canal general (si el cliente no tiene el suyo)
--
-- Solo aditiva: tabla nueva, 3 funciones nuevas, 1 trigger, 1 cron. Idempotente.
-- Sin begin/commit (SQL Editor). Correr fuera de :00/:15/:30/:45.
-- Depende de la 131 (fin_agendas_entrantes con datos/evento/vinculo_ref) y de pg_net / pg_cron.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_agendas_entrantes' and column_name = 'datos') then
    raise exception '230 requiere la 131 (fin_agendas_entrantes.datos)';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise exception '230 requiere la extension pg_net';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Log (una fila por cita avisada)
-- ---------------------------------------------------------------------
create table if not exists public.fin_agenda_avisos (
  id          bigserial primary key,
  cliente_id  text        not null,
  cita_id     text        not null,
  agenda_id   bigint,
  creado      timestamptz not null default now(),
  resultado   text        not null,   -- 'enviado' | 'sin_webhook' | 'error'
  request_id  bigint,
  entregado   boolean,                -- null = esperando respuesta de Discord, true = 2xx, false = fallo
  error       text,
  texto       text,
  constraint fin_agenda_avisos_uk unique (cliente_id, cita_id)
);

comment on table public.fin_agenda_avisos is
  '230: un renglon por cita avisada a Discord (unique cliente + cita = nunca repite). El webhook NO esta aca: vive en Vault.';

alter table public.fin_agenda_avisos enable row level security;
revoke all on table public.fin_agenda_avisos from public, anon, authenticated;
revoke all on sequence public.fin_agenda_avisos_id_seq from public, anon, authenticated;
-- sin policies: solo postgres / service_role leen y escriben

-- ---------------------------------------------------------------------
-- BLOQUE 3. Funcion del trigger
-- ---------------------------------------------------------------------
create or replace function public.fin_agenda_aviso_discord()
returns trigger
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_cliente text := new.cliente_id;
  v_cita    text := new.ghl_cita_id;
  v_url     text;
  v_nombre_c text;
  v_lead    text;
  v_fuente  text;
  v_closer  text;
  v_fecha   text;
  v_texto   text;
  v_log     bigint;
  v_req     bigint;
begin
  begin
    if v_cita is null then return new; end if;
    if new.vinculo_ref like 'superada%' then return new; end if;

    -- Una sola vez por cita: si ya hay fila, no se avisa de nuevo.
    insert into public.fin_agenda_avisos (cliente_id, cita_id, agenda_id, resultado)
    values (v_cliente, v_cita, new.id, 'error')
    on conflict (cliente_id, cita_id) do nothing
    returning id into v_log;
    if v_log is null then return new; end if;

    select s.decrypted_secret into v_url
      from vault.decrypted_secrets s
     where s.name in ('fin_discord_webhook_agendas_' || v_cliente, 'fin_discord_webhook_agendas')
       and nullif(btrim(s.decrypted_secret), '') is not null
     order by (s.name = 'fin_discord_webhook_agendas') limit 1;

    if v_url is null then
      update public.fin_agenda_avisos
         set resultado = 'sin_webhook', entregado = false,
             error = 'falta fin_discord_webhook_agendas_' || v_cliente || ' (o fin_discord_webhook_agendas) en Vault'
       where id = v_log;
      return new;
    end if;

    select k.nombre into v_nombre_c from public.crm_clients k where k.id = v_cliente;

    v_lead   := nullif(btrim(coalesce(new.datos ->> 'nombre', '')), '');
    if v_lead = '(sin nombre)' then v_lead := null; end if;
    v_fuente := nullif(btrim(coalesce(new.datos ->> 'fuente', '')), '');
    v_closer := nullif(btrim(coalesce(new.datos ->> 'closer', '')), '');
    -- datos.fecha / datos.hora son la hora local tal cual la muestra GHL (Argentina)
    v_fecha  := case when new.datos ->> 'fecha' is not null
                     then to_char((new.datos ->> 'fecha')::date, 'DD/MM/YYYY')
                          || coalesce(' ' || left(new.datos ->> 'hora', 5), '') end;

    v_texto := '📅 Nueva agenda – ' || coalesce(v_nombre_c, v_cliente)
      || E'\nLead: '   || coalesce(left(v_lead, 80),   'sin nombre')
      || E'\nFuente: ' || coalesce(left(v_fuente, 40), 'sin fuente')
      || E'\nCloser: ' || coalesce(left(v_closer, 60), 'sin asignar')
      || E'\nLlamada: ' || coalesce(v_fecha, 'sin fecha') || ' (hora Argentina)';
    -- sin menciones ni formato que Discord interprete
    v_texto := regexp_replace(v_texto, '[@`*_~|>]', '', 'g');

    v_req := net.http_post(
      url     := v_url || case when v_url like '%?%' then '&' else '?' end || 'wait=true',
      headers := jsonb_build_object('content-type', 'application/json'),
      body    := jsonb_build_object('username', 'Dystopia Ventas', 'content', v_texto,
                                    'allowed_mentions', jsonb_build_object('parse', '[]'::jsonb)),
      timeout_milliseconds := 10000);

    update public.fin_agenda_avisos
       set resultado = 'enviado', request_id = v_req, entregado = null, error = null, texto = v_texto
     where id = v_log;
  exception when others then
    -- el aviso nunca rompe la carga de la agenda
    begin
      update public.fin_agenda_avisos
         set resultado = 'error', entregado = false, error = left(sqlerrm, 500)
       where cliente_id = v_cliente and cita_id = v_cita;
    exception when others then null;
    end;
  end;
  return new;
end;
$fn$;

comment on function public.fin_agenda_aviso_discord() is
  '230: trigger de fin_agendas_entrantes. Aviso a Discord de agenda nueva ya procesada, una vez por cita. Nunca lanza error.';

revoke all on function public.fin_agenda_aviso_discord() from public, anon, authenticated;

drop trigger if exists fin_agenda_aviso_discord_tg on public.fin_agendas_entrantes;
create trigger fin_agenda_aviso_discord_tg
  after update of procesado_en on public.fin_agendas_entrantes
  for each row
  when (old.procesado_en is null and new.procesado_en is not null
        and new.error is null and new.evento = 'agendada')
  execute function public.fin_agenda_aviso_discord();

-- ---------------------------------------------------------------------
-- BLOQUE 4. Confirmacion (mira la respuesta de Discord) + cron
-- ---------------------------------------------------------------------
create or replace function public.fin_agenda_avisos_confirmar()
returns int
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  r   record;
  h   record;
  v_n int := 0;
begin
  for r in
    select id, request_id, creado from public.fin_agenda_avisos
     where entregado is null and request_id is not null
     order by id
  loop
    select status_code, error_msg, left(content, 200) as cuerpo into h
      from net._http_response where id = r.request_id;
    if found then
      if h.status_code between 200 and 299 then
        update public.fin_agenda_avisos set entregado = true where id = r.id;
      else
        update public.fin_agenda_avisos
           set entregado = false, resultado = 'error',
               error = left(coalesce('Discord ' || h.status_code::text || ' ' || h.cuerpo, h.error_msg, 'sin detalle'), 500)
         where id = r.id;
      end if;
      v_n := v_n + 1;
    elsif r.creado < now() - interval '30 minutes' then
      update public.fin_agenda_avisos
         set entregado = false, resultado = 'error', error = 'sin respuesta de Discord en 30 minutos'
       where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$fn$;

revoke all on function public.fin_agenda_avisos_confirmar() from public, anon, authenticated;
grant execute on function public.fin_agenda_avisos_confirmar() to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'fin_agenda_avisos_confirmar') then
    perform cron.unschedule('fin_agenda_avisos_confirmar');
  end if;
  perform cron.schedule('fin_agenda_avisos_confirmar', '3,13,23,33,43,53 * * * *',
                        'select public.fin_agenda_avisos_confirmar()');
end $$;

-- ---------------------------------------------------------------------
-- CARGA DEL WEBHOOK (lo hace Joaquin, una vez por cliente; NO pegar URLs en el repo)
-- ---------------------------------------------------------------------
--   select vault.create_secret('<URL del webhook de Discord de Liam>', 'fin_discord_webhook_agendas_liam');
--   select vault.create_secret('<URL del webhook de Discord de Agus>', 'fin_discord_webhook_agendas_agus');
--   select vault.create_secret('<URL del webhook de Discord de Teo>',  'fin_discord_webhook_agendas_teo');
--   -- o un canal general para todos:  select vault.create_secret('<URL>', 'fin_discord_webhook_agendas');
--   -- (si el secreto ya existe: select vault.update_secret(id, '<URL>') con el id de vault.secrets)

-- ---------------------------------------------------------------------
-- CONTROLES (correr DE A UNO)
-- ---------------------------------------------------------------------
-- C1. Trigger y cron presentes (2 filas):
--   select 'trigger' as que, tgname::text from pg_trigger where tgname = 'fin_agenda_aviso_discord_tg' and not tgisinternal
--   union all select 'cron', jobname from cron.job where jobname = 'fin_agenda_avisos_confirmar';
-- C2. Que webhooks hay cargados (solo nombres, nunca la URL):
--   select name from vault.decrypted_secrets where name like 'fin_discord_webhook_agendas%' order by 1;
-- C3. Ultimos avisos y su resultado:
--   select id, creado, cliente_id, cita_id, resultado, entregado, error from public.fin_agenda_avisos order by id desc limit 20;
-- C4. Nunca hay dos avisos de la misma cita (0 filas):
--   select cliente_id, cita_id, count(*) from public.fin_agenda_avisos group by 1, 2 having count(*) > 1;
-- C5. Prueba con una agenda de prueba: mandar el webhook ventas-agenda con una cita nueva (evento 'agendada'),
--     esperar al cron de agendas o procesarla a mano con
--       select public.fin_procesar_agenda(<id de fin_agendas_entrantes>);
--     y ver C3: 1 fila 'enviado' y el mensaje en Discord. Reenviar la MISMA cita: sigue 1 fila, sin 2do mensaje.
--     (Para repetir la prueba con el mismo cita_id: delete from public.fin_agenda_avisos where cita_id = '<id>' y
--      update public.fin_agendas_entrantes set procesado_en = null where id = <id>.)
-- VUELTA ATRAS (los avisos quedan en la tabla como historial; para borrar todo, tambien drop table):
--   drop trigger if exists fin_agenda_aviso_discord_tg on public.fin_agendas_entrantes;
--   select cron.unschedule('fin_agenda_avisos_confirmar');
--   drop function if exists public.fin_agenda_avisos_confirmar();
--   drop function if exists public.fin_agenda_aviso_discord();
