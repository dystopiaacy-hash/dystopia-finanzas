// parsers/opps.js — hoja Opps (P&L) -> fin_pnl, fin_pnl_saldos, fin_reparto.
//
// parseOpps(matriz, config) devuelve
//   { filas, saldos, reparto, rechazadas, controles, revisar, estado,
//     avisos, error, encabezado }
// config = { anio }   // fin_fuentes.anio
//
// Plantilla: 12 bloques de 4 columnas, mes tomado del encabezado. Dentro del
// bloque la etiqueta esta en la col 0 (o 1) y el monto en la col 2 (o 3).
// Filas ubicadas por etiqueta, nunca por numero. Ver CONTRATO.md seccion 4.
//
// Fuente de verdad = los items. Los totales de la planilla (Total Revenue,
// Total Expenses, Retained Earnings) son CONTROL: si no cuadran, el mes se
// carga igual con los items reales y queda en `revisar` (estado 'revisar').
// `error` solo se setea por estructura irreconocible (sin fila de meses,
// meses repetidos, sin anio): ahi la corrida no toca datos.

import { esVacio, normalizar, texto, parseMonto, parseFecha, redondear, esAmbiguo, MOTIVO_MONTO_AMBIGUO } from './comun.js';

export const MARGEN = 0.01;
export const MOTIVO_FECHA_EN_MONTO = 'fecha en celda de monto';
export const MOTIVO_REPARTO_SIN_BENEFICIARIO = 'posible reparto sin beneficiario';

const MESES = ['january', 'february', 'march', 'april', 'may', 'june', 'july',
  'august', 'september', 'october', 'november', 'december'];

const CATEGORIAS = ['staff', 'softwares', 'others'];

// Anclas conocidas (normalizadas) -> accion.
const ANCLAS = {
  'revenue': 'revenue',
  'total revenue': 'total_revenue',
  'expenses': 'expenses',
  'staff': 'categoria',
  'softwares': 'categoria',
  'others': 'categoria',
  'total expenses': 'total_expenses',
  'net cash flow': 'net_cash_flow',
  '% net cash flow': 'pct_net_cash_flow',
  'dividends released': 'dividends',
  'retained earnings': 'retained',
  'retained earning': 'retained',
  'opening balance:': 'opening',
  'closing balance:': 'closing',
};

export function etiqueta(fila, b) {
  const a = texto(fila[b]);
  if (a !== null && parseMonto(a) === null) return a;
  const c = fila[b + 1];
  if (typeof c === 'string' && texto(c) !== null && parseMonto(c) === null) return texto(c);
  return a;
}

export function montoDe(fila, b) {
  if (!esVacio(fila[b + 2])) return { crudo: fila[b + 2], col: b + 2 };
  if (!esVacio(fila[b + 3])) return { crudo: fila[b + 3], col: b + 3 };
  return null;
}

// Fila de cada ancla de categoria en los bloques que la tienen. Sirve para
// saber donde empezaria una categoria que falta en un mes puntual.
function filasDeCategoria(matriz, filaMeses, bloques) {
  const votos = {};
  for (const { col } of bloques) {
    for (let r = filaMeses + 1; r < matriz.length; r++) {
      const n = normalizar(etiqueta(matriz[r] || [], col));
      if (CATEGORIAS.includes(n)) (votos[r] ||= {})[n] = ((votos[r] || {})[n] || 0) + 1;
    }
  }
  const mapa = {};
  for (const [r, v] of Object.entries(votos)) {
    mapa[r] = Object.entries(v).sort((x, y) => y[1] - x[1])[0][0];
  }
  return mapa;
}

