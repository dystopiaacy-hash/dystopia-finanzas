// parsers/pagos.js — hoja de PAGOS -> filas canonicas de fin_pagos.
//
// parsePagos(matriz, config) devuelve
//   { filas, rechazadas, descartadas, error, encabezado, stats }
// Invariante: stats.filas_leidas = cargadas + rechazadas + descartadas.
// Ninguna fila desaparece sin quedar en alguna de las tres listas.
//
// config = {
//   alias: [{ campo, alias, obligatorio }],   // fin_alias_columnas de la fuente
//   fila_encabezado: 1,                       // 1-based
//   tope_monto: 10000 | null,                 // null = sin control
//   fecha_min, fecha_max                      // opcional, default 2024..2027
// }
// Reglas: CONTRATO.md secciones 1 a 3.

import {
  FECHA_MIN, FECHA_MAX, esVacio, normalizar, texto, parseMonto, parseMontoInicial,
  parseFecha, fechaEnRango, celdasConDatos, filaCruda, monedaDeMetodo, redondear,
  esAmbiguo, MOTIVO_MONTO_AMBIGUO,
} from './comun.js';

export const MOTIVO_TOPE = 'monto fuera de rango, probable moneda local sin convertir';
export const MOTIVO_REFUND = 'refund sin monto numerico';
export const MOTIVO_FECHA_EN_MONTO = 'fecha en celda de monto';

// Primera columna del encabezado que coincide con algun alias del campo.
// Si el encabezado tiene una columna duplicada, gana la primera aparicion.
function mapearColumnas(encabezado, alias) {
  const norm = encabezado.map(normalizar);
  const col = {};
  const faltan = [];
  const campos = [...new Set(alias.map((a) => a.campo))];
  for (const campo of campos) {
    const del = alias.filter((a) => a.campo === campo);
    let idx = -1;
    for (const a of del) {
      const k = norm.indexOf(normalizar(a.alias));
      if (k > -1 && (idx === -1 || k < idx)) idx = k;
    }
    if (idx > -1) col[campo] = idx;
    else if (del.some((a) => a.obligatorio)) faltan.push(`${campo} (${del.map((a) => a.alias).join(' / ')})`);
  }
  return { col, faltan };
}

function esEncabezadoRepetido(fila, encabezado, col) {
  let iguales = 0;
  for (const k of Object.values(col)) {
    if (!esVacio(fila[k]) && normalizar(fila[k]) === normalizar(encabezado[k])) iguales++;
  }
  return iguales >= 2;
}

