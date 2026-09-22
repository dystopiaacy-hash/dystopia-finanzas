// pruebas/data.mjs — gate del parser de la hoja Data (CRM de ventas).
//
// Filas de ejemplo de los 4 clientes con los encabezados REALES de cada
// planilla (relevados de los xlsx el 2026-09-22), pasadas por procesarFuente
// con los alias de migraciones/014_alias_data.sql (se leen del archivo, no de
// una copia). Verifica:
//  1. NADA FUERA DE DOMINIO LLEGA A LA BASE. Los tres casos de la consigna:
//       - fecha en texto (" Saturday, September 5, 2026 7:00 PM", liam)
//       - #DIV/0! en show_up y calificacion (mauro)
//       - show_up inventado ("Ghosteado", mauro; real, 1 celda)
//     ninguno aparece en datos.llamadas (lo que va a fin_sync_escribir) y
//     cada uno queda en datos.rechazadas con su valor crudo.
//     Ademas: todo show_up / calificacion de datos.llamadas esta en el
//     dominio del CHECK de migraciones/013_llamadas.sql (leido del archivo).
//  2. #DIV/0!, 0 y un valor inventado rechazan la CELDA, no la fila.
//  3. liam: fecha_llamada sale de la columna 2 por posicion, closer de la 1.
//  4. mauro: nombre = Nombre + Apellido; encabezado con salto de linea.
//  5. lucas: 'Se desconoce' = 'no se sabe'; 'por closer' = 'cancelado por closer'.
//  6. Corte por fecha_llamada: las filas formateadas del final (checkbox,
//     "0"/"1") no se leen; las vacias intercaladas se descartan.
//  7. filas_leidas = cargadas + rechazadas + descartadas.
//  8. Con 'posicion' que no coincide con el encabezado la corrida es error.
// Uso: node pruebas/data.mjs

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { procesarFuente } from '../supabase/functions/_shared/procesar.js';
import { parseData, MOTIVO_FECHA_TEXTO, MOTIVO_CELDA } from '../parsers/data.js';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const fallas = [];
const check = (ok, msg) => { if (!ok) fallas.push(msg); };

// --- alias desde la migracion 014 --------------------------------------------
const sql014 = readFileSync(join(RAIZ, 'migraciones', '014_alias_data.sql'), 'utf8');
const ALIAS = {};
for (const m of sql014.matchAll(/^\s*\('(\w+)',\s*'(\w+)',\s*'((?:[^']|'')*)',\s*(true|false),\s*(\d+|null)\)/gm)) {
  (ALIAS[m[1]] ??= []).push({
    campo: m[2], alias: m[3].replace(/''/g, "'"), obligatorio: m[4] === 'true', posicion: m[5] === 'null' ? null : Number(m[5]),
  });
}
const esperadas = { liam: 13, lucas: 15, teo: 15, mauro: 17 };
for (const [c, n] of Object.entries(esperadas)) check(ALIAS[c]?.length === n, `014: ${c} tiene ${ALIAS[c]?.length ?? 0} alias, se esperaban ${n}`);

