// parsers/cuotas.js — hojas de cuotas / cobranzas -> fin_cuotas.
//
// parseCuotas(matriz, config) devuelve
//   { filas, rechazadas, descartadas, error, encabezado, stats }
// config = {
//   forma: 'cuotas_ancho' | 'cuotas_plano' | 'desde_pagos',   // fin_fuentes.forma
//   fila_encabezado,       // 1-based; en cuotas_ancho, la SEGUNDA fila del encabezado
//   tope_monto, fecha_min, fecha_max
// }
// La forma se declara en la configuracion, no se adivina.
// Las filas de la planilla se cuentan una vez (leidas = cargadas + rechazadas
// + descartadas). Una fila cargada puede generar varias cuotas (ancho).
// Una fila con una cuota invalida se rechaza entera: no se carga a medias.

import {
  FECHA_MIN, FECHA_MAX, esVacio, normalizar, texto, parseMonto, parseFecha,
  fechaEnRango, celdasConDatos, filaCruda, esAmbiguo, MOTIVO_MONTO_AMBIGUO,
} from './comun.js';

// Shape normalizado: igual en todas las formas, null donde no aplica.
export const CAMPOS_CUOTA = ['alumno', 'telefono', 'programa', 'numero_cuota', 'tipo_cuota',
  'monto', 'monto_cobrado', 'fecha_pago', 'estado', 'closer', 'contexto', 'fila_planilla'];

const FIJAS = {
  'nombre del cliente': 'alumno',
  'nombre del alumno': 'alumno',
  'numero de whatsapp': 'telefono',
  'closer': 'closer',
  'programa': 'programa',
};
const SUB_CUOTA = {
  'monto': 'monto',
  'fecha de pago': 'fecha_pago',
  'estado': 'estado',
  'contexto': 'contexto',
  'closer': 'closer',
};
const PLANO = {
  'programa': 'programa',
  'nombre del alumno': 'alumno',
  'fecha de cobro': 'fecha_pago',
  'tipo de cuota': 'tipo_cuota',
  'monto por cobrar': 'monto',
  'monto cobrado': 'monto_cobrado',
  'closer': 'closer',
  'situacion del lead': 'estado',
};

function cuotaVacia() {
  return Object.fromEntries(CAMPOS_CUOTA.map((c) => [c, null]));
}

function nuevoResultado() {
  return {
    filas: [], rechazadas: [], descartadas: [], error: null, encabezado: [],
    stats: { filas_leidas: 0, filas_cargadas: 0, rechazadas: 0, descartadas: 0, cuotas: 0 },
  };
}

// Valida y normaliza los valores de una cuota. Devuelve { cuota } o { motivo, valor }.
function validarCuota(base, crudo, cfg, etiqueta) {
  const q = { ...base };
  const sufijo = etiqueta ? ` (${etiqueta})` : '';
  if (esVacio(crudo.monto)) return { motivo: `falta monto${sufijo}`, valor: null };
  q.monto = parseMonto(crudo.monto);
  if (q.monto === null) {
    return { motivo: `${esAmbiguo(crudo.monto) ? MOTIVO_MONTO_AMBIGUO : 'monto no numerico'}${sufijo}`, valor: crudo.monto };
  }
  if (cfg.tope !== null && Math.abs(q.monto) > cfg.tope) {
    return { motivo: `monto fuera de rango, probable moneda local sin convertir${sufijo}`, valor: crudo.monto };
  }
  if (!esVacio(crudo.monto_cobrado)) {
    q.monto_cobrado = parseMonto(crudo.monto_cobrado);
    if (q.monto_cobrado === null) {
      return { motivo: `${esAmbiguo(crudo.monto_cobrado) ? MOTIVO_MONTO_AMBIGUO : 'monto cobrado no numerico'}${sufijo}`, valor: crudo.monto_cobrado };
    }
  }
  if (!esVacio(crudo.fecha_pago)) {
    q.fecha_pago = parseFecha(crudo.fecha_pago);
    if (!q.fecha_pago) return { motivo: `fecha no parsea${sufijo}`, valor: crudo.fecha_pago };
    if (!fechaEnRango(q.fecha_pago, cfg.fMin, cfg.fMax)) return { motivo: `fecha fuera de rango${sufijo}`, valor: crudo.fecha_pago };
  }
  for (const k of ['estado', 'contexto', 'tipo_cuota', 'closer', 'programa']) {
    if (crudo[k] !== undefined && texto(crudo[k]) !== null) q[k] = texto(crudo[k]);
  }
  return { cuota: q };
}

