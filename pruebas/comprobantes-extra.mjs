// pruebas/comprobantes-extra.mjs — una fila sin monto con "segundo comprobante", "x2"
// o solo un link no se rechaza: su link se adjunta al pago anterior (comprobantes_extra).
// Casos reales de la planilla de pagos de Agus (19/10) + bordes.
// Uso: node pruebas/comprobantes-extra.mjs     (sin dependencias)

import fs from 'node:fs';
import { parsePagos, leerComprobanteExtra, MOTIVO_COMP_EXTRA, MOTIVO_COMP_EXTRA_SIN_PAGO } from '../parsers/pagos.js';
import { CONFIG } from './config.mjs';

const fallas = [];
const ok = (cond, msg) => { if (!cond) fallas.push(msg); };

const ENC = ['FECHA DE CARGA', 'NOMBRE DEL ALUMNO', 'PAGO', 'COMPROBANTE', 'QUIÉN RECIBE'];
const L = (n) => `https://drive.google.com/file/d/${n}/view?usp=drivesdk`;
const pago = (alumno, monto, link, fecha = '2026-08-10T00:00:00') => [fecha, alumno, monto, link, 'Sofi'];
const extra = (texto, link, fecha = null) => [fecha, texto, null, link, 'Sofi'];
const correr = (filas) => parsePagos([ENC, ...filas], CONFIG.agus.pagos);
const cuadra = (r) => r.stats.filas_leidas === r.filas.length + r.rechazadas.length + r.descartadas.length;

// --- Reconocimiento del texto ------------------------------------------------
const nom = (t) => { const e = leerComprobanteExtra(t); return e ? e.nombre.join(' ') : null; };
ok(nom('miranda capielo segundo comprobante') === 'miranda capielo', 'segundo comprobante con nombre');
ok(nom('abril garcia sartori segundo comporbante') === 'abril garcia sartori', 'tipeo comporbante');
ok(nom('crisstian sebastain bartolo segundo comporbnate') === 'crisstian sebastain bartolo', 'tipeo comporbnate');
ok(nom('elias ezequiel gimenez segundo c') === 'elias ezequiel gimenez', 'segundo c');
ok(nom('Segundo comprobante') === '', 'sin nombre');
ok(nom('TERCER COMPROBANTE') === '', 'mayusculas');
ok(nom('2do comprobante') === '', '2do comprobante');
ok(nom('x2') === '' && nom('X3') === '', 'x2 / x3');
ok(nom('comprobante 2') === '', 'comprobante 2');
ok(nom('Juan Perez') === null, 'un nombre comun no es extra');
ok(nom('Compagnoni Juan') === null, 'Compagnoni no es comprobante');
ok(nom('Maria Cruz') === null, 'Cruz no dispara la regla de la c');
ok(nom('Pedro segundo') === null, 'ordinal sin comprobante no alcanza');

// --- Adjuntar al pago anterior -----------------------------------------------
let r = correr([
  pago('Miranda Capielo', 100, L('a1')),
  extra('miranda capielo segundo comprobante', L('a2')),
  pago('Sofia Perez', 200, L('b1')),
  extra('x2', L('b2')),
  extra('x3', L('b3')),
  pago('Abril Garcia Sartori', 300, L('c1')),
  extra('abril garcia sartori segundo comporbante', L('c2')),
  extra('Tercer comprobante', L('c3')),
  pago('Lara Martinez', 150, L('d1')),
  extra(null, L('d2')),
  extra(null, 'comprobante.pdf'),
]);
ok(!r.error, `error: ${r.error}`);
ok(r.filas.length === 4 && r.rechazadas.length === 0, `4 pagos y 0 rechazadas (hay ${r.filas.length} / ${r.rechazadas.length})`);
const ex = (n) => (r.filas.find((f) => f.alumno === n) || {}).comprobantes_extra;
ok(JSON.stringify(ex('Miranda Capielo')) === JSON.stringify([L('a2')]), 'Miranda: 1 extra');
ok(JSON.stringify(ex('Sofia Perez')) === JSON.stringify([L('b2'), L('b3')]), 'Sofia: x2 y x3 en orden');
ok(JSON.stringify(ex('Abril Garcia Sartori')) === JSON.stringify([L('c2'), L('c3')]), 'Abril: segundo y tercero');
ok(JSON.stringify(ex('Lara Martinez')) === JSON.stringify([L('d2'), 'comprobante.pdf']), 'Lara: link suelto sin alumno ni monto');
ok(r.filas.every((f) => Array.isArray(f.comprobantes_extra)), 'todo pago trae la lista');
ok(r.descartadas.filter((d) => d.motivo === MOTIVO_COMP_EXTRA).length === 7, 'siete extras adjuntados');
ok(r.revisar.length === 0, 'nada para revisar');
ok(cuadra(r), 'invariante leidas = cargadas + rechazadas + descartadas');

