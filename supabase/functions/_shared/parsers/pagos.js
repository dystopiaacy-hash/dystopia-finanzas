// parsers/pagos.js — hoja de PAGOS -> filas canonicas de fin_pagos.
//
// parsePagos(matriz, config) devuelve
//   { filas, rechazadas, descartadas, error, encabezado, stats }
// Invariante: stats.filas_leidas = cargadas + rechazadas + descartadas.
// Ninguna fila desaparece sin quedar en alguna de las tres listas. Un
// comprobante extra queda en descartadas (motivo 'comprobante_extra', con
// adjunto_a = fila del pago); revisar lista los que no encontraron pago.
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
export const MOTIVO_COMP_EXTRA = 'comprobante_extra';
export const MOTIVO_COMP_EXTRA_SIN_LINK = 'comprobante_extra_sin_link';
export const MOTIVO_COMP_EXTRA_SIN_PAGO = 'comprobante extra sin pago';

// --- Comprobantes extra ---------------------------------------------------
// Una fila SIN monto con texto tipo "<alumno> segundo comprobante", "x2",
// "Tercer comprobante" (tolera tipeos: "comporbnate", "segundo c") o con solo
// un link de comprobante no es un pago: es otro comprobante del pago anterior.
// No se rechaza ni crea pago; su link va a comprobantes_extra de ese pago.
const ORDINAL = /^(segund[oa]?|tercer[oa]?|cuart[oa]?|quint[oa]?|2|3|4|5|2d[oa]|3er|4to|5to|2nd|3rd|otro|otra|extra|adicional)$/;
const RELLENO = new Set(['de', 'del', 'el', 'la', 'y']);

function palabras(v) {
  return normalizar(v).replace(/[^a-z0-9ñ]+/g, ' ').trim().split(' ').filter(Boolean);
}

function levenshtein(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
  }
  return d[a.length][b.length];
}

function palabraIgual(a, b) {
  if (a === b) return true;
  const m = Math.max(a.length, b.length);
  return m >= 5 && levenshtein(a, b) <= (m >= 9 ? 2 : 1);
}

// null si el texto no es de comprobante extra; si lo es, { nombre: [palabras] }.
export function leerComprobanteExtra(alumno) {
  const toks = palabras(alumno);
  const marca = new Array(toks.length).fill(false);
  let hay = false;
  toks.forEach((t, k) => {
    // "x2", "comprobante", "comporbnate" (no "compagnoni")
    if (/^x[2-9]$/.test(t) || (/^comp[a-z]*$/.test(t) && !t.startsWith('compa'))) { marca[k] = true; hay = true; return; }
    // "segundo c": la palabra que sigue a un ordinal y empieza con c
    if (ORDINAL.test(t) && toks[k + 1] && /^c[a-z]{0,11}$/.test(toks[k + 1])) { marca[k] = marca[k + 1] = true; hay = true; }
  });
  if (!hay) return null;
  return { nombre: toks.filter((t, k) => !marca[k] && !ORDINAL.test(t) && !RELLENO.has(t)) };
}

// El alumno del pago tiene (con tolerancia a tipeos) al menos la mitad de las palabras del nombre.
function coincideNombre(nombre, alumno) {
  if (!nombre.length) return true;
  const del = palabras(alumno);
  const ok = nombre.filter((t) => del.some((a) => palabraIgual(t, a))).length;
  return ok >= Math.max(1, Math.ceil(nombre.length / 2));
}

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
    filas: [], rechazadas: [], descartadas: [], revisar: [], error: null, encabezado: [],
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

    // Comprobante extra: sin monto, con texto de "segundo comprobante"/"x2", o solo un link.
    if (esVacio(montoCrudo)) {
      const link = texto(celda(fila, 'comprobante'));
      const extra = alumno ? leerComprobanteExtra(alumno) : null;
      const soloLink = !alumno && link && ['programa', 'telefono', 'concepto', 'closer', 'setter']
        .every((c) => esVacio(celda(fila, c)));
      if (extra || soloLink) {
        if (!link) { descartar(MOTIVO_COMP_EXTRA_SIN_LINK); continue; }
        // El pago valido inmediatamente anterior; si el texto trae nombre y no
        // coincide, el pago anterior mas cercano de ese alumno.
        const nombre = extra ? extra.nombre : [];
        let destino = null;
        for (let k = res.filas.length - 1; k >= 0 && !destino; k--) {
          if (coincideNombre(nombre, res.filas[k].alumno)) destino = res.filas[k];
        }
        if (!destino) {
          descartar(MOTIVO_COMP_EXTRA_SIN_PAGO);
          res.revisar.push({ motivo: MOTIVO_COMP_EXTRA_SIN_PAGO, fila_planilla: nro, valor: alumno || link });
        } else {
          if (link !== destino.comprobante && !destino.comprobantes_extra.includes(link)) destino.comprobantes_extra.push(link);
          res.descartadas.push({ fila_planilla: nro, motivo: MOTIVO_COMP_EXTRA, adjunto_a: destino.fila_planilla });
        }
        continue;
      }
    }

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
      comprobantes_extra: [],
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
