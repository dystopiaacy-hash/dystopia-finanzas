// parsers/cierres.js — pestaña "Clientes" de la planilla de ventas de Agus
// ("Ventas De Cero a CEO") -> filas canonicas de fin_cierres.
//
// Una fila = un trato cerrado. No hay llamadas ni show up: solo lo que cerro
// (fecha, producto, fuente, estado, cash del dia 1, valor del trato).
//
// parseCierres(matriz, config) devuelve
//   { filas, rechazadas, descartadas, error, encabezado, stats }
// Invariante: stats.filas_leidas = cargadas + rechazadas + descartadas.
//
// Igual que Data: una fila sin fecha o sin cliente NO se carga (fila
// rechazada, cuenta en stats.rechazadas); un monto que no es numero deja la
// fila cargada con ese monto en NULL y queda como celda rechazada (cuenta en
// stats.celdas_rechazadas, no en stats.rechazadas).
//
// Encabezados: fijos y normalizados (sin tildes ni mayusculas). La columna
// "Mes" de la planilla se ignora: el mes sale de la fecha de cierre.
//
// config = { fila_encabezado: 1 (1-based), fecha_min, fecha_max }

import {
  FECHA_MIN, FECHA_MAX, esVacio, normalizar, texto, parseMonto, parseFecha, fechaEnRango, celdasConDatos, filaCruda,
} from './comun.js';

export const MOTIVO_CELDA = 'celda rechazada, la fila se cargo sin este valor';

const ERROR_FORMULA = /^#(DIV\/0!|N\/A|REF!|VALUE!|NAME\?|NUM!|NULL!|ERROR!)$/i;

// campo canonico -> [encabezados aceptados, normalizados], obligatorio.
const COLUMNAS = {
  fecha_cierre: { alias: ['fecha de cierre', 'fecha cierre'], obligatorio: true },
  nombre: { alias: ['cliente'], obligatorio: true }, // la persona que compro (no es crm_clients)
  producto: { alias: ['producto'], obligatorio: false },
  fuente: { alias: ['fuente'], obligatorio: false },
  estructura_pago: { alias: ['estructura de pago', 'estructura pago'], obligatorio: false },
  estado: { alias: ['estado'], obligatorio: false },
  cash_dia1: { alias: ['cash dia 1 (usd)', 'cash dia 1', 'cash dia1 (usd)', 'cash dia 1 usd'], obligatorio: true },
  trato_cerrado: { alias: ['trato cerrado (usd)', 'trato cerrado', 'trato cerrado usd'], obligatorio: true },
};
const MONTOS = ['cash_dia1', 'trato_cerrado'];
const TEXTOS = ['producto', 'fuente', 'estructura_pago', 'estado'];

function mapearColumnas(encabezado) {
  const norm = encabezado.map(normalizar);
  const col = {};
  const faltan = [];
  for (const [campo, def] of Object.entries(COLUMNAS)) {
    let idx = -1;
    for (const a of def.alias) {
      const k = norm.indexOf(a);
      if (k > -1 && (idx === -1 || k < idx)) idx = k;
    }
    if (idx > -1) col[campo] = idx;
    else if (def.obligatorio) faltan.push(`${campo} (${def.alias.join(' / ')})`);
  }
  return { col, faltan };
}

export function parseCierres(matriz, config = {}) {
  const res = {
    filas: [], rechazadas: [], descartadas: [], error: null, encabezado: [],
    stats: { filas_leidas: 0, filas_cargadas: 0, rechazadas: 0, descartadas: 0, celdas_rechazadas: 0 },
  };
  const hdr = (config.fila_encabezado ?? 1) - 1;
  const fMin = config.fecha_min ?? FECHA_MIN;
  const fMax = config.fecha_max ?? FECHA_MAX;

  if (!Array.isArray(matriz) || !Array.isArray(matriz[hdr])) {
    res.error = `no hay fila de encabezado en la fila ${hdr + 1}`;
    return res;
  }
  const encabezado = matriz[hdr].map((v) => (esVacio(v) ? '' : String(v).trim()));
  res.encabezado = encabezado;
  const { col, faltan } = mapearColumnas(encabezado);
  if (faltan.length) {
    res.error = `faltan columnas obligatorias: ${faltan.join(', ')}`;
    return res;
  }
  const celda = (fila, campo) => (col[campo] === undefined ? null : fila[col[campo]]);
  const mapeadas = Object.values(col);

  for (let i = hdr + 1; i < matriz.length; i++) {
    const fila = matriz[i] || [];
    const nro = i + 1;
    res.stats.filas_leidas++;
    const descartar = (motivo) => res.descartadas.push({ fila_planilla: nro, motivo });
    const rechazo = (motivo, valor) => ({
      fila_planilla: nro,
      motivo,
      valor_crudo: valor === null || valor === undefined ? null : String(valor),
      comprobante: null,
      metodo_pago: null,
      contenido_crudo: filaCruda(fila),
    });
    const rechazarFila = (motivo, valor) => { res.rechazadas.push(rechazo(motivo, valor)); res.stats.rechazadas++; };

    // Vacia = ninguna columna mapeada con datos ("Mes" suelta no cuenta).
    if (mapeadas.every((k) => esVacio(fila[k]))) { descartar('vacia'); continue; }

    const fechaCruda = celda(fila, 'fecha_cierre');
    const nombre = texto(celda(fila, 'nombre'));
    // Encabezado repetido: la celda de fecha repite el encabezado de su columna.
    if (!esVacio(fechaCruda) && normalizar(fechaCruda) === normalizar(encabezado[col.fecha_cierre])) {
      descartar('encabezado_repetido'); continue;
    }
    // Sin fecha ni cliente pero con algun numero: fila de totales o separador.
    if (esVacio(fechaCruda) && !nombre) {
      if (celdasConDatos(fila).length) { descartar('sin_cliente_ni_fecha'); continue; }
      descartar('vacia'); continue;
    }
    if (esVacio(fechaCruda)) { rechazarFila('falta fecha de cierre', null); continue; }
    const fecha = parseFecha(fechaCruda);
    if (!fecha) { rechazarFila('fecha no parsea', fechaCruda); continue; }
    if (!fechaEnRango(fecha, fMin, fMax)) { rechazarFila('fecha fuera de rango', fechaCruda); continue; }
    if (!nombre) { rechazarFila('falta cliente', null); continue; }

    const out = { fila_planilla: nro, fecha_cierre: fecha, nombre };
    for (const campo of TEXTOS) out[campo] = texto(celda(fila, campo));
    const celdasRech = [];
    for (const campo of MONTOS) {
      const v = celda(fila, campo);
      if (esVacio(v)) { out[campo] = null; continue; }
      const n = parseMonto(v);
      if (n === null) {
        const que = ERROR_FORMULA.test(String(v).trim()) ? 'error de formula' : 'monto no numerico';
        celdasRech.push(rechazo(`${campo}: ${que} (${MOTIVO_CELDA})`, v));
      }
      out[campo] = n;
    }
    res.filas.push(out);
    res.rechazadas.push(...celdasRech);
    res.stats.celdas_rechazadas += celdasRech.length;
  }

  res.stats.filas_cargadas = res.filas.length;
  res.stats.descartadas = res.descartadas.length;
  return res;
}
