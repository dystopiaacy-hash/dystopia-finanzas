# PLAN.md — Dystopia Finanzas

App de números y contabilidad de Dystopia Agency, alimentada automáticamente
desde los Google Sheets de cada cliente. Reemplaza a Airtable.

Tercera app del sistema, junto a Dystopia CRM (contenido) y Dystopia
Seguimiento (clientes finales). Prefijo propio: `fin_`.

---

## 0. REGLAS GENERALES

Aplican a TODAS las fases. Leelas siempre.

### Alcance de lectura
- Nunca leas un archivo entero. `grep` primero, después `sed -n` o Read con
  offset y limit sobre la zona.
- En cada sesión leés solo "REGLAS GENERALES" y la fase que te toca.

### Límites de archivo
- Ningún `.js` pasa de 500 líneas. Ningún `.css` pasa de 300.
- Si un archivo se pasa, partilo antes de seguir. No lo dejes para después.
- Nada de un `index.html` gigante. HTML + CSS + JS con ES modules nativos.

### SQL
- NUNCA ejecutes SQL. Ni con el MCP de Supabase ni por ningún otro medio.
- Cada cambio de base va a un archivo numerado en `/migraciones`.
- Cada migración: una transacción, DDL idempotente, query de control al
  final y prueba de humo que se autorrevierte.
- Joaquín las corre en el SQL Editor de Supabase.

### Stack
- Static HTML/JS, sin build step. Hash routing. Vercel. Supabase.
- `supabase-js` fijado a una versión exacta, nunca `@2`.
- Mismo proyecto de Supabase que CRM y Seguimiento. Reusás `es_fundador()`,
  `rol_actual()` y `tiene_acceso(text)`. No creás usuarios nuevos.

### Al cerrar cada fase, informás
1. Archivos tocados.
2. Decisiones que tomaste por tu cuenta.
3. Supuestos a validar con la agencia.
4. Pendientes.
5. Checklist de prueba manual.

### Cuestionar
Si algo de este plan tiene un problema de diseño o un riesgo que no está
contemplado, decilo ANTES de implementarlo. No lo implementes y después
avises.

---

## 1. DECISIONES YA TOMADAS

No las re-discutas, ya están resueltas.

| Tema | Decisión |
|---|---|
| Fuente de verdad | El Google Sheet. La app es SOLO LECTURA sobre todo lo sincronizado. |
| Sincronización | Pull desde el servidor. Edge Function + `pg_cron`. Sin Apps Script. |
| Frecuencia | Cada 15 minutos. Una corrida completa diaria a las 04:00 ART. |
| Escritura a Sheets | Nunca. Ni un caso. |
| Airtable | Se reemplaza. No se sincroniza nada hacia Airtable. |
| Proyecto Supabase | El mismo del CRM y Seguimiento, prefijo `fin_`. |
| Frontend | App independiente, repo propio, deploy propio. |
| Celdas calculadas | NO se sincronizan. La app recalcula todo desde filas crudas. |
| Estrategia de carga | Reemplazo completo por cliente y por hoja en cada corrida. |
| Moneda | Se guarda monto original + moneda + monto en USD con tipo de cambio fechado. |

### Por qué pull y no push desde Apps Script
- `onEdit` no dispara cuando escribe una API. GHL escribe por API. Ya te pasó
  con las agendas y tuviste que hacer polling igual.
- Un solo lugar de código en vez de un script por planilla.
- Se puede resincronizar todo de cero sin riesgo.
- El costo es hasta 15 minutos de demora, que está aceptado.

### Por qué no se sincronizan celdas calculadas
Las hojas `Maestro de Metricas`, `DASHBOARD` y los dashboards de Trazabilidad
son fórmulas de Google Sheets. Al exportarlas devuelven `#ERROR!` y dependen
de rangos que cualquiera puede romper. La app lee SOLO filas crudas (`Pagos`,
`Data`, `Trazabilidad`, `Cuotas`, `Opps`) y calcula sus propias métricas en
SQL. Eso además permite detectar cuando la planilla calcula mal.

