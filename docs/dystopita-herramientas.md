# Herramientas de Dystopita para Ventas y Finanzas (migración 158)

Para quien conecta estas consultas a la Edge Function `ia-preguntar` (repo dystopia-seguimiento). Son funciones SQL **de solo lectura** que devuelven un resumen corto en `jsonb`. Archivo: `migraciones/158_ia_herramientas_ventas_finanzas.sql` (todavía no corrida).

## Cómo se llaman

- Con el **token del usuario** (`quien.cliente.rpc(...)`, igual que `cs_chat_*`). La `secret key` no sirve: no hay `auth.uid()` y cortan con `42501`.
- Son **SECURITY INVOKER** (decisión de diseño, ver cabecera de la migración): leen las mismas tablas y vistas que la app, con su RLS, así que cada rol recibe exactamente lo que ya ve. Además validan el rol y recortan lo que el front ya oculta.
- Devuelven **un objeto jsonb**, no un array de filas (distinto de `cs_chat_*`). En `ejecutar()`: `const obj = data as Record<string, unknown>`; para `consultas.filas` alcanza con `1`; el resultado va al modelo como `JSON.stringify(obj)` (cada uno pesa entre 1 y 6 KB; el tope `MAX_RESULTADO` de 14.000 caracteres alcanza).
- Montos siempre en **USD**. Nunca devuelven teléfonos ni emails.
- Parámetros comunes: `p_cliente` (id o nombre: `liam`, `agus`, `teo`; vacío = todos los que el usuario ve), `p_desde` y `p_hasta` (fechas `YYYY-MM-DD`, inclusive).
  - **Sin fechas = este mes** (zona Argentina). Ventas llega hasta el fin de mes (cuenta también llamadas ya agendadas para después de hoy); Finanzas, hasta hoy.
  - El modelo debe **resolver "este mes", "el mes pasado", "septiembre"** a fechas con la fecha de hoy del system prompt, o dejar los parámetros vacíos para "este mes". Máximo ~26 meses.
- Errores (`error.code`): `42501` = sin sesión o sin permiso (mensaje en castellano, seguro de mostrar); `22023` = parámetro inválido o cliente que no existe/no ve (también seguro de mostrar). Cualquier otro: responder "la consulta falló".

## Quién puede usar cada herramienta

Roles que entran a Finanzas: `fundador`, `cliente`, `closer`, `setter`, `finanzas`, `ventas`. Con otro rol o sin sesión: `42501`.

| Herramienta | fundador | cliente | finanzas | ventas | closer | setter |
|---|---|---|---|---|---|---|
| `ia_chat_ventas_resumen` / `_equipo` / `_leads` | todo | su cliente | clientes asignados | clientes asignados | solo sus llamadas | solo lo atribuido a él |
| `ia_chat_fin_cobros` / `ia_chat_fin_pagos` | todo | su cliente (no "solo panel") | clientes asignados | **0 filas** (la RLS de pagos no incluye ventas) | solo pagos donde figura como closer | solo pagos donde figura como setter |
| `ia_chat_fin_resultado` (ingresos y gastos) | todo | su cliente | clientes asignados | `42501` | `42501` | `42501` |
| `ia_chat_fin_deudas` (cobranzas) | todo | su cliente (no "solo panel") | clientes asignados | `42501` | solo cuotas de sus alumnos | `42501` |

"Solo panel" = rol `cliente` en un cliente con permisos por área que no puede cargar pagos (hoy agus/teo si se crean así): el front no le muestra Pagos ni Cobranzas, así que cobros, pagos y deudas le dan `42501`; ingresos y gastos sí (el P&L lo ve).

## Ventas

### `ia_chat_ventas_resumen(p_cliente, p_desde, p_hasta)`
Llamadas del periodo. Mismas definiciones que `fin_v_metricas_ventas` (sin duplicadas).
Devuelve `{ periodo, cliente, total, por_cliente[], por_mes[], nota }`; cada bloque trae `agendadas_total` (todas las llamadas con fecha en el periodo, ya ocurridas + a futuro), `ya_ocurridas`, `a_futuro`, `presentadas`, `no_show`, `regendadas_canceladas`, `calificadas`, `cerradas`, `canceladas_en_agenda`, `cash_en_data_usd` (lo anotado en Data: atribución, **no** el cash real; para eso `ia_chat_fin_cobros`), `show_up_pct` (presentadas / (presentadas + no show)) y `cierre_pct` (cerradas / presentadas).
Ejemplo: "¿cuántas llamadas agendaron este mes para todos los clientes?" → sin parámetros → `total.agendadas_total`, `por_cliente`.