function parseBloque(matriz, filaMeses, b, mes, anio, out, mapaCategorias) {
  const nombreMes = MESES[mes - 1];
  const ctrl = { mes, total_revenue: null, total_expenses: null, retained: null, net_cash_flow: null, anclas: [] };
  const saldo = { anio, mes, opening_balance: null, closing_balance: null, dividends_released: null };
  const revisar = (motivo, extra = {}) => out.revisar.push({ mes, motivo, ...extra });
  const rechazar = (nro, motivo, crudo, fila) => {
    out.rechazadas.push({
      fila_planilla: nro, motivo,
      valor_crudo: crudo === null || crudo === undefined ? null : String(crudo),
      comprobante: null, metodo_pago: null,
      contenido_crudo: { mes: nombreMes, columna: b + 1, celdas: (fila || []).slice(b, b + 4) },
    });
  };

  // Categorias presentes en este bloque.
  const presentes = new Set();
  for (let r = filaMeses + 1; r < matriz.length; r++) {
    const n = normalizar(etiqueta(matriz[r] || [], b));
    if (CATEGORIAS.includes(n)) presentes.add(n);
  }

  let zona = 'inicio';
  let categoria = null;
  for (let r = filaMeses + 1; r < matriz.length; r++) {
    const fila = matriz[r] || [];
    const nro = r + 1;
    const lab = etiqueta(fila, b);
    const m = montoDe(fila, b);
    const accion = lab ? ANCLAS[normalizar(lab)] : undefined;
    const valorAncla = m ? parseMonto(m.crudo) : null;

    if (accion) {
      ctrl.anclas.push(normalizar(lab));
      switch (accion) {
        case 'revenue': zona = 'revenue'; categoria = 'revenue'; break;
        case 'total_revenue': ctrl.total_revenue = valorAncla; zona = 'post_revenue'; categoria = null; break;
        case 'expenses': zona = 'gastos'; categoria = 'sin_categoria'; break;
        case 'categoria': zona = 'gastos'; categoria = normalizar(lab); break;
        case 'total_expenses': ctrl.total_expenses = valorAncla; zona = 'post_gastos'; categoria = null; break;
        case 'net_cash_flow': ctrl.net_cash_flow = valorAncla; break;
        case 'dividends': saldo.dividends_released = valorAncla; break;
        case 'retained': ctrl.retained = valorAncla; zona = 'reparto'; break;
        case 'opening': saldo.opening_balance = valorAncla; break;
        case 'closing': saldo.closing_balance = valorAncla; zona = 'fin'; break;
        default: break;
      }
      continue;
    }

    // Categoria ausente en este mes: desde la fila donde otros meses la
    // tienen, los items quedan 'sin_categoria' (no se meten en la anterior).
    const catOtroMes = mapaCategorias[r];
    if (zona === 'gastos' && catOtroMes && !presentes.has(catOtroMes)) categoria = 'sin_categoria';

    if (zona === 'inicio' || !m) continue;   // fila 'Item'/'Price', o item sin monto
    const n = parseMonto(m.crudo);

    if (n === null) {
      if (esAmbiguo(m.crudo)) {
        // En cualquier zona: un numero que no sabemos que es no se carga nunca.
        rechazar(nro, MOTIVO_MONTO_AMBIGUO, m.crudo, fila);
        revisar(MOTIVO_MONTO_AMBIGUO, { fila_planilla: nro, item: lab, valor: String(m.crudo) });
      } else if (parseFecha(m.crudo)) {
        rechazar(nro, MOTIVO_FECHA_EN_MONTO, m.crudo, fila);
        revisar(MOTIVO_FECHA_EN_MONTO, { fila_planilla: nro, item: lab, valor: String(m.crudo) });
      } else if (['revenue', 'gastos', 'reparto'].includes(zona)) {
        rechazar(nro, 'monto no numerico', m.crudo, fila);
        revisar('monto no numerico', { fila_planilla: nro, item: lab, valor: String(m.crudo) });
      }
      continue;
    }

    if (zona === 'revenue' || zona === 'gastos') {
      if (n === 0 && !lab) continue;
      out.filas.push({
        anio, mes, categoria, item: lab, monto_usd: n,
        fila_planilla: nro, columna_planilla: m.col + 1,
      });
    } else if ((zona === 'reparto' || zona === 'fin') && !lab) {
      if (n === 0) continue;
      rechazar(nro, MOTIVO_REPARTO_SIN_BENEFICIARIO, m.crudo, fila);
    } else if (zona === 'reparto') {
      out.reparto.push({ anio, mes, beneficiario: lab, monto: n, fila_planilla: nro });
    } else if (n !== 0) {
      rechazar(nro, 'monto fuera de las anclas', m.crudo, fila);
      revisar('monto fuera de las anclas', { fila_planilla: nro, item: lab, valor: n });
    }
  }

  if (out.reparto.some((x) => x.mes === mes)) {
    // Las etiquetas Opening/Closing fueron reemplazadas por el reparto:
    // no se inventa un saldo.
    saldo.opening_balance = null;
    saldo.closing_balance = null;
  }
  out.saldos.push(saldo);
  out.controles.push(ctrl);
}