### Por qué reemplazo completo y no upsert por ID
Google Sheets no tiene IDs de fila estables: ordenar o insertar cambia el
número de fila. No hay fecha de modificación por celda. Entonces cada corrida
borra las filas de ese cliente y esa hoja, y escribe la foto nueva, todo
dentro de una transacción. Simple y sin desincronización posible.

Consecuencia aceptada: la app NO puede tener datos propios por pago (notas,
"verificado", conciliación manual). Si más adelante hacen falta, se agrega
una columna de ID en la planilla y recién ahí se cambia de estrategia.

---

## 2. CONTRATO DE COLUMNAS (relevado sobre los 9 archivos reales)

Esto es el corazón del proyecto. La suciedad ya está identificada.

### 2.1 Las 5 cuentas

| id | Cliente | Finanzas | CRM |
|---|---|---|---|
| `liam` | Blueprint Financiero | BluePrint - Finanzas 2026 | CRM VENTAS - BPF |
| `agus` | De CERO a CEO | De CERO a CEO - Finanzas 2026 | (sin CRM) |
| `teo` | North Ecom | North Ecom - Finanzas 2026 | CRM Ventas NEC |
| `mauro` | Academia Apple | Academia Apple - Finanzas 2026 | CRM VENTAS - AA |
| `lucas` | Capacitación Auletta | Capacitacion ... Auletta - Finanzas | CRM VENTAS - CCYVDAA |

Usá los mismos ids que ya existen en `crm_clients`. Verificalo en la fase 1
antes de asumirlo.

### 2.2 Hoja de PAGOS — el nombre de la hoja cambia por cliente

| Cliente | Hoja | Particularidades |
|---|---|---|
| liam | `Pagos` | Existe además `PAGOS NO TOCAR` (histórico) y `EN PROCESO`. NO sincronizar esas dos en la fase 1. |
| agus | `Pagos` | Tiene la columna `MÉTODO DE PAGO` DUPLICADA. Se toma la primera, se ignora la segunda. |
| teo | `Pagos` | La columna de fecha se llama `Fecha`, no `FECHA DE CARGA`. |
| mauro | `Historico Pagos` | Columna de fecha titulada `Nombre` (sí, así). Tiene `PAGO` (USD) y `PESOS` a la vez. Trae filas separadoras con el nombre del mes en la primera columna (`DICIEMBRE`) y el resto vacío. |
| lucas | `PAGOS` | Monto en `MONTO EN USD`. Suma `Dias restantes`, `AVISO A LOS 30-21 DÍAS`, `Pitch llamada 10--5 dias`, `ESTADO`. |

Campos canónicos y sus alias aceptados:

| Canónico | Alias aceptados |
|---|---|
| `fecha` | `FECHA DE CARGA`, `Fecha`, `Nombre` (solo mauro) |
| `programa` | `PROGRAMA` |
| `alumno` | `NOMBRE DEL ALUMNO`, `Nombre` |
| `telefono` | `NUMERO` |
| `concepto` | `CONCEPTO` |
| `monto` | `PAGO`, `MONTO EN USD` |
| `monto_pesos` | `PESOS` (solo mauro) |
| `closer` | `CLOSER`, `Closer` |
| `setter` | `SETTER` |
| `comprobante` | `COMPROBANTE` |
| `quien_recibe` | `QUIÉN RECIBE`, `Quien Recibe` |
| `metodo_pago` | `MÉTODO DE PAGO` |
| `monto_restante` | `Monto Restante a Pagar` |
| `estado` | `ESTADO` |

Obligatorias: `fecha`, `alumno`, `monto`. Si falta alguna, la sincronización
de ese cliente se aborta entera y no se toca lo que ya estaba.

Reglas de limpieza de filas de pago:
- Fila sin `alumno` y sin `monto`: se descarta en silencio (fila vacía).
- Fila con texto en la primera columna y todo lo demás vacío: separador de
  mes, se descarta en silencio.
- Fila con `alumno` pero sin `monto`: va a `fin_filas_rechazadas` con el
  motivo y el número de fila real de la planilla.
- `fecha` que no parsea: rechazada, no se adivina.
- Encabezado repetido en medio de los datos: se detecta comparando la fila
  contra los nombres de columna y se descarta en silencio.

