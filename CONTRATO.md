# CONTRATO.md — contrato de columnas de Dystopia Finanzas

Sección 2 del PLAN.md pasada a datos, corregida con lo que mostraron los
fixtures reales (2026-09-21) y con las decisiones de Joaquín sobre esas
diferencias. Es la fuente de `002_seed_config.sql` y de `parsers/contrato.js`.
Si cambia algo acá, cambia en los dos.

## 0. Cómo se lee Google Sheets: GRID, no `FORMATTED_VALUE` (2026-09-21)

**Regla.** Cada hoja se lee con `spreadsheets.get` + `includeGridData=true`,
pidiendo solo estos campos (`fields`):

```
sheets(properties(title),data(startRow,rowData(values(formattedValue,effectiveValue,effectiveFormat/numberFormat/type))))
```

Por celda llega el texto que se ve, el valor real y el **tipo** de formato.
`supabase/functions/_shared/grid.js` lo convierte en la matriz de los parsers:

| Celda | Llega al parser como |
|---|---|
| Número (NUMBER, CURRENCY, sin formato) | el valor real, sin el redondeo del formato |
| PERCENT, TIME | el texto que se ve (no son montos: se rechazan) |
| Texto | el texto, normalizado con el locale de la planilla (`formato.js`) |
| DATE / DATE_TIME, valor en `serialMin..serialMax` | fecha completa `AAAA-MM-DD`, se vea como se vea |
| DATE / DATE_TIME, valor ≤ `montoMaximoReal` | el número (pago real en celda con formato de fecha pegado) |
| DATE / DATE_TIME, cualquier otro valor ("tierra de nadie") | marcada como ambigua: **no se carga nunca** |

**El rango vive en un solo lugar:** `RANGO_FECHA_EN_MONTO` en `grid.js`.

| Constante | Valor | Por qué |
|---|---|---|
| `montoMaximoReal` | 3250 | el pago más alto de las 5 cuentas (relevado 2026-09-21) |
| `serialMin` | 43831 | 2020-01-01, el primer serial de fecha plausible |
| `serialMax` | 47848 | 2030-12-31, el último |

Entre 3250 y 43831 no hay ningún dato real, así que la regla no puede
confundir un monto con una fecha. Un pago de más de 3250 en una celda con
formato de fecha queda rechazado y visible: si pasa, se sube
`montoMaximoReal` ahí y en ningún otro lado.

**Qué pasa con una celda marcada como ambigua.**
- En una columna de monto se rechaza con `monto ambiguo con formato de fecha`,
  y el mes queda `revisar`. La corrida guarda el `COMPROBANTE` de la fila en el
  control, y la vista de Salud lo muestra: es el único dato que permite
  reconstruir el monto.
- En una columna de fecha sigue siendo fecha. Por ejemplo, 2001-12-09 da
  `fecha fuera de rango`, como siempre.

**Casos reales que la motivan.** Son pagos tipeados en celdas con formato de
fecha: Sheets los guardó como **fechas del año 1324/1328/1254**.
- agus F5 = `1/7/1324`, se ve `1324.07` con el formato `yyyy.mm`.
- agus F37 = `1/4/1328`, se ve `1328.4` con `yyyy.m`.
- teo E178 = `1254.11` con `yyyy.m`.

El monto no se puede recuperar de la celda, por dos razones:
- `1328.4` y `1328.04` dan la misma fecha.
- El comprobante de agus F37 dice `1.421,9`: 93,50 USD más que lo que se ve.

Se rechazan, y una persona las corrige en la planilla mirando el comprobante.

**Ojo con los exports.** En el `.xlsx` esas celdas aparecen como texto,
porque Excel no guarda fechas anteriores a 1900. La fuente de verdad es la
planilla, no el export ni los fixtures.

### Por qué `values.get` con `FORMATTED_VALUE` NO alcanza

Esa era la regla original. Salió de un fixture donde la fecha llegaba como
texto ISO, pero eso era un artefacto de cómo se generó el fixture, no de
cómo responde Sheets. El dry_run contra las planillas reales mostró tres fallas:

