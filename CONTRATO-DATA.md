# CONTRATO-DATA.md

Contrato de columnas de la hoja **Data** (CRM de ventas) para el parser
`data.js` de la Edge Function. Sacado de los 4 archivos CRM reales
(BPF, CCYVDAA, NEC, AA) el 2026-09-22.

Complementa a CONTRATO.md, que cubre Pagos, Opps y Cuotas.

---

## 0. Alcance

- Este contrato cubre SOLO la hoja `Data`. **Trazabilidad queda fuera**
  (ver §7: no tiene esquema comun entre clientes).
- Clientes con hoja Data: liam, lucas, teo, mauro. **agus no tiene CRM.**
- Encabezado siempre en la **fila 1** en los 4 clientes.
- Filas formateadas vacias al final: liam tiene 1500 filas de las que solo
  ~501 tienen datos. Cortar por la columna de fecha, igual que en Pagos.

---

## 1. Campos canonicos

| canonico | tipo | obligatorio | nota |
|---|---|---|---|
| `fecha_llamada` | date | si | descarta la fila si falta |
| `closer` | text | si | el "encargado de la llamada" |
| `nombre` | text | si | prospecto |
| `show_up` | enum | no | ver §3 |
| `calificacion` | enum | no | ver §3 |
| `estado_llamada` | text | no | solo teo y mauro |
| `tipo_booking` | text | no | fuente de la agenda, ver §3 |
| `programa` | text | no | |
| `cc_dia1` | numeric | no | cash collected el dia de la llamada |
| `cc_cerrado` | numeric | no | cash collected del trato cerrado |
| `cc_seguimiento` | numeric | no | cash collected posterior |
| `monto_restante` | numeric | no | |
| `telefono` | text | no | |
| `instagram` | text | no | |
| `contexto_closer` | text | no | |
| `contexto_setter` | text | no | liam no lo tiene |
| `fila_planilla` | int | si | para trazar rechazos |

**No hay campo `setter`.** Ningun cliente lo tiene en Data. Ver §5.

---

## 2. Mapeo de alias por cliente

Cargar en `fin_alias_columnas` (fuente_id, campo_canonico, alias, obligatorio).

### liam (BPF) — 26 columnas
| # | encabezado en la planilla | canonico |
|---|---|---|
| 1 | `Encargado de la llamada` | closer |
| 2 | `Encargado de la llamada` | **fecha_llamada** (ver §4.1) |
| 3 | `Nombre` | nombre |
| 4 | `Calificacion` | calificacion |
| 5 | `Show up` | show_up |
| 6 | `Contexto` | contexto_setter |
| 7 | `Contexto Closer` | contexto_closer |
| 8 | `CC DIA 1` | cc_dia1 |
| 9 | `CC Seguimiento` | cc_seguimiento |
| 10 | `CC TRATO CERRADO` | cc_cerrado |
| 11 | `Monto restante a pagar` | monto_restante |
| 13 | `Teléfono` | telefono |
| 14 | `tipo de booking` | tipo_booking |
| 26 | `False` | IGNORAR |

Sin `Estado de la llamada`, sin `Programa`, sin `instagram`.

### lucas (CCYVDAA) — 20 columnas
| # | encabezado | canonico |
|---|---|---|
| 1 | `Nombre` | nombre |
| 2 | `Fecha de llamada` | fecha_llamada |
| 3 | `Encargado de la llamada` | closer |
| 4 | `Show up` | show_up |
| 5 | `Calificacion` | calificacion |
| 7 | `Contexto Setter` | contexto_setter |
| 8 | `Contexto Closer` | contexto_closer |
| 9 | `Tipo de Booking` | tipo_booking |
| 10 | `Cuenta de IG` | instagram |
| 11 | `Celular` | telefono |
| 15 | `Programa` | programa |
| 16 | `CC DIA 1` | cc_dia1 |
| 17 | `CC TRATO CERRADO` | cc_cerrado |
| 18 | `CC en Seguimiento` | cc_seguimiento |
| 19 | `Monto restante a pagar` | monto_restante |

Sin `Estado de la llamada`.

### teo (NEC) — 25 columnas
| # | encabezado | canonico |
|---|---|---|
| 1 | `Nombre Completo` | nombre |
| 2 | `Fecha de llamada` | fecha_llamada |
| 3 | `Encargado de la llamada` | closer |
| 4 | `Show up` | show_up |
| 5 | `Calificacion` | calificacion |
| 6 | `Estado de la llamada` | estado_llamada |
| 7 | `Fuente` | tipo_booking |
| 8 | `Telefono` | telefono |
| 9 | `instagram` | instagram |
| 15 | `CONTEXTO CLOSER` | contexto_closer |
| 16 | `Programa` | programa |
| 17 | `CC DIA 1` | cc_dia1 |
| 18 | `CC TRATO CERRADO` | cc_cerrado |
| 19 | `CC en Seguimiento` | cc_seguimiento |
| 20 | `Monto restante a pagar` | monto_restante |
| 21 | `Cerro?` | IGNORAR (vacia en las 358 filas) |
| 22 | `CC Closer` | IGNORAR (verificar antes de usar) |
| 25 | `False` | IGNORAR |