### 2.3 Hoja `Opps` — el P&L. Idéntica en las 5 cuentas.

Verificado: la plantilla es la misma en los 5 archivos. Es una grilla de 12
bloques mensuales puestos uno al lado del otro.

- Cada bloque mensual ocupa 4 columnas. El primero arranca en la columna C
  (índice 2) con el encabezado `JANUARY` y de ahí en adelante cada 4 columnas.
- Dentro del bloque: columna del ítem e, dos más a la derecha, la del monto.
- Anclas de fila, por etiqueta y NUNCA por número fijo: `REVENUE`,
  `Total Revenue`, `EXPENSES`, `Staff`, `Softwares`, `Others`,
  `Total Expenses`, `Net Cash Flow`, `% Net Cash Flow`, `Dividends Released`,
  `Retained Earning`, `Opening Balance:`, `Closing Balance:`.
- Entre una etiqueta de categoría y la siguiente, toda fila con ítem y monto
  es un gasto de esa categoría. Los nombres de ítem son texto libre y
  cambian mes a mes (`Agus`, `ciro`, `Skool`, `Manychat`, `ads`, `fees`).
- `Total Expenses`, `Net Cash Flow` y `% Net Cash Flow` NO se guardan: se
  recalculan y se usan solo para controlar que la suma dé igual.
- La cuenta `lucas` no tiene la categoría `Others`. El parser tiene que
  tolerar categorías ausentes sin romper.

Importante: el bloque `Staff` son pagos a personas con nombre y monto. Es
información de sueldos. Ver sección 4, roles.

### 2.4 Hoja de CUOTAS / cobranzas pendientes — la más inconsistente

| Cliente | Hoja | Forma |
|---|---|---|
| liam | `Cuotas` | Encabezado en DOS filas. Fila 1: `Nombre del cliente`, `Numero de WhatsApp`, `CUOTA 1` (combinada). Fila 2: `Monto`, `Fecha de pago`, `Estado`, `Contexto` debajo de la cuota. Puede haber CUOTA 2 y 3. |
| mauro | `Pagos Por Cobrar` | Misma idea. Fila 2 trae `CLOSER` y `Monto`. |
| teo | `CUOTAS` | Formato plano y distinto: `Programa`, `Nombre del Alumno`, `Fecha de Cobro`, `Tipo de Cuota`, `Monto por Cobrar`, `Monto Cobrado`, `Closer`, `Situación del Lead`. Hoy está vacía. |
| agus, lucas | no tienen | En lucas el vencimiento vive dentro de `PAGOS` (`Dias restantes`, `ESTADO`). |

Decisión: las cuotas van a UNA sola tabla normalizada `fin_cuotas`, con un
parser distinto por forma (`cuotas_ancho`, `cuotas_plano`, `desde_pagos`).
La forma se declara en la configuración del cliente, no se adivina.

### 2.5 CRM `Data` — métricas comerciales

No entra en las fases 1 a 5. Entra en la fase 6.

Motivo: es lo que menos se parece entre clientes. `liam` tiene la columna
`Encargado de la llamada` DUPLICADA y una columna titulada `False`. `teo`
tiene `Cerro?` y `CC Closer`, que los demás no tienen. `mauro` separa
`Nombre` y `Apellido`. Los campos de cash collected (`CC DIA 1`,
`CC TRATO CERRADO`, `CC en Seguimiento`, `Monto restante a pagar`) sí están
en los 4, y ese es el mínimo común denominador de la fase 6.

### 2.6 Monedas

- `liam`, `agus`, `teo`: los montos están en USD.
- `lucas`: `MONTO EN USD` ya viene convertido. `MÉTODO DE PAGO` dice en qué
  moneda entró (`TRANSFER EN PESOS-...`, `TRANSFER EN USD - ...`). Se guarda
  la moneda de origen parseada de ahí, a título informativo.
- `mauro`: tiene `PAGO` en USD y `PESOS` en pesos a la vez.

