# ESQUEMA-FINANZAS.md · cómo queda Finanzas al terminar la reestructuración

Borrador para aprobar. Reusa lo que ya existe y no duplica tablas:
- `fin_conceptos` (031) para los conceptos.
- `fin_catalogos` (059) para los desplegables.
- `fin_vendedores` y `fin_personas` (009) para closers y setters.
- La `clave` (062) como identidad de cada pago.

---

## 1. Principio

| | hoy | al terminar |
|---|---|---|
| Pagos | se cargan en el Sheet y se copian cada 15 min | se cargan en la app; el Sheet queda como histórico de solo lectura |
| Valores de los desplegables | texto libre, 38 métodos de pago distintos | catálogos cerrados por cliente; lo histórico se traduce con alias |
| Gastos | 12 bloques de Opps tipeados a mano | tabla de gastos en la app, con catálogo de ítems |
| P&L | Opps + Pagos | calculado: ingresos de Pagos y gastos de la tabla de gastos |

**Regla de oro (aprendida en Ventas):** el texto que vino del Sheet no se
pisa nunca. Se guarda tal cual y al lado va el valor del catálogo. Así,
si el mapeo está mal, se corrige el alias y no el dato.

---

## 2. Pagos: `fin_pagos` (existe, se le agregan columnas)

| columna | qué es | migración |
|---|---|---|
| `clave` | identidad estable (ya está) | 062 |
| `origen` | `'sheet'` o `'app'`. La sync solo borra filas `'sheet'` | 065 |
| `concepto` | texto crudo del Sheet (ya está) | |
| `concepto_id` | concepto del catálogo (`fin_catalogos`, dimensión `concepto`). La categoría (venta nueva, cuota, producto) la sigue dando `fin_conceptos`. En filas `'app'` es obligatorio | 064 |
| `metodo_pago` / `metodo_pago_id` | crudo / del catálogo (`fin_catalogos`, dimensión `metodo_pago`) | 064 |
| `quien_recibe` / `quien_recibe_id` | crudo / del catálogo (dimensión `quien_recibe`) | 064 |
| `programa` / `programa_id` | crudo / del catálogo (dimensión `programa`, ya existe para Ventas) | 064 |
| `closer` / `closer_id`, `setter` / `setter_id` | crudo / `fin_vendedores`. En filas `'sheet'` se sigue resolviendo por alias como hoy | 066 |
| `pago_original_clave` | solo para devoluciones: la `clave` del pago que se devuelve | 066 |
| `anulado`, `anulado_motivo` | baja lógica de filas `'app'`. Nunca se borra un pago cargado en la app | 066 |
| `creado_por`, `creado_en`, `editado_por`, `editado_en` | auditoría, igual que `fin_llamadas` (059) | 066 |

**Devoluciones (V6):**
- Una fila con concepto REFUND, monto **negativo** y `pago_original_clave`
  obligatorio.
- El ingreso del mes queda neto solo.
- La comisión del vendedor del mes del refund baja sola, según la regla
  de la 012: "el refund se imputa al mes en que ocurre".

---

## 3. Catálogos

### `fin_conceptos` (existe)

Se le agrega:
- `activo`: un concepto viejo deja de ofrecerse sin borrar el historial.
- `en_formulario`: si aparece en el formulario de carga de la app.
- `orden`.
- La categoría `devolucion` para REFUND.

Las categorías actuales se mantienen: `venta_nueva`, `cuota`, `producto`
y `sin_clasificar`.

### `fin_catalogos` (existe)

Se amplían las dimensiones permitidas con `metodo_pago`, `quien_recibe`
e `item_gasto`. `programa` ya existe y se comparte con Ventas: un
programa es el mismo en las dos apps.

### `fin_catalogo_alias` (nueva)

| columna | qué es |
|---|---|
| `cliente_id` | |
| `dimension` | `metodo_pago`, `quien_recibe`, `programa`, `concepto` |
| `crudo_norm` | el texto del Sheet normalizado (minúsculas, sin espacios dobles) |
| `catalogo_id` | a qué valor del catálogo corresponde |

**Ejemplo de mapeo:**
- `TRANFER PESOS`, `TRANSFER EN PESOS` y `TRANSFER PESOS` → **Transferencia ARS**.
- `TRANSFER EN PESOS-Calypso Soluciones` se parte en dos:
  - método: **Transferencia ARS**
  - quien recibe: **Calypso Soluciones**

Los textos que no tienen alias quedan sin `*_id` y aparecen en una vista
de pendientes, igual que hoy `fin_v_conceptos_desconocidos`.

---

## 4. Gastos: `fin_gastos` (nueva, fase 8)

| columna | qué es |
|---|---|
| `id`, `cliente_id` | |
| `mes` | primer día del mes (los gastos de Opps son mensuales) |
| `categoria` | `staff`, `softwares` u `others` (las mismas de Opps) |
| `item_id` | catálogo `item_gasto` del cliente ("Manychat", "Skool", "Editor") |
| `detalle` | texto libre opcional |
| `monto_usd` | |
| `pagado_por` | catálogo `quien_recibe`: quién puso la plata (hoy "PAGO NACHO" va escrito en el ítem) |
| `vendedor_id` | si el gasto es una comisión de closer o setter |
| `origen` | `'sheet'` (copiado de Opps hasta el corte) o `'app'` |
| auditoría | igual que pagos |

**Doble conteo de comisiones (punto 9 de la agencia):**
- **Si la agencia dice que Ventas manda:** el P&L toma las comisiones de
  las liquidaciones y los gastos con `vendedor_id` no suman.
- **Si dice que manda Opps:** al revés.

El esquema sirve para las dos respuestas.

---

## 5. Lo que se calcula (vistas)

| vista | de dónde sale |
|---|---|
| `fin_v_pnl_mensual` | ingreso: `fin_pagos` (neto de refunds, sin anulados). Gastos: `fin_pnl` hasta el corte y `fin_gastos` después |
| `fin_v_comisiones` (existe) | la misma lógica, leyendo `closer_id`/`setter_id` cuando existen y el alias cuando no |
| `fin_v_comisiones_fuera_de_cierre` (062) | sin cambios |
| `fin_v_alias_pendientes` (nueva) | textos del Sheet sin mapear, por cliente y dimensión, con cantidad y USD |
| comisión de la agencia | `fin_comision_agencia` + `base_calculo` (`cash_collected` o `neto`, por Julia) |

---

## 6. Orden de migraciones y qué necesita cada una

| migración | qué | ¿necesita a la agencia? |
|---|---|---|
| 064 | Estructura de catálogos + `fin_catalogo_alias` + columnas `*_id` en pagos. **Semilla provisional:** el valor más usado de cada grupo, mapeado automáticamente | **No.** Genera la lista para que la agencia apruebe |
| 065 | `origen` + la sync borra solo filas `'sheet'` | No |
| (fase 5) | Grilla de Pagos de solo lectura | No |
| 066 | Formulario de carga, devoluciones, anulación, auditoría y permisos de escritura | Solo el catálogo de conceptos aprobado |
| (fase 7) | Corte por cliente | **Sí:** fechas de Nacho |
| 067+ | `fin_gastos` y el P&L final | **Sí:** doble conteo (punto 9) |

**Con esto el mensaje a la agencia se achica:** el punto 10 deja de ser
"¿qué conceptos usan?" y pasa a ser "aprueben estas tres listas:
conceptos, métodos y quién recibe".
