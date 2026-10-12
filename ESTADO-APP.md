# ESTADO-APP · dystopia-finanzas

<!-- Sección escrita por el chat FINANZAS (12/10/2026). El repo también aloja el
     módulo VENTAS (migraciones 073-074, función ventas-agenda): si otro chat
     suma su sección, que la marque con su tema y no borre esta. -->

## Identidad
- Dystopia Finanzas: P&L, pagos, conciliación y comisiones de los clientes de Dystopia Agency
  (Liam, Agus, Teo, Lucas, Mauro). Reemplaza de a poco los Google Sheets por carga en la app.
- Ruta: C:\Users\Admin\Downloads\dystopia-finanzas (en el shell remoto: $HOME/mnt/dystopia-finanzas).
- Stack: HTML + JS vanilla (módulos ES, sin build), Supabase (Postgres + Edge Functions Deno + pg_cron).
- Deploy: Vercel, dystopia-finanzas.vercel.app, se publica solo con push a master (verificar).
- Repo: github.com/dystopiaacy-hash/dystopia-finanzas, rama master.
- Supabase: proyecto alxdjcdfpdayucassfub, compartido por las 4 apps (Marketing, Ventas, Producto, Finanzas).

## Cómo trabajamos
- Joaquín NUNCA delega SQL: Claude escribe migraciones numeradas, él las corre a mano en el SQL Editor.
- Cada migración: probada 2 veces contra un Postgres local con el esquema real, prueba de humo que
  se revierte sola y controles al final que él corre DE A UNO (el editor muestra solo el último).
- Si toca tablas que lee la sync o la app: begin; set local lock_timeout='10s'; lock de todas las
  tablas juntas al principio; commit. (La 066 dio deadlock sin esto.)
- No correr migraciones a las :00/:15/:30/:45 ni a las 9:00 (corre la sync).
- Controles que leen vistas con filtro de fundador: set_config('request.jwt.claim.sub', <uuid fundador>, true)
  en la misma ejecución, si no devuelven 0 filas.
- El número de cada migración lo asigna el jefe. No elijas números por tu cuenta: si necesitás una
  migración y no te dieron número, frená y pedilo en el resumen.
- Última usada que se ve en disco (12/10): 074_ventas_columnas_acentos.sql (Ventas, en este repo).
  Última de Finanzas: 072_finanzas_columnas.sql. Producto llega a 071. Otros chats pueden haber
  usado números después de 074 (dato histórico, no para elegir número).
- Archivos: migraciones/ en la raíz del repo.
- Código con Claude Code: grep primero, nunca leer archivos enteros, JS < 500 líneas y CSS < 300
  por archivo. Sin commit ni push hasta que Joaquín pruebe.
- Comandos para él: PowerShell (Windows), listos para copiar, siempre con el cd al repo adelante.
- UI: nunca alert/confirm/prompt del navegador (confirmaciones dentro de la página).
- Pruebas: maqueta pruebas/fixtures/_mock.html (gitignored, tiene datos reales) que simula Supabase
  y las RPC. Se prueba con Playwright como fundador; para otro rol, copiar el mock cambiando rol.
- Estilo de respuesta: vos, bullets, párrafos de 3 líneas máx, sin em-dashes, sin dar la razón por complacencia.

## Mapa del código
- js/datos.js: lecturas a Supabase y llamadas a las RPC.
- js/columnas.js: config de columnas (fin_columnas_de), extras por clave de pago, huérfanos.
- js/views/pagos.js + pagos-celdas.js: grilla de Pagos con edición en celda (311 líneas, la más larga).
- js/views/columnas-panel.js: panel "Columnas" (solo fundador): renombrar, ocultar, ordenar, agregar, archivar.
- js/views/cargar.js: formulario Cargar pago (RPC fin_pago_cargar de la 066).
- js/views/resumen.js, conciliacion.js, cliente.js: reportes (P&L, conciliación Opps vs Pagos).
- supabase/functions/sincronizar + _shared/parsers: Edge Function que lee los Sheets cada 15 min (pg_cron)
  y escribe con fin_sync_escribir (solo borra pagos origen='sheet').
