/* Lecturas de Supabase (la app es de SOLO LECTURA sobre los datos
   sincronizados) y los helpers de formato y de link a celda.
   fin_reparto no se lee en ninguna parte de esta app: son las comisiones de
   la agencia y quedan solo para el fundador fuera de toda pantalla. */
import { sb } from './supabase.js';
import { esc } from './ui.js';

/* ---------- Lecturas ---------- */

/* PostgREST corta en 1000 filas: se pagina hasta traer todo. */
async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}

/* Fuentes (solo fundador por RLS: para el resto vuelve vacío y los números
   se muestran sin link, con el número de fila). */
let fuentesCache = null;
export async function fuentes() {
  if (fuentesCache) return fuentesCache;
  const { data, error } = await sb.from('fin_fuentes')
    .select('id,cliente_id,spreadsheet_id,gid,nombre_hoja_esperado,tipo,activo');
  if (error) { console.warn('fin_fuentes', error.message); return new Map(); }
  fuentesCache = new Map((data || []).map(f => [f.id, f]));
  return fuentesCache;
}

export const pnlMensual = () =>
  todas(() => sb.from('fin_v_pnl_mensual').select('*').order('anio').order('mes'));

export const conciliacion = () =>
  todas(() => sb.from('fin_v_conciliacion').select('*').order('anio').order('mes'));

export const cobranzas = () =>
  todas(() => sb.from('fin_v_cobranzas').select('*').order('fecha_pago', { ascending: true, nullsFirst: false }));

/* fin_v_cobranzas no trae fuente_id: se completa desde fin_cuotas (misma RLS). */
export async function fuentePorCuota() {
  const filas = await todas(() => sb.from('fin_cuotas').select('id,fuente_id'));
  return new Map(filas.map(f => [f.id, f.fuente_id]));
}

export const salud = async () => {
  const { data, error } = await sb.from('fin_v_salud_sync').select('*').order('cliente_id').order('tipo');
  if (error) throw error;
  return data || [];
};

export async function corridas(fuenteId, limite = 10) {
  const { data, error } = await sb.from('fin_sync_corridas')
    .select('id,inicio,fin,estado,filas_leidas,filas_cargadas,filas_rechazadas,filas_descartadas,mensaje')
    .eq('fuente_id', fuenteId).order('inicio', { ascending: false }).limit(limite);
  if (error) throw error;
  return data || [];
}

export async function rechazadas(corridaId) {
  const { data, error } = await sb.from('fin_filas_rechazadas')
    .select('fila_planilla,motivo,valor_crudo,comprobante,metodo_pago')
    .eq('corrida_id', corridaId).order('fila_planilla').limit(500);
  if (error) throw error;
  return data || [];
}

export function pnlItems(clienteId, anio, mes) {
  let q = () => {
    let x = sb.from('fin_pnl').select('id,fuente_id,anio,mes,categoria,item,monto_usd,fila_planilla,columna_planilla')
      .eq('cliente_id', clienteId).eq('anio', anio);
    if (mes) x = x.eq('mes', mes);
    return x.order('mes').order('fila_planilla');
  };
  return todas(q);
}

const COLS_PAGO = 'id,cliente_id,fuente_id,fila_planilla,fecha,programa,alumno,concepto,monto_usd,monto_origen,moneda_origen,closer,setter,metodo_pago';

/* Pagos de un mes (o de todo el año si mes = null). clienteId null = todos los visibles. */
export function pagos({ clienteId = null, anio, mes = null }) {
  const desde = `${anio}-${String(mes || 1).padStart(2, '0')}-01`;
  const hasta = mes ? finDeMes(anio, mes) : `${anio}-12-31`;
  return todas(() => {
    let x = sb.from('fin_pagos').select(COLS_PAGO).gte('fecha', desde).lte('fecha', hasta);
    if (clienteId) x = x.eq('cliente_id', clienteId);
    return x.order('fecha').order('fila_planilla');
  });
}

