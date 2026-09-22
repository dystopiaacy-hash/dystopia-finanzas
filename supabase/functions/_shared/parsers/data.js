// parsers/data.js — hoja DATA (CRM de ventas) -> filas canonicas de fin_llamadas.
//
// parseData(matriz, config) devuelve
//   { filas, rechazadas, descartadas, error, encabezado, stats }
// Invariante: stats.filas_leidas = cargadas + rechazadas + descartadas.
// Ninguna fila desaparece sin quedar en alguna de las tres listas.
//
// `rechazadas` lleva dos clases de entradas (las dos van a fin_filas_rechazadas):
//   - fila rechazada: la fila NO se carga (falta fecha, closer o nombre).
//     Son las que cuenta stats.rechazadas.
//   - celda rechazada: la fila SE CARGA con esa columna en NULL (show_up,
//     calificacion o un monto fuera de dominio). Cuentan en
//     stats.celdas_rechazadas. El motivo empieza con MOTIVO_CELDA.
//
// config = {
//   alias: [{ campo, alias, obligatorio, posicion }],   // fin_alias_columnas de la fuente
//   fila_encabezado: 1,                                  // 1-based
//   fecha_min, fecha_max                                 // opcional, default 2024..2027
// }
// Reglas: CONTRATO-DATA.md secciones 1 a 4.
//
// REGLA CENTRAL: show_up y calificacion tienen CHECK en fin_llamadas (013).
// Un valor fuera del dominio hace fallar la escritura ENTERA de la fuente.
// Por eso salen solo de los mapas cerrados de abajo; cualquier otra cosa es
// NULL + celda rechazada con el valor crudo.

import {
  FECHA_MIN, FECHA_MAX, esVacio, normalizar, texto, parseMonto, parseFecha, fechaEnRango, filaCruda,
} from './comun.js';

export const MOTIVO_CELDA = 'celda rechazada, la fila se cargo sin este valor';
export const MOTIVO_FECHA_TEXTO = 'fecha en texto no reconocida';

// Claves: normalizar() del valor de la planilla. Valores: el dominio del CHECK de 013.
export const SHOW_UP = Object.freeze({
  'si': 'si',
  'no': 'no',
  'regenda': 'regenda',
  'cancelado por closer': 'cancelado por closer',
  'por closer': 'cancelado por closer',
});
export const CALIFICACION = Object.freeze({
  'calificado': 'calificado',
  'no calificado': 'no calificado',
  'no se sabe': 'no se sabe',
  'se desconoce': 'no se sabe',   // lucas
});

const NUMERICOS = ['cc_dia1', 'cc_cerrado', 'cc_seguimiento', 'monto_restante'];
const TEXTOS = ['estado_llamada', 'programa', 'telefono', 'instagram', 'contexto_closer', 'contexto_setter'];
const ERROR_FORMULA = /^#(DIV\/0!|N\/A|REF!|VALUE!|NAME\?|NUM!|NULL!|ERROR!)$/i;

// Campo -> lista de columnas (0-based). Solo 'nombre' puede tener mas de una
// (mauro: Nombre + Apellido, se concatenan en orden de columna); en los demas
// campos gana la primera.
// Con `posicion` cargada el campo se lee de esa columna sin buscar por nombre
// (liam: dos "Encargado de la llamada", la fecha es la segunda). Igual se
// exige que el encabezado de esa columna coincida con el alias: si la agencia
// mueve columnas, la corrida falla en vez de leer otra cosa.
function mapearColumnas(encabezado, alias) {
  const norm = encabezado.map(normalizar);
  const col = {};
  const faltan = [];
  const errores = [];
  const campos = [...new Set(alias.map((a) => a.campo))];
  for (const campo of campos) {
    const del = alias.filter((a) => a.campo === campo);
    const idx = [];
    for (const a of del) {
      if (a.posicion !== null && a.posicion !== undefined) {
        const k = Number(a.posicion) - 1;
        if (norm[k] !== normalizar(a.alias)) {
          errores.push(`${campo}: la columna ${a.posicion} dice '${encabezado[k] ?? ''}' y se esperaba '${a.alias}'`);
        } else idx.push(k);
      } else {
        const k = norm.indexOf(normalizar(a.alias));
        if (k > -1) idx.push(k);
      }
    }
    const unicos = [...new Set(idx)].sort((x, y) => x - y);
    if (unicos.length) col[campo] = campo === 'nombre' ? unicos : [unicos[0]];
    else if (del.some((a) => a.obligatorio)) faltan.push(`${campo} (${del.map((a) => a.alias).join(' / ')})`);
  }
  return { col, faltan, errores };
}

