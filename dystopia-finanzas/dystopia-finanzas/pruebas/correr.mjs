// pruebas/correr.mjs — gate de la fase 3.
// Corre los 3 parsers contra los fixtures reales de las 5 cuentas y verifica:
//  a) opps, ESTRUCTURAL: toda fila del bloque (entre REVENUE y Total
//     Expenses) con item y monto numerico queda capturada por el parser, sin
//     saltear ninguna ni inventar otras. Se verifica con un escaneo propio del
//     bloque, no contra la formula de la planilla. Un monto no numerico tiene
//     que quedar en rechazadas.
//     - Ningun gasto de Opps mayor a 40000 (sintoma de serial de fecha colado).
//     - Toda 'fecha en celda de monto' deja el mes en 'revisar'.
//     - Reparto del mes = Retained Earnings (margen 0.01) donde hay reparto.
//     CONTROL (no falla): items vs Total Expenses / Total Revenue. Se exige
//     que el parser marque 'revisar' en todo mes que no cuadra.
//  b) pagos: filas_leidas = cargadas + rechazadas + descartadas.
//  c) cuotas: las 3 formas devuelven filas con el mismo shape.
//  d) ninguna fecha parseada fuera de 2024-01-01 .. 2027-12-31.
//  e) ningun monto NaN ni null en una fila cargada.
// Imprime una tabla por cuenta y sale con codigo 1 si algo falla.
// Uso: node pruebas/correr.mjs     (sin dependencias)

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parsePagos, MOTIVO_TOPE } from '../parsers/pagos.js';
import { parseOpps, MARGEN, MOTIVO_FECHA_EN_MONTO } from '../parsers/opps.js';
import { parseCuotas, CAMPOS_CUOTA } from '../parsers/cuotas.js';
import { FECHA_MIN, FECHA_MAX } from '../parsers/comun.js';
import { CONFIG } from './config.mjs';

const DIR = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
const MESES_EN = ['JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE', 'JULY', 'AUGUST',
  'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER'];
const TOPE_GASTO_OPPS = 40000;
const indice = JSON.parse(readFileSync(join(DIR, 'index.json'), 'utf8'));
const fallas = [];
const avisos = [];
const tabla = [];

const cargar = (archivo) => JSON.parse(readFileSync(join(DIR, archivo), 'utf8')).filas;
const esNumero = (n) => typeof n === 'number' && Number.isFinite(n);
const r2 = (n) => (n === null || n === undefined ? '-' : (Math.round(n * 100) / 100).toString());
const fechaOk = (f) => typeof f === 'string' && f >= FECHA_MIN && f <= FECHA_MAX;

function falla(cuenta, hoja, msg) { fallas.push(`[${cuenta}/${hoja}] ${msg}`); return false; }

// --- Escaneo propio del bloque de Opps (independiente del parser) -----------
const vacia = (v) => v === null || v === undefined || String(v).trim() === '';
const numLimpio = (v) => (typeof v === 'number' ? v : (/^-?\d+(\.\d+)?$/.test(String(v).trim()) ? Number(v) : null));
const ANCLAS_DATOS = ['revenue', 'total revenue', 'expenses', 'staff', 'softwares', 'others'];
const lbl = (f, b) => {
  for (const k of [b, b + 1]) if (typeof f[k] === 'string' && !vacia(f[k]) && numLimpio(f[k]) === null) return f[k].trim();
  return null;
};

// Filas con monto entre REVENUE y Total Expenses: { fila_planilla, item, monto|null, crudo }.
function escanearBloque(filas, filaMeses, b) {
  const labs = filas.map((f) => (lbl(f || [], b) || '').toLowerCase().replace(/\s+/g, ' '));
  const ini = labs.findIndex((l, r) => r > filaMeses && l === 'revenue');
  const fin = labs.findIndex((l, r) => r > filaMeses && l === 'total expenses');
  if (ini === -1 || fin === -1) return null;
  const out = [];
  for (let r = ini + 1; r < fin; r++) {
    if (ANCLAS_DATOS.includes(labs[r])) continue;
    const f = filas[r] || [];
    const crudo = !vacia(f[b + 2]) ? f[b + 2] : (!vacia(f[b + 3]) ? f[b + 3] : null);
    if (crudo === null) continue;
    out.push({ fila_planilla: r + 1, item: lbl(f, b), monto: numLimpio(crudo), crudo });
  }
  return out;
}

