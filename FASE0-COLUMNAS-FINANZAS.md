# FASE0-COLUMNAS-FINANZAS.md · columnas editables en Finanzas (03/10)

Relevado con grep sobre `js/views/*.js` y las migraciones 001 a 067. Se
replica el patrón de Producto (071 en dystopia-seguimiento). La próxima
migración es la 072.

## 1. Las tablas de Finanzas

| pantalla | qué es cada fila | de dónde sale | ¿se escribe? |
|---|---|---|---|
| **Pagos** (`#/pagos`) | un pago (`fin_pagos`) | filas `sheet`: la sync, cada 15 min. Filas `app`: el formulario (RPC de la 066) | **sí: es la única tabla de registros** |
| Pagos, "Pendientes de catálogo" | un texto sin mapear | vista `fin_v_alias_pendientes` | no, es un cálculo |
| Cargar pago (`#/cargar`) | formulario, no grilla | escribe `fin_pagos` por RPC | hereda las columnas de Pagos |
| Resumen agencia | un cliente, o un mes | `fin_v_pnl_mensual` | no, todo cálculo |
| Cliente: P&L | una categoría por mes | `fin_v_pnl_mensual` | no, todo cálculo |
| Cliente: detalle del mes | un ítem de Opps / un pago | `fin_pnl` (sync) / `fin_pagos` | gastos: fase 8 |
| Conciliación | cliente y mes | `fin_v_conciliacion` | no, todo cálculo |
| Cash por concepto | torta por categoría | `fin_v_cash_collected_concepto` | no, cálculo |
| Cobranzas | una cuota | `fin_cuotas` (sync de liam y mauro) | pasa a Producto (V4) |
| Mis números | mes / pago / vendedor | comisiones calculadas | no, todo cálculo |
| Salud | una corrida de la sync | `fin_sync_corridas` | no, operativo |

**Conclusión:** en Finanzas hay **una sola grilla de registros: Pagos**.
El resto son reportes. En los reportes, a lo sumo tiene sentido renombrar,
mover y ocultar columnas.

## 2. Columnas de Pagos: dato o cálculo, y quién las escribe

| columna | clave interna | tipo | escribe | ¿editable a mano? |
|---|---|---|---|---|
| Fecha | `fecha` | dato | sync / app | solo filas `app`, y no si el pago está en una liquidación cerrada (cambia el período) |
| Cliente | `cliente_id` | dato | sync / app | **nunca** |
| Alumno | `alumno` | dato | sync / app | filas `app` |
| Teléfono | `telefono` | dato | sync / app | filas `app` |
| Programa | `programa_id` | dato (catálogo) | sync (alias) / app | filas `app`, desde el catálogo |
| Concepto | `concepto_id` | dato (catálogo) | sync (alias) / app | filas `app`, desde el catálogo; nunca REFUND |
| Monto USD | `monto_usd` | dato base de todos los cálculos | sync / app | **nunca** (se corrige anulando y recargando, o con una devolución) |
| Método | `metodo_pago_id` | dato (catálogo) | sync / app | filas `app` |
| Quién recibe | `quien_recibe_id` | dato (catálogo) | sync / app | filas `app` |
| Closer / Setter | `closer` / `setter` | dato que **mueve comisiones** | sync / app | filas `app`, y no si está en una liquidación cerrada |
| Comprobante | `comprobante` | dato | sync / app | filas `app` |
| Nota | `nota` | dato | app | filas `app` |
| Origen | `origen` | sistema | sync / app | nunca |
| Fila | `fila_planilla` | sistema | sync | nunca |
| Acciones | — | botones | — | no es dato |
| tc_usado, clave, huella, creado_por | — | sistema, ocultas | — | nunca |

**Por qué solo filas `app`:** las filas `sheet` se borran y se reescriben
cada 15 minutos. Cualquier cambio a mano duraría hasta la siguiente sync.

## 3. Diferencia con Producto

En Producto cada fila es estable, así que los valores de las columnas
nuevas viven en un jsonb de la fila. En Finanzas las filas `sheet` se
recrean cada 15 minutos y se perdería el jsonb.

**Propuesta:** guardar los valores extra en una tabla aparte, por
`clave` del pago (062), que no cambia con la sync. Así una columna nueva
(por ejemplo "Factura emitida") se puede completar también en pagos de la
planilla, sin esperar el corte.

**Límite:** si alguien corrige ese pago en el Sheet (alumno, fecha, monto
o concepto), la clave cambia y el valor extra queda huérfano. Se ve en una
vista de huérfanos y se reasigna.
