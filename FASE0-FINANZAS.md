# FASE0-FINANZAS.md · relevamiento al 2026-10-02

Fuentes leídas: los 5 xlsx exportados hoy (valores reales, no solo
encabezados), el parser actual (`_shared/parsers/pagos.js`, `opps.js`,
`cuotas.js`), `002_seed_config.sql`, `031_conceptos.sql` y
`CONFIG-FUENTES.md`. No se ejecutó nada contra Supabase. Lo que hay que
confirmar en la base está en la sección 10.

---

## 1. Resumen

- **Hoy la app lee 12 hojas de 5 planillas**: 5 de Pagos, 5 de Opps y 2 de
  Cuotas (las de liam y mauro). "Cargar Pago" está en el seed como
  `form`, inactiva.
- **Quién escribe Pagos: en la práctica, gente a mano.** El Apps Script
  "Cargar Pago" existe en las 5 planillas, pero el único rastro de uso son
  filas de prueba del 10 y el 13/09. No encontré nada escrito por GHL ni
  por otra automatización. Cortar Pagos no rompe ninguna entrada
  automática, como sí pasaba con Data en Ventas.
- **El "ventas" de Opps es la suma de Pagos copiada a mano.** En 22 de 30
  meses cuadra con Pagos por menos de 200 USD. Hoy la app tiene dos
  fuentes para el mismo ingreso.
- **Hay 2.500 USD de pagos de prueba cargados como reales** en septiembre
  de liam (filas 182 y 190).
- **Los meses de Opps están mal rotulados en agus y también en lucas.**
  Lo de lucas no estaba relevado. El parser toma el mes del rótulo, así que
  en la base esos números están en el mes equivocado.
- **La huella de contenido es viable como identidad de `fin_pagos`, pero
  sin `fila_planilla`.** Medido sobre 1.732 filas: el único grupo de pagos
  idénticos son 4 filas de prueba. Si la identidad incluye la fila, como
  en la 033, cambia cada vez que alguien inserta una fila arriba.
- **Nada referencia hoy `fin_pagos.id`** en las migraciones (no hay ninguna
  FK). El problema del id inestable bloquea lo que viene, todavía no rompe
  nada. Falta confirmarlo en la base (query 10.4).
- **Las comisiones de closers y setters ya están como gasto en Opps.** El
  "Male Setter" de agus es exactamente el 10% de las ventas. Si Ventas las
  calcula y Finanzas las suma, se cuentan dos veces.

---

## 2. Qué alimenta hoy la app

| cliente | hoja | gid | tipo app | tabla destino | filas en el xlsx |
|---|---|---|---|---|---|
| liam | Pagos | 667978021 | pagos | fin_pagos | 189 datos (incluye 7 de prueba) |
| liam | Cuotas | 677639895 | cuotas (`cuotas_ancho`) | fin_cuotas | 7 alumnos |
| liam | Opps | 2122278614 | opps | fin_pnl / saldos / reparto | feb a ago |
| agus | Pagos | 667978021 | pagos | fin_pagos | 262 |
| agus | Opps | 2122278614 | opps | fin_pnl | 3 bloques (mal rotulados) |
| teo | Pagos | 667978021 | pagos | fin_pagos | 229 |
| teo | Opps | 2122278614 | opps | fin_pnl | ene a ago |
| mauro | Historico Pagos | 667978021 | pagos | fin_pagos | 847 (dic 2025 a sep 2026) |
| mauro | Pagos Por Cobrar | 1304167527 | cuotas (`cuotas_ancho`) | fin_cuotas | 15 alumnos, solo cuota 1 |
| mauro | Opps | 2122278614 | opps | fin_pnl | ene a ago |
| lucas | PAGOS | 188432479 | pagos | fin_pagos | 209 |
| lucas | Opps | 0 | opps | fin_pnl | 6 bloques (ene mal rotulado) |

- Las cuotas de teo están en su planilla de CRM (CUOTAS, gid 93797201),
  inactiva. agus y lucas no tienen hoja de cuotas.