// --- dominio del CHECK desde la migracion 013 ---------------------------------
const sql013 = readFileSync(join(RAIZ, 'migraciones', '013_llamadas.sql'), 'utf8');
const dominio = (col) => {
  const m = sql013.match(new RegExp(`${col}\\s+text\\s+check \\(${col} in \\(([^)]*)\\)\\)`));
  if (!m) throw new Error(`no encontre el CHECK de ${col} en 013`);
  return new Set([...m[1].matchAll(/'([^']*)'/g)].map((x) => x[1]));
};
const DOMINIO = { show_up: dominio('show_up'), calificacion: dominio('calificacion') };

// --- encabezados reales ------------------------------------------------------
const ENC = {
  liam: ['Encargado de la llamada', 'Encargado de la llamada', 'Nombre', 'Calificacion', 'Show up', 'Contexto',
    'Contexto Closer', 'CC DIA 1', 'CC Seguimiento', 'CC TRATO CERRADO', 'Monto restante a pagar', 'Email',
    'Teléfono', 'tipo de booking', 'Edad', 'Profesión', 'Contexto + IG', 'Situación actual de inversiones',
    'Objetivo de la consultoria', 'Ingreso mensual actual', 'Capital inicial para invertir', 'Objetivo al invertir',
    'Inversión mensual', 'MES', 'semana', 'False'],
  lucas: ['Nombre', 'Fecha de llamada', 'Encargado de la llamada', 'Show up', 'Calificacion', 'Contexto',
    'Contexto Setter', 'Contexto Closer', 'Tipo de Booking', 'Cuenta de IG', 'Celular ', 'Ocupacion Actual',
    'Bloqueo Principal', 'Inversion Disponible', 'Programa', 'CC DIA 1', 'CC TRATO CERRADO', 'CC en Seguimiento',
    'Monto restante a pagar', 'MES'],
  teo: ['Nombre Completo', 'Fecha de llamada', 'Encargado de la llamada', 'Show up', 'Calificacion',
    'Estado de la llamada', 'Fuente', 'Telefono', 'instagram', 'En qué punto estas en E-Commerce',
    'Ingreso mensual actual', 'Qué objetivo tenés con tu E-Commerce?', 'bloqueo principal', 'Inversión disponible',
    'CONTEXTO CLOSER', 'Programa', 'CC DIA 1', 'CC TRATO CERRADO', 'CC en Seguimiento', 'Monto restante a pagar',
    'Cerro?', 'CC Closer', 'semana', 'MES', 'False'],
  mauro: ['Nombre', 'Apellido', 'Fecha de llamada', 'Encargado de la llamada', 'Show up', 'Calificacion',
    'Estado de la llamada', 'Inicio seguimiento', 'Avisar', 'CONTEXTO SETTER',
    'Que paso en la llamda?\nContexto + Phatom', 'Programa ', 'CC DIA 1', 'CC TRATO CERRADO', 'CC en Seguimiento',
    'Monto restante a pagar', 'tipo de booking', 'telefono', 'instagram', 'Actividad actual',
    'Ingreso mensual actual', 'objetivo de ganancia', 'bloqueo principal', 'Inversión disponible', 'MES', 'SEMANA',
    'GRUPO CREADO'],
};

// Fila desde {encabezado(1-based): valor}.
const fila = (cli, celdas) => {
  const f = new Array(ENC[cli].length).fill('');
  for (const [k, v] of Object.entries(celdas)) f[Number(k) - 1] = v;
  return f;
};

const FECHA_TEXTO = ' Saturday, September 5, 2026 7:00 PM';
const INVENTADO = 'Ghosteado';

const MATRIZ = {
  liam: [
    ENC.liam,
    fila('liam', { 1: 'Lucas Deza ', 2: '2026-09-03', 3: 'Ana Perez', 4: 'CALIFICADO', 5: 'SI', 8: 1500, 10: 1500, 13: '0381 514-4456', 14: 'instagram', 26: '1' }),
    fila('liam', { 1: 'Valentin Morello', 2: FECHA_TEXTO, 3: 'Bruno Diaz', 4: 'NO SE SABE', 5: 'NO', 26: '0' }),
    fila('liam', { 26: '0' }),   // vacia intercalada (solo checkbox)
    fila('liam', { 1: 'Liam Wickham', 2: 46270, 3: 'Carla Ruiz', 4: 'SI', 5: 'Regenda', 14: 'YOUTUBE', 26: '1' }),
    fila('liam', { 26: '0' }),   // cola formateada: no se lee
    fila('liam', { 26: '0' }),
  ],
  lucas: [
    ENC.lucas,
    fila('lucas', { 1: 'Diego Sosa', 2: '2026-08-12', 3: 'Fran ', 4: 'SI', 5: 'Se desconoce', 9: 'LANDING', 15: 'Mentoria', 16: '900' }),
    fila('lucas', { 1: 'Eva Gomez', 2: '2026-08-13', 3: 'franco ', 4: 'por closer', 5: 'NO CALIFICADO' }),
    fila('lucas', { 1: 'Fede Luna', 2: '2026-08-14', 3: 'German ', 4: 'NO', 5: 'Calificacion' }),
  ],
  teo: [
    ENC.teo,
    fila('teo', { 1: 'Gaston Rey', 2: '2026-06-03', 3: 'Franco Lagrega', 4: 'SI', 5: 'CALIFICADO', 6: 'EN SEGUIMIENTO', 7: 'tiktok', 17: 500, 18: 'abc', 25: 'False' }),
    fila('teo', { 1: 'Julieta Duarte', 3: 'Valentin Morello', 4: 'SI', 5: 'CALIFICADO', 25: '1' }),   // sin fecha (real, f281)
    fila('teo', { 1: 'Hugo Paz', 2: '2026-06-05', 3: 'GONZA GUGLIELMINO', 4: 'Cancelado por Closer', 5: 'Regenda' }),
  ],
  mauro: [
    ENC.mauro,
    fila('mauro', { 1: 'Ines', 2: 'Vera', 3: '2026-06-01', 4: 'Lauty Tiseyra', 5: '#DIV/0!', 6: '#DIV/0!', 7: 'NO CIERRE', 11: 'contexto', 17: 'WEBINAR' }),
    fila('mauro', { 1: 'Juan', 2: 'Mora', 3: '2026-06-02', 4: 'Facundo Came', 5: 0, 6: 0, 13: '#DIV/0!' }),
    fila('mauro', { 1: 'Kevin', 2: 'Lopez', 3: '2026-06-03', 4: 'Lucas Deza', 5: INVENTADO, 6: 'CALIFICADO' }),
  ],
};

const fuente = (cli) => ({ id: 1, cliente_id: cli, tipo: 'data', fila_encabezado: 1, alias: ALIAS[cli] });
const R = {};
for (const cli of Object.keys(MATRIZ)) {
  R[cli] = await procesarFuente(fuente(cli), MATRIZ[cli], null);
  const parse = parseData(MATRIZ[cli], { alias: ALIAS[cli] });
  const s = parse.stats;
  check(!parse.error, `${cli}: error ${parse.error}`);
  check(s.filas_leidas === s.filas_cargadas + s.rechazadas + s.descartadas,
    `${cli}: leidas ${s.filas_leidas} != cargadas ${s.filas_cargadas} + rechazadas ${s.rechazadas} + descartadas ${s.descartadas}`);
  check(R[cli].estado !== 'error' && R[cli].datos, `${cli}: procesarFuente dio ${R[cli].estado}: ${R[cli].mensaje}`);
}

// 1. Nada fuera de dominio llega a la base.
for (const [cli, r] of Object.entries(R)) {
  for (const l of r.datos?.llamadas ?? []) {
    for (const campo of ['show_up', 'calificacion']) {
      check(l[campo] === null || DOMINIO[campo].has(l[campo]), `${cli} f${l.fila_planilla}: ${campo} '${l[campo]}' fuera del CHECK de 013`);
    }
    check(/^\d{4}-\d{2}-\d{2}$/.test(l.fecha_llamada), `${cli} f${l.fila_planilla}: fecha_llamada '${l.fecha_llamada}' no es ISO`);
    for (const campo of ['cc_dia1', 'cc_cerrado', 'cc_seguimiento', 'monto_restante']) {
      check(l[campo] === null || Number.isFinite(l[campo]), `${cli} f${l.fila_planilla}: ${campo} '${l[campo]}' no es numero`);
    }
  }
  const json = JSON.stringify(r.datos?.llamadas ?? []);
  for (const crudo of [FECHA_TEXTO.trim(), 'Saturday', '#DIV/0!', INVENTADO]) {
    check(!json.includes(crudo), `${cli}: '${crudo}' llego a datos.llamadas`);
  }
}
const rech = (cli) => R[cli].datos.rechazadas;
const llam = (cli, f) => R[cli].datos.llamadas.find((l) => l.fila_planilla === f);

check(rech('liam').some((x) => x.fila_planilla === 3 && x.motivo === MOTIVO_FECHA_TEXTO && x.valor_crudo === FECHA_TEXTO),
  'liam f3: la fecha en texto no quedo en rechazadas con su valor crudo');
check(!llam('liam', 3), 'liam f3: la fila con fecha en texto se cargo');
check(rech('mauro').filter((x) => x.fila_planilla === 2 && x.valor_crudo === '#DIV/0!').length === 2,
  'mauro f2: #DIV/0! en show_up y calificacion no quedaron las dos en rechazadas');
check(rech('mauro').some((x) => x.fila_planilla === 4 && x.valor_crudo === INVENTADO && x.motivo.startsWith('show_up')),
  'mauro f4: el show_up inventado no quedo en rechazadas');

// 2. Celda rechazada, fila cargada.
const m2 = llam('mauro', 2);
check(m2 && m2.show_up === null && m2.calificacion === null && m2.nombre === 'Ines Vera', 'mauro f2: con #DIV/0! la fila no se cargo con show_up/calificacion null');
const m3 = llam('mauro', 3);
check(m3 && m3.show_up === null && m3.calificacion === null && m3.cc_dia1 === null, 'mauro f3: 0 / #DIV/0! no quedaron en null');
check(rech('mauro').filter((x) => x.fila_planilla === 3).length === 3, 'mauro f3: se esperaban 3 celdas rechazadas (show_up 0, calificacion 0, cc_dia1 #DIV/0!)');
const m4 = llam('mauro', 4);
check(m4 && m4.show_up === null && m4.calificacion === 'calificado', 'mauro f4: show_up inventado no dejo la fila cargada con show_up null');
check(rech('mauro').every((x) => x.motivo.includes(MOTIVO_CELDA)), 'mauro: una celda rechazada se rechazo como fila');
check(R.mauro.estado === 'ok', `mauro: celdas rechazadas no deben poner la corrida en parcial (dio ${R.mauro.estado})`);
check(llam('teo', 4)?.calificacion === null && rech('teo').some((x) => x.fila_planilla === 4 && x.valor_crudo === 'Regenda'),
  "teo f4: calificacion 'Regenda' (real) no se rechazo como celda");
check(llam('teo', 2)?.cc_cerrado === null && rech('teo').some((x) => x.fila_planilla === 2 && x.valor_crudo === 'abc'),
  'teo f2: monto no numerico no se rechazo como celda');
check(llam('liam', 5)?.calificacion === null && rech('liam').some((x) => x.fila_planilla === 5 && x.valor_crudo === 'SI'),
  "liam f5: calificacion 'SI' no se rechazo");
check(llam('lucas', 4)?.calificacion === null && rech('lucas').some((x) => x.fila_planilla === 4 && x.valor_crudo === 'Calificacion'),
  "lucas f4: calificacion 'Calificacion' no se rechazo");

// 3. liam por posicion.
const l2 = llam('liam', 2);
check(l2 && l2.fecha_llamada === '2026-09-03' && l2.closer === 'Lucas Deza', `liam f2: fecha/closer mal mapeados: ${JSON.stringify(l2)}`);
check(l2 && l2.tipo_booking === 'INSTAGRAM' && l2.cc_dia1 === 1500 && l2.telefono === '0381 514-4456', `liam f2: campos: ${JSON.stringify(l2)}`);
check(llam('liam', 5)?.fecha_llamada === '2026-09-05', 'liam f5: serial 46270 no dio 2026-09-05');
check(llam('liam', 5)?.show_up === 'regenda', 'liam f5: Regenda');

// 4. mauro.
const m1 = llam('mauro', 4);
check(m1?.nombre === 'Kevin Lopez', `mauro: nombre no concatena Nombre + Apellido (${m1?.nombre})`);
check(llam('mauro', 2)?.contexto_closer === 'contexto', 'mauro: la columna 11 (encabezado con salto de linea) no se mapeo');
check(llam('mauro', 2)?.estado_llamada === 'NO CIERRE' && llam('mauro', 2)?.tipo_booking === 'WEBINAR', 'mauro f2: estado/tipo_booking');

// 5. lucas.
check(llam('lucas', 2)?.calificacion === 'no se sabe', "lucas: 'Se desconoce' no se mapeo a 'no se sabe'");
check(llam('lucas', 2)?.closer === 'Fran' && llam('lucas', 2)?.cc_dia1 === 900, 'lucas f2: closer sin btrim o cc_dia1');
check(llam('lucas', 3)?.show_up === 'cancelado por closer', "lucas: 'por closer' no se mapeo");
check(llam('teo', 4)?.show_up === 'cancelado por closer', "teo: 'Cancelado por Closer' no se mapeo");

// 6. Corte y descartes.
const pl = parseData(MATRIZ.liam, { alias: ALIAS.liam });
check(pl.stats.filas_leidas === 4 && pl.stats.cola_sin_fecha === 2, `liam: corte por fecha (leidas ${pl.stats.filas_leidas}, cola ${pl.stats.cola_sin_fecha})`);
check(pl.descartadas.length === 1 && pl.descartadas[0].fila_planilla === 4, 'liam f4: la vacia intercalada no se descarto');
check(rech('teo').some((x) => x.fila_planilla === 3 && x.motivo === 'falta fecha_llamada'), 'teo f3: fila sin fecha no quedo rechazada');

// 8. posicion que no coincide.
const malo = ALIAS.liam.map((a) => (a.campo === 'fecha_llamada' ? { ...a, posicion: 3 } : a));
const pm = parseData(MATRIZ.liam, { alias: malo });
check(pm.error && /posicion/.test(pm.error), 'liam: posicion que no coincide con el encabezado no dio error');

for (const [cli, r] of Object.entries(R)) {
  console.log(`${cli.padEnd(6)} ${r.estado.padEnd(8)} cargadas ${r.stats.cargadas}  rechazadas(entradas) ${r.stats.rechazadas}  descartadas ${r.stats.descartadas}  ${r.mensaje ?? ''}`);
}
if (fallas.length) {
  console.error(`\n${fallas.length} FALLAS:\n - ${fallas.join('\n - ')}`);
  process.exit(1);
}
console.log('\ndata: OK');