### `ia_chat_ventas_equipo(p_cliente, p_desde, p_hasta, p_tipo = 'closer', p_nombre)`
Lo mismo por persona. `p_tipo`: `closer` o `setter`; `p_nombre`: filtro por nombre parcial (sin tildes no hace falta; ignora mayúsculas). Top 25 por agendadas.
Devuelve `{ periodo, cliente, tipo, llamadas_visibles_en_el_periodo, personas[{cliente_id, persona, agendadas_total, ya_ocurridas, presentadas, no_show, calificadas, cerradas, show_up_pct, cierre_pct}], nota }`. Los setters cuentan solo las llamadas **atribuidas** a un setter (fuente de setter), igual que `fin_v_metricas_setter`.

### `ia_chat_ventas_leads(p_cliente, p_desde, p_hasta, p_nivel = 'caliente')`
Leads del periodo y su calificación de IA (147/154). `p_nivel` de la lista: `caliente`, `tibio`, `frio`, `sin_calificar` o `todos`.
Devuelve `{ periodo, cliente, total_leads, por_nivel{caliente,tibio,frio,sin_calificar}, puntaje_promedio, por_cliente[], nivel_de_la_lista, leads[hasta 10: fecha, cliente_id, nombre, closer, nivel, puntaje, motivo, show_up, estado_llamada], nota }`. Excluye canceladas de la agenda y duplicadas.

## Finanzas

### `ia_chat_fin_cobros(p_cliente, p_desde, p_hasta)`
Cobros del periodo (tabla de pagos). Las devoluciones son pagos negativos.
Devuelve `{ periodo, cliente, total, por_cliente[], por_mes[], por_concepto[top 10], por_programa[top 10], por_closer[top 10], nota }`; `total`/`por_cliente`/`por_mes` traen `neto_usd` (= cobrado + devoluciones), `cobrado_usd`, `devoluciones_usd`, `pagos`, `devoluciones`.
Ejemplo: "¿cuánto cobramos en septiembre?" → `p_desde='2026-09-01'`, `p_hasta='2026-09-30'` → `total.neto_usd`.

### `ia_chat_fin_resultado(p_cliente, p_desde, p_hasta)`
Ingresos, gastos y net cash flow por cliente y mes (se toman **meses completos** que toca el periodo).
Devuelve `{ meses{desde,hasta}, cliente, total, por_cliente[], por_mes[], detalle_cliente_mes[], nota }` con `ingreso_real_usd` (pagos), `gastos_usd` y su apertura (`gastos_staff_usd`, `gastos_softwares_usd`, `gastos_otros_usd`, `gastos_sin_categoria_usd`), `net_cash_flow_usd` (= ingreso real − gastos, la regla de la app desde el 14/10), `revenue_opps_usd` (lo declarado en Opps, para contrastar) y, en el detalle, `sin_pagos_cargados`.

### `ia_chat_fin_deudas(p_cliente, p_desde, p_hasta, p_solo_vencidas = true)`
Cobranzas: cuotas pendientes (mismo criterio que Cobranzas: estado vacío o distinto de pagado/churn/pausado/cancelado). `p_desde`/`p_hasta` filtran por fecha de vencimiento y son opcionales (sin fechas = toda la deuda). `p_solo_vencidas=false` suma las que vencen después.
Devuelve `{ cliente, solo_vencidas, filtro_vencimiento, total{cuotas, alumnos, pendiente_usd, cuotas_vencidas, pendiente_vencido_usd, max_dias_de_atraso}, por_cliente[], por_programa[top 10], top_deudores[top 15: cliente_id, alumno, cuotas, pendiente_usd, dias_de_atraso_max], nota }`.
Ejemplo: "¿quién debe plata?" → sin parámetros.

### `ia_chat_fin_pagos(p_cliente, p_desde, p_hasta, p_alumno, p_limite = 20)`
Últimos pagos. Con `p_alumno` (nombre parcial) busca en todo el historial; sin alumno y sin fechas, este mes. `p_limite` de 1 a 50.
Devuelve `{ periodo, cliente, alumno_buscado, total_pagos_encontrados, monto_neto_usd, pagos[{fecha, cliente_id, alumno, concepto, programa, monto_usd, closer, metodo_pago}], nota }`.
Ejemplo: "¿cuándo pagó Juan Pérez?".