function esEncabezadoRepetido(fila, encabezado, col) {
  let iguales = 0;
  for (const ks of Object.values(col)) {
    for (const k of ks) if (!esVacio(fila[k]) && normalizar(fila[k]) === normalizar(encabezado[k])) iguales++;
  }
  return iguales >= 2;
}

export function parseData(matriz, config = {}) {
  const res = {
    filas: [], rechazadas: [], descartadas: [], error: null, encabezado: [],
    stats: { filas_leidas: 0, filas_cargadas: 0, rechazadas: 0, descartadas: 0, celdas_rechazadas: 0, cola_sin_fecha: 0 },
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
  const { col, faltan, errores } = mapearColumnas(encabezado, config.alias || []);
  if (errores.length) { res.error = `columnas por posicion que no coinciden: ${errores.join('; ')}`; return res; }
  if (faltan.length) { res.error = `faltan columnas obligatorias: ${faltan.join(', ')}`; return res; }

  const celda = (fila, campo) => (col[campo] === undefined ? null : fila[col[campo][0]]);
  const mapeadas = [...new Set(Object.values(col).flat())];

  // Corte por fecha_llamada (CONTRATO-DATA.md §4.3): liam tiene 1500 filas
  // formateadas y 501 con datos, salteadas hasta la ultima. Se lee hasta la
  // ultima fila con fecha; lo de abajo es formato (checkbox, "0"/"1") y no se
  // cuenta como leido.
  const kFecha = col.fecha_llamada[0];
  let fin = hdr;
  for (let i = matriz.length - 1; i > hdr; i--) {
    if (!esVacio((matriz[i] || [])[kFecha])) { fin = i; break; }
  }
  res.stats.cola_sin_fecha = Math.max(0, matriz.length - 1 - fin);

  for (let i = hdr + 1; i <= fin; i++) {
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
    const celdasRech = [];
    const rechazarCelda = (campo, que, valor) => celdasRech.push(rechazo(`${campo}: ${que} (${MOTIVO_CELDA})`, valor));

    // Vacia = ninguna columna MAPEADA tiene datos (las ignoradas traen checkbox).
    if (mapeadas.every((k) => esVacio(fila[k]))) { descartar('vacia'); continue; }
    if (esEncabezadoRepetido(fila, encabezado, col)) { descartar('encabezado_repetido'); continue; }

    const fechaCruda = celda(fila, 'fecha_llamada');
    if (esVacio(fechaCruda)) { rechazarFila('falta fecha_llamada', null); continue; }
    const fecha = parseFecha(fechaCruda);
    if (!fecha) {
      rechazarFila(typeof fechaCruda === 'string' && /[a-z]/i.test(fechaCruda) ? MOTIVO_FECHA_TEXTO : 'fecha no parsea', fechaCruda);
      continue;
    }
    if (!fechaEnRango(fecha, fMin, fMax)) { rechazarFila('fecha fuera de rango', fechaCruda); continue; }

    const closer = texto(celda(fila, 'closer'));
    if (!closer) { rechazarFila('falta closer', null); continue; }
    const nombre = col.nombre.map((k) => texto(fila[k])).filter(Boolean).join(' ') || null;
    if (!nombre) { rechazarFila('falta nombre', null); continue; }

    // Enums cerrados: fuera del mapa -> NULL + celda rechazada.
    const enumerado = (campo, mapa) => {
      const v = celda(fila, campo);
      if (esVacio(v)) return null;
      const ok = mapa[normalizar(v)];
      if (ok) return ok;
      const que = typeof v === 'string' && ERROR_FORMULA.test(v.trim()) ? 'error de formula'
        : typeof v === 'number' ? 'numero en celda de texto' : 'valor fuera de dominio';
      rechazarCelda(campo, que, v);
      return null;
    };

    const fila_out = {
      fila_planilla: nro,
      fecha_llamada: fecha,
      closer,
      nombre,
      show_up: enumerado('show_up', SHOW_UP),
      calificacion: enumerado('calificacion', CALIFICACION),
      tipo_booking: esVacio(celda(fila, 'tipo_booking')) ? null : normalizar(celda(fila, 'tipo_booking')).toUpperCase(),
    };
    for (const campo of TEXTOS) fila_out[campo] = texto(celda(fila, campo));
    for (const campo of NUMERICOS) {
      const v = celda(fila, campo);
      if (esVacio(v)) { fila_out[campo] = null; continue; }
      const n = parseMonto(v);
      if (n === null) rechazarCelda(campo, ERROR_FORMULA.test(String(v).trim()) ? 'error de formula' : 'monto no numerico', v);
      fila_out[campo] = n;
    }

    res.filas.push(fila_out);
    res.rechazadas.push(...celdasRech);
    res.stats.celdas_rechazadas += celdasRech.length;
  }

  res.stats.filas_cargadas = res.filas.length;
  res.stats.descartadas = res.descartadas.length;
  return res;
}