- Filas válidas que debería cargar hoy el parser: unas 1.625. Coincide con
  las 1.621 del 25/09 más lo cargado desde entonces.

---

## 3. Quién o qué escribe cada hoja

| hoja | escritor | evidencia |
|---|---|---|
| Pagos (las 5) | persona, a mano | Fechas sin hora, nombres de archivo tipeados en Comprobante, separadores de mes ("MARZO", "Mayo"), notas sueltas en la columna L. |
| Cargar Pago → Pagos | Apps Script, sin uso real | Solo hay pruebas: liam filas 182 a 190 ("gabriel", "alfredo", tel 1111111) y mauro 852 y 853 ("joaquin fernandez", 13/09 16:13, con hora). |
| Opps (las 5) | persona, a mano, a fin de mes | Un solo "ventas" tipeado por mes, gastos con texto libre, totales con fórmula. |
| Cuotas liam / Pagos Por Cobrar mauro | persona (CSM) | Estados escritos a mano ("Cuota pagada", "CHURN", "Pausado"). |
| PAGOS lucas, columnas L a O | fórmula + persona | `=INT(A+90-TODAY())` (días de programa), aviso a 30-21 días, pitch, estado de renovación. Es seguimiento de producto, no finanzas. |

**Consecuencia:** no hace falta reemplazar ninguna automatización antes del
corte. Alcanza con desactivar el menú "Cargar pago" de cada planilla el
mismo día del corte de esa planilla.

**Bug del script si alguien lo usa:** en mauro, la prueba escribió "si" en
PAGO y 1000 en PESOS. El script no valida que el monto sea un número.

---

## 4. Mapa columna por columna: Pagos

El orden de columnas cambia por cliente. El parser mapea por encabezado
(alias en `fin_alias_columnas`), así que el orden no le importa.

| campo canónico | liam | agus | teo | mauro | lucas |
|---|---|---|---|---|---|
| fecha | A `FECHA DE CARGA` | A `FECHA DE CARGA` | A `Fecha` | A `Nombre` (tiene fechas) | A `FECHA DE CARGA` |
| programa | B | B | B | B | B |
| alumno | C `NOMBRE DEL ALUMNO` | C | C | C | C `Nombre` |
| telefono | D `NUMERO` | D | D | D | D (10 son fórmula `=+549...`) |
| concepto | E | E | **F** | **G** | E |
| monto (USD) | F `PAGO` | F `PAGO` | **E** `PAGO` | E `PAGO` | F `MONTO EN USD` |
| monto_pesos | no | no | no | F `PESOS` (527 filas) | no |
| closer | G | G | G | H | G `Closer` |
| setter | H | H | H | I | H |
| comprobante | I | I | I | J | I |
| quien_recibe | J | J | J | K | J `Quien Recibe` |
| metodo_pago | K | K y **L duplicada** `MÉTODO DE PAGO` (vacía) | K | L | K |
| extra sin mapear | L: fuente de la venta (`FUENTE IG`, `FUENTE LANDING`, `LOW TICKET 700`, nota de acuerdo con Valen del 06/04) | | L: quién recibió (`Nacho`, `Sillo`) en 9 filas | M `Monto Restante a Pagar` (1 fila) | L a O: renovación (ver sección 3) |

**Cómo se completa cada columna (filas con datos):**

| | liam | agus | teo | mauro | lucas |
|---|---|---|---|---|---|
| quien_recibe vacío | 60% | 4% | 72% | 82% | 88% |
| comprobante vacío | 31% | 6% | 37% | 42% | 17% |
| closer vacío | 12% | 2% | 44% | 10% | 2% |
| setter vacío | 36% | 99,6% | 44% | 16% | 19% |

- En agus el closer es siempre "MALE" (247 de 247) y el setter va vacío.
- En liam, `BPF` como closer aparece en 54 pagos. No es una persona.

---

## 5. Mapa: Opps (P&L)

