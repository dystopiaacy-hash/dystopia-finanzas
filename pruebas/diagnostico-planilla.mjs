// pruebas/diagnostico-planilla.mjs — corre los parsers REALES (_shared) contra un xlsx descargado.
// Solo lectura, sin red ni base. Imprime ESTRUCTURA y CONTEOS: nunca nombres, telefonos ni montos.
// Uso: node pruebas/diagnostico-planilla.mjs <agus|teo> "<ruta al xlsx de Finanzas>"
//   Compara el encabezado de Pagos contra el fixture del 21/09 y prueba Opps y Pagos.
import fs from 'node:fs';
import { leerXlsx } from './xlsx-leer.mjs';
import { serialAIso, RANGO_FECHA_EN_MONTO } from '../supabase/functions/_shared/grid.js';
import { parsePagos } from '../supabase/functions/_shared/parsers/pagos.js';
import { parseOpps, mesDeRotulo } from '../supabase/functions/_shared/parsers/opps.js';
import { hashEncabezado } from '../supabase/functions/_shared/procesar.js';
import { CONFIG } from './config.mjs';

const [cuenta, ruta] = process.argv.slice(2);
if (!CONFIG[cuenta] || !ruta) { console.error('uso: node pruebas/diagnostico-planilla.mjs <agus|teo> <xlsx>'); process.exit(2); }

// Misma regla que grid.js valorDeCelda para celdas con formato de fecha.
const { montoMaximoReal, serialMin, serialMax } = RANGO_FECHA_EN_MONTO;
const celda = (v) => {
  if (v === undefined || v === null) return '';
  if (typeof v === 'object' && 'fecha' in v) {
    const n = v.fecha;
    if (n >= serialMin && n <= serialMax) return serialAIso(n);
    return Math.abs(n) <= montoMaximoReal ? n : String(n);
  }
  return v;
};
const matriz = (filas) => Array.from(filas, (f) => Array.from(f || [], celda));

const libro = leerXlsx(ruta);
console.log('Hojas:', Object.entries(libro).map(([h, f]) => `${h} (${f.length} filas)`).join(' | '));

// ---- Opps
if (!libro.Opps) console.log('\nOPPS: no hay pestana "Opps"');
else {
  const m = matriz(libro.Opps);
  console.log('\nOPPS');
  m.forEach((fila, i) => {
    const rot = fila.map((v, k) => [k, mesDeRotulo(v)]).filter(([, n]) => n > 0);
    if (rot.length >= 3) {
      console.log(`  fila de meses: fila ${i + 1}, ${rot.length} rotulos`);
      console.log('  rotulos tal como estan (col:texto -> mes):');
      for (const [k] of rot) console.log(`    col ${k + 1}: ${JSON.stringify(String(fila[k]))} -> ${mesDeRotulo(fila[k])}`);
    }
  });
  const r = parseOpps(m, CONFIG[cuenta].opps);
  if (r.error) console.log('  parser:', r.error);
  else {
    const porMes = {};
    for (const f of r.filas) porMes[f.mes] = (porMes[f.mes] || 0) + 1;
    console.log(`  parser OK: ${r.filas.length} items, ${r.rechazadas.length} rechazadas, ${r.revisar.length} controles 'revisar'`);
    console.log('  items por mes:', JSON.stringify(porMes));
    console.log('  hash encabezado:', await hashEncabezado('opps', r.encabezado));
  }
}

// ---- Pagos
if (!libro.Pagos) console.log('\nPAGOS: no hay pestana "Pagos"');
else {
  const m = matriz(libro.Pagos);
  const enc = (m[0] || []).map((v) => String(v ?? '').trim());
  while (enc.length && enc[enc.length - 1] === '') enc.pop();
  console.log('\nPAGOS');
  console.log(`  encabezado actual (${enc.length} cols):`, JSON.stringify(enc));
  const fx = new URL(`./fixtures/${cuenta}_pagos.json`, import.meta.url);
  if (fs.existsSync(fx)) {
    const ant = (JSON.parse(fs.readFileSync(fx, 'utf8')).filas[0] || []).map((v) => String(v ?? '').trim());
    while (ant.length && ant[ant.length - 1] === '') ant.pop();
    console.log(`  encabezado fixture 21/09 (${ant.length} cols):`, JSON.stringify(ant));
    console.log('  columnas nuevas:', JSON.stringify(enc.filter((c) => c && !ant.includes(c))));
    console.log('  columnas que ya no estan:', JSON.stringify(ant.filter((c) => c && !enc.includes(c))));
    console.log('  mismo orden y texto:', JSON.stringify(enc) === JSON.stringify(ant));
  }
  const r = parsePagos(m, CONFIG[cuenta].pagos);
  if (r.error) console.log('  parser:', r.error);
  else {
    const mot = {};
    for (const x of r.rechazadas) mot[x.motivo] = (mot[x.motivo] || 0) + 1;
    const des = {};
    for (const x of r.descartadas) des[x.motivo] = (des[x.motivo] || 0) + 1;
    console.log('  stats:', JSON.stringify(r.stats));
    console.log('  rechazadas por motivo:', JSON.stringify(mot));
    console.log('  descartadas por motivo:', JSON.stringify(des));
    console.log('  hash encabezado:', await hashEncabezado('pagos', r.encabezado));
  }
}
