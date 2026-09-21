// pruebas/formato.mjs — gate de la lectura de Google Sheets (sin red).
//
// 1. Cada fixture se convierte en la respuesta de GRID que daria Sheets
//    (texto mostrado + valor real + tipo de formato por celda) y se pasa por
//    matrizDesdeGrid + procesarFuente: tiene que dar EXACTAMENTE lo mismo que
//    los parsers sobre el fixture crudo, en es_AR, es_ES y en_US.
// 2. Los 5 casos REALES que encontro el dry_run del 2026-09-21 con
//    FORMATTED_VALUE, en su fila y columna reales y con el texto exacto que
//    devolvio la API. Con grid tienen que dar lo mismo que el fixture. Si
//    alguien vuelve a leer solo el texto (FORMATTED_VALUE), fallan:
//      A  lucas opps  sep f27 AK  fecha 2026-05-26 mostrada "26.5"  (se cargaba 26,5 USD)
//      A  lucas pagos f154 monto  fecha 2026-08-31 mostrada "31.8"  (se cargaba 31,8 USD)
//      B  liam cuotas f3  CUOTA 1 fecha 2026-07-02 mostrada "02-07" (se perdia la fila y 532 USD pendientes)
//      B  liam cuotas f6  CUOTA 1 fecha 2026-06-14 mostrada "14/06"
//      C  liam opps  ago f46 AG  10,8 mostrado "11"                 (se cargaba 11)
// 2b. Celdas con formato de FECHA en columnas de monto (RANGO_FECHA_EN_MONTO de
//    grid.js): las 3 celdas reales (agus f5 = 1/7/1324 yyyy.mm, agus f37 y teo
//    f178 yyyy.m) y toda la tierra de nadie se rechazan con 'monto ambiguo con
//    formato de fecha' + comprobante; <= 3250 carga; 43831..47848 es fecha.
// 3. El codigo de la Edge Function lee por grid con `fields` y no usa
//    valueRenderOption. Si alguien lo cambia, falla aca.
// 4. Siguen las dos barreras de defensa en profundidad: 'fecha en celda de
//    monto' y la red 45000..47500 (mauro junio 46637: avisa, no rechaza).
// Uso: node pruebas/formato.mjs

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizarCelda, normalizarMatriz } from '../supabase/functions/_shared/formato.js';
import { matrizDesdeGrid, isoASerial, RANGO_FECHA_EN_MONTO } from '../supabase/functions/_shared/grid.js';
import { MOTIVO_MONTO_AMBIGUO } from '../supabase/functions/_shared/parsers/comun.js';
import { procesarFuente, MOTIVO_SERIAL } from '../supabase/functions/_shared/procesar.js';
import { CONFIG } from './config.mjs';

const RAIZ = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIR = join(RAIZ, 'pruebas', 'fixtures');
const indice = JSON.parse(readFileSync(join(DIR, 'index.json'), 'utf8'));
const fallas = [];
const falla = (m) => fallas.push(m);
const leer = (cuenta, tipo) => JSON.parse(readFileSync(join(DIR, indice[cuenta][tipo].archivo), 'utf8')).filas;

const LOCALES = {
  es_AR: { num: new Intl.NumberFormat('es-AR', { maximumFractionDigits: 10 }), fecha: (a, m, d) => `${d}/${m}/${a}` },
  es_ES: { num: new Intl.NumberFormat('es-ES', { maximumFractionDigits: 10 }), fecha: (a, m, d) => `${d}/${m}/${a}` },
  en_US: { num: new Intl.NumberFormat('en-US', { maximumFractionDigits: 10 }), fecha: (a, m, d) => `${m}/${d}/${a}` },
};
const ISO = /^(\d{4})-(\d{2})-(\d{2})(?:T00:00:00)?$/;