- **Plantilla idéntica en las 5:** 12 bloques de 4 columnas desde C
  (rótulo del mes en la fila 4).
  - **Revenue:** filas 7 a 22.
  - **Gastos:** Staff 27 a 41, Softwares 43 a 52, Others 54 a 61.
  - **Totales y cierre:** totales en 23 y 62, Net Cash Flow en 63,
    Dividends en 65, Retained en 66, Opening y Closing en 67 y 68.
- **El parser no depende de los números de fila:** se ubica por etiqueta y
  lee el monto en la columna +2 o +3. Por eso ya levanta los 10 montos que
  quedaron corridos una columna (liam julio y agosto, mauro junio, lucas
  julio y agosto).
- **Revenue:** una sola línea por mes, "ventas", tipeada a mano.
  Conciliación en la sección 7.
- **Gastos:** texto libre, sin catálogo ("ADS", "ads", "ADS "; "joa",
  "Joa", "joaco"). Mezclan sueldos, comisiones de closers y setters, fees
  de Stripe y pagos que hizo Nacho por el cliente ("julian PAGO NACHO").
- **Fórmulas de la planilla con errores:** en liam y agus, el Total
  Expenses de mayo (`U62`) arranca en U44 y se saltea la primera fila de
  Softwares. La app no se ve afectada porque suma los ítems y marca el mes
  como `revisar`.
- **Celdas fuera de la plantilla** (el parser no las lee y está bien):
  - liam I71 (4.267) e I72 (`=I63-I71`): una cuenta auxiliar.
  - lucas AA71: "BB ME DEBE 1K".

### Meses mal rotulados

| cliente | bloque rotulado | contiene | evidencia |
|---|---|---|---|
| agus | JANUARY | julio | ventas 73.649,4, igual a la suma de Pagos de julio |
| agus | FEBRUARY | agosto | 96.544 contra 96.544,70 en Pagos de agosto |
| agus | JULY | otra versión de julio | ventas 73.844,5 y solo 2 gastos. Suma julio dos veces en el total del año |
| lucas | JANUARY | abril | 27.210,8 contra 27.281,16 en Pagos de abril. Pagos de lucas arranca el 01/04 |

---

## 6. Cuotas

| | liam `Cuotas` | mauro `Pagos Por Cobrar` |
|---|---|---|
| forma | ancho: hasta 3 cuotas (Monto, Fecha de pago, Estado) + Contexto | ancho: 1 cuota (Monto, Fecha, Estado) + Closer |
| filas | 7 alumnos | 15 alumnos |
| estados en uso | pagado, pendiente, Pausado | Pendiente, CHURN, Cuota pagada, pagado |
| desplegable | pendiente, pagado, Pausado | dos listas distintas según la fila (con y sin CHURN) |

- **Vinculación con Pagos:** ninguna. La cuota no apunta al pago que la
  saldó: solo hay coincidencia por nombre.
- **Qué es en realidad:** es seguimiento de cobranza, con el mismo dominio
  que Producto/Seguimiento (renovaciones, días restantes). Ver la decisión
  V4.

---

## 7. Conciliación: ventas de Opps contra suma de Pagos

| cliente | mes | Pagos | Opps "ventas" | diferencia |
|---|---|---|---|---|
| liam | feb | 21.640,00 | 21.500,00 | -140 |
| liam | abr | 19.366,00 | 22.816,00 | **+3.450** |
| liam | ago | 35.855,50 | 36.019,50 | +164 |
| liam | sep | 2.500,00 | no hay | **las 2 filas son de prueba** |
| teo | mar | 463.290,16 | 31.976,70 | **3 pagos en pesos** (ver 8) |
| teo | jul | 20.814,24 | 20.854,50 | +40 |
| lucas | may | 10.432,20 | 11.932,20 | **+1.500** |
| lucas | jun / ago | | | +49 / +40 |
| mauro | feb | 25.942,10 | 25.992,10 | +50 |
| mauro | abr | 47.341,90 | 48.084,30 | **+742,40** |
| mauro | ago | 16.922,90 | 16.992,00 | +69 |

Todos los meses que no aparecen cuadran a menos de 1 USD.