// Procesa filas de datos. `extraer(fila)` devuelve
//   { base, cuotas: [{ crudo, etiqueta, numero }], mapeadas: [valores] }
function procesar(matriz, desde, cfg, res, extraer) {
  for (let i = desde; i < matriz.length; i++) {
    const fila = matriz[i] || [];
    const nro = i + 1;
    res.stats.filas_leidas++;
    const rechazar = (motivo, valor) => res.rechazadas.push({
      fila_planilla: nro, motivo, valor_crudo: valor === null || valor === undefined ? null : String(valor),
      comprobante: null, metodo_pago: null, contenido_crudo: filaCruda(fila),
    });
    if (celdasConDatos(fila).length === 0) { res.descartadas.push({ fila_planilla: nro, motivo: 'vacia' }); continue; }

    const { base, cuotas, mapeadas } = extraer(fila);
    const hayDatos = mapeadas.some((v) => !esVacio(v));
    if (!base.alumno) {
      if (hayDatos) rechazar('falta alumno', null);
      else res.descartadas.push({ fila_planilla: nro, motivo: 'sin_datos' });  // solo celdas fuera de columnas mapeadas
      continue;
    }
    const conDatos = cuotas.filter((c) => Object.values(c.crudo).some((v) => !esVacio(v)));
    if (conDatos.length === 0) { rechazar('sin datos de cuota', null); continue; }

    const validas = [];
    let fallo = null;
    for (const c of conDatos) {
      const v = validarCuota({ ...base, numero_cuota: c.numero ?? null, fila_planilla: nro }, c.crudo, cfg, c.etiqueta);
      if (v.motivo) { fallo = v; break; }
      validas.push(v.cuota);
    }
    if (fallo) { rechazar(fallo.motivo, fallo.valor); continue; }
    res.filas.push(...validas);
    res.stats.filas_cargadas++;
  }
}

function parseAncho(matriz, cfg, res) {
  const h2 = cfg.hdr;
  const h1 = h2 - 1;
  if (h1 < 0 || !Array.isArray(matriz[h1]) || !Array.isArray(matriz[h2])) {
    res.error = 'cuotas_ancho necesita dos filas de encabezado (fila_encabezado >= 2)';
    return;
  }
  const f1 = matriz[h1];
  const f2 = matriz[h2];
  const ancho = Math.max(f1.length, f2.length);
  const fijas = {};                  // campo -> columna
  const grupos = [];                 // { numero, etiqueta, cols: { campo: col } }
  let actual = null;                 // grupo abierto o null
  for (let k = 0; k < ancho; k++) {
    const t1 = texto(f1[k]);
    const t2 = texto(f2[k]);
    const mc = t1 ? normalizar(t1).match(/^cuota\s*(\d+)$/) : null;
    if (mc) {
      actual = { numero: +mc[1], etiqueta: t1, cols: {} };
      grupos.push(actual);
    } else if (t1) {
      actual = null;                 // columna fija (o fin de grupo: 'Referencia de colores')
    }
    res.encabezado.push(`${t1 ?? ''}|${t2 ?? ''}`);
    if (actual) {
      const campo = t2 ? SUB_CUOTA[normalizar(t2)] : undefined;
      if (campo && actual.cols[campo] === undefined) actual.cols[campo] = k;
    } else {
      const campo = FIJAS[normalizar(t1 ?? t2)];
      if (campo && fijas[campo] === undefined) fijas[campo] = k;
    }
  }
  if (fijas.alumno === undefined) { res.error = "no se encontro la columna 'Nombre del cliente'"; return; }
  if (grupos.length === 0) { res.error = "no se encontro ningun grupo 'CUOTA n'"; return; }

  procesar(matriz, h2 + 1, cfg, res, (fila) => {
    const base = cuotaVacia();
    base.alumno = texto(fila[fijas.alumno]);
    base.telefono = fijas.telefono !== undefined ? texto(fila[fijas.telefono]) : null;
    base.closer = fijas.closer !== undefined ? texto(fila[fijas.closer]) : null;
    base.programa = fijas.programa !== undefined ? texto(fila[fijas.programa]) : null;
    const mapeadas = Object.values(fijas).map((k) => fila[k]);
    const cuotas = grupos.map((g) => {
      const crudo = {};
      for (const [campo, k] of Object.entries(g.cols)) { crudo[campo] = fila[k]; mapeadas.push(fila[k]); }
      return { crudo, etiqueta: g.etiqueta, numero: g.numero };
    });
    return { base, cuotas, mapeadas };
  });
}

