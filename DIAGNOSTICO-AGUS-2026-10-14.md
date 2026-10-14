# Diagnóstico planillas de Agus (14/10/2026) · solo lectura

Límite: no pude leer la hoja VIVA (la lectura necesita los secretos de Google de la Edge Function, que no
están en el repo) ni la base. "Antes" = fixture del 21/09 (`pruebas/fixtures/agus_*.json`, última foto
guardada en el repo). La corrida buena real fue el 3/10: si la hoja cambió entre el 21/09 y el 3/10 y se
aceptó, el "antes" real difiere un poco. Lo que guarda la base es solo el HASH del encabezado
(`fin_sync_corridas.hash_encabezado`), no el texto: no se puede reconstruir el encabezado guardado desde ahí.

## Tabla

| Hoja | Antes (fixture 21/09) | Ahora | Qué cambió |
|---|---|---|---|
| Agus Opps (fuente 7, "Opps") | Fila 4 = `YEAR REVIEW, null, JANUARY, …, DECEMBER` (inglés, mayúsculas, bloques de 4 columnas desde la col C). Error actual: "no se encontro la fila de meses ('JANUARY')" | NO VERIFICADO (no leí la hoja). Por el mensaje: ya no hay ninguna celda que normalizada sea exactamente `january`. Candidatos: castellano (`ENERO`), abreviado (`ene`/`Jan`), con año (`ENERO 2026`) o un `JANUARY ` con otro texto | Parser: ya acepta inglés, castellano, abreviado (con o sin punto) y con año; ver abajo. Si la causa es otra (fila de meses borrada, celdas combinadas, fechas reales), el parser sigue dando error y hay que ver la hoja |
| Agus Pagos (fuente 8, "Pagos") | 27 columnas, 12 con texto: `FECHA DE CARGA, PROGRAMA, NOMBRE DEL ALUMNO, NUMERO, CONCEPTO, PAGO, CLOSER, SETTER, COMPROBANTE, QUIÉN RECIBE, MÉTODO DE PAGO, MÉTODO DE PAGO` (la última está duplicada) | NO VERIFICADO | El hash cambió. El hash cubre TODA la fila de encabezado (texto, orden, columnas nuevas, renombres, espacios): cualquier columna agregada o renombrada lo dispara aunque los datos estén bien |

## Opps: cambio hecho
- `supabase/functions/_shared/parsers/opps.js`: nueva `mesDeRotulo()`. La fila de meses es la primera con
  3 o más rótulos de mes reconocibles (antes: la primera con `january`). Acepta `JANUARY`, `ENERO`,
  `ene`, `Ene.`, `Sept`/`Set`, `ENERO 2026`, `ene-26`. `encabezado` se sigue armando con el nombre en inglés,
  así que el hash NO cambia y no hace falta `aceptar_encabezado` en Opps.
- `pruebas/opps-meses.mjs` (en `npm test`): el fixture de Agus con los meses reescritos en castellano,
  abreviado, abreviado con punto y con año da las mismas filas y el mismo encabezado que en inglés.
  Liam y Teo siguen igual (usan `JANUARY`).
- Aviso aparte, no es del parser: en el fixture del 21/09 la hoja de Agus ya traía Jul-Sep (73.649, 96.544,
  73.844) bajo los rótulos JANUARY/FEBRUARY/JULY. Esos "meses corridos" que ve la revisión vienen de los
  rótulos de la hoja (Pendientes 6, "rótulos de meses en Opps de agus"), no de la lectura. El parser lee el
  mes que dice el rótulo. Hay que corregirlos en la planilla.

## Pagos: qué dejar decidido (NO ejecutado)
1. Mirar la hoja "Pagos" de Agus y comparar con los 12 encabezados de arriba (orden, textos, columnas nuevas).
2. Si el cambio es correcto y solo agregaron/renombraron columnas que no usamos: sincronizar esa fuente
   aceptando el encabezado (lo corre el jefe, con la sb_secret_ del proyecto):
   `POST /functions/v1/sincronizar` con cuerpo `{ "fuente_id": 8, "aceptar_encabezado": true }`.
   Antes, `{ "fuente_id": 8, "dry_run": true }` para ver conteos sin escribir.
3. Si renombraron una columna que el parser usa (FECHA, ALUMNO, PAGO, CONCEPTO…), aceptar el encabezado no
   alcanza: la corrida daría "faltan columnas". Hay que agregar el alias nuevo en `fin_alias_columnas` de la
   fuente 8 (migración, necesita número del jefe) y recién después aceptar.
4. Si la hoja de Pagos de Agus ya se cortó en la app (067, no confirmado como corrida), esta fuente no
   debería leerse: verificar `fin_fuentes.activo/cortada_en` de la 8 antes de aceptar nada.

## Actualización (14/10, segunda tanda con las planillas reales): BLOQUEADA, "ahora" sigue NO VERIFICADO
- Las planillas reales están en `jefe\insumos\planillas-2026-10-14\` (Agus y Teo, `... - Finanzas 2026.xlsx`), pero en esa
  sesión no se pudo ejecutar `node` (pedía aprobación y no había quien la diera). Un .xlsx es un zip: no se lee a mano.
  Por eso la columna "Ahora" de arriba no cambia y no hay conteos. No se inventó ningún resultado.
- Dejado listo: `pruebas/diagnostico-planilla.mjs` (solo lectura, usa los parsers reales de `_shared`, imprime estructura y
  conteos, sin nombres ni montos). Correr desde el repo:
  `node pruebas/diagnostico-planilla.mjs agus "C:\Users\Admin\Downloads\jefe\insumos\planillas-2026-10-14\agus\De CERO a CEO - Finanzas 2026.xlsx"`
  `node pruebas/diagnostico-planilla.mjs teo "C:\Users\Admin\Downloads\jefe\insumos\planillas-2026-10-14\teo\North Ecom - Finanzas 2026.xlsx"`
- Qué imprime: fila y rótulos de meses de Opps (y a qué mes los lee el parser), items por mes, encabezado actual de Pagos
  contra el fixture del 21/09 (columnas nuevas, quitadas, orden) y filas leídas/cargadas/rechazadas/descartadas por motivo.
- Cómo decidir con el resultado: (a) Pagos con solo columnas agregadas o renombradas que el mapeo no usa y filas cargadas:
  redeploy + aceptar encabezado; (b) "faltan columnas obligatorias": alias nuevo en `fin_alias_columnas` (migración, hay que
  pedir número); (c) rótulos de Opps corridos (julio a septiembre bajo JANUARY/FEBRUARY): el parser lee lo que dice el
  rótulo, la corrección es en la planilla (el script lista col:texto de cada rótulo, de ahí salen las celdas).
- Ojo: `pruebas/config.mjs` usa los alias del seed para Agus; la base real puede tener otros en `fin_alias_columnas` (fuente 8).