**Lectura:** Pagos es la fuente primaria y Opps copia el total. Las
diferencias grandes son pagos que están en un lado y no en el otro, o
refunds descontados en Opps y no en Pagos. Las pregunta la agencia (A6).

---

## 8. Valores raros (con lo que hace hoy el parser)

| cliente | fila | valor | qué es | parser hoy | impacto |
|---|---|---|---|---|---|
| liam | 182 | 10/09/2026, "gabriel", 1500 PIF, tel 1111111 | prueba del script | **lo carga** | +1.500 USD sep |
| liam | 190 | 13/09/2026, "joaquin fernandez", 1000 PIF UPSELL | prueba del script | **lo carga** | +1.000 USD sep |
| liam | 183 a 188 | 09/12/2001, "alfredo" x4, 1000 PIF | pruebas | rechaza (fecha fuera de rango) | ninguno |
| mauro | 852 y 853 | 13/09 16:13, monto "si" | prueba del script | rechaza | ninguno |
| teo | 15, 18, 27 | 350.000 / 50.000 / 40.000 (Liam Gómez) | pesos en la columna USD | rechaza (tope 10.000) | faltan esos USD en marzo |
| 5 clientes | 8 filas | "refund" / "REFUND" en el monto | devoluciones sin monto | rechaza | la comisión no se puede neto de refunds |
| lucas | 154 | monto con formato `d.m`, vale 31/08/2026 | monto pisado por una fecha | rechaza | falta 1 pago de Valentín Martinez |
| agus | 5, 37 | 1324,07 y 1328,4 con formato de fecha | el comprobante dice 1.321,9 y 1.421,9 | carga el valor de la celda | posible error de 2,17 y 93,5 USD |
| teo | 178 | 1254,11 con formato `yyyy.m` | formato raro, valor razonable | carga | ninguno aparente |
| lucas | 193 | monto 0, FEE | | carga con 0 | ninguno |
| liam, teo, mauro | varias | fila sin fecha con monto (Joaquin Loustaneau 1500, Ivan Zarate 1500, Victor 450...) | | rechaza | 3.450 USD en liam, justo la diferencia de abril |
| mauro | 3 a 60 | diciembre 2025 sin montos (58 filas) | historial sin cargar | rechaza | |
| agus | 78, 92, 104... | "segundo comprobante", "x2", "x3" sin monto | segunda foto del mismo pago | descarta o rechaza | ninguno |
| teo | 133 a 163 | 9 pagos de 50 y 100 USD sin programa ni concepto | probable evento (en Opps de junio hay "airbnb evento") | carga como `sin_clasificar` | 650 USD |
| mauro | 389, 721 | 100 USD contra 973.000 ARS; 700 USD contra 290.500 ARS | USD o pesos mal tipeados | carga, con TC absurdo | baja prioridad (mauro sale) |

**Dato a confirmar:** los 3.450 USD de liam sin fecha (filas 52, 65 y 66)
son exactamente la diferencia de abril entre Opps y Pagos. Es casi seguro
que son pagos de abril sin fecha cargada.

---

## 9. Desplegables y catálogos

### Concepto
- **Histórico:** 30 valores distintos. El catálogo `fin_conceptos` (031)
  cubre los 30.
- **Formulario Cargar Pago:** ofrece 11 valores, iguales en las 5
  planillas.
  - **Le faltan conceptos que hoy se usan:** REFUERZA FEE (98 pagos), CUOTA
    RENOVACION (21), COMPLETA FEE (13) y COMUNIDAD (16).
  - **Trae 4 que nunca se usaron y no están en el catálogo:** PIF RESELL,
    1ER CUOTA RESELL, 1ER CUOTA UPSELL y 2DA CUOTA UPSELL. Si se usaran,
    caerían en `sin_clasificar`.

### Método de pago
- **Histórico:** 38 valores, con escrituras distintas para lo mismo:
  - `TRANFER PESOS` / `TRANSFER EN PESOS` / `TRANSFER PESOS`
  - `TRANFER USD - ARG` / `TRANSFER EN USD - ARG`
  - `Stripe` / `stripe` / `STRIPE` / `STRIPE DYSTOPIA`
