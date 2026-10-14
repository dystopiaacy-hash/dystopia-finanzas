// pruebas/opps-meses.mjs — la fila de meses de Opps se acepta en ingles, castellano
// y abreviada, y el resultado (y el hash del encabezado) es el mismo.
// Uso: node pruebas/opps-meses.mjs     (sin dependencias)

import fs from 'node:fs';
import { parseOpps, mesDeRotulo } from '../supabase/functions/_shared/parsers/opps.js';

const fallas = [];
const ok = (cond, msg) => { if (!cond) fallas.push(msg); };

const EN = ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
const ES = ['ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO', 'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE'];
const AB = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const ABP = ['Ene.', 'Feb.', 'Mar.', 'Abr.', 'May.', 'Jun.', 'Jul.', 'Ago.', 'Set.', 'Oct.', 'Nov.', 'Dic.'];
const ANIO = ES.map((m) => `${m.toLowerCase()} 2026`);

// Rotulos sueltos.
ok(mesDeRotulo('JANUARY') === 1, 'JANUARY debe ser 1');
ok(mesDeRotulo('Septiembre') === 9, 'Septiembre debe ser 9');
ok(mesDeRotulo('  mar ') === 3, 'mar debe ser 3');
ok(mesDeRotulo('Item') === 0, 'Item no es mes');
ok(mesDeRotulo('YEAR REVIEW') === 0, 'YEAR REVIEW no es mes');
ok(mesDeRotulo(null) === 0, 'null no es mes');

// Misma hoja de Agus (fixture) con la fila de meses reescrita.
const fx = JSON.parse(fs.readFileSync(new URL('./fixtures/agus_opps.json', import.meta.url), 'utf8'));
const base = fx.filas;
const filaMeses = base.findIndex((f) => Array.isArray(f) && f.includes('JANUARY'));
ok(filaMeses > -1, 'el fixture de agus tiene que tener la fila JANUARY');

function conMeses(rotulos) {
  const m = base.map((f) => (Array.isArray(f) ? [...f] : f));
  base[filaMeses].forEach((v, k) => {
    const i = EN.indexOf(v);
    if (i > -1) m[filaMeses][k] = rotulos[i];
  });
  return m;
}

const ref = parseOpps(base, { anio: 2026 });
ok(!ref.error, `referencia en ingles dio error: ${ref.error}`);
ok(ref.filas.length > 0, 'la referencia no cargo filas');

for (const [nombre, rot] of [['castellano', ES], ['abreviado', AB], ['abreviado con punto', ABP], ['con anio', ANIO]]) {
  const r = parseOpps(conMeses(rot), { anio: 2026 });
  ok(!r.error, `${nombre}: error ${r.error}`);
  ok(JSON.stringify(r.filas) === JSON.stringify(ref.filas), `${nombre}: las filas difieren de la version en ingles`);
  ok(JSON.stringify(r.encabezado) === JSON.stringify(ref.encabezado), `${nombre}: el encabezado (hash) cambio`);
}

// Sin ninguna fila de meses sigue siendo error.
const sin = base.map((f) => (Array.isArray(f) ? f.map((v) => (EN.includes(v) ? 'X' : v)) : f));
ok(parseOpps(sin, { anio: 2026 }).error, 'sin meses debe dar error');

if (fallas.length) {
  console.error('FALLAS opps-meses:\n - ' + fallas.join('\n - '));
  process.exit(1);
}
console.log('opps-meses: OK');
