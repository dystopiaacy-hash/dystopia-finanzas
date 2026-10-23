// pruebas/pagos-columnas-nuevas.mjs — NOTA, MAIL, FUENTE DEL MAIL y FUENTE (columna L sin titulo) de la planilla de Pagos de Agus (23/10).
// Con los alias en la fuente, el parser los lee; sin alias (Liam, Teo) quedan en null y no cambia nada mas.
// Datos inventados. Uso: node pruebas/pagos-columnas-nuevas.mjs     (sin dependencias)

import { parsePagos } from '../parsers/pagos.js';
import { CONFIG } from './config.mjs';

const fallas = [];
const ok = (cond, msg) => { if (!cond) fallas.push(msg); };

// Encabezado como la hoja nueva: 3 columnas sin titulo en el medio y despues MAIL / FUENTE DEL MAIL / NOTA (carga 19/10).
const ENC = ['FECHA DE CARGA', 'NOMBRE DEL ALUMNO', 'PAGO', 'COMPROBANTE', 'MÉTODO DE PAGO', '', '', '', 'MAIL', 'FUENTE DEL MAIL', 'NOTA (carga 19/10)'];
const fila = (alumno, monto, mail, fuente, nota) =>
  ['2026-10-11T00:00:00', alumno, monto, 'https://x.test/1', 'TRANFER PESOS', 'instagram', null, null, mail, fuente, nota];

const ALIAS_NUEVOS = [
  { campo: 'nota', alias: 'NOTA (carga 19/10)', obligatorio: false },
  { campo: 'nota', alias: 'NOTA', obligatorio: false },
  { campo: 'email', alias: 'MAIL', obligatorio: false },
  { campo: 'fuente_email', alias: 'FUENTE DEL MAIL', obligatorio: false },
];
const base = CONFIG.agus.pagos;
const conAlias = { ...base, alias: [...base.alias, ...ALIAS_NUEVOS] };

const matriz = [ENC,
  fila('Alumno Uno', 800, 'uno@ejemplo.test', 'Formulario de ingreso CRM Ventas DCAC', 'Solo foto (Male)'),
  fila('Alumno Dos', 500, null, 'Sin mail (no esta en el form)', null),
  fila('Alumno Tres', 300, '  tres@ejemplo.test ', null, '  '),
];

const r = parsePagos(matriz, conAlias);
ok(!r.error, `error: ${r.error}`);
ok(r.filas.length === 3, `filas: ${r.filas.length}`);
ok(r.filas[0].email === 'uno@ejemplo.test' && r.filas[0].fuente_email === 'Formulario de ingreso CRM Ventas DCAC'
  && r.filas[0].nota === 'Solo foto (Male)', `fila 1: ${JSON.stringify(r.filas[0])}`);
ok(r.filas[1].email === null && r.filas[1].fuente_email === 'Sin mail (no esta en el form)' && r.filas[1].nota === null,
  `fila 2: ${JSON.stringify(r.filas[1])}`);
ok(r.filas[2].email === 'tres@ejemplo.test' && r.filas[2].fuente_email === null && r.filas[2].nota === null,
  `fila 3 (recorta espacios, nota en blanco = null): ${JSON.stringify(r.filas[2])}`);

// Si la planilla renombra el titulo a solo NOTA, tambien se lee.
const m2 = [ENC.map((c) => (c === 'NOTA (carga 19/10)' ? 'NOTA' : c)), fila('Alumno Uno', 800, null, null, 'hola')];
const r2 = parsePagos(m2, conAlias);
ok(!r2.error && r2.filas[0].nota === 'hola', `alias NOTA: ${r2.error || JSON.stringify(r2.filas[0])}`);

// Sin alias (Liam, Teo): las tres columnas quedan en null aunque la hoja las tenga.
const r3 = parsePagos(matriz, base);
ok(!r3.error && r3.filas.length === 3, `sin alias: ${r3.error || r3.filas.length}`);
ok(r3.filas.every((f) => f.nota === null && f.email === null && f.fuente_email === null), 'sin alias: nota/email/fuente_email en null');

// Las cuentas siguen cuadrando.
ok(r.stats.filas_leidas === r.filas.length + r.rechazadas.length + r.descartadas.length, 'invariante de filas');

// --- Fuente (origen del lead): la columna L de la hoja de Agus no tiene titulo (211 / 209) -------------------------
// Aca la columna sin titulo es la 6 (indice 5); en la hoja real es la 12 (L). Alias de la migracion: por titulo y, en blanco, por posicion.
const ALIAS_FUENTE = [
  { campo: 'fuente_lead', alias: 'FUENTE', obligatorio: false },
  { campo: 'fuente_lead', alias: 'FUENTE DEL LEAD', obligatorio: false },
  { campo: 'fuente_lead', alias: 'ORIGEN DEL LEAD', obligatorio: false },
  { campo: 'fuente_lead', alias: '', obligatorio: false, posicion: 6 },
];
const conFuente = { ...conAlias, alias: [...conAlias.alias, ...ALIAS_FUENTE] };