Modelo: `monto_origen`, `moneda_origen`, `monto_usd`, `tc_usado`,
`tc_fuente`. Cuando la planilla ya trae USD, `monto_usd = monto_origen`,
`tc_fuente = 'planilla'`. La tabla `fin_tipo_cambio` queda creada y vacía,
para cuando la agencia defina qué cotización usar. No inventes cotizaciones.

---

## 3. MODELO DE DATOS

Todo con prefijo `fin_`.

### Configuración
- `fin_fuentes` — una fila por hoja a sincronizar: `cliente_id`,
  `spreadsheet_id`, `gid`, `tipo` (`pagos`|`opps`|`cuotas`|`data`),
  `nombre_hoja_esperado`, `fila_encabezado`, `activo`.
  Se usa el `gid` y no el nombre, porque renombrar la hoja no cambia el gid.
- `fin_alias_columnas` — `fuente_id`, `campo_canonico`, `alias`,
  `obligatorio`.

### Datos
- `fin_pagos` — un pago por fila. Columnas canónicas de 2.2 más
  `fila_planilla`, `sync_id`.
- `fin_pnl` — `cliente_id`, `anio`, `mes`, `categoria`
  (`revenue`|`staff`|`softwares`|`others`), `item`, `monto_usd`,
  `fila_planilla`.
- `fin_pnl_saldos` — `cliente_id`, `anio`, `mes`, `opening_balance`,
  `closing_balance`, `dividends_released`.
- `fin_cuotas` — `cliente_id`, `alumno`, `telefono`, `numero_cuota`, `monto`,
  `fecha_pago`, `estado`, `closer`, `contexto`, `fila_planilla`.

### Operación
- `fin_sync_corridas` — `fuente_id`, `inicio`, `fin`, `estado`
  (`ok`|`error`|`parcial`), `filas_leidas`, `filas_cargadas`,
  `filas_rechazadas`, `mensaje`, `hash_encabezado`.
- `fin_filas_rechazadas` — `corrida_id`, `fila_planilla`, `motivo`,
  `contenido_crudo` (jsonb).
- `fin_tipo_cambio` — `fecha`, `moneda`, `valor_usd`, `fuente`.

### Vistas (todas con `security_invoker = true`)
- `fin_v_pnl_mensual` — P&L por cliente y mes, con ingreso real desde
  `fin_pagos` al lado del declarado en `fin_pnl`.
- `fin_v_conciliacion` — diferencia entre `Total Revenue` de Opps y la suma
  de `fin_pagos` del mismo mes. Esta es la vista que justifica toda la app:
  detecta plata mal cargada. Airtable no hace esto.
- `fin_v_ranking_closers` — cierres y monto por closer y por mes.
- `fin_v_cobranzas` — cuotas pendientes con días al vencimiento.
- `fin_v_salud_sync` — última corrida por fuente y su estado.

### Detección de cambios de estructura
En cada corrida se calcula un hash de la fila de encabezados. Si cambia
respecto de la corrida anterior, la corrida se marca `error`, NO se toca
ningún dato y se avisa. Renombrar o mover una columna deja de ser un
desastre silencioso y pasa a ser una alerta.

---

## 4. ROLES Y QUÉ VE CADA UNO

Roles nuevos en esta app, sobre los que ya existen: `closer` y `setter`.

| | fundador | cliente | closer | setter |
|---|---|---|---|---|
| P&L completo (incluye sueldos) | sí | solo el suyo | NO | NO |
| Pagos detallados | sí | solo los suyos | solo donde figura como closer | solo donde figura como setter |
| Cobranzas pendientes | sí | solo las suyas | solo las suyas | NO |
| Comisión de la agencia | sí | NO | NO | NO |
| Comparativa entre clientes | sí | NO | NO | NO |
| Salud de sincronización | sí | NO | NO | NO |

Reglas duras:
- `anon` no lee NINGUNA tabla `fin_*`. Cero excepciones.
- Un closer nunca ve la tabla `fin_pnl`, en ninguna forma, ni agregada. El
  bloque `Staff` son los sueldos del equipo.
