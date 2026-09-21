-- 004_cron.sql — Dystopia Finanzas: sincronizacion cada 15 minutos.
-- NO CORRER hasta que:
--   1. 005_sync_escribir.sql este corrida (sin ella cada fuente termina en error).
--   2. La Edge Function 'sincronizar' este deployada (--no-verify-jwt) y una
--      prueba manual por HTTP haya dado bien.
--   3. Existan en Vault los dos secretos de abajo (el paso 0 los crea; la
--      service_role key NO se escribe en este archivo ni en el repo).
--
-- pg_cron 1.6.4 y pg_net 0.20.4 ya estan habilitados.
-- Idempotente: si el job ya existe, se reemplaza.

-- ---------------------------------------------------------------------------
-- Paso 0 (una sola vez, A MANO en el SQL Editor, fuera de este archivo):
--   select vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/sincronizar', 'fin_sync_url');
--   select vault.create_secret('<una secret key sb_secret_...: Project Settings > API Keys>', 'fin_sync_service_key');
--   OJO: tiene que ser una sb_secret_ nueva. La service_role key LEGACY (JWT
--   eyJ...) la funcion la rechaza a proposito (ver sincronizar/auth.ts).
-- ---------------------------------------------------------------------------

begin;

-- Sin los secretos el cron correria y fallaria en silencio: se corta aca.
do $$
begin
  if (select count(*) from vault.decrypted_secrets where name in ('fin_sync_url', 'fin_sync_service_key')) <> 2 then
    raise exception 'faltan los secretos fin_sync_url y/o fin_sync_service_key en Vault (ver paso 0)';
  end if;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'fin_sincronizar';

-- La Edge Function tarda unos segundos por planilla: timeout de 150 s.
select cron.schedule(
  'fin_sincronizar',
  '*/15 * * * *',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_service_key')
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 150000
    );
  $cron$
);

-- ---------------------------------------------------------------------------
-- Prueba de humo (se autorrevierte): el job quedo una sola vez, activo y con
-- el horario correcto. No dispara la funcion.
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  begin
    select count(*) into v_n from cron.job
    where jobname = 'fin_sincronizar' and schedule = '*/15 * * * *' and active;
    if v_n <> 1 then raise exception 'smoke 004: se esperaba 1 job activo fin_sincronizar y hay %', v_n; end if;
    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then raise notice 'prueba de humo 004: OK'; else raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control
-- ---------------------------------------------------------------------------
select jobid, jobname, schedule, active::text as activo
from cron.job
where jobname = 'fin_sincronizar';

commit;

-- Despues de 15-20 minutos, para ver si corrio:
--   select status::text, return_message, start_time from cron.job_run_details
--   where jobid = (select jobid from cron.job where jobname = 'fin_sincronizar')
--   order by start_time desc limit 5;
--   select id, status_code, left(content::text, 300), error_msg, created
--   from net._http_response order by created desc limit 5;
