// _shared/grid.js — respuesta de spreadsheets.get (includeGridData) -> matriz
// para los parsers. ES module sin dependencias: corre en Node (pruebas) y en Deno.
//
// Por que grid y no values.get con FORMATTED_VALUE (ver CONTRATO.md 0):
//   A. una fecha colada en un monto, con formato "d.m", llega como "26.5" y
//      se carga como 26,5 USD (lucas opps sep f27, lucas pagos f154);
//   B. una fecha con formato sin anio llega como "14/05" y el anio se pierde
//      (8 pagos reales y 532 USD de cuotas pendientes de liam);
//   C. un monto llega redondeado al formato de la celda ("11" por 10,8).
// El grid trae por celda el texto mostrado, el valor real y el TIPO de
// formato, y con eso ninguno de los tres casos puede pasar:
//   - celda DATE / DATE_TIME con valor numerico -> 'AAAA-MM-DD' completo,
//     se vea como se vea. En una columna de monto el parser la rechaza como
//     'fecha en celda de monto'.
//   - cualquier otro numero -> el valor real, sin el redondeo del formato.
//     (PERCENT y TIME quedan como texto: no son montos.)
//   - texto -> el texto tal cual; despues pasa por formato.js (locale).
// Un 46637 tipeado como numero sigue siendo numero: lo avisa la red
// 45000..47500 de procesar.js.

import { normalizarCelda, opcionesDeLocale } from './formato.js';

const TIPOS_FECHA = new Set(['DATE', 'DATE_TIME']);
const TIPOS_TEXTO = new Set(['PERCENT', 'TIME']);

// Serial de Sheets (dias desde 1899-12-30) -> 'AAAA-MM-DD'.
export function serialAIso(serial) {
  const t = new Date(Date.UTC(1899, 11, 30) + Math.floor(serial) * 86400000);
  return t.toISOString().slice(0, 10);
}

export function isoASerial(iso) {
  const [a, m, d] = iso.split('-').map(Number);
  return Math.round((Date.UTC(a, m - 1, d) - Date.UTC(1899, 11, 30)) / 86400000);
}

// Una celda del grid -> valor para el parser.
export function valorDeCelda(c, opciones) {
  if (!c) return '';
  const ev = c.effectiveValue;
  const texto = c.formattedValue ?? '';
  if (!ev) return texto === '' ? '' : normalizarCelda(texto, opciones);
  if (typeof ev.numberValue === 'number') {
    const tipo = c.effectiveFormat?.numberFormat?.type;
    if (TIPOS_FECHA.has(tipo)) return serialAIso(ev.numberValue);
    if (TIPOS_TEXTO.has(tipo)) return texto;
    return ev.numberValue;
  }
  if (typeof ev.stringValue === 'string') return normalizarCelda(texto || ev.stringValue, opciones);
  return texto;   // boolValue, errorValue (#REF!, #N/A): el texto que se ve
}

// data = sheets[i].data[0] de la respuesta (una hoja completa).
export function matrizDesdeGrid(data, locale) {
  const opciones = opcionesDeLocale(locale);
  const filas = (data && data.rowData) || [];
  const desdeFila = (data && data.startRow) || 0;
  const matriz = [];
  for (let i = 0; i < desdeFila; i++) matriz.push([]);
  for (const fila of filas) matriz.push(((fila && fila.values) || []).map((c) => valorDeCelda(c, opciones)));
  return matriz;
}