export function parsePagos(matriz, config = {}) {
  const res = {
    filas: [], rechazadas: [], descartadas: [], error: null, encabezado: [],
    stats: { filas_leidas: 0, filas_cargadas: 0, rechazadas: 0, descartadas: 0 },
  };
  const hdr = (config.fila_encabezado ?? 1) - 1;
  const tope = config.tope_monto ?? null;
  const fMin = config.fecha_min ?? FECHA_MIN;
  const fMax = config.fecha_max ?? FECHA_MAX;

  if (!Array.isArray(matriz) || !Array.isArray(matriz[hdr])) {
    res.error = `no hay fila de encabezado en la fila ${hdr + 1}`;
    return res;
  }
  const encabezado = matriz[hdr].map((v) => (esVacio(v) ? '' : String(v).trim()));
  res.encabezado = encabezado;
  const { col, faltan } = mapearColumnas(encabezado, config.alias || []);
  if (faltan.length) {
    res.error = `faltan columnas obligatorias: ${faltan.join(', ')}`;
    return res;
  }

  const celda = (fila, campo) => (col[campo] === undefined ? null : fila[col[campo]]);

  for (let i = hdr + 1; i < matriz.length; i++) {
    const fila = matriz[i] || [];
    const nro = i + 1;
    res.stats.filas_leidas++;
    const descartar = (motivo) => res.descartadas.push({ fila_planilla: nro, motivo });
    const rechazar = (motivo, valor) => res.rechazadas.push({
      fila_planilla: nro,
      motivo,
      valor_crudo: valor === null || valor === undefined ? null : String(valor),
      comprobante: texto(celda(fila, 'comprobante')),
      metodo_pago: texto(celda(fila, 'metodo_pago')),
      contenido_crudo: filaCruda(fila),
    });

    const conDatos = celdasConDatos(fila);
    if (conDatos.length === 0) { descartar('vacia'); continue; }
    if (esEncabezadoRepetido(fila, encabezado, col)) { descartar('encabezado_repetido'); continue; }

    const alumno = texto(celda(fila, 'alumno'));
    const montoCrudo = celda(fila, 'monto');
    const monto = parseMonto(montoCrudo);

    if (!alumno) {
      const unica = conDatos.length === 1 ? conDatos[0][1] : null;
      if (unica !== null && parseMonto(unica) === null && parseFecha(unica) === null) descartar('separador');
      else if (monto === null) descartar('sin_alumno_sin_monto');
      else rechazar('falta alumno', montoCrudo);
      continue;
    }
    if (esVacio(montoCrudo)) { rechazar('falta monto', null); continue; }
    if (monto === null) {
      const motivo = esAmbiguo(montoCrudo) ? MOTIVO_MONTO_AMBIGUO
        : /refund/i.test(String(montoCrudo)) ? MOTIVO_REFUND
        : parseFecha(montoCrudo) ? MOTIVO_FECHA_EN_MONTO : 'monto no numerico';
      rechazar(motivo, montoCrudo);
      continue;
    }

    const fechaCruda = celda(fila, 'fecha');
    if (esVacio(fechaCruda)) { rechazar('falta fecha', fechaCruda); continue; }
    const fecha = parseFecha(fechaCruda);
    if (!fecha) { rechazar('fecha no parsea', fechaCruda); continue; }
    if (!fechaEnRango(fecha, fMin, fMax)) { rechazar('fecha fuera de rango', fechaCruda); continue; }

    if (tope !== null && Math.abs(monto) > tope) { rechazar(MOTIVO_TOPE, montoCrudo); continue; }

    // Moneda: la planilla ya trae USD. Si ademas trae PESOS (mauro), el
    // monto en pesos es el de origen y el tipo de cambio sale de la fila.
    let monto_origen = monto;
    let moneda_origen = 'USD';
    let tc_usado = 1;
    const pesosCrudo = celda(fila, 'monto_pesos');
    const pesos = esVacio(pesosCrudo) ? null : parseMontoInicial(pesosCrudo);
    if (pesos !== null) {
      monto_origen = pesos;
      moneda_origen = /colombian/i.test(String(pesosCrudo)) ? 'COP' : 'ARS';
      tc_usado = monto !== 0 ? redondear(pesos / monto, 6) : null;
    }

    const metodo = texto(celda(fila, 'metodo_pago'));
    res.filas.push({
      fila_planilla: nro,
      fecha,
      programa: texto(celda(fila, 'programa')),
      alumno,
      telefono: texto(celda(fila, 'telefono')),
      concepto: texto(celda(fila, 'concepto')),
      monto_usd: monto,
      monto_origen,
      moneda_origen,
      tc_usado,
      tc_fuente: 'planilla',
      moneda_cobro: monedaDeMetodo(metodo),
      closer: texto(celda(fila, 'closer')),
      setter: texto(celda(fila, 'setter')),
      comprobante: texto(celda(fila, 'comprobante')),
      quien_recibe: texto(celda(fila, 'quien_recibe')),
      metodo_pago: metodo,
      monto_restante: parseMonto(celda(fila, 'monto_restante')),
      estado: texto(celda(fila, 'estado')),
    });
  }

  res.stats.filas_cargadas = res.filas.length;
  res.stats.rechazadas = res.rechazadas.length;
  res.stats.descartadas = res.descartadas.length;
  return res;
}
