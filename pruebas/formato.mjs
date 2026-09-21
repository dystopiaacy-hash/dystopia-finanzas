// pruebas/formato.mjs — gate de la fase 4 (sin red).
// Simula lo que devuelve Google Sheets con FORMATTED_VALUE: cada fixture se
// reescribe como texto con el formato de un locale (numeros "1.321,9" o
// "1,321.9", fechas "10/2/2026" o "2/10/2026") y se pasa por
// normalizarMatriz + procesarFuente. Tiene que dar EXACTAMENTE lo mismo que
// los parsers sobre el fixture crudo. Ademas:
//  - la red de seguridad 45000..47500 marca 'revisar' sin rechazar (mauro junio 46637)
//  - una fecha colada en monto llega como texto y va a rechazadas
//  - un cambio de encabezado da 'error' y datos = null
//  - una hoja sin filas validas despues de una corrida con datos da 'error'
// Uso: node pruebas/formato.mjs

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizarMatriz, normalizarCelda } from '../supabase/functions/_shared/formato.js';
import { procesarFuente, MOTIVO_SERIAL } from '../supabase/functions/_shared/procesar.js';
import { CONFIG } from './config.mjs';

const DIR = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const indice = JSON.parse(readFileSync(join(DIR, 'index.json'), 'utf8'));
const fallas = [];
const falla = (m) => fallas.push(m);

const LOCALES = {
  es_AR: { num: new Intl.NumberFormat('es-AR', { maximumFractionDigits: 10 }), fecha: (a, m, d) => `${d}/${m}/${a}` },
  en_US: { num: new Intl.NumberFormat('en-US', { maximumFractionDigits: 10 }), fecha: (a, m, d) => `${m}/${d}/${a}` },
};

// Celda cruda del fixture -> como la mostraria Sheets en ese locale.
function formatear(v, loc) {
  if (typeof v === 'number') return loc.num.format(v);
  if (v === null || v === undefined) return '';
  const m = String(v).match(/^(\d{4})-(\d{2})-(\d{2})T00:00:00$/);
  if (m) return loc.fecha(+m[1], +m[2], +m[3]);
  return String(v);
}

function fuenteDe(cuenta, tipo) {
  const c = CONFIG[cuenta][tipo];
  return { tipo, anio: c.anio, forma: c.forma, fila_encabezado: c.fila_encabezado ?? 4, tope_monto: c.tope_monto ?? null, alias: c.alias };
}

const suma = (arr, k) => Math.round(arr.reduce((s, x) => s + (Number(x[k]) || 0), 0) * 100) / 100;
function firma(res) {
  if (!res.datos) return `error:${res.mensaje}`;
  const d = res.datos;
  return JSON.stringify({
    estado: res.estado,
    pagos: [d.pagos.length, suma(d.pagos, 'monto_usd'), d.pagos.map((p) => p.fecha).sort().join()],
    pnl: [d.pnl.length, suma(d.pnl, 'monto_usd')],
    reparto: [d.reparto.length, suma(d.reparto, 'monto')],
    cuotas: [d.cuotas.length, suma(d.cuotas, 'monto'), d.cuotas.map((c) => c.fecha_pago).join()],
    rech: d.rechazadas.map((r) => `${r.fila_planilla}:${r.motivo}`).sort().join('|'),
  });
}