| | Qué pasa | Caso real |
|---|---|---|
| A | Una fecha colada en un monto, con formato `d.m`, llega como `"26.5"` y **se carga como 26,5 USD**, sin aviso: se saltea la detección de fecha y la red 45000–47500 | lucas Opps septiembre f27 (`Dominio`, fecha 2026-05-26); lucas Pagos f154 (fecha 2026-08-31, se ve `31.8`) |
| B | Una fecha con formato sin año llega como `"14/05"`: **el año se pierde** y la fila se rechaza | 8 pagos reales (liam f75, teo f91, mauro f473/474/566, lucas f155) y liam Cuotas f3/f6: **532 USD de cobranza pendiente** que desaparecían |
| C | El monto llega **redondeado al formato de la celda** | liam/teo Opps agosto 10,8 → `11`; 26,5 → `27`; 335,6643357 → `335,66`; 9 pagos de lucas con un solo decimal |

**Tamaño de la respuesta** (medido 2026-09-21):

| Hoja | Sin `fields` | Con `fields` |
|---|---|---|
| mauro Data (CRM), la más grande | 169,5 MB | 5,8 MB |
| liam Data (CRM) | 180,0 MB | 3,3 MB |
| mauro Pagos, la más grande de las activas | — | 2,5 MB |

Pedir sin filtro tumba la Edge Function (546, sin recursos).

**Defensa en profundidad.** Las dos barreras de antes siguen, aunque con el
grid ya no deberían dispararse:
- el rechazo `fecha en celda de monto`;
- la red 45000–47500 sobre ingresos de Opps, que avisa y no rechaza (mauro junio 46637 es real).

`pruebas/formato.mjs` falla si alguien vuelve a `valueRenderOption`, saca
`includeGridData` o `fields`, o repite los números del rango en otro archivo.

## 1. Alias de columnas de PAGOS (`fin_alias_columnas`)

Una fila por (cliente, campo canónico, alias). El alias se compara
normalizado: sin tildes, en minúsculas, espacios colapsados.
`obl` = obligatorio: si falta en el encabezado, la corrida de esa fuente se
aborta entera y no se toca nada.

| cliente | campo | alias | obl |
|---|---|---|---|
| liam | fecha | FECHA DE CARGA | sí |
| liam | programa | PROGRAMA | |
| liam | alumno | NOMBRE DEL ALUMNO | sí |
| liam | telefono | NUMERO | |
| liam | concepto | CONCEPTO | |
| liam | monto | PAGO | sí |
| liam | closer | CLOSER | |
| liam | setter | SETTER | |
| liam | comprobante | COMPROBANTE | |
| liam | quien_recibe | QUIÉN RECIBE | |
| liam | metodo_pago | MÉTODO DE PAGO | |
| agus | fecha | FECHA DE CARGA | sí |
| agus | programa | PROGRAMA | |
| agus | alumno | NOMBRE DEL ALUMNO | sí |
| agus | telefono | NUMERO | |
| agus | concepto | CONCEPTO | |
| agus | monto | PAGO | sí |
| agus | closer | CLOSER | |
| agus | setter | SETTER | |
| agus | comprobante | COMPROBANTE | |
| agus | quien_recibe | QUIÉN RECIBE | |
| agus | metodo_pago | MÉTODO DE PAGO | |
| teo | fecha | Fecha | sí |
| teo | programa | PROGRAMA | |
| teo | alumno | NOMBRE DEL ALUMNO | sí |
| teo | telefono | NUMERO | |
| teo | concepto | CONCEPTO | |
| teo | monto | PAGO | sí |
| teo | closer | CLOSER | |
| teo | setter | SETTER | |
| teo | comprobante | COMPROBANTE | |
| teo | quien_recibe | QUIÉN RECIBE | |
| teo | metodo_pago | MÉTODO DE PAGO | |
| mauro | fecha | Nombre | sí |
| mauro | programa | PROGRAMA | |
| mauro | alumno | NOMBRE DEL ALUMNO | sí |
| mauro | telefono | NUMERO | |
| mauro | concepto | CONCEPTO | |
| mauro | monto | PAGO | sí |
| mauro | monto_pesos | PESOS | |
| mauro | closer | CLOSER | |
| mauro | setter | SETTER | |
| mauro | comprobante | COMPROBANTE | |
| mauro | quien_recibe | QUIÉN RECIBE | |
| mauro | metodo_pago | MÉTODO DE PAGO | |
| mauro | monto_restante | Monto Restante a Pagar | |
| lucas | fecha | FECHA DE CARGA | sí |
| lucas | programa | PROGRAMA | |
| lucas | alumno | Nombre | sí |
| lucas | telefono | NUMERO | |
| lucas | concepto | CONCEPTO | |
| lucas | monto | MONTO EN USD | sí |
| lucas | closer | Closer | |
| lucas | setter | SETTER | |
| lucas | comprobante | COMPROBANTE | |
| lucas | quien_recibe | Quien Recibe | |
| lucas | metodo_pago | MÉTODO DE PAGO | |
| lucas | estado | ESTADO | |

