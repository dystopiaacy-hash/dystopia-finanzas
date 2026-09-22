// parsers/comun.js — utilidades compartidas por los parsers.
// ES module sin dependencias: corre igual en Node (pruebas) y en Deno (Edge Function).

export const FECHA_MIN = '2024-01-01';
export const FECHA_MAX = '2027-12-31';

// Celda con formato de fecha cuyo valor cae en la tierra de nadie (ver
// RANGO_FECHA_EN_MONTO en grid.js): como MONTO no se sabe que es; como FECHA
// si (la celda tiene formato de fecha). grid.js la entrega marcada:
//   - parseMonto la ve como no numerica y los parsers la rechazan con
//     MOTIVO_MONTO_AMBIGUO (el mes queda en 'revisar'). Nunca se carga.
//   - parseFecha devuelve la fecha completa, asi en una columna de fecha
//     sigue el camino de siempre (ej. 2001-12-09 -> 'fecha fuera de rango').
export const MOTIVO_MONTO_AMBIGUO = 'monto ambiguo con formato de fecha';
const PREFIJO_AMBIGUO = `${MOTIVO_MONTO_AMBIGUO}: `;
export function marcarAmbiguo(textoMostrado, valor, fechaIso) {
  return `${PREFIJO_AMBIGUO}${textoMostrado} (valor ${valor}, fecha ${fechaIso})`;
}
export function esAmbiguo(v) {
  return typeof v === 'string' && v.startsWith(PREFIJO_AMBIGUO);
}

export function esVacio(v) {
  return v === null || v === undefined || (typeof v === 'string' && v.trim() === '');
}

// Texto comparable: sin tildes, minusculas, espacios colapsados.
export function normalizar(v) {
  return String(v ?? '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

export function texto(v) {
  if (esVacio(v)) return null;
  return String(v).trim();
}

// Numero desde celda. Acepta numero, "775.5", "1.321,9", "1,321.9", "$ 900".
// Devuelve null si no es un numero limpio (ej. "REFUND", "si", una fecha).
export function parseMonto(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  if (esVacio(v)) return null;
  let s = String(v).trim().replace(/^(us\$|usd|\$)\s*/i, '').replace(/\s*usd$/i, '').replace(/\s+/g, '');
  if (!/^-?[\d.,]+$/.test(s) || !/\d/.test(s)) return null;
  const coma = s.lastIndexOf(',');
  const punto = s.lastIndexOf('.');
  if (coma > -1 && punto > -1) {
    s = coma > punto ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '');
  } else if (coma > -1) {
    const partes = s.split(',');
    s = partes.length === 2 && partes[1].length <= 2 ? partes.join('.') : s.replace(/,/g, '');
  } else if (punto > -1 && s.split('.').length > 2) {
    s = s.replace(/\./g, '');
  }
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

// Numero al principio de un texto: "2624000 (pesos colombianos)" -> 2624000.
export function parseMontoInicial(v) {
  if (typeof v === 'number') return parseMonto(v);
  const m = String(v ?? '').trim().match(/^-?\$?\s*[\d.,]+/);
  return m ? parseMonto(m[0]) : null;
}

function isoValida(a, m, d) {
  const t = new Date(Date.UTC(a, m - 1, d));
  if (t.getUTCFullYear() !== a || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  return `${String(a).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

// Fecha desde celda -> 'AAAA-MM-DD' o null. No adivina: formatos aceptados
// ISO (con o sin hora/fraccion), dd/mm/aaaa (dia primero, Argentina) y
// numero de serie de Google Sheets.
export function parseFecha(v) {
  if (esAmbiguo(v)) {
    const a = String(v).match(/fecha (\d{4})-(\d{2})-(\d{2})\)$/);
    return a ? isoValida(+a[1], +a[2], +a[3]) : null;
  }
  if (typeof v === 'number') {
    if (!Number.isFinite(v) || v < 20000 || v > 80000) return null;
    const t = new Date(Date.UTC(1899, 11, 30) + Math.floor(v) * 86400000);
    return isoValida(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
  }
  if (esVacio(v)) return null;
  const s = String(v).trim();
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/);
  if (m) return isoValida(+m[1], +m[2], +m[3]);
  m = s.match(/^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})$/);
  if (m) {
    const anio = m[3].length === 2 ? 2000 + +m[3] : +m[3];
    return isoValida(anio, +m[2], +m[1]);
  }
  return null;
}

// Fecha en texto como la escribe GHL por API en las hojas Data:
// "Saturday, September 5, 2026 7:00 PM" (a veces con un espacio adelante).
// Devuelve 'AAAA-MM-DD' o null. Solo ese patron exacto, en ingles (en los 4
// CRM no hay meses ni dias en castellano, relevado 2026-09-22); nada parecido
// se adivina ("July 7 2016, 6 PM", "friday, september 22", "9:00AM" -> null).
// ZONA HORARIA: el resultado es un date, no un instante. Anio, mes y dia se
// sacan del texto y la hora se descarta: NUNCA new Date(texto), que interpreta
// en la zona del servidor y corre el dia en las llamadas de la noche.
// El dia de la semana se exige en el patron pero no se contrasta con la fecha.
const MESES_EN = ['january', 'february', 'march', 'april', 'may', 'june', 'july',
  'august', 'september', 'october', 'november', 'december'];
const RE_FECHA_GHL = new RegExp(
  '^(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), '
  + '(January|February|March|April|May|June|July|August|September|October|November|December) '
  + '(\\d{1,2}), (\\d{4}) (?:1[0-2]|0?[1-9]):[0-5]\\d (?:AM|PM)$');

export function parseFechaTexto(v) {
  if (typeof v !== 'string') return null;
  const m = v.trim().match(RE_FECHA_GHL);
  if (!m) return null;
  const mes = MESES_EN.indexOf(m[1].toLowerCase()) + 1;
  const dia = Number(m[2]);
  if (mes < 1 || dia < 1 || dia > 31) return null;
  return isoValida(Number(m[3]), mes, dia);
}

export function fechaEnRango(iso, min = FECHA_MIN, max = FECHA_MAX) {
  return iso >= min && iso <= max;
}

// Celdas con contenido de una fila, como [indice, valor].
export function celdasConDatos(fila) {
  const out = [];
  (fila || []).forEach((v, k) => { if (!esVacio(v)) out.push([k, v]); });
  return out;
}

// Fila cruda para guardar en jsonb: sin las celdas vacias del final.
export function filaCruda(fila) {
  const f = (fila || []).map((v) => (v === undefined ? null : v));
  let fin = f.length;
  while (fin > 0 && esVacio(f[fin - 1])) fin--;
  return f.slice(0, fin);
}

export function monedaDeMetodo(metodo) {
  const n = normalizar(metodo);
  if (!n) return null;
  if (/\busdt\b/.test(n)) return 'USDT';
  if (n.includes('peso')) return 'ARS';
  if (/\busd\b/.test(n)) return 'USD';
  return null;
}

export function redondear(n, dec = 2) {
  const f = 10 ** dec;
  return Math.round((n + Number.EPSILON) * f) / f;
}
