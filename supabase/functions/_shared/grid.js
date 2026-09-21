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
import { marcarAmbiguo } from './parsers/comun.js';

// Celda con formato de FECHA (DATE / DATE_TIME) y valor numerico: que es?
// Pasa: hay pagos reales guardados en celdas con formato de fecha pegado de
// otra columna (agus f5 1324.07 'yyyy.mm', agus f37 1328.4 y teo f178
// 1254.11 'yyyy.m'). Y hay fechas reales coladas en celdas de monto (lucas
// opps sep f27 '26.5', lucas pagos f154 '31.8'). Se decide por el VALOR:
//   valor <= montoMaximoReal              -> es un monto: se usa el numero.
//   serialMin <= valor <= serialMax        -> es una fecha: 'AAAA-MM-DD'
//                                            (en una columna de monto el
//                                            parser la rechaza, como siempre).
//   cualquier otro valor (tierra de nadie) -> ambiguo: se rechaza con
//                                            'monto ambiguo con formato de
//                                            fecha' y el mes queda en revisar.
// Por que estos numeros (relevado sobre las 5 cuentas, 2026-09-21):
//   3250  = el pago mas alto de todo el sistema.
//   43831 = 2020-01-01, el primer serial de fecha plausible.
//   47848 = 2030-12-31, el ultimo.
// Entre 3250 y 43831 no hay ningun dato real: por eso la regla no puede
// confundir un monto con una fecha. Si aparece un pago de mas de 3250 en
// una celda con formato de fecha, queda rechazado y visible (no se carga un
// numero que no sabemos que es): subir montoMaximoReal ACA, en un solo lugar.
export const RANGO_FECHA_EN_MONTO = Object.freeze({ montoMaximoReal: 3250, serialMin: 43831, serialMax: 47848 });

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
    if (TIPOS_FECHA.has(tipo)) {
      const v = ev.numberValue;
      const { montoMaximoReal, serialMin, serialMax } = RANGO_FECHA_EN_MONTO;
      if (v >= serialMin && v <= serialMax) return serialAIso(v);
      if (Math.abs(v) <= montoMaximoReal) return v;
      return marcarAmbiguo(texto, v, serialAIso(v));
    }
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