Notas:
- `Nombre` significa `fecha` en mauro y `alumno` en lucas. Por eso los alias
  son por fuente y no globales.
- Columna duplicada (agus tiene `MÉTODO DE PAGO` dos veces): se toma la
  primera aparición, se ignora el resto. Regla general, no de agus.
- Columnas no declaradas (lucas: `Dias restantes`, `AVISO...`, `Pitch...`)
  se ignoran. Son fórmulas.

## 2. Limpieza de filas de PAGOS

Toda fila leída termina en exactamente uno de tres destinos. Se verifica
`filas_leidas = cargadas + rechazadas + descartadas`.

| Caso | Destino | Motivo |
|---|---|---|
| Fila vacía (ninguna celda con contenido) | descartada | `vacia` |
| Una sola celda con texto no numérico, sin alumno (`MARZO`, o `JULIO` en la columna PAGO) | descartada | `separador` |
| Encabezado repetido en medio de los datos | descartada | `encabezado_repetido` |
| Sin alumno y sin monto numérico (resto de casos) | descartada | `sin_alumno_sin_monto` |
| Sin alumno pero con monto | rechazada | `falta alumno` |
| Alumno pero monto vacío | rechazada | `falta monto` |
| Monto con el texto `REFUND` (cualquier mayúscula) | rechazada | `refund sin monto numerico` |
| Monto que es una fecha (`2026-08-31`) | rechazada | `fecha en celda de monto` |
| Monto en celda con formato de fecha, valor en la tierra de nadie (sección 0) | rechazada | `monto ambiguo con formato de fecha` |
| Otro monto no numérico (`si`, texto libre) | rechazada | `monto no numerico` |
| `abs(monto) > tope_monto` de la fuente | rechazada | `monto fuera de rango, probable moneda local sin convertir` |
| Fecha vacía | rechazada | `falta fecha` |
| Fecha que no parsea | rechazada | `fecha no parsea` |
| Fecha fuera de 2024-01-01 .. 2027-12-31 | rechazada | `fecha fuera de rango` |

- Separadores de mes: se detectan por forma, no por lista de clientes. Hoy
  aparecen en liam (3), mauro (4) y teo (4); agus y lucas no tienen.
- Toda rechazada guarda `fila_planilla` real, motivo, `valor_crudo`,
  `comprobante`, `metodo_pago` y la fila cruda entera en `contenido_crudo`.
- `tope_monto` es columna de `fin_fuentes`, nullable, default 10000. NULL =
  sin control. No se deduce el USD desde el comprobante ni se divide por una
  cotización estimada: preferimos el dato faltante a un número inventado.
- Formatos de fecha aceptados: ISO (`2026-02-10T00:00:00`, con o sin
  fracción de segundo), `dd/mm/aaaa`, y número de serie de Google Sheets.

## 3. Monedas en PAGOS