- El vínculo entre un usuario y su nombre de closer se hace con una tabla
  `fin_personas` que mapea `user_id` a los nombres tal como aparecen en las
  planillas. Los nombres vienen sucios (`Fran`, `franco`, `Fran Escudero`,
  `Franco Randisi` conviven). La tabla acepta varios alias por persona.
- El % que cobra la agencia se guarda en `fin_comision_agencia` por cliente y
  período, y solo lo ve `fundador`.

---

## 5. FASES

### FASE 1 — Inspección y contrato
Salida: `migraciones/000_inspeccion.sql` (solo SELECTs, no modifica nada) que
verifica: ids reales de `crm_clients`, firma de `es_fundador()`,
`rol_actual()` y `tiene_acceso()`, valores de rol existentes, versión de
Postgres, si están `pg_cron` y `pg_net`, y si hay choque de nombres con
prefijo `fin_`.
Además: `CONTRATO.md` con la tabla de alias de la sección 2 pasada a datos.
No escribís nada en la base. Parás.

### FASE 2 — Esquema completo
Salida: `001_esquema_fin.sql` con todas las tablas, índices, RLS y políticas
de la sección 3 y 4. `002_seed_config.sql` con las filas de `fin_fuentes` y
`fin_alias_columnas` de las 5 cuentas (los `spreadsheet_id` y `gid` van como
placeholders `PEGAR_AQUI`, los completa Joaquín).
`003_vistas.sql` con las 5 vistas.
No ejecutás nada. Parás.

### FASE 3 — Parsers, probados contra los archivos reales
Esto es lo más delicado y va ANTES que la UI.
- `parsers/pagos.js`, `parsers/opps.js`, `parsers/cuotas.js`.
- Cada uno recibe una matriz de filas crudas y devuelve
  `{ filas: [], rechazadas: [], error: null }`.
- `pruebas/fixtures/` con los datos reales exportados a JSON de las 9
  planillas. Joaquín te los pasa.
- `pruebas/correr.mjs`: corre los 3 parsers contra las 5 cuentas y verifica
  que la suma de `Total Expenses` calculada coincida con la de la planilla,
  con un margen de 1 centavo. Si no coincide, FALLA RUIDOSAMENTE.
- Esta prueba es el gate de la fase. No sigas si no pasa.

### FASE 4 — Edge Function de sincronización
- `sincronizar/index.ts`: lee Google Sheets con una service account, aplica
  los parsers, escribe en una transacción por fuente, registra la corrida.
- Service account en secreto de Supabase. Nunca en el frontend, nunca en el
  repo.
- Si falla una fuente, las demás siguen. Los datos viejos de la fuente que
  falló se conservan.
- `004_cron.sql` con el `pg_cron` cada 15 minutos.

### FASE 5 — Frontend
Mismo diseño visual que Dystopia CRM y Seguimiento.
Vistas: Resumen agencia, Cliente (P&L mensual y detalle), Conciliación,
Cobranzas, Mis números (closer/setter), Salud de sincronización.
Barra superior con links a las otras dos apps.
Cada número con fila de origen tiene un link directo a la celda de la
planilla, con el formato `https://docs.google.com/spreadsheets/d/<id>/edit#gid=<gid>&range=A<fila>`.

### FASE 6 — CRM Data y métricas comerciales
Recién acá entran las hojas `Data`. Se define después de que la agencia vea
las fases 1 a 5.

### FASE 7 — Notificaciones a Discord
Reporte diario de números al canal de la agencia. Alerta cuando una
sincronización falla, al canal `logs-tecnicos`. Queda pendiente del webhook,
igual que en Seguimiento.

---

## 6. PENDIENTES BLOQUEANTES (no son opcionales)

1. Vercel y Supabase a cuentas de la agencia, con planes pagos, ANTES de
   cargar un solo dato real. Hay sueldos y facturación de clientes reales y
   Supabase free no tiene backups. Vercel Hobby además prohíbe uso comercial.
2. Los 5 spreadsheets compartidos con la service account, en modo lector.
3. Definir con la agencia qué tipo de cambio se usa y de qué fecha.
4. Proteger la fila de encabezados de cada hoja en Google Sheets
   (Datos > Proteger hojas y rangos). Evita la mitad de los problemas.