## Definiciones de herramienta para `ia-preguntar` (sugeridas)

Una por función; todas con `required: []` salvo aclaración. Mapeo en `ejecutar()`:

| name (tool) | RPC | args desde el input |
|---|---|---|
| `ventas_llamadas` | `ia_chat_ventas_resumen` | `p_cliente`, `p_desde`, `p_hasta` |
| `ventas_por_persona` | `ia_chat_ventas_equipo` | `p_cliente`, `p_desde`, `p_hasta`, `p_tipo` (`closer`/`setter`), `p_nombre` |
| `ventas_leads` | `ia_chat_ventas_leads` | `p_cliente`, `p_desde`, `p_hasta`, `p_nivel` |
| `fin_cobros` | `ia_chat_fin_cobros` | `p_cliente`, `p_desde`, `p_hasta` |
| `fin_ingresos_gastos` | `ia_chat_fin_resultado` | `p_cliente`, `p_desde`, `p_hasta` |
| `fin_deudas` | `ia_chat_fin_deudas` | `p_cliente`, `p_desde`, `p_hasta`, `p_solo_vencidas` |
| `fin_pagos` | `ia_chat_fin_pagos` | `p_cliente`, `p_desde`, `p_hasta`, `p_alumno`, `p_limite` |

Descripciones sugeridas: copiar la primera frase de cada sección de arriba. Recortar a los tipos: texto ≤ 80 caracteres, fechas con `/^\d{4}-\d{2}-\d{2}$/` (si no matchea, `null`), `p_limite` entero 1 a 50.

Lo que el system prompt tiene que decir:
- "Solo respondé con lo que devuelven las herramientas; los montos están en USD; `agendadas_total` incluye las llamadas ya agendadas para después de hoy; el cash de Data no es el cash real."
- "Si una herramienta devuelve `42501`, explicá que ese rol no ve ese dato; no insistas."
- Para Finanzas, los clientes son `liam`, `agus` y `teo`.

## Cosas que tiene que resolver quien conecte `ia-preguntar`

1. **Puerta de entrada.** Hoy `ia-preguntar` valida con `cs_chat_puede` (fundador, rol `producto` o `cliente`), así que `closer`, `setter`, `finanzas` y `ventas` reciben **403** aunque Dystopita ya se les muestre en Finanzas. Hay que ampliar esa función (migración en dystopia-seguimiento) o validar con las funciones de este archivo (`ia_chat_rol()` no tira error para los seis roles).
2. **Herramientas por app.** El chat de Finanzas manda `{ pregunta, programa: <cliente que está mirando o undefined>, app: 'finanzas' }`; `app` es nuevo (la función actual lo ignora). Sugerencia: con `app:'finanzas'` ofrecer las 7 herramientas de acá (y las 3 de Producto solo si el rol es `fundador`/`producto`/`cliente`); `programa` es el id del cliente y puede pasarse como `p_cliente` por defecto.
3. **`ia_uso`.** Registrar `app` (`finanzas` o `ventas`) y una `funcion` propia (por ejemplo `chat_interno`), como hoy con `producto`.
4. **Nombres en la UI.** `js/views/preguntar-ia.js` de Finanzas traduce a castellano la línea "Consultó: …" con un mapa `HERRAMIENTA` cuyas claves son los nombres de herramienta de la tabla de arriba (`ventas_llamadas`, `fin_cobros`, …). Si en `ia-preguntar` se llaman distinto, ajustar ese mapa (las que no figuran se muestran tal cual).
5. **Dystopita en Ventas.** La app de Ventas puede copiar los mismos tres archivos (`js/dystopita*.js`, `css/dystopita.css`, `js/views/preguntar-ia.js` y `js/datos-ia-chat.js` de este repo) y usar las herramientas `ventas_*`.

## Pruebas

La migración trae una prueba de humo (no escribe nada) y los controles C1 a C10. C3/C4 comparan "agendadas este mes" contra `fin_v_metricas_ventas`; C5/C6 contra el Resumen y el P&L de la app; C7 a C9 prueban los recortes por rol. No se ejecutó nada: sin correr, sin deploy.