function probarOpps(cuenta, fx) {
  const filas = cargar(fx.archivo);
  const res = parseOpps(filas, CONFIG[cuenta].opps);
  if (res.error) return { ok: falla(cuenta, 'opps', res.error), txt: 'ERROR' };
  let ok = true;
  const filaMeses = filas.findIndex((f) => Array.isArray(f) && f.includes('JANUARY'));
  let meses = 0;
  let conReparto = 0;
  for (let k = 2; k < filas[filaMeses].length; k++) {
    const mes = MESES_EN.indexOf(String(filas[filaMeses][k]).trim()) + 1;
    if (mes < 1) continue;
    const m = MESES[mes - 1];
    const esperadas = escanearBloque(filas, filaMeses, k);
    if (!esperadas) { ok = falla(cuenta, 'opps', `${m}: no se encontro REVENUE o Total Expenses en el bloque`); continue; }
    const parseadas = res.filas.filter((f) => f.mes === mes);
    const rechMes = res.rechazadas.filter((x) => x.contenido_crudo?.columna === k + 1);
    // Cada fila con monto numerico, capturada con el mismo item y monto.
    for (const e of esperadas) {
      if (e.monto === null) {
        if (!rechMes.some((x) => x.fila_planilla === e.fila_planilla)) ok = falla(cuenta, 'opps', `${m} fila ${e.fila_planilla}: monto no numerico ${JSON.stringify(e.crudo)} ni capturado ni rechazado`);
        continue;
      }
      if (e.monto === 0 && !e.item) continue;
      const p = parseadas.find((f) => f.fila_planilla === e.fila_planilla);
      if (!p) ok = falla(cuenta, 'opps', `${m} fila ${e.fila_planilla}: '${e.item}' ${e.monto} no fue capturado`);
      else if (Math.abs(p.monto_usd - e.monto) > 1e-9 || (p.item ?? null) !== (e.item ?? null)) ok = falla(cuenta, 'opps', `${m} fila ${e.fila_planilla}: capturado '${p.item}' ${p.monto_usd}, esperado '${e.item}' ${e.monto}`);
    }
    // Nada inventado: toda fila parseada existe en el bloque.
    for (const p of parseadas) {
      if (!esperadas.some((e) => e.fila_planilla === p.fila_planilla && e.monto !== null)) ok = falla(cuenta, 'opps', `${m} fila ${p.fila_planilla}: fila parseada que no existe en el bloque`);
    }
    // Control contra la planilla: si no cuadra, el parser tiene que marcar revisar.
    const c = res.controles.find((x) => x.mes === mes);
    const gastos = parseadas.filter((f) => f.categoria !== 'revenue').reduce((s, f) => s + f.monto_usd, 0);
    const revenue = parseadas.filter((f) => f.categoria === 'revenue').reduce((s, f) => s + f.monto_usd, 0);
    if (Math.abs(gastos - (c.total_expenses ?? 0)) > MARGEN || Math.abs(revenue - (c.total_revenue ?? 0)) > MARGEN) {
      avisos.push(`[${cuenta}/opps] REVISAR ${m}: items ${r2(gastos)} vs Total Expenses ${r2(c.total_expenses)} (dif ${r2(gastos - (c.total_expenses ?? 0))}); revenue ${r2(revenue)} vs ${r2(c.total_revenue)}`);
      if (c.estado !== 'revisar') ok = falla(cuenta, 'opps', `${m}: no cuadra y el parser no lo marco 'revisar'`);
    }
    const rep = res.reparto.filter((x) => x.mes === mes);
    if (rep.length) {
      conReparto++;
      const suma = rep.reduce((s, x) => s + x.monto, 0);
      if (Math.abs(suma - (c.retained ?? 0)) > MARGEN) ok = falla(cuenta, 'opps', `${m}: reparto ${r2(suma)} != Retained Earnings ${c.retained}`);
    }
    if (esperadas.length) meses++;
  }
  for (const f of res.filas) {
    if (!esNumero(f.monto_usd)) ok = falla(cuenta, 'opps', `fila ${f.fila_planilla}: monto ${f.monto_usd}`);
    if (!['revenue', 'staff', 'softwares', 'others', 'sin_categoria'].includes(f.categoria)) ok = falla(cuenta, 'opps', `fila ${f.fila_planilla}: categoria ${f.categoria}`);
    if (f.categoria !== 'revenue' && Math.abs(f.monto_usd) > TOPE_GASTO_OPPS) ok = falla(cuenta, 'opps', `${MESES[f.mes - 1]} fila ${f.fila_planilla}: gasto '${f.item}' ${f.monto_usd} > ${TOPE_GASTO_OPPS} (serial de fecha colado?)`);
  }
  for (const x of res.reparto) if (!esNumero(x.monto)) ok = falla(cuenta, 'opps', `reparto fila ${x.fila_planilla}: monto ${x.monto}`);
  for (const x of res.rechazadas) {
    avisos.push(`[${cuenta}/opps] rechazada ${x.contenido_crudo.mes} fila ${x.fila_planilla}: ${x.motivo} (${x.valor_crudo})`);
    const mes = MESES_EN.indexOf(x.contenido_crudo.mes.toUpperCase()) + 1;
    if (x.motivo === MOTIVO_FECHA_EN_MONTO && res.controles.find((c) => c.mes === mes)?.estado !== 'revisar') ok = falla(cuenta, 'opps', `fila ${x.fila_planilla}: fecha en celda de monto sin marcar el mes 'revisar'`);
  }
  const sinCat = res.filas.filter((f) => f.categoria === 'sin_categoria');
  if (sinCat.length) avisos.push(`[${cuenta}/opps] sin_categoria: ${sinCat.map((f) => `${MESES[f.mes - 1]} fila ${f.fila_planilla} '${f.item}' ${f.monto_usd}`).join(', ')}`);
  const revisar = res.controles.filter((c) => c.estado === 'revisar').length;
  return { ok, txt: `${meses}m, ${res.filas.length} items, ${revisar} revisar, rep ${conReparto}m` };
}