/* Todos los pagos visibles para el usuario (closer/setter: la RLS deja solo los suyos). */
export const pagosVisibles = () =>
  todas(() => sb.from('fin_pagos').select(COLS_PAGO).order('fecha', { ascending: false }));

export const rankingClosers = () =>
  todas(() => sb.from('fin_v_ranking_closers').select('*').order('anio').order('mes'));

/* Dispara la Edge Function (lee Google Sheets, escribe solo en Supabase). */
export async function sincronizarAhora(cuerpo = {}) {
  const { data, error } = await sb.functions.invoke('sincronizar', { body: cuerpo });
  if (error) {
    let detalle = error.message;
    try { const j = await error.context.json(); if (j && j.error) detalle = j.error; } catch { /* sin cuerpo */ }
    throw new Error(detalle);
  }
  return data;
}

/* ---------- Formato ---------- */

const fmtUSD0 = new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 });
const fmtUSD2 = new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 2 });

export function usd(n, { centavos = false } = {}) {
  if (n == null || isNaN(n)) return '—';
  return (centavos || !Number.isInteger(Number(n)) ? fmtUSD2 : fmtUSD0).format(Number(n));
}

export const MESES = ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio', 'Julio', 'Agosto',
  'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'];
export const MESES_CORTOS = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

export function finDeMes(anio, mes) {
  const d = new Date(Date.UTC(anio, mes, 0)).getUTCDate();
  return `${anio}-${String(mes).padStart(2, '0')}-${d}`;
}

export const CATEGORIAS = {
  revenue: 'Revenue', staff: 'Staff', softwares: 'Softwares', others: 'Others', sin_categoria: 'Sin categoría'
};

/* ---------- Link a la celda de la planilla ---------- */

export function columnaLetra(n) {
  let s = '';
  for (let k = Number(n) || 1; k > 0; k = Math.floor((k - 1) / 26)) s = String.fromCharCode(65 + ((k - 1) % 26)) + s;
  return s;
}

/* https://docs.google.com/spreadsheets/d/<id>/edit#gid=<gid>&range=A<fila> */
export function urlCelda(fuente, fila, columna = 1) {
  if (!fuente || !fuente.spreadsheet_id || fila == null) return '';
  return `https://docs.google.com/spreadsheets/d/${encodeURIComponent(fuente.spreadsheet_id)}/edit#gid=${fuente.gid}&range=${columnaLetra(columna)}${fila}`;
}

/* Un número con link a su celda. Sin fuente legible (no fundador), el número va
   solo, con la fila en el title para que igual se pueda ubicar. */
export function numCelda(texto, fuente, fila, columna = 1) {
  const url = urlCelda(fuente, fila, columna);
  const donde = fuente ? `${fuente.nombre_hoja_esperado}!${columnaLetra(columna)}${fila}` : `fila ${fila}`;
  if (!url) return `<span title="${esc(donde)}">${esc(texto)}</span>`;
  return `<a class="celda-link" href="${esc(url)}" target="_blank" rel="noopener" title="Abrir ${esc(donde)} en la planilla">${esc(texto)}</a>`;
}

/* Periodo con datos más reciente que no esté en el futuro. */
export function ultimoPeriodo(filas, hoyIso) {
  const [ha, hm] = hoyIso.split('-').map(Number);
  const pasados = filas.filter(f => f.anio < ha || (f.anio === ha && f.mes <= hm))
    .filter(f => Number(f.ingreso_real ?? f.revenue_pagos ?? 0) !== 0 || Number(f.revenue_declarado ?? f.revenue_opps ?? 0) !== 0);
  const base = pasados.length ? pasados : filas;
  if (!base.length) return { anio: ha, mes: hm };
  const u = base.reduce((a, b) => (b.anio * 12 + b.mes > a.anio * 12 + a.mes ? b : a));
  return { anio: u.anio, mes: u.mes };
}
