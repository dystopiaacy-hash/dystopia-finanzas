-- 160: DIAGNOSTICO de solo lectura (no cambia datos). Salud de sincronizacion del 16/10:
-- liam Pagos y Data "Inactivas desde el 12/10", teo sin pagos despues del 30/09.
-- Correr de a uno (el editor muestra solo el ultimo resultado).

-- C1. Fuentes inactivas/cortadas: liam pagos = 076 (12/10), liam data = 077. Esperado: cortada_en del 12/10 en esas dos y NINGUNA otra inactiva sin explicacion.
-- select id, cliente_id, tipo, nombre_hoja_esperado, activo, cortada_en from public.fin_fuentes order by cliente_id, tipo, id;

-- C2. Ultima corrida de cada fuente ACTIVA (estado, mensaje, rechazadas, hora). Si todas son de hace < 15 min, la sync (cron) corre bien.
-- select distinct on (f.id) f.cliente_id, f.tipo, c.estado, c.inicio, c.filas_leidas, c.filas_cargadas, c.filas_rechazadas, left(c.mensaje, 160) as mensaje
--   from public.fin_fuentes f join public.fin_sync_corridas c on c.fuente_id = f.id
--  where f.activo order by f.id, c.inicio desc;

-- C3. Liam: pagos por origen y por mes de 2026. Esperado: octubre con origen 'app' solo lo cargado a mano en la app desde el 12/10.
-- select to_char(fecha, 'YYYY-MM') as mes, origen, count(*) as pagos, sum(monto_usd) as usd
--   from public.fin_pagos where cliente_id = 'liam' and fecha >= '2026-09-01' group by 1, 2 order by 1, 2;

-- C4. Teo: ultimo pago cargado y rechazos de su fuente de pagos (si las filas de octubre estan rechazadas, ahi esta el corte).
-- select max(fecha) as ultimo_pago, count(*) as pagos from public.fin_pagos where cliente_id = 'teo';
-- select r.fila_planilla, r.motivo, r.valor_crudo from public.fin_filas_rechazadas r join public.fin_fuentes f on f.id = r.fuente_id
--  where f.cliente_id = 'teo' and f.tipo = 'pagos' order by r.fila_planilla;