- **Mezcla método con quien recibe**, sobre todo en lucas:
  - `TRANSFER EN PESOS-Calypso Soluciones`
  - `LBFinanzas - BLAS`
  - `RECIBIO NACHITO`
  - `transferencia en pesos - recibe sofi`
  - `Red Tron TRC20 (Nacho)`
- **Formulario:** usa otros 7 valores (`TRANSFERENCIA PESOS`,
  `TRANSFERENCIA USD`...) que no coinciden con ninguno del histórico.

### Quién recibe
- **Histórico:** 21 valores (`Sofi`, `SOFI FINANCIERA`, `Sofi Financiera`;
  `Joaco Fernandez`, `joaco Feranandez`...).
- **Formulario:** `SOFÍA FINANCIERA` y `LUCAS FINANCIERA`.

### Closer y setter
- Hay variantes por mayúsculas y por apodo:
  - `LUCAS` / `Lucas` / `LUCAS DEZA`
  - `Lautaro` / `LAUTY`
  - `GONZA` / `Gonza` / `gonza`
  - `FRANCO LAGREGA` / `franco lagrega` / `FRAN LAGREGA`
- Ya está resuelto en `fin_vendedores` y sus alias (009 y 010). Pagos tiene
  que usar el mismo catálogo que Ventas.

### Programa
- 17 valores. liam usa 9 distintos para 4 programas reales:
  - `BPF 1 A 1 4 MESES`
  - `BPF 1 A 1`
  - `BPF 1 a 1 - 4 Meses`
  - `1 a 1 Blueprint Financiero`
- agus mezcla `1 a 1` y `GRUPAL` con `1 mes`, `3 meses` y `skool`
  (julio contra agosto en adelante).

---

## 10. Queries de control (solo lectura, de a una)

**10.1 Pagos cargados por cliente.** Tiene que dar 5 filas. Esperado
aproximado: agus 252, liam 173, lucas 205, mauro 778, teo 219.

```sql
select cliente_id, count(*) as pagos, round(sum(monto_usd), 2) as usd
from public.fin_pagos
group by cliente_id
order by cliente_id;
```

**10.2 Pagos de prueba de liam en septiembre.** Tiene que dar 2 filas:
gabriel 1500 y joaquin fernandez 1000.

```sql
select fila_planilla, fecha, alumno, monto_usd, concepto, telefono
from public.fin_pagos
where cliente_id = 'liam' and fecha >= '2026-09-01'
order by fila_planilla;
```

**10.3 Revenue de Opps de agus y lucas por mes.** Tiene que mostrar agus
en los meses 1, 2 y 7, y lucas en 1, 5, 6, 7 y 8.

```sql
select cliente_id, mes, item, monto_usd
from public.fin_pnl
where categoria = 'revenue' and cliente_id in ('agus', 'lucas')
order by cliente_id, mes;
```

**10.4 Qué depende hoy de fin_pagos.** Tiene que dar 0 filas de FK. Las
vistas que aparezcan son las que hay que revisar si cambia la identidad.

```sql
select 'fk' as tipo, conrelid::regclass::text as objeto
from pg_constraint where confrelid = 'public.fin_pagos'::regclass
union all
select distinct 'vista', v.oid::regclass::text
from pg_depend d
join pg_rewrite r on r.oid = d.objid
join pg_class v on v.oid = r.ev_class
where d.refobjid = 'public.fin_pagos'::regclass and v.oid <> 'public.fin_pagos'::regclass;
```

**10.5 Choques de huella en la base.** Tiene que dar 0 filas.

```sql
select cliente_id, fecha, lower(trim(alumno)) as alumno, monto_usd,
       upper(trim(coalesce(concepto, ''))) as concepto, count(*)
from public.fin_pagos
group by 1, 2, 3, 4, 5
having count(*) > 1;
```

---

## 11. Riesgos para la reestructuración