### mauro (AA) — 27 columnas
| # | encabezado | canonico |
|---|---|---|
| 1 | `Nombre` | nombre (concatenar con 2) |
| 2 | `Apellido` | nombre |
| 3 | `Fecha de llamada` | fecha_llamada |
| 4 | `Encargado de la llamada` | closer |
| 5 | `Show up` | show_up |
| 6 | `Calificacion` | calificacion |
| 7 | `Estado de la llamada` | estado_llamada |
| 10 | `CONTEXTO SETTER` | contexto_setter |
| 11 | `Que paso en la llamda?\nContexto + Phatom` | contexto_closer |
| 12 | `Programa` | programa |
| 13 | `CC DIA 1` | cc_dia1 |
| 14 | `CC TRATO CERRADO` | cc_cerrado |
| 15 | `CC en Seguimiento` | cc_seguimiento |
| 16 | `Monto restante a pagar` | monto_restante |
| 17 | `tipo de booking` | tipo_booking |
| 18 | `telefono` | telefono |
| 19 | `instagram` | instagram |

Unico cliente que separa nombre y apellido.
El encabezado de la col 11 tiene un salto de linea adentro: normalizar
espacios antes de comparar.

---

## 3. Dominios de valores

### show_up
`SI` | `NO` | `Regenda` | `Cancelado por Closer` (tambien `por closer`).
mauro trae ademas `0` y `#DIV/0!`, que son errores de formula: rechazar.

Normalizar a minusculas sin tildes. **Definicion pendiente de la agencia:**
las regendas y las canceladas por el closer, entran en el denominador del
show up rate?

### calificacion
`CALIFICADO` | `NO CALIFICADO` | `NO SE SABE` | `Se desconoce` (lucas).
liam trae 3 `SI` y 1 `NO` sueltos, y lucas 1 fila con el texto
`Calificacion`: rechazar.

`NO SE SABE` y `Se desconoce` son el mismo valor con distinto nombre.

### estado_llamada (solo teo y mauro)
`NO CIERRE` | `NO SHOW` | `NO CALIFICADO` | `EN SEGUIMIENTO` | `FEE` |
`ADENTRO EN SEGUIMIENTO` | `ADENTRO EN LLAMADA` | `PODRIDO`.
Lista abierta: no validar contra un enum cerrado, guardar el texto.

### tipo_booking
`INSTAGRAM` | `WEBINAR` | `LANDING` | `YOUTUBE` | `TIKTOK` | `PRODUCTO` |
`LANDING INSTAGRAM`. Viene en mayusculas y en minusculas: normalizar.

---

## 4. Trampas conocidas

### 4.1 liam tiene la fecha en una columna mal etiquetada
Las columnas 1 y 2 se llaman las dos `Encargado de la llamada`. La 1 es el
closer, la 2 es la **fecha de la llamada**. El mapeo va por posicion, no
por nombre. Avisarle a la agencia para que la renombren.

### 4.2 Fechas mixtas: texto y fecha real
En liam: 169 celdas son fecha real y **332 son texto** con formato
` Saturday, September 5, 2026 ...`, con espacio adelante. Misma mezcla en
teo y mauro. Es GHL escribiendo por API.

Reusar el parseo de fechas en texto de `notificador-agendas.gs`.
Si no parsea, rechazar con motivo `fecha en texto no reconocida`.

### 4.3 Filas formateadas vacias
liam: 1500 filas, ~501 con datos. Cortar por `fecha_llamada`, no por
`getLastRow`.

### 4.4 Errores de formula
mauro trae `#DIV/0!` y `0` en show_up y calificacion. Rechazar la celda,
no la fila entera.

### 4.5 Tamano
CONTRATO.md §0: Data de mauro pesa 169 MB sin filtrar y 5,8 MB con
`fields`. **Usar `fields` desde la primera llamada**, nunca traer la hoja
entera: la Edge Function se queda sin memoria.

---

## 5. Lo que Data NO permite calcular

**No hay columna de setter.** Los 4 clientes atribuyen la llamada a un solo
`Encargado de la llamada`, que es el closer. lucas y mauro tienen
`Contexto Setter`, pero es texto libre, no un nombre.

Consecuencia: **las metricas por setter no se pueden calcular.** Llamadas
agendadas por setter, show up rate por setter y tasa de cierre por setter
quedan fuera hasta que la agencia agregue una columna de setter a Data.

Lo que si se puede: todas las metricas generales y todas las de closer.

---

## 6. Alias de vendedores: son un set NUEVO

Los nombres en Data no coinciden con los de Pagos. Cargar aparte en
`fin_personas`, con el mismo alcance por cliente.

| cliente | nombres en Data | veces |
|---|---|---|
| liam | Lucas Deza / Valentin Morello / Liam Wickham / Ignacio Mazzei / Ignacio Colombetti / Fabian Silva | 313/62/45/32/20/15 |
| lucas | `Fran ` / `franco ` / `German ` / Maxi Sandoval / `fran ` / Agustin Turone | 155/135/92/62/54/17 |
| teo | Franco Lagrega / GONZA GUGLIELMINO / Valentin Morello / Teo North / Felipe Byrne / Emi Gonda | 147/113/54/13/11/9 |
| mauro | Lauty Tiseyra / Facundo Came / Lucas Deza / Alejando Exeni / Franco Randisi | 412/294/199/41/23 |