// Celda cruda del fixture -> celda de grid como la devolveria Sheets.
function celdaGrid(v, loc) {
  if (v === null || v === undefined || v === '') return {};
  if (typeof v === 'number') {
    return { formattedValue: loc.num.format(v), effectiveValue: { numberValue: v }, effectiveFormat: { numberFormat: { type: 'NUMBER' } } };
  }
  const m = String(v).match(ISO);
  if (m) {
    return { formattedValue: loc.fecha(+m[1], +m[2], +m[3]), effectiveValue: { numberValue: isoASerial(`${m[1]}-${m[2]}-${m[3]}`) }, effectiveFormat: { numberFormat: { type: 'DATE' } } };
  }
  return { formattedValue: String(v), effectiveValue: { stringValue: String(v) } };
}
const aGrid = (crudo, loc) => ({ rowData: crudo.map((f) => ({ values: (f || []).map((v) => celdaGrid(v, loc)) })) });
// Lo que devolveria values.get con FORMATTED_VALUE: solo el texto.
const soloTexto = (grid) => grid.rowData.map((f) => f.values.map((c) => c.formattedValue ?? ''));

function fuenteDe(cuenta, tipo) {
  const c = CONFIG[cuenta][tipo];
  return { tipo, anio: c.anio, forma: c.forma, fila_encabezado: c.fila_encabezado ?? 4, tope_monto: c.tope_monto ?? null, alias: c.alias };
}

const suma = (arr, k) => Math.round(arr.reduce((s, x) => s + (Number(x[k]) || 0), 0) * 1e6) / 1e6;
function firma(res) {
  if (!res.datos) return `error:${res.mensaje}`;
  const d = res.datos;
  return JSON.stringify({
    estado: res.estado,
    pagos: [d.pagos.length, suma(d.pagos, 'monto_usd'), d.pagos.map((p) => `${p.fila_planilla}:${p.fecha}:${p.monto_usd}`).join()],
    pnl: [d.pnl.length, d.pnl.map((p) => `${p.mes}:${p.fila_planilla}:${p.monto_usd}`).join()],
    reparto: [d.reparto.length, suma(d.reparto, 'monto')],
    cuotas: [d.cuotas.length, d.cuotas.map((c) => `${c.fila_planilla}:${c.monto}:${c.fecha_pago}`).join()],
    rech: d.rechazadas.map((r) => `${r.fila_planilla}:${r.motivo}`).sort().join('|'),
  });
}

// ---------------------------------------------------------------------------
// 1. Grid == crudo, en tres locales.
// ---------------------------------------------------------------------------
const base = {};
for (const [cuenta, hojas] of Object.entries(indice)) {
  for (const tipo of Object.keys(hojas)) {
    if (!CONFIG[cuenta][tipo]) continue;
    const crudo = leer(cuenta, tipo);
    const fuente = fuenteDe(cuenta, tipo);
    const b = await procesarFuente(fuente, crudo, null);
    base[`${cuenta}/${tipo}`] = b;
    for (const [nombre, loc] of Object.entries(LOCALES)) {
      const res = await procesarFuente(fuente, matrizDesdeGrid(aGrid(crudo, loc), nombre), null);
      if (firma(res) !== firma(b)) falla(`[${cuenta}/${tipo}/${nombre}] el grid da distinto que el crudo\n  crudo: ${firma(b).slice(0, 300)}\n  grid:  ${firma(res).slice(0, 300)}`);
      if (res.hash !== b.hash) falla(`[${cuenta}/${tipo}/${nombre}] el hash de encabezado depende del locale`);
    }
    const s = b.datos ? `${b.stats.cargadas} cargadas / ${b.stats.rechazadas} rechazadas` : b.mensaje;
    console.log(`${cuenta.padEnd(6)} ${tipo.padEnd(7)} ${b.estado.padEnd(8)} ${s}`);
  }
}