| cliente | monto_usd | monto_origen / moneda_origen | tc_usado / tc_fuente |
|---|---|---|---|
| liam, agus, teo, lucas | `monto` | = monto_usd / `USD` | 1 / `planilla` |
| mauro con PESOS | `PAGO` | `PESOS` / `ARS` (`COP` si el texto dice colombianos) | PESOS / PAGO / `planilla` |
| mauro sin PESOS | `PAGO` | = monto_usd / `USD` | 1 / `planilla` |

`moneda_cobro` (informativa, todas las cuentas): se parsea de
`MÉTODO DE PAGO`: `USDT` → `USDT`, contiene `PESOS` → `ARS`, contiene `USD`
→ `USD`, otro → NULL.

## 4. Hoja `Opps` (P&L) — plantilla común a las 5 cuentas

- 12 bloques de 4 columnas. El mes se toma del encabezado (`JANUARY`..
  `DECEMBER`), no de la posición. El año viene de `fin_fuentes.anio`.
- Etiqueta de fila: columna 0 del bloque; si está vacía, columna 1.
- Monto: columna 2 del bloque; si está vacía, columna 3. (La planilla tiene
  celdas combinadas y el export a veces deja el valor en la 3. El Total
  Expenses de la propia planilla solo cuadra contándolos.)
- Anclas por etiqueta, buscadas por bloque: `REVENUE`, `Total Revenue`,
  `EXPENSES`, `Staff`, `Softwares`, `Others`, `Total Expenses`,
  `Net Cash Flow`, `% Net Cash Flow`, `Dividends Released`,
  `Retained Earnings`, `Opening Balance:`, `Closing Balance:`.
- Cualquier categoría puede faltar en cualquier mes de cualquier cliente.
  Si falta, los ítems desde la fila donde otros meses tienen esa etiqueta
  van con categoría `sin_categoria`, no se meten en la anterior. Lo mismo
  para ítems entre `EXPENSES` y la primera categoría. (Hoy: lucas mayo y
  junio, donde `Others` recién aparece en julio.)
- Fila con monto y sin ítem: se guarda con `item` NULL.
- Monto que es una fecha: `fin_filas_rechazadas`, motivo
  `fecha en celda de monto`, y el mes queda `revisar`. NUNCA se suma el
  serial de la fecha (lucas septiembre: `Dominio` = `2026-05-26`, que la
  planilla suma como 46168).
- Otro monto no numérico en REVENUE/gastos/reparto: rechazada
  `monto no numerico`, mes `revisar`.

### Fuente de verdad: los ítems. Los totales de la planilla son control.

Los números de la app son SIEMPRE la suma de los ítems, nunca el
`Total Expenses` / `Total Revenue` de la planilla. Esos totales son fórmulas
que la gente edita y pueden omitir filas (liam mayo excluye `skool` 9; agus
febrero, `Stripe AF` 516.45; teo agosto, `Juli Disenio` 42.5; mauro junio,
`comision sillo` 137.87; lucas junio, `gasto comisiones blas` 39.5).

- Si ítems ≠ `Total Expenses` o `Total Revenue` (margen 0.01): el mes se
  carga igual y la corrida queda `revisar`, con el detalle en
  `fin_sync_corridas.controles` (mes, control, ítems, planilla, diferencia).
  Aparece en `fin_v_salud_sync`.
- Gate de la prueba (`pruebas/correr.mjs`), estructural: toda fila del
  bloque entre `REVENUE` y `Total Expenses` con ítem y monto numérico queda
  capturada, sin saltear ni inventar filas. Se verifica escaneando el
  bloque, no contra la fórmula.
- Gate: ningún gasto de Opps mayor a 40000 (síntoma de un serial de fecha
  colado). No se aplica a REVENUE: hay ventas mensuales reales de 46637 a
  96544 (agus, mauro).

### Reparto de ganancia (`fin_reparto`)

Entre `Retained Earnings` y `Closing Balance:`, toda fila con etiqueta
distinta de `Opening Balance:` y monto numérico es un reparto: beneficiario
= etiqueta (`Dystopia`, `BILL`). Es la comisión de la agencia. Control:
suma del reparto del mes = `Retained Earnings` del mes, margen 0.01.
Solo `es_fundador()` lo ve. En esos meses `opening_balance` y
`closing_balance` quedan NULL.