// 1) Columna sin titulo + alias en blanco con posicion: se lee. No pisa a las demas (mail/fuente del mail/nota siguen igual).
const f1 = parsePagos(matriz, conFuente);
ok(!f1.error && f1.filas.length === 3, `fuente sin titulo: ${f1.error || f1.filas.length}`);
ok(f1.filas.every((f) => f.fuente_lead === 'instagram'), `fuente sin titulo: ${JSON.stringify(f1.filas.map((f) => f.fuente_lead))}`);
ok(f1.filas[0].email === 'uno@ejemplo.test' && f1.filas[0].fuente_email === 'Formulario de ingreso CRM Ventas DCAC'
  && f1.filas[0].nota === 'Solo foto (Male)', 'fuente sin titulo: las otras columnas nuevas no cambian');
ok(f1.filas[0].metodo_pago === 'TRANFER PESOS', 'fuente sin titulo: metodo de pago intacto');

// 2) Valor en blanco o con espacios = null; trae el texto recortado.
const m2f = [ENC, fila('Alumno Uno', 800, null, null, null), fila('Alumno Dos', 500, null, null, null), fila('Alumno Tres', 300, null, null, null)];
m2f[1][5] = '  webinar ';
m2f[2][5] = '   ';
m2f[3][5] = null;
const f2 = parsePagos(m2f, conFuente);
ok(!f2.error && f2.filas[0].fuente_lead === 'webinar' && f2.filas[1].fuente_lead === null && f2.filas[2].fuente_lead === null,
  `fuente recorta / vacia: ${f2.error || JSON.stringify(f2.filas.map((f) => f.fuente_lead))}`);

// 3) Si Agus le pone titulo a la columna (FUENTE, u ORIGEN DEL LEAD en minusculas), se lee por nombre; el alias en blanco se ignora sin error.
for (const titulo of ['Fuente', 'origen del lead']) {
  const encT = ENC.map((c, i) => (i === 5 ? titulo : c));
  const f3 = parsePagos([encT, ...matriz.slice(1)], conFuente);
  ok(!f3.error && f3.filas.every((f) => f.fuente_lead === 'instagram'), `fuente con titulo ${titulo}: ${f3.error || JSON.stringify(f3.filas.map((f) => f.fuente_lead))}`);
}

// 4) Un alias en blanco SIN posicion no matchea la primera columna vacia (antes de este cambio, indexOf('') la agarraba).
const f4 = parsePagos(matriz, { ...conAlias, alias: [...conAlias.alias, { campo: 'fuente_lead', alias: '', obligatorio: false }] });
ok(!f4.error && f4.filas.every((f) => f.fuente_lead === null), `alias en blanco sin posicion: ${f4.error || JSON.stringify(f4.filas.map((f) => f.fuente_lead))}`);

// 5) Posicion que cae en una columna CON titulo (la hoja se movio): se ignora, sin error ni dato de otra columna.
const f5 = parsePagos(matriz, { ...conAlias, alias: [...conAlias.alias, { campo: 'fuente_lead', alias: '', obligatorio: false, posicion: 9 }] });
ok(!f5.error && f5.filas.every((f) => f.fuente_lead === null), `posicion en columna con titulo: ${f5.error || JSON.stringify(f5.filas.map((f) => f.fuente_lead))}`);
// ...y una posicion fuera de la hoja tampoco rompe.
const f5b = parsePagos(matriz, { ...conAlias, alias: [...conAlias.alias, { campo: 'fuente_lead', alias: '', obligatorio: false, posicion: 99 }] });
ok(!f5b.error && f5b.filas.every((f) => f.fuente_lead === null), `posicion fuera de la hoja: ${f5b.error || JSON.stringify(f5b.filas.map((f) => f.fuente_lead))}`);

// 6) Sin los alias de Fuente (Liam, Teo): null aunque la hoja tenga la columna, y el resto igual.
ok(r.filas.every((f) => f.fuente_lead === null) && r3.filas.every((f) => f.fuente_lead === null), 'sin alias de fuente: fuente_lead en null');

// 7) Un alias con posicion pero con titulo (como los de Data) se sigue leyendo por nombre en Pagos: no cambia lo existente.
const f7 = parsePagos(matriz, { ...conAlias, alias: [...conAlias.alias, { campo: 'fuente_email', alias: 'FUENTE DEL MAIL', obligatorio: false, posicion: 3 }] });
ok(!f7.error && f7.filas[0].fuente_email === 'Formulario de ingreso CRM Ventas DCAC', `alias con titulo y posicion: ${f7.error || f7.filas[0].fuente_email}`);

// 8) La invariante de filas se mantiene con la columna nueva.
ok(f1.stats.filas_leidas === f1.filas.length + f1.rechazadas.length + f1.descartadas.length, 'invariante de filas con fuente');

if (fallas.length) {
  console.error(`pagos-columnas-nuevas: ${fallas.length} falla(s)`);
  for (const f of fallas) console.error('  - ' + f);
  process.exit(1);
}
console.log('pagos-columnas-nuevas: OK');