function probarPagos(cuenta, fx) {
  const filas = cargar(fx.archivo);
  const res = parsePagos(filas, CONFIG[cuenta].pagos);
  if (res.error) return { ok: falla(cuenta, 'pagos', res.error), txt: 'ERROR' };
  let ok = true;
  const s = res.stats;
  const suma = res.filas.length + res.rechazadas.length + res.descartadas.length;
  if (s.filas_leidas !== suma) ok = falla(cuenta, 'pagos', `leidas ${s.filas_leidas} != cargadas+rechazadas+descartadas ${suma}`);
  if (s.filas_leidas + 1 !== fx.filas) ok = falla(cuenta, 'pagos', `leidas ${s.filas_leidas} + encabezado != ${fx.filas} filas del fixture`);
  const vistas = [...res.filas, ...res.rechazadas, ...res.descartadas].map((x) => x.fila_planilla);
  if (new Set(vistas).size !== vistas.length) ok = falla(cuenta, 'pagos', 'una fila quedo contada en dos destinos');
  for (const f of res.filas) {
    if (!fechaOk(f.fecha)) ok = falla(cuenta, 'pagos', `fila ${f.fila_planilla}: fecha ${f.fecha} fuera de rango`);
    for (const k of ['monto_usd', 'monto_origen']) if (!esNumero(f[k])) ok = falla(cuenta, 'pagos', `fila ${f.fila_planilla}: ${k} = ${f[k]}`);
    if (!f.alumno) ok = falla(cuenta, 'pagos', `fila ${f.fila_planilla}: cargada sin alumno`);
  }
  for (const x of res.rechazadas) {
    if (!x.motivo || !Number.isInteger(x.fila_planilla)) ok = falla(cuenta, 'pagos', `rechazada sin motivo o sin fila: ${JSON.stringify(x)}`);
    if (x.motivo === MOTIVO_TOPE && !('comprobante' in x && 'metodo_pago' in x && x.valor_crudo)) ok = falla(cuenta, 'pagos', `fila ${x.fila_planilla}: rechazo por tope sin comprobante/metodo/valor`);
  }
  const motivos = {};
  res.rechazadas.forEach((x) => { motivos[x.motivo] = (motivos[x.motivo] || 0) + 1; });
  const detalle = Object.entries(motivos).map(([m, n]) => `${n} ${m}`).join(', ');
  if (detalle) avisos.push(`[${cuenta}/pagos] rechazadas: ${detalle}`);
  return { ok, txt: `${s.filas_leidas}=${s.filas_cargadas}+${s.rechazadas}+${s.descartadas}` };
}