// ---------------------------------------------------------------------------
// 2. Los 5 casos reales.
// ---------------------------------------------------------------------------
const CASOS = [
  { id: 'A 26.5', cuenta: 'lucas', tipo: 'opps', locale: 'es_ES', fila: 27, col: 37, texto: '26.5',
    malo: (r) => r.datos && r.datos.pnl.some((x) => x.fila_planilla === 27 && x.monto_usd === 26.5) },
  { id: 'A 31.8', cuenta: 'lucas', tipo: 'pagos', locale: 'es_ES', fila: 154, col: 6, texto: '31.8',
    malo: (r) => r.datos && r.datos.pagos.some((x) => x.fila_planilla === 154 && x.monto_usd === 31.8) },
  { id: 'B 02-07', cuenta: 'liam', tipo: 'cuotas', locale: 'es_AR', fila: 3, col: 4, texto: '02-07',
    malo: (r) => r.datos && !r.datos.cuotas.some((x) => x.fila_planilla === 3) },
  { id: 'B 14/06', cuenta: 'liam', tipo: 'cuotas', locale: 'es_AR', fila: 6, col: 4, texto: '14/06',
    malo: (r) => r.datos && !r.datos.cuotas.some((x) => x.fila_planilla === 6) },
  { id: 'C 11 vs 10.8', cuenta: 'liam', tipo: 'opps', locale: 'es_AR', fila: 46, col: 33, texto: '11',
    malo: (r) => r.datos && r.datos.pnl.some((x) => x.fila_planilla === 46 && x.columna_planilla === 33 && x.monto_usd === 11) },
];
console.log('\nCasos reales (texto que devolvio la API con FORMATTED_VALUE):');
for (const c of CASOS) {
  const crudo = leer(c.cuenta, c.tipo);
  const fuente = fuenteDe(c.cuenta, c.tipo);
  const grid = aGrid(crudo, LOCALES[c.locale]);
  const celda = grid.rowData[c.fila - 1].values[c.col - 1];
  if (!celda || celda.effectiveValue === undefined) { falla(`[caso ${c.id}] la celda f${c.fila} c${c.col} esta vacia en el fixture`); continue; }
  celda.formattedValue = c.texto;   // el formato de visualizacion real de la planilla
  const conGrid = await procesarFuente(fuente, matrizDesdeGrid(grid, c.locale), null);
  const conTexto = await procesarFuente(fuente, normalizarMatriz(soloTexto(grid), c.locale), null);
  const ok = firma(conGrid) === firma(base[`${c.cuenta}/${c.tipo}`]) && !c.malo(conGrid);
  if (!ok) falla(`[caso ${c.id}] con grid NO da lo mismo que el fixture (${c.cuenta}/${c.tipo} f${c.fila})`);
  if (!c.malo(conTexto)) falla(`[caso ${c.id}] la simulacion de FORMATTED_VALUE ya no reproduce el bug: revisar el test`);
  console.log(`  ${c.id.padEnd(13)} ${c.cuenta}/${c.tipo} f${c.fila}: grid ${ok ? 'OK' : 'MAL'} · solo texto ${c.malo(conTexto) ? 'reproduce el bug (esperado)' : '??'}`);
}