1. **Identidad de `fin_pagos` con `fila_planilla`.**
   - **Riesgo:** la identidad de la 033 incluye la fila. Si alguien
     inserta un pago atrasado arriba (en lucas y mauro hay 5 pagos fuera de
     orden de fecha), todas las filas de abajo cambian de identidad.
   - **Propuesta:** huella = cliente + fecha + alumno normalizado + monto +
     concepto normalizado, más un número de ocurrencia para desempatar
     duplicados legítimos.
   - **Lo que no resuelve:** corregir un nombre o un monto en la planilla
     sigue cambiando la huella. Por eso es un puente: el id definitivo es el
     de la app desde el corte.
2. **Doble fuente de ingresos.** Si la app sigue leyendo el "ventas" de
   Opps y además muestra cash collected desde Pagos, cualquier diferencia
   (sección 7) aparece como dos números distintos para el mismo mes.
3. **Doble conteo de comisiones.** Opps Staff ya trae closers y setters.
   Si Ventas calcula comisiones y Finanzas las resta como gasto, se cuentan
   dos veces.
4. **Editar antes del corte.** Es la misma lección de Ventas: la sync
   reemplaza todo por fuente cada 15 minutos. `fin_sync_escribir` tiene que
   respetar el `origen` y el `cortada_en` (como la 060 para Data) antes de
   habilitar cualquier edición de pagos.
5. **Opps es un formato de planilla, no de datos.** Pasarlo tal cual a una
   grilla de 12 bloques no tiene sentido. En la app conviene una tabla de
   gastos (fecha o mes, categoría, ítem, monto, quién pagó) con catálogo, y
   el P&L calculado.
6. **Repo:** `035_prueba_closer.sql` y `036_metricas_setter.sql` están
   fuera de git. La diferencia en `nucleo.ts` es solo de finales de línea
   (CRLF), no hay cambios reales.

---

## 12. Decisiones

### Para vos

- **V1. Identidad.** Huella de contenido sin `fila_planilla`, como puente
  hasta el corte. ¿Ok?
- **V2. Ingresos.**
  - **Propuesta:** el revenue del P&L sale de `fin_pagos` y Opps queda
    solo para gastos. Se deja de leer la fila "ventas".
  - **Alternativa:** seguir leyendo las dos y mostrar la diferencia como
    alerta de conciliación.
- **V3. Mauro.** ¿Queda afuera de la reestructuración, como en Marketing?
  Sus datos quedan y la fuente sigue como está hasta que se desvincule.
- **V4. Cuotas.** Las de liam (7) y mauro (15) son seguimiento de
  cobranza. ¿Van a Producto/Seguimiento, junto con renovaciones y días
  restantes, o se quedan en Finanzas? Lo mismo para las columnas L a O de
  PAGOS de lucas.
- **V5. Método y quién recibe.** ¿Los separamos en dos catálogos cerrados?
  Hoy método mezcla las dos cosas.
- **V6. Refunds.**
  - **Propuesta:** un pago negativo con concepto REFUND que apunta al pago
    original.
  - **Lo que la agencia tiene que definir:** si la comisión de la agencia y
    la de los vendedores van netas de devoluciones.
- **V7. Gastos (Opps).** ¿Entran en esta reestructuración o se cortan
  primero Pagos y después gastos? Recomiendo Pagos primero: es lo que
  bloquea comisiones y conciliación.

### Para la agencia (un solo mensaje)

1. **Filas de prueba.**
   - **Qué hay:** liam filas 182 a 190 (gabriel, alfredo, joaquin
     fernandez) y mauro 852 y 853.
   - **Qué hacer:** borrarlas. Hoy suman 2.500 USD falsos en septiembre de
     liam.
2. **Refunds:** 8 pagos con "refund" en vez de monto. ¿Cuánto se devolvió
   y de qué pago? Están en liam 94, agus 128, lucas 106, teo 193, 194 y
   222, y mauro 136 y 145.