// Compara los items con los totales de la planilla. No bloquea: marca revisar.
function controlar(out) {
  for (const c of out.controles) {
    const delMes = out.filas.filter((f) => f.mes === c.mes);
    const suma = (arr) => redondear(arr.reduce((s, f) => s + f.monto_usd, 0), 6);
    c.suma_revenue = suma(delMes.filter((f) => f.categoria === 'revenue'));
    c.suma_gastos = suma(delMes.filter((f) => f.categoria !== 'revenue'));
    const rep = out.reparto.filter((x) => x.mes === c.mes);
    c.suma_reparto = rep.length ? redondear(rep.reduce((s, x) => s + x.monto, 0), 6) : null;

    const comparar = (control, items, planilla) => {
      if (Math.abs(items - (planilla ?? 0)) > MARGEN) {
        out.revisar.push({ mes: c.mes, motivo: 'descuadre', control, items, planilla, diferencia: redondear(items - (planilla ?? 0), 2) });
      }
    };
    if (!c.anclas.includes('total expenses')) out.revisar.push({ mes: c.mes, motivo: "falta 'Total Expenses'" });
    if (!c.anclas.includes('total revenue')) out.revisar.push({ mes: c.mes, motivo: "falta 'Total Revenue'" });
    comparar('total_expenses', c.suma_gastos, c.total_expenses);
    comparar('total_revenue', c.suma_revenue, c.total_revenue);
    if (c.suma_reparto !== null) comparar('retained_earnings', c.suma_reparto, c.retained);
  }
  const meses = new Set(out.revisar.map((x) => x.mes));
  for (const c of out.controles) c.estado = meses.has(c.mes) ? 'revisar' : 'ok';
  out.estado = meses.size ? 'revisar' : 'ok';
}

export function parseOpps(matriz, config = {}) {
  const out = {
    filas: [], saldos: [], reparto: [], rechazadas: [], controles: [], revisar: [],
    estado: null, avisos: [], error: null, encabezado: [],
  };
  const anio = config.anio;
  if (!Number.isInteger(anio)) { out.error = 'config.anio es obligatorio para Opps'; return out; }
  if (!Array.isArray(matriz)) { out.error = 'matriz vacia'; return out; }

  const filaMeses = matriz.findIndex((f) => Array.isArray(f) && f.some((v) => normalizar(v) === 'january'));
  if (filaMeses === -1) { out.error = "no se encontro la fila de meses ('JANUARY')"; return out; }

  const bloques = [];
  matriz[filaMeses].forEach((v, k) => {
    const i = MESES.indexOf(normalizar(v));
    if (i > -1 && k >= 2) bloques.push({ mes: i + 1, col: k });
  });
  out.encabezado = bloques.map((x) => `${MESES[x.mes - 1]}@${x.col}`);
  if (bloques.length !== 12) out.avisos.push(`se esperaban 12 bloques mensuales y hay ${bloques.length}`);
  if (new Set(bloques.map((x) => x.mes)).size !== bloques.length) {
    out.error = 'hay meses repetidos en el encabezado';
    return out;
  }

  const mapa = filasDeCategoria(matriz, filaMeses, bloques);
  for (const { mes, col } of bloques) parseBloque(matriz, filaMeses, col, mes, anio, out, mapa);
  controlar(out);
  return out;
}