// ---------------------------------------------------------------------------
// 2b. Celdas con formato de FECHA en columnas de monto (RANGO_FECHA_EN_MONTO).
//     Las 3 reales (confirmadas en la PLANILLA, 2026-09-21): alguien tipeo el
//     monto en una celda con formato de fecha y Sheets lo guardo como una
//     FECHA del anio 1324/1328/1254 (agus F5 = 1/7/1324, se ve "1324.07" con
//     yyyy.mm). En el .xlsx aparecen como texto porque Excel no guarda fechas
//     anteriores a 1900: el export mentia, la fuente de verdad es la planilla.
//     El monto NO se puede recuperar de la celda: 1328.4 y 1328.04 dan la
//     misma fecha, y el comprobante de agus f37 dice 1.421,9 (93,50 USD mas
//     que lo que se ve). Tienen que RECHAZARSE como 'monto ambiguo con formato
//     de fecha', con el mes en revisar y el COMPROBANTE en el control, para
//     que una persona las corrija mirando el comprobante.
// ---------------------------------------------------------------------------
const celdaFecha = (valor, patron, texto) => ({
  formattedValue: texto, effectiveValue: { numberValue: valor },
  effectiveFormat: { numberFormat: { type: 'DATE', pattern: patron } },
});
console.log('\nCeldas con formato de fecha en columnas de monto:');
const REALES_FORMATO_FECHA = [
  { id: 'agus f5', cuenta: 'agus', col: 6, fila: 5, fecha: '1324-07-01', patron: 'yyyy.mm', texto: '1324.07' },
  { id: 'agus f37', cuenta: 'agus', col: 6, fila: 37, fecha: '1328-04-01', patron: 'yyyy.m', texto: '1328.4' },
  { id: 'teo f178', cuenta: 'teo', col: 5, fila: 178, fecha: '1254-11-01', patron: 'yyyy.m', texto: '1254.11' },
];
for (const c of REALES_FORMATO_FECHA) {
  const crudo = leer(c.cuenta, 'pagos');
  const grid = aGrid(crudo, LOCALES.es_AR);
  grid.rowData[c.fila - 1].values[c.col - 1] = celdaFecha(isoASerial(c.fecha), c.patron, c.texto);
  const res = await procesarFuente(fuenteDe(c.cuenta, 'pagos'), matrizDesdeGrid(grid, 'es_AR'), null);
  const b = base[`${c.cuenta}/pagos`];
  const rech = res.datos && res.datos.rechazadas.find((r) => r.fila_planilla === c.fila);
  const ctl = res.controles.find((x) => x.fila_planilla === c.fila);
  // El comprobante del control tiene que ser el de la fila (texto o link de Drive).
  const colComp = crudo[0].findIndex((h) => String(h ?? '').trim().toUpperCase() === 'COMPROBANTE');
  const compFixture = crudo[c.fila - 1][colComp];
  const compEsperado = compFixture === null || compFixture === undefined ? null : String(compFixture).trim();
  const resto = (d) => d.pagos.filter((p) => p.fila_planilla !== c.fila).map((p) => `${p.fila_planilla}:${p.fecha}:${p.monto_usd}`).join();
  const checks = {
    'no carga': res.datos && !res.datos.pagos.some((p) => p.fila_planilla === c.fila),
    'motivo ambiguo': rech && rech.motivo === MOTIVO_MONTO_AMBIGUO,
    'mes en revisar': res.estado === 'revisar',
    'comprobante en el control': ctl && ctl.motivo === MOTIVO_MONTO_AMBIGUO && ctl.comprobante === compEsperado,
    'marca con lo que se ve y la fecha': rech && rech.valor_crudo.includes(c.texto) && rech.valor_crudo.includes(c.fecha),
    'el resto igual': res.datos && resto(res.datos) === resto(b.datos) && res.datos.pagos.length === b.datos.pagos.length - 1,
  };
  const mal = Object.entries(checks).filter(([, v]) => !v).map(([k]) => k);
  if (mal.length) falla(`[formato fecha ${c.id}] ${c.fecha} ('${c.texto}', ${c.patron}): falla ${mal.join(', ')}`);
  console.log(`  ${c.id.padEnd(9)} ${c.fecha} se ve ${c.texto.padEnd(8)} ${mal.length ? 'MAL' : 'rechazada, revisar, con comprobante'}`);
}