- Monto numérico SIN etiqueta después de `Retained Earnings` (también
  debajo de `Closing Balance:`): `fin_filas_rechazadas`, motivo
  `posible reparto sin beneficiario`. No se inventa beneficiario (liam
  febrero: 4267 + 13563.42 = Retained Earnings).
- Etiqueta de reparto sin monto (teo enero y abril: `DYSTOPIA`): se ignora.

## 4.1 Cuándo se aborta una corrida (cambia la regla del PLAN)

El PLAN decía "si una fuente falla se aborta entera". Queda así:

| Situación | Estado | ¿Toca datos? |
|---|---|---|
| Falta una columna obligatoria | `error` | No. Se conserva lo anterior. |
| Cambió el hash de encabezado | `error` | No. Se conserva lo anterior. |
| Estructura irreconocible (Opps sin fila de meses, meses repetidos) | `error` | No. |
| Total de la planilla ≠ suma de ítems | `revisar` | Sí, con los ítems reales. |
| Fecha o texto en celda de monto | `revisar` | Sí; la fila va a rechazadas. |
| Monto ambiguo con formato de fecha (sección 0) | `revisar` | Sí; la fila va a rechazadas con su COMPROBANTE en el control. |
| Payload de la hoja > `FIN_PAYLOAD_UMBRAL_BYTES` (sección 4.2) | `revisar` | Sí; control `payload grande`. |
| La función muere (memoria, CPU, tiempo) | `error` con `corte` | No. Ver sección 4.2. |
| Todo cuadra | `ok` | Sí. |

Las filas rechazadas o descartadas nunca abortan una corrida: se registran.

## 4.2 Cuando la función muere: ninguna corrida queda invisible (006, 2026-09-21)

Una Edge Function que el runtime mata (memoria, CPU, tiempo) no ejecuta
ningún `catch`. Antes de la 006, una muerte **durante la lectura** no dejaba
rastro: la corrida se abría recién después de leer y parsear la planilla, así
que las fuentes seguían mostrando la última corrida buena. Con el cron
prendido nadie lo habría visto.

### Ciclo de vida (`fin_sync_corridas.estado`)

```
pendiente ──> en_curso ──> ok | revisar | parcial | error
    │             │
    │             └─ muere ──> error  (corte = motivo)
    └──────────── muere ──> omitida (corte = motivo)
```

1. Al arrancar, la invocación **barre** lo que dejó abierto otra invocación
   hace más de `HUERFANA_MIN` (10 min, mayor que los 400 s de wall clock
   máximo): `en_curso` → `error` con `corte = 'sin_cierre'`; `pendiente` →
   `omitida`.
2. Abre **todas** sus corridas en `pendiente` (mismo `invocacion`), antes de
   hablar con Google.
3. Fuente por fuente, **en serie**: `en_curso` justo antes de leerla, una hoja
   por llamada a Google, `payload_bytes` escrito **antes** del `JSON.parse`,
   procesa y cierra.

Si muere en la fuente 3: la 3 queda `en_curso` → `error` (se intentó y murió,
**con** su `payload_bytes` si llegó a descargar); la 4..12 quedan `pendiente`
→ `omitida` (no fallaron: no arrancaron). Salud muestra **1** problema, no 12:
`fin_v_salud_sync` ignora `pendiente` y `omitida` como última corrida y cuenta
aparte `cortes_24h` y `omitidas_24h`.

`beforeunload` (motivo del runtime en `detail.reason`): marca las corridas
abiertas con ese motivo. Es best effort: no es `async`, no usa `waitUntil`,
las escrituras salen en segundo plano y los filtros por estado impiden pisar
una corrida que ya cerró. Si no llega a escribir, el barrido del paso 1 la
cierra como `sin_cierre` en la invocación siguiente (≤ 15 min con el cron).