- parsers/ y pruebas/*.mjs: parsers de las planillas y sus tests.
- Docs: FASE0-FINANZAS.md (relevamiento + decisiones §12), PLAN-FINANZAS-2.md (fases),
  ESQUEMA-FINANZAS.md, LISTAS-AGENCIA.md (catálogos a aprobar), FASE0-COLUMNAS-FINANZAS.md.

## Qué hicimos últimamente
000000000. (12/10) Rol cliente con un solo cliente (clienteUnico()): Resumen sin lenguaje de agencia. Solo js/views/resumen.js:
   sección mensual "Octubre 2026" (sin "por cliente"), sin columna Cliente (la fila sigue siendo clicable), leyenda "Clic en la
   fila para ver tu P&L...", subtítulo de la tarjeta de diferencia en singular. Fundador y multi-cliente no cambian. Sin
   migración, sin commit. `npm test` pasa; no se probó en navegador con cliente@liam (solo texto/plantilla).
   Además se hizo el relevamiento de la próxima tanda (sección "Relevamiento próxima tanda" al final), sin tocar código.
00000000. (12/10) 088 (número asignado por el jefe), sin correr, sin commit:
   - 088_liam_borrar_pagos_de_mas.sql: borra los 3 pagos de más de liam (ids 2505043, 2505056, 2505062, 3.500,00 USD),
     un solo `do`, diagnóstico de solo lectura antes. Conjunto = misma lógica de la Q2 de la 076c (huella + ocurrencia
     contra fin_import_liam_076), comparado como conjunto con los 3 ids. Aborta sin borrar si: conjunto distinto, suma
     distinta de 3.500,00, algún pago con creado_por/editado_por, o con dependientes (fin_liquidacion_items por clave o
     id, devoluciones por pago_original_clave, fin_pagos_extra), o fuente de pagos de liam activa / sin cortar.
     Respaldo previo en tabla normal fin_respaldo_088_liam_pagos (RLS, solo postgres). Re-ejecutable.
   - 088b_liam_borrar_pagos_control.sql: 6 controles sueltos (C1 a C6).
   - 088c_liam_restaurar_pagos.sql: restaura los 3 desde el respaldo. No se corre salvo pedido de Joaquín.
   - UI: para un usuario no fundador con un solo cliente (ej. cliente@liam.dystopia) Resumen se llama "Resumen" con
     subtítulo = nombre del cliente, y la sección anual pierde ", todos los clientes". Nuevo clienteUnico() en
     sesion.js; tocados layout.js (nav), app.js (header), resumen.js. Solo texto, sin cambios de permisos ni datos.
0000000. (12/10) 076c CORREGIDA: Q1, Q2 y Q3 fallaban con 42703 porque la foto fin_import_liam_076 que quedó en producción
   (de un intento viejo de la 076) no tiene la columna huella. Ahora la huella de la foto se calcula en la consulta con
   public.fin_pago_huella('liam', fecha, alumno, monto, concepto) (062, la misma de la 076 y del trigger de fin_pagos).
   Agregada Q0 (columnas reales de las dos tablas). Sin migración, sin número, sin correr.
000000. (12/10) migraciones/076c-liam-pagos-control-consultas-sueltas.sql: 3 consultas sueltas de solo lectura (Q1 resumen
   234 vs 231, Q2 C4 reescrito = los 3 pagos de más, Q3 inverso xlsx sin pago). Usan fin_import_liam_076 (tabla normal) y
   el cruce huella+ocurrencia; sin temporales. No es migración, sin número, sin datos personales en el archivo. Sin correr.
00000. (12/10) 076 REESCRITA tras fallar en producción con `42P01 relation "_liam_dif" does not exist`. Causa: el SQL Editor
   pasa por un pooler y no respeta begin/commit ni una sola conexión: la temporal `on commit drop` desapareció entre
   sentencias. Ahora el generador (pruebas/liam-generar-076.mjs) emite UNA sola sentencia `do $liam076$ ... $liam076$`
   (atómica), sin begin/commit ni temporales; la foto del xlsx es la tabla normal fin_import_liam_076 (se recrea, con
   columnas huella y ocu) y los controles C4/L1 la usan sueltos. Re-ejecutable: si algún pago de liam ya tiene
   importado_en no hace nada; sobre una base a medias la termina. Bloque DIAGNOSTICO (solo lectura) al principio y al
   final: devuelve estado FALTA LA 075 / NADA APLICADO / A MEDIAS / COMPLETO. La guarda "ya importado" pasó de
   excepción a no-op. Sin commit, no corrida. 078 (Ventas) no tocada.
0000. (12/10) 075 CORREGIDA tras fallar en producción (GUARDA 075 por el CHECK de crm_members.rol; abortó todo, no quedó
   nada aplicado: begin + falló antes de cualquier cambio). Causa: la guarda esperaba `ARRAY[...]` y producción devuelve
   `CHECK ((rol = ANY ('{cliente,closer,editor,fundador,setter}'::text[])))`. Ahora compara el CONJUNTO de valores (acepta
   las dos formas), suma finanzas/ventas/producto/contenido sin sacar ninguno y escribe el CHECK como ARRAY['x'::text,...]
   para que la guarda de la 077 (busca 'finanzas' entre comillas) lo reconozca. Re-corrible. fundador@agencia.dystopia
   es opcional y un fundador existente no se toca. Regex de las vistas fin_v_pnl_mensual/fin_v_conciliacion aflojada.
   076 sin cambios (corrió y abortó bien por su guarda). Sin commit, no corridas.
000. (12/10) js/nav-areas.js unificado con los roles por área del jefe (marketing: fundador/cliente/editor/contenido;
   ventas: fundador/cliente/closer/setter/ventas/finanzas; producto: fundador/cliente/producto; finanzas:
   fundador/cliente/closer/setter/finanzas/ventas). Solo cambió AREAS y la línea de cabecera. Sin commit.
   La pantalla "Sin acceso" (sesion.js ROLES + guardias de app.js) coincide con la lista de Finanzas.
00. (12/10) LIAM listo para el equipo (tema FINANZAS-LIAM, sin commit, migraciones NO corridas):
   - 075_finanzas_areas_liam.sql: permisos por área. crm_members.rol suma finanzas/ventas/producto/contenido,
     crm_asignaciones = cliente, y la tabla fin_clientes_areas (interruptor por cliente, hoy solo liam) hace que
     en ese cliente carguen fundador/finanzas/ventas y editen o anulen SOLO fundador. Los demás clientes siguen
     con las reglas de la 066. Vincula por mail a los 6 usuarios (si falta alguno, avisa y se vuelve a correr).
     Catálogos de liam (COMUNIDAD, 3RA CUOTA RENEWAL, programas), fin_catalogo_agregar, fin_diag_permisos.
   - 076_liam_pagos_al_dia.sql (GENERADA por `npm run liam:generar` desde el xlsx; no editar a mano): corta la
     planilla de PAGOS de liam (Opps y Cuotas siguen sincronizando), mete lo que falte del xlsx, pasa todos los
     pagos de liam a origen 'app' (editables, clave intacta) y deja la columna "Fuente". 231 pagos, 231.600,80 USD.
   - JS: sesion.js (roles por área, soloPanel), app.js y layout.js (pantallas por rol), cargar.js (alta de opción
     de concepto/método/quién recibe), pagos-celdas.js (puede_extras), datos.js. pruebas/xlsx-leer.mjs +
     pruebas/liam-generar-076.mjs (lector de xlsx sin dependencias y generador). `npm test` pasa.
   - Pendiente de Joaquín: crear usuarios en Auth, correr 075 y 076, deploy. Ver Pendientes 00.
0. (12/10) Regla de numeración de migraciones reemplazada en "Cómo trabajamos": el número lo asigna
   el jefe. Solo documentación, sin código ni migraciones.
1. (03/10) UI de columnas editables como planilla, commit bfce061, pusheado. Probado en mock como
   fundador y closer. Sin probar con rol cliente.
2. (03/10) 072 corrida en prod, controles OK: fin_columnas, fin_pagos_extra (valores por clave de pago),
   fin_pago_editar (solo filas origen 'app'), vista de huérfanos.
3. 067 corte de la planilla de pagos de agus: ESCRITA, NO CORRIDA.
4. 066 en prod: cargar, anular y devolver pagos desde la app (+ concepto REFUND, fin_pagos_anulados).
5. 065: fin_pagos.origen ('sheet'|'app'); la sync no toca lo cargado en la app.
6. 064: catálogos (programa, concepto, método, quién recibe) con alias y vista de pendientes.
7. 063: el ingreso del P&L sale de fin_pagos desde el primer pago de cada cliente.
8. 062: clave estable de pagos (huella md5 + ocurrencia; '#a'+n para filas app).

## Pendientes (en orden)
000000000. Commitear y pushear js/views/resumen.js (texto para rol cliente) y ESTADO-APP.md; verificar en producción con
    cliente@liam.dystopia. Decidir con Joaquín el orden de la sección "Relevamiento próxima tanda".
00000000. Correr la 088: primero el DIAGNOSTICO (debe decir LISTA PARA CORRER), después el bloque do, y los controles
    088b de a uno (C1 231 y 231.600,80; C2 0 filas; C3 3 filas y 3.500,00; C4 0 filas; C5 0; C6 pagos activo=false con
    cortada_en). Si hace falta deshacer: 088c. Después de correrla, la 076c ya no devuelve sobrantes. No subir al repo
    076, 076c, 078 ni scripts/salida/ (traen o generan datos personales); 088/088b/088c no traen datos personales.
0000000. Correr de a una Q0, Q1, Q2 y Q3 (en ese orden) de migraciones/076c-liam-pagos-control-consultas-sueltas.sql y pasar el resultado.
    Si Q0 muestra que a la foto le faltan fecha/alumno/concepto/monto/fila, frenar y avisar.
    Sobran 3 pagos (3.500 USD) en liam: decidir si se borran (L1 de la 076, o migración nueva con número del jefe).
    No pegar el resultado fuera del equipo (trae alumnos). 076c tampoco se sube al repo si se decide no subir la 076.
000. nav-areas.js: copiar el mismo archivo a Marketing, Ventas y Producto (cada repo lo hace su chat) y commitear
    junto con el resto de cambios de Finanzas cuando Joaquín pruebe.
0000. 076: correr primero el bloque DIAGNOSTICO (solo ese) del archivo regenerado; si dice NADA APLICADO o A MEDIAS,
    correr el archivo entero y verificar que el último resultado diga COMPLETO. Del intento fallido pudo quedar: fuente
    de pagos de liam cortada, tabla fin_import_liam_076 (foto vieja) y filas de prueba 182-190 borradas; no pudo quedar
    el import de pagos ni origen 'app'. Si la 078 (Ventas) usa otras temporales, la arregla Ventas.
00. LIAM (12/10), en este orden: (a) los 5 usuarios @liam.dystopia ya existen en Auth (el fundador ya tiene usuario,
    fundador@agencia.dystopia no hace falta); (b) volver a correr la 075 corregida y mirar C1 a C9 (la 077 y la 081
    detectan la 075 por fin_clientes_areas, fin_asignado, fin_ve_plata y el CHECK con los roles entre comillas);
    (c) avisar al equipo de Liam que deja de cargar en la planilla de Pagos y correr 076 (no a :00/:15/:30/:45);
    (d) revisar C4 de la 076 (en la base y no en el xlsx) y decidir L1; (e) deploy de la app (push a master);
    (f) probar con los 6 usuarios. Abiertos: refund de Natalia Moren (fila 94, falta el pago original: el FEE
    pagado en la llamada no está en Pagos), fila 226 (tomas ferrarotti, sin monto), "BPF 1 A 1" y "BPF 1 AÑO"
    quedaron como programas propios (Nacho dijo "seguramente a 1500": confirmar equivalencia), borrar usuarios
    de prueba (L3/L4 de la 076), Opps y Cuotas de liam siguen leyendo el Sheet (corte cuando exista la carga de
    gastos), cliente@liam ve en la base lo mismo que hoy un cliente (solo el panel es del lado de la UI).
    Borrar pruebas/liam-analisis.mjs (exploración, ya sin npm script).
0. Cualquier migración nueva necesita número asignado por el jefe antes de escribirse.
1. js/views/cargar.js tiene un cambio sin commitear (simplifica ctl/num/txt porque ahora todos
   los campos del sistema están siempre en el form). Revisar, probar Cargar pago y commitear (verificar origen).
2. Usuarios Agus (rol cliente) y Male (rol a definir, probablemente closer): faltan mails y rol.
   Invitar desde Supabase y escribir migración de vínculo (crm_members + asignación a cliente), número a pedir al jefe.
3. Correr la 067 (corte agus) recién DESPUÉS de crear los usuarios. Falta fecha y quién avisa al
   equipo de Agus. Después: sacar el menú "Cargar pago" de la planilla de agus. Si ya se corrió (verificar).
4. Probar columnas y Cargar pago con rol cliente cuando exista el usuario de Agus.
5. Respuestas de la agencia (reunión del 03/10, resultado verificar): ver FASE0-FINANZAS.md §12 y
   LISTAS-AGENCIA.md. Bloquean: comisiones de vendedores (¿se dejan de cargar en Opps? riesgo de
   doble conteo), comisiones netas de devoluciones, desde qué mes cuenta cada cliente en el dashboard.
6. Datos a corregir en Sheets (agencia): filas de prueba Liam 182-190 y Mauro 852-853 (2.500 USD falsos
   en sept de Liam), 8 refunds sin monto, rótulos de meses en Opps de agus y lucas, pagos sin fecha de Liam.
7. Fase 8 gastos (Opps a la app), medios de pago + calculadora dólar (qué tipo de cambio), ordenar
   Cobranzas y Mis números. Cuotas de liam/mauro: ¿pasan a Producto? (decisión V4).

## Bugs conocidos
- Ninguno abierto. Detalle UX: subir una columna junto a una oculta no muestra cambio visible en la grilla.

## Decisiones que esperan a Joaquín
- Fecha de corte de agus y quién avisa. Mails y rol de Agus y Male.
- Decisiones V2 a V7 de FASE0-FINANZAS.md §12 que no estén resueltas (verificar cuáles se cerraron).

## Cuidado con
- fin_pagos de origen 'sheet' se BORRAN y reescriben cada 15 min: nunca editarlas a mano; los valores
  extra viven en fin_pagos_extra por clave. Si corrigen el pago en el Sheet, la clave cambia y el extra queda huérfano.
- Nunca editables: monto_usd, tc_usado, clave, cliente, origen, fila_planilla. El monto se corrige anulando o devolviendo.
- fecha/closer/setter no se editan si el pago está en una liquidación cerrada (mueve comisiones).
- Columnas del sistema sin orden guardado valen posición x 10. Alumno no se puede ocultar.
- La config de columnas oculta Teléfono y Nota en la GRILLA; Cargar pago los muestra igual (decisión, no revertir).
- Un corte de planilla (cortada_en) no se deshace desde la app.
- Constraints de alias se llaman fin_cat_alias_* (fin_alias_uq ya existía).
- Mauro se desvincula: sus datos quedan, la fuente se desactiva.
- Postgres local de pruebas se muere si el contenedor queda inactivo: hay que reiniciarlo.
- No tocar ni commitear archivos de Ventas (073/074) desde tareas de Finanzas.
- liam (tras la 076): sus pagos son origen 'app' con importado_en (sin creado_por) y su planilla de Pagos está
  cortada. En clientes por áreas (fin_clientes_areas) editar/anular/devolver es solo fundador, y las columnas
  nuevas también (salvo quien cargó el pago, 15 min). fin_pago_editar y fin_pago_anular no cambiaron: obedecen
  a fin_puede_anular. No regenerar la 076 después de corrida (tiene guarda de "ya importado").

## Relevamiento próxima tanda (12/10, reuniones 07/10 y 08/10 con Nacho; solo lectura de código y migraciones)
Hechos de base: Cuotas y Opps viven en tablas SIN origen (fin_cuotas, fin_pnl): solo las llena la sync, que borra y reescribe
todo por fuente (005/060). Cortar una fuente = activo=false + cortada_en (065): la sync no la lee y lo cargado queda congelado.
Hoy no hay en la app ningún lugar donde escribir cuotas ni gastos. Cambió: FASE0 V4 y PLAN-FINANZAS-2 decían "cuotas a
Producto/Seguimiento"; Nacho las pide en Finanzas (confirmar con Joaquín que V4 queda sin efecto).
1. Cuotas (imputación, calendario, pendientes editables). Existe: fin_cuotas (001, ancho: hasta 3 cuotas por alumno en liam, 1
   en mauro), fin_v_cobranzas (003, pendiente = estado vacío o no pagado/churn/pausado/cancelado, "supuesto a validar"),
   pantalla Cobranzas (js/views/cobranzas.js, solo lectura). No hay vínculo cuota-pago (FASE0 §6). Falta: tabla de cuotas con
   origen 'app' (una fila por cuota: alumno, programa, n°, monto, vence, estado), imputar pago a cuota (clave del pago en la
   cuota o tabla puente), calendario (vista por mes de vencimientos), edición en celda (reusar pagos-celdas.js y fin_columnas).
   Migración: estructura + permisos + datos (pasar las 22 cuotas de liam/mauro). Tamaño: grande.
   Pregunta: ¿la cuota se imputa a mano al cargar el pago o por match alumno+monto? ¿Teo y Agus tienen cuotas fuera de las hojas?
   Riesgo: Producto/Seguimiento maneja renovaciones y días restantes: definir de quién es la tabla o se duplica.
2. Resell / Upsell diferenciados. Existe: conceptos RESELL, UPSELL y ~14 variantes con categoría 'producto' (031), catálogo por
   cliente con alias (064), tarjeta "Producto" en conceptos-calculo.js. Todo cae en una categoría y no hay campo propio.
   Falta: decidir si es categoría nueva en fin_conceptos (su check admite 4 valores) o un atributo "tipo de venta" del pago
   (columna extra con fin_columnas, sin migración de estructura). Migración: chica de datos, o ninguna si va por columna
   extra. Tamaño: chico. Pregunta: ¿es categoría del concepto o marca aparte del pago? ¿"RESELL / UPSELL" (29 pagos) a cuál va?
   Riesgo: fin_v_pagos_categoria y el cash collected de Ventas (016/017) leen categoria; una quinta rompe sumas de otros chats.
3. Conciliación pagos vs CRM. Existe: Conciliación Opps vs Pagos (003 fin_v_conciliacion, conciliacion.js), fin_llamadas (Data =
   CRM de ventas, 013/073, con cc_cerrado/cc_dia1/cc_seguimiento) y fin_v_pagos_doble_carga (065). No hay cruce pago-llamada.
   Falta: vista que una por alumno/teléfono y mes los cc_* de Data contra fin_pagos, con tolerancia, y su pantalla.
   Migración: solo vistas. Tamaño: mediano. Pregunta: ¿quién es la verdad cuando no cierran, CRM o pago? ¿Cruce por teléfono,
   nombre o ambos? Riesgo: Data es de Ventas (084/089); el match por nombre ya dio problemas (033); exige Data cargada.
4. Gastos por cliente. Existe: fin_pnl con staff/softwares/others/sin_categoria desde Opps (parsers/opps.js), gastos_total en
   fin_v_pnl_mensual, pantalla cliente.js. Solo lectura de planilla; fase 8 de PLAN-FINANZAS-2 sigue pendiente. Falta: tabla
   fin_gastos (origen 'app', catálogo de categoría/proveedor, cliente, fecha, monto, moneda) + formulario + grilla + P&L que
   lea de ahí; resolver comisiones de vendedores cargadas como gasto en Opps (doble conteo con fin_v_comisiones).
   Migración: estructura + permisos + catálogos + vista. Tamaño: grande. Pregunta: ¿catálogo de categorías (los 12 bloques
   de Opps) y quién carga? ¿Comisiones de vendedores salen de Opps? (FASE0 punto 9, sin respuesta).
   Riesgo: cambia fin_v_pnl_mensual, que usan Resumen, Cliente y Conciliación.
5. Panel Dystopia (Agus 25 %, Liam 30 %, Teo 40 %). Existe: fin_comision_agencia (porcentaje por cliente y período, 001, solo
   fundador, sin datos sembrados y sin lectura en la app) y fin_reparto (beneficiario y monto del mes tomado de Opps, tampoco
   expuesto). Falta: sembrar los porcentajes, vista solo fundador (% x base) y pantalla nueva. Migración: datos + vista +
   permisos. Tamaño: mediano. Pregunta: ¿el % es sobre cash collected o sobre neto (Julia pidió neto, base_calculo)? ¿Y Lucas
   y Mauro? ¿Se restan refunds? Riesgo: dato sensible, nunca visible con rol cliente; depende de 4 si la base es neto.
6. "Resumen descuadrado". Existe: resumen.js sobre fin_v_pnl_mensual (063). Causas posibles vistas en el código, sin datos
   para confirmar: (a) net_cash_flow usa Opps como ingreso en meses anteriores al primer pago, pero la tarjeta dice "Ingreso
   real − gastos"; (b) las tarjetas suman todas las filas del mes y la tabla solo yo.clientes: un cliente con filas fuera de
   esa lista (mauro desvinculado) descuadra; (c) pagos en pesos de teo (marzo 463.290) con fin_tipo_cambio vacía; (d) rótulos
   de meses de Opps de agus y lucas; (e) liam cambió con 076/088. Falta: un caso concreto. Migración: probablemente ninguna
   (UI) o 063 corregida. Tamaño: chico. Pregunta: ¿qué número y mes ve Nacho que no cierra, contra qué otro?
   Riesgo: corregir (a) cambia el net histórico.
7. Cortar Opps y Cuotas de Liam. Existe: el mecanismo (cortada_en + activo, 065/067/076; Pagos y Data de liam ya cortados).
   Falta: no se puede cortar sin pérdida: cortar Opps congela los gastos de liam y cortar Cuotas congela Cobranzas, y la app no
   tiene dónde escribir gastos (4) ni cuotas (1). Después: migración de datos que pase fin_pnl/fin_cuotas de liam a las tablas
   nuevas y el corte (update en fin_fuentes). Tamaño: chico pero depende de 1 y 4. Pregunta: ¿se corta la hoja entera o solo
   gastos? ¿Quién avisa al equipo de Liam? Riesgo: Opps también trae saldos (fin_pnl_saldos) y fin_reparto: decidir si se
   pierden.
Orden propuesto: 6 (diagnóstico) y 2 en paralelo; luego 5; 1 y 4 en paralelo (tablas distintas, un número de migración
cada una); 3 después; 7 al final, depende de 1 y 4.
