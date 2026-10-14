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

// Meses repetidos (agus, fuente 7): dos bloques, el primero en castellano (C..W)
// y una copia vieja en ingles (AA..AU). Vale el primero; el resto se ignora,
// no es error, deja aviso y el estado queda en revisar.
{
  const ANCHO = 50;
  const fila = () => Array(ANCHO).fill('');
  const m = [fila(), fila(), fila(), fila(), fila(), fila(), fila()];
  const ESP = ['Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
  const ING = ['JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
  const bloque = (col, rotulo, monto) => {
    m[1][col] = rotulo;
    m[2][col] = 'Revenue';
    m[3][col] = 'Alumno A'; m[3][col + 2] = monto;
    m[4][col] = 'Total Revenue'; m[4][col + 2] = monto;
    m[5][col] = 'Expenses';
    m[6][col] = 'Total Expenses'; m[6][col + 2] = 0;
  };
  ESP.forEach((r, i) => bloque(2 + i * 4, r, 1000 * (i + 1)));       // C, G, K, O, S, W
  ING.forEach((r, i) => bloque(26 + i * 4, r, i === 0 ? 777 : 0));   // AA, AE, ..., AU

  const r = parseOpps(m, { anio: 2026 });
  ok(!r.error, `meses repetidos: no debe dar error (${r.error})`);
  ok(r.estado === 'revisar', `meses repetidos: estado ${r.estado}, esperaba revisar`);
  ok(r.filas.length === 6, `meses repetidos: ${r.filas.length} filas, esperaba 6 (solo el primer bloque)`);
  ok(r.filas.every((f) => f.columna_planilla < 26), 'meses repetidos: hay filas tomadas del bloque ignorado');
  const montos = r.filas.map((f) => `${f.mes}:${f.monto_usd}`).join(',');
  ok(montos === '7:1000,8:2000,9:3000,10:4000,11:5000,12:6000', `meses repetidos: montos ${montos}`);
  ok(r.encabezado.length === 6 && r.encabezado[0] === 'july@2', `meses repetidos: encabezado ${r.encabezado}`);
  const rep = r.revisar.filter((x) => x.motivo === 'mes repetido en el encabezado');
  ok(rep.length === 6, `meses repetidos: ${rep.length} controles, esperaba 6`);
  ok(rep[0] && rep[0].usado === 'C' && rep[0].ignorado === 'AA', 'meses repetidos: columnas C / AA mal informadas');
  ok(r.revisar.length === 6, 'meses repetidos: no debe haber otros motivos de revision');
  ok(r.avisos.some((a) => a.includes('columna C') && a.includes('columna AA')), 'meses repetidos: falta el aviso');

  // Sin repetidos el resultado no cambia: mismo encabezado y sin avisos de repeticion.
  ok(!ref.avisos.some((a) => a.includes('repetido')) && !ref.revisar.some((x) => x.motivo === 'mes repetido en el encabezado'),
    'sin repetidos no debe avisar');
}

if (fallas.length) {
  console.error('FALLAS opps-meses:\n - ' + fallas.join('\n - '));
  process.exit(1);
}
console.log('opps-meses: OK');