function parsePlano(matriz, cfg, res) {
  const enc = matriz[cfg.hdr];
  if (!Array.isArray(enc)) { res.error = `no hay fila de encabezado en la fila ${cfg.hdr + 1}`; return; }
  const cols = {};
  enc.forEach((v, k) => {
    const campo = PLANO[normalizar(v)];
    if (campo && cols[campo] === undefined) cols[campo] = k;
    res.encabezado.push(texto(v) ?? '');
  });
  if (cols.alumno === undefined) { res.error = "no se encontro la columna 'Nombre del Alumno'"; return; }
  if (cols.monto === undefined) { res.error = "no se encontro la columna 'Monto por Cobrar'"; return; }

  procesar(matriz, cfg.hdr + 1, cfg, res, (fila) => {
    const base = cuotaVacia();
    base.alumno = texto(fila[cols.alumno]);
    base.programa = cols.programa !== undefined ? texto(fila[cols.programa]) : null;
    base.closer = cols.closer !== undefined ? texto(fila[cols.closer]) : null;
    const crudo = {};
    for (const campo of ['monto', 'monto_cobrado', 'fecha_pago', 'tipo_cuota', 'estado']) {
      if (cols[campo] !== undefined) crudo[campo] = fila[cols[campo]];
    }
    const tipo = texto(crudo.tipo_cuota);
    const numero = tipo && /^\d+/.test(tipo) ? parseInt(tipo, 10) : null;
    const mapeadas = Object.values(cols).map((k) => fila[k]);
    return { base, cuotas: [{ crudo, etiqueta: null, numero }], mapeadas };
  });
}

export function parseCuotas(matriz, config = {}) {
  const res = nuevoResultado();
  if (!Array.isArray(matriz)) { res.error = 'matriz vacia'; return res; }
  const cfg = {
    hdr: (config.fila_encabezado ?? 1) - 1,
    tope: config.tope_monto ?? null,
    fMin: config.fecha_min ?? FECHA_MIN,
    fMax: config.fecha_max ?? FECHA_MAX,
  };
  if (config.forma === 'cuotas_ancho') parseAncho(matriz, cfg, res);
  else if (config.forma === 'cuotas_plano') parsePlano(matriz, cfg, res);
  else if (config.forma === 'desde_pagos') res.error = "forma 'desde_pagos' todavia no implementada";
  else res.error = `forma de cuotas desconocida: ${config.forma}`;

  res.stats.rechazadas = res.rechazadas.length;
  res.stats.descartadas = res.descartadas.length;
  res.stats.cuotas = res.filas.length;
  return res;
}
