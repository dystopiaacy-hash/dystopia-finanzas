# CONTRATO.md — contrato de columnas de Dystopia Finanzas

Sección 2 del PLAN.md pasada a datos, corregida con lo que mostraron los
fixtures reales (2026-09-21) y con las decisiones de Joaquín sobre esas
diferencias. Es la fuente de `002_seed_config.sql` y de `parsers/contrato.js`.
Si cambia algo acá, cambia en los dos.

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
| Monto no numérico (`REFUND`, `si`, una fecha) | rechazada | `monto no numerico` |
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
- Fila con monto y sin ítem: se guarda con `item` NULL (la planilla la suma).
- Controles (no se guardan): suma de gastos del mes = `Total Expenses`, suma
  del bloque REVENUE = `Total Revenue`, margen 0.01.

### Reparto de ganancia (`fin_reparto`)

Entre `Retained Earnings` y `Closing Balance:`, toda fila con etiqueta
distinta de `Opening Balance:` y monto numérico es un reparto: beneficiario
= etiqueta (`Dystopia`, `BILL`). Es la comisión de la agencia. Control:
suma del reparto del mes = `Retained Earnings` del mes, margen 0.01.
Solo `es_fundador()` lo ve. En esos meses `opening_balance` y
`closing_balance` quedan NULL.

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
