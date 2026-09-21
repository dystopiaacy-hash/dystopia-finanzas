// _shared/formato.js — normaliza las celdas de TEXTO que trae el grid de
// Google Sheets (ver grid.js) antes de pasarlas a los parsers.
//
// Numeros y fechas ya NO pasan por aca: el grid trae su valor real y su tipo
// (grid.js). Esto queda para texto con forma de numero o de fecha que alguien
// escribio en una celda con formato texto: "1.321,90" en es_AR, "1,321.90" en
// en_US, "15/03/2026". parseMonto de comun.js adivina el separador y con
// "1.321" (mil trescientos en es_AR) daria 1.321. Por eso se reescribe cada
// texto con el locale explicito de la planilla, sin adivinar:
//   - numero con formato  -> "1321.9"   (punto decimal, sin miles)
//   - fecha m/d o d/m     -> "AAAA-MM-DD"
//   - todo lo demas       -> igual que vino
// Historia: antes se leia con FORMATTED_VALUE y esto era la unica barrera.
// No alcanzaba (fechas "d.m" como montos, fechas sin anio, montos
// redondeados): ver CONTRATO.md seccion 0.
// ES module sin dependencias: corre en Node (pruebas) y en Deno.

// Locales de Sheets que escriben la fecha con el mes primero.
const MES_PRIMERO = new Set(['en_US', 'en_PH', 'en_CA', 'es_US', 'fil_PH']);

// Separador decimal del locale ("es_AR" -> ","). Default ".".
export function separadorDecimal(locale) {
  try {
    const partes = new Intl.NumberFormat(String(locale || 'en_US').replace('_', '-')).formatToParts(1.5);
    const d = partes.find((p) => p.type === 'decimal');
    return d ? d.value : '.';
  } catch {
    return '.';
  }
}

const RE_FECHA = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4}|\d{2})(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?$/;
const RE_ISO_HORA = /^(\d{4}-\d{2}-\d{2})\s+\d{1,2}:\d{2}(?::\d{2})?$/;
// Numero con formato: signo, parentesis contables, moneda al principio o al final.
const RE_NUMERO = /^(\()?\s*(-)?\s*(?:US\$|USD|\$|€)?\s*(-)?\s*([\d.,]*\d)\s*(?:USD|%)?\s*(\))?$/i;

function dosDigitos(n) { return String(n).padStart(2, '0'); }

function fechaIso(a, m, d) {
  const t = new Date(Date.UTC(a, m - 1, d));
  if (t.getUTCFullYear() !== a || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  return `${a}-${dosDigitos(m)}-${dosDigitos(d)}`;
}

// Una celda. Devuelve el valor a pasarle al parser.
export function normalizarCelda(v, { mesPrimero = false, decimal = '.' } = {}) {
  if (typeof v !== 'string') return v;
  const s = v.trim();
  if (s === '') return '';

  let m = s.match(RE_ISO_HORA);
  if (m) return m[1];

  m = s.match(RE_FECHA);
  if (m) {
    const anio = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    const [dia, mes] = mesPrimero ? [Number(m[2]), Number(m[1])] : [Number(m[1]), Number(m[2])];
    // Si no es una fecha valida en el orden del locale, se deja el texto:
    // el parser la rechaza como 'fecha no parsea' y queda visible.
    return fechaIso(anio, mes, dia) ?? s;
  }

  m = s.match(RE_NUMERO);
  if (m && !s.endsWith('%')) {
    const negativo = Boolean(m[2] || m[3] || (m[1] && m[5]));
    if (Boolean(m[1]) !== Boolean(m[5])) return s;   // parentesis sin cerrar
    let cuerpo = m[4];
    const miles = decimal === ',' ? '.' : ',';
    // Miles bien formados (grupos de 3) o nada: si no, se deja el texto.
    const partes = cuerpo.split(decimal);
    if (partes.length > 2) return s;
    const entero = partes[0];
    if (entero.includes(miles) && !new RegExp(`^\\d{1,3}(\\${miles}\\d{3})+$`).test(entero)) return s;
    if (partes[1] !== undefined && !/^\d+$/.test(partes[1])) return s;
    cuerpo = entero.split(miles).join('') + (partes[1] !== undefined ? '.' + partes[1] : '');
    return (negativo ? '-' : '') + cuerpo;
  }
  return s;
}

export function opcionesDeLocale(locale) {
  return { mesPrimero: MES_PRIMERO.has(locale), decimal: separadorDecimal(locale) };
}

// Matriz completa. locale = spreadsheet.properties.locale (ej. "es_AR").
export function normalizarMatriz(matriz, locale) {
  const opciones = opcionesDeLocale(locale);
  return (matriz || []).map((fila) => (fila || []).map((v) => normalizarCelda(v, opciones)));
}