Casi todos traen espacios al final. Normalizar con `btrim`.

**Personas que aparecen en Data y no en Pagos:** Liam Wickham, Ignacio
Mazzei, Ignacio Colombetti, Fabian Silva, Maxi Sandoval, Agustin Turone,
Felipe Byrne, Emi Gonda.

**Ambiguedad a resolver con la agencia:** en Data de liam hay DOS Ignacios
distintos (Mazzei y Colombetti). En Pagos de liam hay un solo `Nacho`, por
10 pagos y 12.000 USD. No se puede saber cual de los dos es.

---

## 7. Trazabilidad: no tiene contrato posible hoy

Las 4 hojas tienen esquemas distintos y casi no tienen datos.

| cliente | fila encabezado | columnas | filas con datos |
|---|---|---|---|
| liam | 3 | 10 | 43 |
| lucas | 1 | 12 | 153 |
| teo | 3 | 6 | 25 |
| mauro | 1 (datos desde la 4) | 15 | 283 |

Problemas encontrados:

- **liam:** el encabezado de la primera columna dice `MARZO`, que es un mes,
  no un nombre de campo. La columna `CC` trae fechas tipo `1904-02-08`:
  es el bug de formato de fecha sobre un numero, el mismo que ya
  apareciera en Pagos.
- **lucas:** la columna `CC` trae **telefonos** (`1161264181`,
  `9 3425 20 7891`), no montos. Y `FORMATO PRIMER CONTACTO`,
  `ANGULO PRIMER CONTACTO` y `Tipo de Cliente` estan vacias en las filas
  revisadas.
- **teo:** esquema totalmente distinto, 6 columnas
  (Nombre, Monto, Fuente, Angulo, Contesto algo?, Aclaraciones).
  No comparte ninguna columna con los otros tres.
- **liam y lucas:** tienen dos columnas con el mismo nombre,
  `ANGULO PRIMER CONTACTO`, en posiciones distintas. La segunda deberia
  llamarse `ANGULO ULTIMO CONTACTO`.

**Recomendacion:** no construir el parser de Trazabilidad todavia. Primero
que la agencia unifique el formato. Con 25 filas en teo, la atribucion de
contenido no da para un dashboard de todas formas.

---

## 8. Metricas: ya estan definidas

No hace falta inventarlas. Estan en la hoja `Maestro de Metricas` de BPF y
de AA, armada por la consultoria.

**Bloque Volumen**
- Llamadas Agendadas (Total)
- Llamadas Calificadas (Agendadas)
- Llamadas No Calificadas (Agendadas)
- % Calificados Total
- % Calificados Presentados

**Bloque Show up**
- Llamadas Presentadas (Total)
- Show Up Rate (Total)
- Llamadas Presentadas (Calificadas)

**Bloque Ventas**
- Unidades Cerradas Totales
- Tasa de Cierre Total
- Tasa de Cierre Calificadas
- Unidades Cerradas en Llamada
- Unidades Cerradas en Seguimiento
- AOV Dia 1
- AOV Trato Cerrado
- CC Mes

**Bloque Instagram** (no sale de Data, sale del CRM de contenido)
- Conversaciones Reels, Conversaciones Historias, Tasa de Agenda,
  Seguidores Nuevos y Netos, Piezas de Contenido, Visualizaciones,
  Interacciones, Guardados, Compartidos

mauro repite el bloque entero por `tipo de booking`: INSTAGRAM, WEBINAR,
LANDING IG, YOUTUBE. Eso mapea directo a la columna `tipo_booking`.

**Definiciones a confirmar con la agencia** (las formulas del Maestro estan
rotas con `#ERROR!`, asi que no se pueden leer del archivo):
1. Tasa de Cierre Total: sobre presentadas o sobre agendadas?
2. Show Up Rate: las regendas y canceladas entran en el denominador?
3. Una llamada cuenta en el mes en que se agendo o en el que se tomo?
4. `Unidad Cerrada` se cuenta con CC DIA 1 > 0, con CC TRATO CERRADO > 0,
   o con `Estado de la llamada`?
5. AOV Dia 1: promedio sobre las cerradas o sobre todas las presentadas?

---

## 9. Orden propuesto

1. Migracion: tabla `fin_llamadas` con los campos canonicos de §1.
2. Ampliar `fin_sync_escribir` con la clave `llamadas`.
3. Parser `data.js` con el mapeo de §2 y las trampas de §4.
4. Agregar `data` a `TIPOS` en `nucleo.ts` y a `parsear()` en `procesar.js`.
5. Activar las 4 fuentes de tipo `data` en `fin_fuentes`.
6. Cargar los alias de §6 en `fin_personas`.
7. Vistas de metricas de §8, con las definiciones ya confirmadas.
8. Trazabilidad: recien despues de que la agencia unifique el formato.