3. **Opps de agus:**
   - JANUARY tiene julio y FEBRUARY tiene agosto.
   - JULY tiene otra versión de julio (73.844,5 contra 73.649,4).
   - ¿Cuál vale? ¿Se corrigen los rótulos?
4. **Opps de lucas:** JANUARY tiene abril. ¿Se corrige el rótulo?
5. **Teo, marzo:** 3 pagos de Liam Gómez cargados en pesos (350.000,
   50.000 y 40.000). ¿Cuánto es en USD?
6. **Montos a revisar contra el comprobante:**
   - lucas 154 (Valentín Martinez, la celda tiene una fecha).
   - agus 5 (1.324,07 contra 1.321,9).
   - agus 37 (1.328,4 contra 1.421,9).
7. **Pagos sin fecha en liam:** Joaquin Loustaneau 1.500, Ivan Zarate
   1.500 y Victor 450. ¿Son de abril? Explicarían la diferencia de abril.
8. **Diferencias Opps contra Pagos:** lucas mayo +1.500 y mauro abril
   +742,4. ¿Qué incluye el "ventas" de Opps que no está en Pagos?
9. **Comisiones de vendedores.** Hoy se cargan como gasto en Opps. Cuando
   las calcule la app, ¿se dejan de cargar en la planilla?
10. **Conceptos.**
    - **Qué hay:** el formulario Cargar Pago no tiene REFUERZA FEE, CUOTA
      RENOVACION, COMPLETA FEE ni COMUNIDAD, y trae 4 que nunca se usaron.
    - **Qué tiene que confirmar:** el catálogo único de conceptos para la
      app.
11. **Teo, junio:** 9 pagos de 50 y 100 USD sin programa ni concepto
    (Mateando, Aurora, Lemu...). ¿Son de un evento? ¿Qué concepto llevan?
12. **liam:**
    - **"BPF" como closer:** ¿significa "sin closer" (venta de la marca)?
    - **Columna L** (FUENTE IG, FUENTE LANDING, LOW TICKET): ¿la usan para
      algo, por ejemplo comisiones?
13. **Fecha de corte de Pagos por cliente** (decide Nacho). Tiene que
    entrar en cuenta que teo, lucas y mauro cargan a fin de mes.
14. **Julia Aguirre:** ¿existe la planilla de Finanzas 2025? ¿Qué se hace
    con los meses de neto negativo?

---

## 13. Resultados de las queries (corridas el 2026-10-02)

- 10.1: agus 250, liam 171, lucas 205, mauro 777, teo 218.
  - liam y lucas coinciden al centavo con el xlsx.
  - Faltan 4 filas, todas rechazadas por el parser:
    - agus 5 y 37: 2.652,47 USD, formato de fecha en el monto.
    - teo 178: 1.254,11 USD, mismo motivo.
    - mauro 661: 131 USD FEE del 21/06, sin nombre de alumno.
- 10.2: confirmadas las 2 filas de prueba de liam en septiembre (182 y
  190, 2.500 USD).
- 10.3: confirmados los rótulos mal puestos. agus tiene revenue en los
  meses 1, 2 y 7, y lucas en el mes 1. Las ventas de agus en Opps suman
  244.037,90 USD contra 170.194,10 reales de julio y agosto.
- 10.4: ninguna FK contra fin_pagos. Dependen 9 vistas: alias_sin_mapear,
  cobertura_vendedores, conceptos_desconocidos, conciliacion,
  conciliacion_cc, pago_vendedores, pagos_categoria, pnl_mensual y
  ranking_closers. Agregar una columna no rompe ninguna.
- 10.5: 0 choques de huella en la base.
- 10.6 (nueva): la liquidación 5 (2026-06, cerrada) tiene 62 ítems y los
  62 tienen un pago_id que ya no existe.
  - fin_liquidacion_items.pago_id no tiene FK a propósito (012).
  - Hoy no se puede volver de un ítem liquidado a su pago, ni saber si un
    pago ya se liquidó.
  - Arreglo: guardar la huella en los ítems y reconectar los 62 por
    fecha + alumno + monto.