// --- El nombre manda: pago anterior mas cercano de ese alumno -----------------
r = correr([
  pago('Lara Martinez', 150, L('l1')),
  pago('Delfina Blestcher', 90, L('e1')),
  extra('lara martinez segundo comprobante', L('l2')),
  extra('delfina blestcher segundo comporbnate', L('e2')),
  pago('Cristian Sebastian Bartolo', 80, L('f1')),
  extra('crisstian sebastain bartolo segundo comporbnate', L('f2')),
]);
ok(r.filas[0].comprobantes_extra.join() === L('l2'), 'Lara: salta a la fila de Lara, no a la anterior');
ok(r.filas[1].comprobantes_extra.join() === L('e2'), 'Delfina con tipeo');
ok(r.filas[2].comprobantes_extra.join() === L('f2'), 'Cristian con tipeos en nombre y comprobante');
ok(r.revisar.length === 0 && r.rechazadas.length === 0, 'sin revisar ni rechazadas');

// --- Sin pago al que adjuntar: Revisar, no rechazada ---------------------------
r = correr([
  extra('Segundo comprobante', L('g1'), '2026-08-27T00:00:00'),
  pago('Juan Perez', 100, L('h1')),
  extra('maria lopez segundo comprobante', L('h2')),
]);
ok(r.filas.length === 1 && r.filas[0].comprobantes_extra.length === 0, 'ninguno se adjunta al pago equivocado');
ok(r.rechazadas.length === 0, 'no quedan en rechazadas');
ok(r.revisar.length === 2 && r.revisar.every((x) => x.motivo === MOTIVO_COMP_EXTRA_SIN_PAGO), 'dos para revisar');
ok(r.descartadas.filter((d) => d.motivo === MOTIVO_COMP_EXTRA_SIN_PAGO).length === 2, 'quedan descartadas con motivo');
ok(cuadra(r), 'invariante con revisar');

// --- Sin link no hay nada que adjuntar; el link repetido no se duplica --------
r = correr([
  pago('Juan Perez', 100, L('k1')),
  extra('segundo comprobante', null),
  extra('segundo comprobante', L('k1')),
  extra('segundo comprobante', L('k2')),
  extra('segundo comprobante', L('k2')),
]);
ok(r.filas[0].comprobantes_extra.join() === L('k2'), 'sin duplicados ni el link del propio pago');
ok(r.rechazadas.length === 0 && r.revisar.length === 0, 'sin rechazadas ni revisar');
ok(cuadra(r), 'invariante');

// --- Lo que NO es comprobante extra sigue igual ------------------------------
r = correr([
  pago('Juan Perez', 100, L('m1')),
  pago('Compagnoni Juan', null, L('m2')),
  pago('Ana Gomez', 'REFUND', L('m3')),
  [null, null, null, null, null],
]);
ok(r.rechazadas.length === 2, `falta monto + refund siguen rechazadas (hay ${r.rechazadas.length})`);
ok(r.rechazadas.some((x) => x.motivo === 'falta monto') && r.rechazadas.some((x) => x.motivo === 'refund sin monto numerico'), 'motivos intactos');
ok(r.filas[0].comprobantes_extra.length === 0, 'sin extras');

// --- Idempotencia: la misma hoja da el mismo resultado ------------------------
const hoja = [pago('Sofia Perez', 200, L('b1')), extra('x2', L('b2')), extra('x3', L('b3'))];
ok(JSON.stringify(correr(hoja)) === JSON.stringify(correr(hoja)), 'dos corridas iguales');

// --- Fixture real de Agus: ninguna rechazada es un comprobante extra ----------
const fx = JSON.parse(fs.readFileSync(new URL('./fixtures/agus_pagos.json', import.meta.url), 'utf8'));
const real = parsePagos(fx.filas, CONFIG.agus.pagos);
ok(!real.error, `fixture agus: ${real.error}`);
ok(cuadra(real), 'fixture agus: invariante');
const adj = real.descartadas.filter((d) => d.motivo === MOTIVO_COMP_EXTRA);
ok(adj.length >= 5, `fixture agus: se esperaban al menos 5 comprobantes extra adjuntados (hay ${adj.length})`);
ok(real.rechazadas.every((x) => !leerComprobanteExtra(String((x.contenido_crudo || [])[2] ?? ''))),
  'fixture agus: queda una rechazada que es un comprobante extra');
console.log(`fixture agus: ${adj.length} extras adjuntados, ${real.revisar.length} para revisar, ${real.rechazadas.length} rechazadas`);

if (fallas.length) {
  console.error(`\nFALLAS (${fallas.length}):\n- ${fallas.join('\n- ')}`);
  process.exit(1);
}
console.log('comprobantes-extra OK');