// Tierra de nadie: ni monto real (<= montoMaximoReal) ni fecha plausible
// (serialMin..serialMax). No se carga NUNCA: rechazada + mes en revisar.
const { montoMaximoReal, serialMin, serialMax } = RANGO_FECHA_EN_MONTO;
async function pagoConMonto(celda) {
  const crudo = leer('liam', 'pagos');
  const grid = aGrid(crudo, LOCALES.es_AR);
  const L = LOCALES.es_AR;
  grid.rowData.push({ values: [celdaGrid('2026-02-10T00:00:00', L), celdaGrid('X', L), celdaGrid('Alumno prueba', L), {}, celdaGrid('FEE', L), celda] });
  const res = await procesarFuente(fuenteDe('liam', 'pagos'), matrizDesdeGrid(grid, 'es_AR'), null);
  return { res, fila: grid.rowData.length };
}
const ESPERADOS = [
  // [valor, que tiene que pasar]
  [12000, 'ambiguo'], [montoMaximoReal + 0.01, 'ambiguo'], [serialMin - 1, 'ambiguo'], [serialMax + 1, 'ambiguo'], [60000, 'ambiguo'],
  [montoMaximoReal, 'carga'], [900, 'carga'],
  [serialMin, 'fecha'], [isoASerial('2026-06-12'), 'fecha'], [serialMax, 'fecha'],
];
for (const [valor, esperado] of ESPERADOS) {
  const { res, fila } = await pagoConMonto(celdaFecha(valor, 'dd/mm/yyyy', String(valor)));
  const rech = res.datos && res.datos.rechazadas.find((r) => r.fila_planilla === fila);
  const cargo = res.datos && res.datos.pagos.some((p) => p.fila_planilla === fila && p.monto_usd === valor);
  const obtenido = cargo ? 'carga'
    : rech && rech.motivo === MOTIVO_MONTO_AMBIGUO && res.estado === 'revisar' ? 'ambiguo'
    : rech && rech.motivo === 'fecha en celda de monto' && res.estado === 'revisar' ? 'fecha' : `otro (${rech ? rech.motivo : 'sin rechazo'}, ${res.estado})`;
  if (obtenido !== esperado) falla(`[tierra de nadie] celda DATE con valor ${valor} en monto: se esperaba '${esperado}' y dio '${obtenido}'`);
}
console.log(`  pagos: tierra de nadie (${montoMaximoReal}..${serialMin} y > ${serialMax}) rechaza, <= ${montoMaximoReal} carga, ${serialMin}..${serialMax} es fecha`);

// Tierra de nadie tambien en cuotas y en Opps.
{
  const crudo = leer('liam', 'cuotas');
  const grid = aGrid(crudo, LOCALES.es_AR);
  grid.rowData[2].values[2] = celdaFecha(12000, 'yyyy.m', '1932.11');   // CUOTA 1 monto de la fila 3
  const res = await procesarFuente(fuenteDe('liam', 'cuotas'), matrizDesdeGrid(grid, 'es_AR'), null);
  const r = res.datos && res.datos.rechazadas.find((x) => x.fila_planilla === 3);
  if (!r || !r.motivo.startsWith(MOTIVO_MONTO_AMBIGUO) || res.estado === 'ok' || res.datos.cuotas.some((q) => q.fila_planilla === 3)) {
    falla(`[tierra de nadie] cuotas: no se rechazo como ambiguo (${r ? r.motivo : 'sin rechazo'}, ${res.estado})`);
  } else console.log(`  cuotas: '${r.motivo}' -> ${res.estado}`);
}
{
  const crudo = leer('liam', 'opps');
  const grid = aGrid(crudo, LOCALES.es_AR);
  const item = base['liam/opps'].datos.pnl.find((x) => x.categoria === 'revenue');
  grid.rowData[item.fila_planilla - 1].values[item.columna_planilla - 1] = celdaFecha(12000, 'yyyy.m', '1932.11');
  const res = await procesarFuente(fuenteDe('liam', 'opps'), matrizDesdeGrid(grid, 'es_AR'), null);
  const cargo = res.datos.pnl.some((x) => x.fila_planilla === item.fila_planilla && x.mes === item.mes);
  const marcado = res.controles.some((x) => x.mes === item.mes && x.motivo === MOTIVO_MONTO_AMBIGUO);
  if (cargo || !marcado || res.estado !== 'revisar') falla('[tierra de nadie] opps: un ingreso ambiguo se cargo o no dejo el mes en revisar');
  else console.log(`  opps: ingreso ambiguo en ${item.mes}/f${item.fila_planilla} rechazado, mes en revisar`);
}
// En una columna de FECHA la celda DATE es fecha aunque caiga en la tierra de
// nadie (liam pagos f183..188 tienen 2001-12-09): 'fecha fuera de rango', como siempre.
{
  const r = base['liam/pagos'].datos.rechazadas.filter((x) => x.fila_planilla >= 183 && x.fila_planilla <= 188);
  const crudo = leer('liam', 'pagos');
  const res = await procesarFuente(fuenteDe('liam', 'pagos'), matrizDesdeGrid(aGrid(crudo, LOCALES.es_AR), 'es_AR'), null);
  const g = res.datos.rechazadas.filter((x) => x.fila_planilla >= 183 && x.fila_planilla <= 188);
  if (!g.length || g.some((x, i) => x.motivo !== r[i].motivo || x.motivo !== 'fecha fuera de rango')) falla('[fecha] una celda DATE de 2001 en la columna de fecha no dio fecha fuera de rango');
}

