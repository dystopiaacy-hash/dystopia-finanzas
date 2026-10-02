-- =====================================================================
-- 067_corte_agus_pagos.sql
-- FINANZAS, fase 7: corte de la planilla de PAGOS de agus.
--
-- NO CORRER hasta el dia acordado. Antes de correrla:
--   1. El equipo de agus sabe que desde hoy los pagos se cargan en la app
--      (dystopia-finanzas.vercel.app/#/cargar) y no en la planilla.
--   2. Se espero a la ultima sincronizacion despues de lo ultimo cargado
--      en la planilla (C0 de abajo: la ultima corrida de agus pagos tiene
--      que ser posterior a la ultima carga).
--   3. Despues de correrla: sacar el menu "Cargar pago" de la planilla de
--      agus (o protegerla como solo lectura).
--
-- Que hace:
--   - fin_fuentes de agus tipo 'pagos': cortada_en = now(), activo = false.
--     La sync deja de leerla. Los pagos que ya estan cargados quedan como
--     estan (no se borran) y el formulario de la app se habilita para agus.
--   - Solo PAGOS. El Opps (gastos) de agus sigue sincronizando igual.
-- Un corte no se deshace desde la app (fin_fuentes_cortada_ck).
-- =====================================================================

-- C0 (correr ANTES, solo lectura): ultima corrida de pagos de agus.
-- select c.estado, c.filas_cargadas, c.inicio
--   from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--  where f.cliente_id = 'agus' and f.tipo = 'pagos' order by c.id desc limit 1;

do $$
declare n int;
begin
  if to_regprocedure('public.fin_pago_cargar(jsonb)') is null then
    raise exception 'GUARDA 067: falta la 066 (carga desde la app). No se corta nada.';
  end if;
  select count(*) into n from public.fin_fuentes
   where cliente_id = 'agus' and tipo = 'pagos' and activo and cortada_en is null;
  if n = 0 then
    raise notice '067: la planilla de pagos de agus ya estaba cortada. No se hace nada.';
  end if;
end $$;

update public.fin_fuentes
   set cortada_en = now(), activo = false
 where cliente_id = 'agus' and tipo = 'pagos' and cortada_en is null;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. agus habilitado, el resto no. Esperado: solo agus en true.
-- select cliente_id, public.fin_carga_habilitada(cliente_id)
--   from public.fin_fuentes where tipo = 'pagos' order by 1;

-- C2. Los pagos de agus siguen ahi (la misma cantidad que antes del corte, ~250).
-- select origen, count(*) from public.fin_pagos where cliente_id = 'agus' group by 1;

-- C3. El Opps de agus sigue activo (true).
-- select activo from public.fin_fuentes where cliente_id = 'agus' and tipo = 'opps';
