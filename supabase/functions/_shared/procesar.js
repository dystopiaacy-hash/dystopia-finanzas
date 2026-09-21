// _shared/procesar.js — de la matriz de una hoja a lo que se escribe en la base.
// Puro (sin red ni base): lo usa la Edge Function y lo prueban los tests en Node.
//
// procesarFuente(fuente, matriz, previo, opciones) devuelve
//   { estado, mensaje, hash, stats, controles, datos }
//   estado: 'ok' | 'revisar' | 'parcial' | 'error'
//   datos:  null si estado = 'error' (NO se toca nada), si no
//           { pagos, pnl, saldos, reparto, cuotas, rechazadas }
// fuente = fila de fin_fuentes + alias: [{ campo, alias, obligatorio }]
// previo = { hash, filas_cargadas } de la ultima corrida no-error, o null.

import { parsePagos } from './parsers/pagos.js';
import { parseOpps } from './parsers/opps.js';
import { parseCuotas } from './parsers/cuotas.js';

// Red de seguridad independiente del formato: seriales de fecha 2023..2030.
// Un ingreso real puede caer aca (mauro junio: 46637), por eso solo avisa.
export const SERIAL_MIN = 45000;
export const SERIAL_MAX = 47500;
export const MOTIVO_SERIAL = 'posible serial de fecha en ingresos';
// Con mas de esta proporcion de filas rechazadas la corrida queda 'parcial':
// carga lo valido pero se ve tan urgente como un error.
export const UMBRAL_PARCIAL = 0.2;

async function sha256(texto) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// Hash de la estructura: encabezado del parser sin celdas vacias al final
// (FORMATTED_VALUE recorta las columnas vacias del final; asi no cambia el hash).
export async function hashEncabezado(tipo, encabezado) {
  const e = (encabezado || []).map((v) => String(v ?? '').trim());
  while (e.length && e[e.length - 1] === '') e.pop();
  return sha256(`${tipo}|${JSON.stringify(e)}`);
}

function parsear(fuente, matriz) {
  if (fuente.tipo === 'pagos') {
    return parsePagos(matriz, {
      alias: fuente.alias, fila_encabezado: fuente.fila_encabezado, tope_monto: fuente.tope_monto,
    });
  }
  if (fuente.tipo === 'opps') return parseOpps(matriz, { anio: fuente.anio });
  if (fuente.tipo === 'cuotas') {
    return parseCuotas(matriz, {
      forma: fuente.forma, fila_encabezado: fuente.fila_encabezado, tope_monto: fuente.tope_monto,
    });
  }
  return { error: `tipo '${fuente.tipo}' no se sincroniza todavia` };
}

// Controles extra sobre el P&L: montos de ingreso en el rango de seriales.
export function controlSeriales(filasPnl) {
  return filasPnl
    .filter((f) => f.categoria === 'revenue' && f.monto_usd >= SERIAL_MIN && f.monto_usd <= SERIAL_MAX)
    .map((f) => ({ mes: f.mes, motivo: MOTIVO_SERIAL, fila_planilla: f.fila_planilla, item: f.item, valor: f.monto_usd }));
}

function numeros(v) { return Number(v ?? 0) || 0; }

export async function procesarFuente(fuente, matriz, previo, { aceptarEncabezado = false } = {}) {
  const r = parsear(fuente, matriz);
  const base = { hash: null, stats: { leidas: null, cargadas: 0, rechazadas: 0, descartadas: null }, controles: [], datos: null };
  if (r.error) return { ...base, estado: 'error', mensaje: r.error };

  const hash = await hashEncabezado(fuente.tipo, r.encabezado);
  if (previo && previo.hash && previo.hash !== hash && !aceptarEncabezado) {
    return {
      ...base, hash, estado: 'error',
      mensaje: 'cambio el encabezado de la hoja respecto de la ultima corrida buena. No se toco ningun dato. '
        + 'Revisar la hoja y, si el cambio es correcto, sincronizar esta fuente con aceptar_encabezado.',
    };
  }

  const controles = [];
  const avisos = [...(r.avisos || [])];
  let estado = 'ok';
  let cargadas;
  let rechazadas = r.rechazadas || [];
  let leidas;
  let descartadas;
  const datos = { pagos: [], pnl: [], saldos: [], reparto: [], cuotas: [], rechazadas };

  if (fuente.tipo === 'opps') {
    datos.pnl = r.filas;
    datos.saldos = r.saldos.filter((s) => s.opening_balance !== null || s.closing_balance !== null || s.dividends_released !== null);
    datos.reparto = r.reparto;
    controles.push(...r.revisar, ...controlSeriales(r.filas));
    if (controles.length) estado = 'revisar';
    cargadas = r.filas.length;
    leidas = null;
    descartadas = null;
  } else {
    if (fuente.tipo === 'pagos') datos.pagos = r.filas;
    else datos.cuotas = r.filas;
    cargadas = r.stats.filas_cargadas ?? r.filas.length;
    leidas = r.stats.filas_leidas;
    descartadas = r.stats.descartadas;
    const fechasEnMonto = rechazadas.filter((x) => x.motivo === 'fecha en celda de monto');
    for (const x of fechasEnMonto) {
      controles.push({ motivo: 'fecha en celda de monto', fila_planilla: x.fila_planilla, valor: x.valor_crudo });
    }
    if (fechasEnMonto.length) estado = 'revisar';
  }

  // Hoja que viene sin ninguna fila valida cuando antes tenia datos: casi
  // seguro un cambio de formato (fechas, locale). No se borra lo anterior.
  if (cargadas === 0 && numeros(previo && previo.filas_cargadas) > 0) {
    return {
      ...base, hash, estado: 'error', controles,
      stats: { leidas, cargadas, rechazadas: rechazadas.length, descartadas },
      mensaje: `la hoja no dio ninguna fila valida y la corrida anterior habia cargado ${previo.filas_cargadas}. `
        + 'No se toco ningun dato.',
    };
  }

  const validasMasRechazadas = cargadas + rechazadas.length;
  const proporcion = validasMasRechazadas ? rechazadas.length / validasMasRechazadas : 0;
  if (fuente.tipo !== 'opps' && proporcion > UMBRAL_PARCIAL) {
    estado = 'parcial';
    avisos.push(`${rechazadas.length} de ${validasMasRechazadas} filas rechazadas (${Math.round(proporcion * 100)}%)`);
  }

  return {
    hash, estado, controles, datos,
    stats: { leidas, cargadas, rechazadas: rechazadas.length, descartadas },
    mensaje: avisos.length ? avisos.join(' · ') : null,
  };
}
