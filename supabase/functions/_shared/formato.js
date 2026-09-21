// _shared/formato.js — normaliza una matriz leida de Google Sheets con
// valueRenderOption = FORMATTED_VALUE antes de pasarla a los parsers.
//
// Por que FORMATTED_VALUE: una fecha colada en una celda de monto tiene que
// llegar como TEXTO ("12/06/2026") para que el parser la detecte y la
// rechace. Con UNFORMATTED_VALUE llega como serial (46185) y se sumaria como
// plata.
//
// El costo: los numeros llegan con el formato del locale de la planilla
// ("1.321,90" en es_AR, "1,321.90" en en_US) y las fechas con el orden del
// locale (d/m o m/d). parseMonto de comun.js adivina el separador y con
// "1.321" (mil trescientos en es_AR) daria 1.321. Por eso aca se reescribe
// cada celda con el locale explicito de la planilla, sin adivinar:
//   - numero con formato  -> "1321.9"   (punto decimal, sin miles)
//   - fecha m/d o d/m     -> "AAAA-MM-DD"
//   - todo lo demas       -> igual que vino
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

// Matriz completa. locale = spreadsheet.properties.locale (ej. "es_AR").
export function normalizarMatriz(matriz, locale) {
  const opciones = { mesPrimero: MES_PRIMERO.has(locale), decimal: separadorDecimal(locale) };
  return (matriz || []).map((fila) => (fila || []).map((v) => normalizarCelda(v, opciones)));
}
