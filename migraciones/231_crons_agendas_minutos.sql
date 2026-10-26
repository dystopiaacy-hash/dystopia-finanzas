-- =====================================================================
-- 231. Crons de agendas a minutos permitidos
-- (reemplaza los horarios de la 131 y de la 230; NO toca funciones, tablas
--  ni Edge Functions: solo cambia el schedule de dos jobs de pg_cron)
-- =====================================================================
-- Antes:
--   fin_agendas_procesar        11,26,43,56 * * * *        (131)
--   fin_agenda_avisos_confirmar 3,13,23,33,43,53 * * * *   (230)
-- Despues (pg_cron corre en UTC; 9:00 a 9:21 ART = 12:00 a 12:21 UTC no puede correr nada):
--   fin_agendas_procesar        1,16,31,46   en horas 0-11 y 13-23
--   fin_agenda_avisos_confirmar 6,21,36,51   en horas 0-11 y 13-23
--
-- OPCION ELEGIDA: horas partidas + un job extra para la hora 12 UTC solo con
-- los minutos validos (no se usa guard dentro del comando). Motivo: el comando
-- de cada job queda EXACTAMENTE igual al de hoy (el de la 131 y el de la 230),
-- sin logica nueva que pueda fallar; el cron mismo garantiza la ventana.
--   fin_agendas_procesar_h12        31,46 en hora 12  (12:01 y 12:16 quedan afuera)
--   fin_agenda_avisos_confirmar_h12 36,51 en hora 12  (12:06 y 12:21 quedan afuera)
--
-- Idempotente: cada job se des-programa por nombre si existe y se vuelve a
-- crear; correrla dos veces deja los mismos 4 jobs, sin duplicados.
-- Correr en un minuto permitido (no :00/:15/:30/:45 ni 9:00 ART).
-- Depende de que existan fin_agendas_procesar_pendientes() (131) y
-- fin_agenda_avisos_confirmar() (230): si falta alguna, aborta sin tocar nada.
-- =====================================================================

do $$
begin
  if to_regprocedure('public.fin_agendas_procesar_pendientes(integer)') is null then
    raise exception '231: falta fin_agendas_procesar_pendientes (migracion 131). No se toco nada.';
  end if;
  if to_regprocedure('public.fin_agenda_avisos_confirmar()') is null then
    raise exception '231: falta fin_agenda_avisos_confirmar (migracion 230). No se toco nada.';
  end if;

  -- fin_agendas_procesar (comando de la 131)
  perform cron.unschedule(jobid) from cron.job
   where jobname in ('fin_agendas_procesar', 'fin_agendas_procesar_h12');
  perform cron.schedule('fin_agendas_procesar', '1,16,31,46 0-11,13-23 * * *',
    $cron$ select public.fin_agendas_procesar_pendientes(); $cron$);
  perform cron.schedule('fin_agendas_procesar_h12', '31,46 12 * * *',
    $cron$ select public.fin_agendas_procesar_pendientes(); $cron$);

  -- fin_agenda_avisos_confirmar (comando de la 230)
  perform cron.unschedule(jobid) from cron.job
   where jobname in ('fin_agenda_avisos_confirmar', 'fin_agenda_avisos_confirmar_h12');
  perform cron.schedule('fin_agenda_avisos_confirmar', '6,21,36,51 0-11,13-23 * * *',
    'select public.fin_agenda_avisos_confirmar()');
  perform cron.schedule('fin_agenda_avisos_confirmar_h12', '36,51 12 * * *',
    'select public.fin_agenda_avisos_confirmar()');
end $$;

-- =====================================================================
-- CONTROLES (correr DE A UNO)
-- =====================================================================
-- C1. Los 4 jobs, activos y con el comando de siempre:
--   select jobname, schedule, command, active
--     from cron.job
--    where jobname like 'fin_agenda%'
--    order by jobname;
-- Esperado: exactamente 4 filas, active = true:
--   fin_agenda_avisos_confirmar      | 6,21,36,51 0-11,13-23 * * * | select public.fin_agenda_avisos_confirmar()
--   fin_agenda_avisos_confirmar_h12  | 36,51 12 * * *              | select public.fin_agenda_avisos_confirmar()
--   fin_agendas_procesar             | 1,16,31,46 0-11,13-23 * * * |  select public.fin_agendas_procesar_pendientes();
--   fin_agendas_procesar_h12         | 31,46 12 * * *              |  select public.fin_agendas_procesar_pendientes();
--
-- C2. Sin duplicados (correrla dos veces no suma jobs). Esperado: 0 filas:
--   select jobname, count(*) from cron.job
--    where jobname like 'fin_agenda%' group by jobname having count(*) > 1;
--
-- C3. No quedaron los horarios viejos. Esperado: 0 filas:
--   select jobname, schedule from cron.job
--    where jobname like 'fin_agenda%'
--      and schedule in ('11,26,43,56 * * * *', '3,13,23,33,43,53 * * * *');
--
-- C4. Despues de unos minutos, que corrieron en los minutos nuevos (esperado: start_time con
--     minutos 1,16,31,46 / 6,21,36,51; status 'succeeded'):
--   select j.jobname, d.start_time, d.status, d.return_message
--     from cron.job_run_details d join cron.job j using (jobid)
--    where j.jobname like 'fin_agenda%'
--    order by d.start_time desc limit 12;
--
-- VUELTA ATRAS (volver a los horarios de la 131 y la 230):
--   select cron.unschedule(jobid) from cron.job
--    where jobname in ('fin_agendas_procesar_h12', 'fin_agenda_avisos_confirmar_h12');
--   select cron.alter_job((select jobid from cron.job where jobname = 'fin_agendas_procesar'),
--                         schedule := '11,26,43,56 * * * *');
--   select cron.alter_job((select jobid from cron.job where jobname = 'fin_agenda_avisos_confirmar'),
--                         schedule := '3,13,23,33,43,53 * * * *');