// ---------------------------------------------------------------------------
// 3. El codigo lee por grid, con fields, y no por values.get.
// ---------------------------------------------------------------------------
const google = readFileSync(join(RAIZ, 'supabase/functions/sincronizar/google.ts'), 'utf8');
// index.ts (HTTP) + nucleo.ts (el trabajo): se revisan juntos.
const index = ['index.ts', 'nucleo.ts'].map((n) => readFileSync(join(RAIZ, 'supabase/functions/sincronizar', n), 'utf8')).join('\n');
if (/valueRenderOption|values:batchGet|\/values\//.test(google)) falla('[codigo] google.ts vuelve a leer con values.get / valueRenderOption: NO (ver CONTRATO.md seccion 0)');
if (!/includeGridData/.test(google)) falla('[codigo] google.ts no pide includeGridData');
for (const campo of ['formattedValue', 'effectiveValue', 'effectiveFormat/numberFormat/type']) {
  if (!google.includes(campo)) falla(`[codigo] CAMPOS_GRID no pide ${campo}`);
}
if (!/fields:\s*CAMPOS_GRID/.test(google)) falla('[codigo] leerGrid no filtra con fields: el payload vuelve a ser enorme');
if (!/matrizDesdeGrid\(/.test(index) || /normalizarMatriz\(/.test(index)) falla('[codigo] index.ts no arma la matriz con matrizDesdeGrid');
if (/detalle/.test(index.replace(/^\s*\/\/.*$/gm, ''))) falla('[codigo] index.ts vuelve a tener un modo detalle: la respuesta no puede traer contenido de filas');
// El rango se define UNA vez (grid.js, RANGO_FECHA_EN_MONTO). Ningun otro archivo repite los numeros.
{
  const { readdirSync, statSync } = await import('node:fs');
  const archivos = [];
  const recorrer = (d) => { for (const n of readdirSync(d)) { const p = join(d, n); if (statSync(p).isDirectory()) recorrer(p); else if (/\.(js|ts|mjs|sql)$/.test(n)) archivos.push(p); } };
  for (const d of ['supabase/functions', 'js', 'migraciones']) recorrer(join(RAIZ, d));
  for (const p of archivos) {
    if (p.endsWith(join('_shared', 'grid.js'))) continue;
    const s = readFileSync(p, 'utf8');
    for (const n of ['3250', '43831', '47848']) if (new RegExp(`\\b${n}\\b`).test(s)) falla(`[codigo] ${p.slice(RAIZ.length + 1)} repite ${n}: el rango vive solo en RANGO_FECHA_EN_MONTO (grid.js)`);
  }
}

// ---------------------------------------------------------------------------
// 4. Defensa en profundidad: las dos barreras siguen.
// ---------------------------------------------------------------------------
{
  const m = base['mauro/opps'];
  if (!m.controles.some((c) => c.motivo === MOTIVO_SERIAL && c.mes === 6 && c.valor === 46637)) falla('[red] 45000..47500 no marco mauro junio 46637');
  if (!m.datos.pnl.some((f) => f.mes === 6 && f.monto_usd === 46637)) falla('[red] el 46637 de mauro junio se rechazo: solo tiene que avisar');
  // Un 46185 tipeado como NUMERO en un ingreso: el grid lo deja como numero y la red avisa.
  const crudo = leer('mauro', 'opps');
  const grid = aGrid(crudo, LOCALES.es_AR);
  const res = await procesarFuente(fuenteDe('mauro', 'opps'), matrizDesdeGrid(grid, 'es_AR'), null);
  if (res.estado !== 'revisar') falla('[red] con un posible serial el estado tiene que ser revisar');
}
{
  // Fecha en celda de monto, llegue como fecha del grid o como texto: rechazada + revisar.
  const crudo = leer('liam', 'pagos');
  const fuente = fuenteDe('liam', 'pagos');
  for (const [etq, monto] of [['celda DATE', { formattedValue: '12/06/2026', effectiveValue: { numberValue: isoASerial('2026-06-12') }, effectiveFormat: { numberFormat: { type: 'DATE' } } }],
    ['texto', { formattedValue: '12/06/2026', effectiveValue: { stringValue: '12/06/2026' } }]]) {
    const grid = aGrid(crudo, LOCALES.es_AR);
    const fila = [celdaGrid('2026-02-10T00:00:00', LOCALES.es_AR), celdaGrid('X', LOCALES.es_AR), celdaGrid('Alumno prueba', LOCALES.es_AR), {}, celdaGrid('FEE', LOCALES.es_AR), monto];
    grid.rowData.push({ values: fila });
    const res = await procesarFuente(fuente, matrizDesdeGrid(grid, 'es_AR'), null);
    const n = grid.rowData.length;
    if (!res.datos || !res.datos.rechazadas.some((r) => r.fila_planilla === n && r.motivo === 'fecha en celda de monto') || res.estado !== 'revisar') {
      falla(`[barrera] fecha en celda de monto (${etq}) no se rechazo`);
    }
  }
}

// Guardas de procesar.js.
for (const [clave, b] of Object.entries(base)) {
  const [cuenta, tipo] = clave.split('/');
  const crudo = leer(cuenta, tipo);
  const cambio = await procesarFuente(fuenteDe(cuenta, tipo), crudo, { hash: 'otro', filas_cargadas: 1 });
  if (cambio.estado !== 'error' || cambio.datos !== null) falla(`[${clave}] cambio de encabezado no dio error sin datos`);
  const aceptado = await procesarFuente(fuenteDe(cuenta, tipo), crudo, { hash: 'otro', filas_cargadas: 0 }, { aceptarEncabezado: true });
  if (!aceptado.datos) falla(`[${clave}] aceptar_encabezado no cargo`);
}
{
  const crudo = leer('liam', 'pagos');
  const vacia = await procesarFuente(fuenteDe('liam', 'pagos'), [crudo[0]], { hash: base['liam/pagos'].hash, filas_cargadas: 180 });
  if (vacia.estado !== 'error' || vacia.datos !== null) falla('[liam/pagos] hoja vacia despues de datos no dio error');
}

// Normalizador de texto (celdas con formato texto).
const casos = [
  ['1.321', 'es_AR', '1321'], ['1.321,9', 'es_AR', '1321.9'], ['1,321.9', 'en_US', '1321.9'],
  ['$ 900,00', 'es_AR', '900.00'], ['(1.200)', 'es_AR', '-1200'], ['46.637', 'es_AR', '46637'],
  ['12/06/2026', 'es_AR', '2026-06-12'], ['6/12/2026', 'en_US', '2026-06-12'], ['31/02/2026', 'es_AR', '31/02/2026'],
  ['REFUND', 'es_AR', 'REFUND'], ['15%', 'es_AR', '15%'], ['11 2345-6789', 'es_AR', '11 2345-6789'],
];
for (const [v, loc, esperado] of casos) {
  const r = normalizarCelda(v, { mesPrimero: loc === 'en_US', decimal: loc === 'en_US' ? '.' : ',' });
  if (r !== esperado) falla(`normalizarCelda(${JSON.stringify(v)}, ${loc}) = ${JSON.stringify(r)}, esperado ${JSON.stringify(esperado)}`);
}

if (fallas.length) {
  console.log(`\nFALLAS (${fallas.length}):\n- ${fallas.join('\n- ')}`);
  process.exit(1);
}
console.log('\nRESULTADO: OK — lectura por grid == fixtures en 3 locales; los 5 casos reales OK; barreras y guardas OK');
