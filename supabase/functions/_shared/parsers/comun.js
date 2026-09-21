// parsers/comun.js — utilidades compartidas por los parsers.
// ES module sin dependencias: corre igual en Node (pruebas) y en Deno (Edge Function).

export const FECHA_MIN = '2024-01-01';
export const FECHA_MAX = '2027-12-31';

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
