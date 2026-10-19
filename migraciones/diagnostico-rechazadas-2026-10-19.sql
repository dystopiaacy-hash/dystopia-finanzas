-- DIAGNOSTICO de solo lectura (no cambia datos, no es migracion, no lleva numero). 19/10/2026.
-- Filas rechazadas de la sync: Agus pagos (18), Agus opps (meses repetidos, columna AA), Liam opps (2).
-- Correr DE A UNO (el editor muestra solo el ultimo resultado). Cada query usa la ULTIMA corrida de la fuente.

-- D1. Fuentes de Agus y Liam (ids, tipo, activa/cortada). NO tocar la de pagos de Liam (cortada a proposito).
-- select id, cliente_id, tipo, nombre_hoja_esperado, activo, cortada_en from public.fin_fuentes where cliente_id in ('agus','liam') order by cliente_id, tipo, id;

-- D2. AGUS PAGOS: las rechazadas de la ultima corrida, con motivo, valor y contenido de la fila.
--     Mirar: motivo (falta monto / refund sin monto numerico / monto ambiguo / fecha en celda de monto),
--     alumno y concepto dentro de contenido_crudo, y fila_planilla para ubicarla en la hoja.
-- select r.fila_planilla, r.motivo, r.valor_crudo, r.comprobante, r.contenido_crudo
--   from public.fin_filas_rechazadas r
--  where r.corrida_id = (select c.id from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--                         where f.cliente_id = 'agus' and f.tipo = 'pagos' order by c.inicio desc limit 1)
--  order by r.fila_planilla;

-- D3. AGUS PAGOS: conteo por motivo (esperado el 14/10: falta monto 13, refund sin monto numerico 3; ahora son 18).
-- select r.motivo, count(*) from public.fin_filas_rechazadas r
--  where r.corrida_id = (select c.id from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--                         where f.cliente_id = 'agus' and f.tipo = 'pagos' order by c.inicio desc limit 1)
--  group by 1 order by 2 desc;

-- D4. AGUS PAGOS: ultimas corridas (estado, rechazadas, mensaje) para ver desde cuando son 18.
-- select c.id, c.inicio, c.estado, c.filas_leidas, c.filas_cargadas, c.filas_rechazadas, left(c.mensaje, 200) as mensaje
--   from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--  where f.cliente_id = 'agus' and f.tipo = 'pagos' order by c.inicio desc limit 10;

-- D5. AGUS OPPS: mensaje y controles de la ultima corrida. Buscar "mes repetido en el encabezado (<mes>): se uso el bloque de la
--     columna X, se ignoro el de la columna AA" y las entradas de `controles`/revisar con ese motivo. Dice que meses y que columnas.
-- select c.id, c.inicio, c.estado, c.filas_leidas, c.filas_cargadas, c.filas_rechazadas, c.mensaje, c.controles
--   from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--  where f.cliente_id = 'agus' and f.tipo = 'opps' order by c.inicio desc limit 1;

-- D6. AGUS OPPS: que hay cargado por mes (sirve para ver si el bloque que se USA (castellano, primero a la izquierda)
--     es el que tiene los numeros reales). Comparar contra lo que se ve en la hoja en C y en AA.
-- select anio, mes, categoria, count(*) as items, sum(monto_usd) as total, min(columna_planilla) as col_min, max(columna_planilla) as col_max
--   from public.fin_pnl where cliente_id = 'agus' group by 1, 2, 3 order by 1, 2, 3;

-- D7. LIAM OPPS: las 2 rechazadas (hipotesis: "posible reparto sin beneficiario", montos 4267 y 13563,42 de febrero sin etiqueta).
-- select r.fila_planilla, r.motivo, r.valor_crudo, r.contenido_crudo
--   from public.fin_filas_rechazadas r
--  where r.corrida_id = (select c.id from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--                         where f.cliente_id = 'liam' and f.tipo = 'opps' order by c.inicio desc limit 1)
--  order by r.fila_planilla;

-- D8. LIAM OPPS: reparto cargado (para ver si falta el beneficiario de febrero y si el total cierra con Retained Earnings).
-- select anio, mes, beneficiario, monto from public.fin_reparto where cliente_id = 'liam' order by anio, mes, beneficiario;