for (const [cuenta, hojas] of Object.entries(indice)) {
  for (const [tipo, meta] of Object.entries(hojas)) {
    if (!CONFIG[cuenta][tipo]) continue;
    const crudo = JSON.parse(readFileSync(join(DIR, meta.archivo), 'utf8')).filas;
    const fuente = fuenteDe(cuenta, tipo);
    const base = await procesarFuente(fuente, crudo, null);
    for (const [nombre, loc] of Object.entries(LOCALES)) {
      const formateado = crudo.map((f) => (f || []).map((v) => formatear(v, loc)));
      const res = await procesarFuente(fuente, normalizarMatriz(formateado, nombre), null);
      if (firma(res) !== firma(base)) falla(`[${cuenta}/${tipo}/${nombre}] FORMATTED_VALUE da distinto que el crudo\n  crudo: ${firma(base)}\n  fmt:   ${firma(res)}`);
      if (res.hash !== base.hash) falla(`[${cuenta}/${tipo}/${nombre}] el hash de encabezado depende del locale`);
    }
    console.log(`${cuenta.padEnd(6)} ${tipo.padEnd(7)} ${base.estado.padEnd(8)} ${base.datos ? '' : base.mensaje}`);

    if (tipo === 'opps') {
      const seriales = base.controles.filter((c) => c.motivo === MOTIVO_SERIAL);
      if (cuenta === 'mauro') {
        const junio = seriales.find((c) => c.mes === 6 && c.valor === 46637);
        if (!junio) falla('[mauro/opps] la red 45000..47500 no marco el ingreso de junio (46637)');
        if (!base.datos.pnl.some((f) => f.mes === 6 && f.monto_usd === 46637)) falla('[mauro/opps] el 46637 de junio se rechazo: solo tiene que avisar');
        if (base.estado !== 'revisar') falla('[mauro/opps] con un posible serial el estado tiene que ser revisar');
      }
    }

    // Cambio de encabezado: error y sin datos. Con aceptarEncabezado, carga.
    const cambio = await procesarFuente(fuente, crudo, { hash: 'otro', filas_cargadas: 1 });
    if (cambio.estado !== 'error' || cambio.datos !== null) falla(`[${cuenta}/${tipo}] cambio de encabezado no dio error sin datos`);
    const aceptado = await procesarFuente(fuente, crudo, { hash: 'otro', filas_cargadas: 0 }, { aceptarEncabezado: true });
    if (!aceptado.datos) falla(`[${cuenta}/${tipo}] aceptar_encabezado no cargo`);
  }
}

// Hoja vaciada (solo encabezado) despues de una corrida con datos: error.
{
  const crudo = JSON.parse(readFileSync(join(DIR, indice.liam.pagos.archivo), 'utf8')).filas;
  const fuente = fuenteDe('liam', 'pagos');
  const base = await procesarFuente(fuente, crudo, null);
  const vacia = await procesarFuente(fuente, [crudo[0]], { hash: base.hash, filas_cargadas: 180 });
  if (vacia.estado !== 'error' || vacia.datos !== null) falla('[liam/pagos] hoja vacia despues de datos no dio error');
}

// Fecha colada en celda de monto: con FORMATTED_VALUE llega como texto -> rechazada + revisar.
{
  const fuente = fuenteDe('liam', 'pagos');
  const crudo = JSON.parse(readFileSync(join(DIR, indice.liam.pagos.archivo), 'utf8')).filas;
  const m = [...crudo.map((f) => (f || []).map((v) => formatear(v, LOCALES.es_AR))), ['10/2/2026', 'X', 'Alumno prueba', '', 'FEE', '12/06/2026', 'C', 'S']];
  const res = await procesarFuente(fuente, normalizarMatriz(m, 'es_AR'), null);
  if (!res.datos || !res.datos.rechazadas.some((r) => r.fila_planilla === m.length && r.motivo === 'fecha en celda de monto') || res.estado !== 'revisar') {
    falla(`[sintetico] fecha en monto no se rechazo: ${firma(res)}`);
  }
}

// Casos puntuales del normalizador.
const casos = [
  ['1.321', 'es_AR', '1321'], ['1.321,9', 'es_AR', '1321.9'], ['1,321.9', 'en_US', '1321.9'],
  ['$ 900,00', 'es_AR', '900.00'], ['(1.200)', 'es_AR', '-1200'], ['46.637', 'es_AR', '46637'],
  ['12/06/2026', 'es_AR', '2026-06-12'], ['6/12/2026', 'en_US', '2026-06-12'], ['31/02/2026', 'es_AR', '31/02/2026'],
  ['REFUND', 'es_AR', 'REFUND'], ['15%', 'es_AR', '15%'], ['11 2345-6789', 'es_AR', '11 2345-6789'],
];
for (const [v, loc, esperado] of casos) {
  const opciones = { mesPrimero: loc === 'en_US', decimal: loc === 'en_US' ? '.' : ',' };
  const r = normalizarCelda(v, opciones);
  if (r !== esperado) falla(`normalizarCelda(${JSON.stringify(v)}, ${loc}) = ${JSON.stringify(r)}, esperado ${JSON.stringify(esperado)}`);
}

if (fallas.length) {
  console.log(`\nFALLAS (${fallas.length}):\n- ${fallas.join('\n- ')}`);
  process.exit(1);
}
console.log('\nRESULTADO: OK — FORMATTED_VALUE (es_AR y en_US) da lo mismo que el crudo; red de seguridad y guardas OK');