function probarCuotas(cuenta, fx, shapes) {
  const cfg = CONFIG[cuenta].cuotas;
  const res = parseCuotas(cargar(fx.archivo), cfg);
  if (res.error) return { ok: falla(cuenta, 'cuotas', res.error), txt: 'ERROR' };
  let ok = true;
  const s = res.stats;
  if (s.filas_leidas !== s.filas_cargadas + s.rechazadas + s.descartadas) ok = falla(cuenta, 'cuotas', `leidas ${s.filas_leidas} != ${s.filas_cargadas}+${s.rechazadas}+${s.descartadas}`);
  const esperado = [...CAMPOS_CUOTA].sort().join(',');
  for (const f of res.filas) {
    const shape = Object.keys(f).sort().join(',');
    shapes.add(shape);
    if (shape !== esperado) ok = falla(cuenta, 'cuotas', `fila ${f.fila_planilla}: shape distinto (${shape})`);
    if (!esNumero(f.monto)) ok = falla(cuenta, 'cuotas', `fila ${f.fila_planilla}: monto ${f.monto}`);
    if (f.fecha_pago !== null && !fechaOk(f.fecha_pago)) ok = falla(cuenta, 'cuotas', `fila ${f.fila_planilla}: fecha ${f.fecha_pago} fuera de rango`);
    if (!f.alumno) ok = falla(cuenta, 'cuotas', `fila ${f.fila_planilla}: sin alumno`);
  }
  res.rechazadas.forEach((x) => avisos.push(`[${cuenta}/cuotas] rechazada fila ${x.fila_planilla}: ${x.motivo}`));
  return { ok, txt: `${cfg.forma.replace('cuotas_', '')}: ${res.filas.length} cuotas de ${s.filas_cargadas} filas (${s.filas_leidas}=${s.filas_cargadas}+${s.rechazadas}+${s.descartadas})` };
}

const shapes = new Set();
for (const cuenta of ['liam', 'agus', 'teo', 'mauro', 'lucas']) {
  const fx = indice[cuenta];
  const o = probarOpps(cuenta, fx.opps);
  const p = probarPagos(cuenta, fx.pagos);
  const c = fx.cuotas ? probarCuotas(cuenta, fx.cuotas, shapes) : { ok: true, txt: '(no tiene)' };
  tabla.push({ cuenta, o, p, c, ok: o.ok && p.ok && c.ok });
}
if (shapes.size > 1) falla('todas', 'cuotas', `las formas devuelven shapes distintos: ${[...shapes].join(' | ')}`);

const pad = (s, n) => String(s).padEnd(n);
console.log('\nAVISOS (no hacen fallar la prueba)');
avisos.forEach((a) => console.log('  ' + a));
console.log('\n' + pad('cuenta', 7) + pad('opps', 44) + pad('pagos leidas=carg+rech+desc', 29) + pad('cuotas', 44) + 'resultado');
console.log('-'.repeat(133));
for (const t of tabla) {
  const marca = (x) => (x.ok ? '' : ' X');
  console.log(pad(t.cuenta, 7) + pad(t.o.txt + marca(t.o), 44) + pad(t.p.txt + marca(t.p), 29) + pad(t.c.txt + marca(t.c), 44) + (t.ok ? 'OK' : 'FALLA'));
}
if (fallas.length) {
  console.log(`\nFALLAS (${fallas.length})`);
  fallas.forEach((f) => console.log('  ' + f));
  console.log('\nRESULTADO: FALLA');
  process.exit(1);
}
console.log('\nRESULTADO: OK — los 3 parsers pasan contra las 5 cuentas');