En Salud:
- `error` con `corte`: la corrida murió; el mensaje dice el motivo y el payload.
- **Se cortó** (rojo, requiere acción): hubo un corte en las últimas 24 h
  aunque la última corrida haya terminado bien. Sin esto, la corrida
  siguiente tapaba el corte.
- **Desactualizada**: ahora también para `revisar` (antes solo `ok`).
- `omitida`: gris, solo en el historial y como "no se intentó N× en 24 h".

### Payload por fuente

`payload_bytes` = bytes de la respuesta de Google para esa hoja (grid
filtrado con `fields`). Medición del 2026-09-21: mauro pagos ~2,5 MB, pico de
heap ~29 MB parseándola, contra 256 MB de límite (igual en Pro): margen ~4×
en payload antes de que el heap se acerque al límite. Por encima de
`FIN_PAYLOAD_UMBRAL_BYTES` (secreto de la función; default 5 MB, el doble de
hoy) la corrida queda en `revisar` con el control `payload grande`: los datos
se cargan igual, es un aviso para verlo venir antes de un 546. Cambiar el
umbral no requiere redeploy:
`supabase secrets set FIN_PAYLOAD_UMBRAL_BYTES=<bytes> --project-ref <ref>`.

Pruebas: `npm run test:fn` (`pruebas/corte.test.ts`: muere en la fuente 3,
muere descargando, beforeunload que no bloquea, umbral, dry_run, barrido).

### 546 del 2026-09-21 — cerrado

- **Qué:** un único `POST /functions/v1/sincronizar` con HTTP 546 el
  2026-09-21 a las 14:40:00 UTC (11:40 ART), 26,3 s, sobre el deploy **v4**
  de la función. Log de la función en el mismo milisegundo (14:40:00.958):
  `Memory limit exceeded` → `Shutdown`.
- **Causa probable:** el v4 fue un deploy intermedio, anterior al commit
  `dbe6c3d` (14:42 UTC, "lectura por grid (fields filtrado)"). v4 y v5
  tardaban ~26 s por invocación; desde el v6 (primer deploy con la medición
  de payloads, que sigue en `google.ts`) tardan 8–11 s. Lo más probable es
  que el v4 pidiera el grid sin el filtro `fields` (formato completo de cada
  celda) y el parseo superara los 256 MB. No se puede confirmar: la API solo
  devuelve el fuente de la última versión.
- **Por qué se cierra:** ninguna invocación del v6 en adelante dio distinto
  de 200 (incluidas el dry_run y la primera sync real, v8). Con el código
  actual el peor caso medido es ~29 MB de heap. La 006 (esta sección) hace
  que una muerte futura quede escrita y visible en Salud.

## 5. Cuotas (`fin_cuotas`) — forma declarada en `fin_fuentes.forma`

| cliente | hoja | forma |
|---|---|---|
| liam | `Cuotas` | `cuotas_ancho` |
| mauro | `Pagos Por Cobrar` | `cuotas_ancho` |
| teo | `CUOTAS` (planilla CRM, inactiva) | `cuotas_plano` |
| lucas | vive en `PAGOS` | `desde_pagos` (pendiente, no implementada) |
| agus | no tiene | — |

`cuotas_ancho`: encabezado en dos filas. Fila 1: columnas fijas y grupos
`CUOTA n`. Fila 2: subcolumnas (`Monto`, `Fecha de pago`, `Estado`,
`Contexto`, `CLOSER`). Un grupo termina en la próxima celda con texto de la
fila 1 (así queda afuera la `Referencia de colores` de liam). Cada grupo con
algún dato genera una fila de `fin_cuotas`.

`cuotas_plano`: una fila por cuota. `Programa`, `Nombre del Alumno`,
`Fecha de Cobro`, `Tipo de Cuota`, `Monto por Cobrar`, `Monto Cobrado`,
`Closer`, `Situación del Lead` (→ `estado`).

Shape normalizado (igual en todas las formas, NULL donde no aplica):
`alumno, telefono, programa, numero_cuota, tipo_cuota, monto, monto_cobrado,
fecha_pago, estado, closer, contexto, fila_planilla`.
