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

/* Cache corto de la vista más pesada (fin_v_pnl_mensual la piden Resumen, Cliente y
   Pagos): al cambiar de pantalla se reusa la misma respuesta unos segundos.
   Se limpia al escribir (RPC de esta app y de columnas.js) y al tocar "Recargar". */
const TTL_CACHE = 30000;
const cacheCorto = new Map();
export function limpiarCache() { cacheCorto.clear(); }
function conCache(clave, pedir) {
  const hit = cacheCorto.get(clave);
  if (hit && Date.now() - hit.t < TTL_CACHE) return hit.p.then(filas => [...filas]);
  const p = pedir();
  const ent = { t: Date.now(), p };
  cacheCorto.set(clave, ent);
  p.catch(() => { if (cacheCorto.get(clave) === ent) cacheCorto.delete(clave); });
  return p.then(filas => [...filas]);
}
if (typeof document !== 'undefined') {
  document.addEventListener('click', e => {
    if (e.target && e.target.closest && e.target.closest('#btn-recargar')) limpiarCache();
  }, true);
}

export const pnlMensual = () =>
  conCache('pnl_mensual', () => todas(() => sb.from('fin_v_pnl_mensual').select('*').order('anio').order('mes')));

/* Con el mismo cache corto de pnlMensual: volver a Conciliación (o entrar y recargar) no repite la consulta. */
export const conciliacion = () =>
  conCache('conciliacion', () => todas(() => sb.from('fin_v_conciliacion').select('*').order('anio').order('mes')));

/* Precarga en segundo plano (sin esperar ni propagar errores): la sesión ya pidió el P&L en Resumen,
   así que cuando el usuario entra a Conciliación la respuesta ya está en el cache. */
export function precargarConciliacion() { conciliacion().catch(() => {}); }

/* Cash collected por cliente / mes / categoría de concepto (032). */
export const cashPorConcepto = () =>
  todas(() => sb.from('fin_v_cash_collected_concepto')
    .select('cliente_id,anio,mes,categoria,pagos,monto_usd').order('anio').order('mes').order('cliente_id').order('categoria'));

export const cobranzas = () =>
  todas(() => sb.from('fin_v_cobranzas').select('*').order('fecha_pago', { ascending: true, nullsFirst: false }));

/* Pagos con alumno, programa y closer: base para completar Programa y Closer de las cuotas (116). */
export const pagosParaCuotas = () =>
  todas(() => sb.from('fin_pagos').select('cliente_id,fecha,alumno,programa,closer').order('fecha', { ascending: false }));

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
    .select('*')
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

/* ---------- Grilla de Pagos (fase 5, solo lectura) ---------- */

const COLS_PAGO_GRILLA = 'id,cliente_id,fuente_id,fila_planilla,clave,origen,fecha,alumno,telefono,monto_usd,closer,setter,comprobante,comprobantes_extra,nota,email,fuente_email,fuente_lead,fuente_ingreso,pago_original_clave,'
  + 'programa,programa_id,concepto,concepto_id,metodo_pago,metodo_pago_id,quien_recibe,quien_recibe_id';

/* Algún *_id sin resolver con texto crudo en la columna (lo mismo que cuenta fin_v_alias_pendientes). */
const PENDIENTE_CATALOGO = ['programa', 'concepto', 'metodo_pago', 'quien_recibe']
  .map(c => `and(${c}_id.is.null,${c}.not.is.null)`).join(',');

/* Una página de pagos con el total exacto. Los filtros van en la query: hay
   más de 1000 filas y PostgREST corta ahí. mes null = todo el año.
   conceptoIds: ids de fin_catalogos (dimensión concepto), null = sin filtro. */
export async function pagosGrilla({ clienteId = null, anio, mes = null, conceptoIds = null, fuenteIngreso = null, soloPendientes = false, pagina = 0, porPagina = 50 }) {
  const desde = `${anio}-${String(mes || 1).padStart(2, '0')}-01`;
  const hasta = mes ? finDeMes(anio, mes) : `${anio}-12-31`;
  let x = sb.from('fin_pagos').select(COLS_PAGO_GRILLA, { count: 'exact' }).gte('fecha', desde).lte('fecha', hasta);
  if (clienteId) x = x.eq('cliente_id', clienteId);
  if (conceptoIds) x = x.in('concepto_id', conceptoIds);
  if (fuenteIngreso) x = fuenteIngreso === '__sin' ? x.is('fuente_ingreso', null) : x.eq('fuente_ingreso', fuenteIngreso);
  if (soloPendientes) x = x.or(PENDIENTE_CATALOGO);
  const { data, error, count } = await x
    .order('fecha', { ascending: false }).order('fila_planilla', { ascending: false }).order('id')
    .range(pagina * porPagina, pagina * porPagina + porPagina - 1);
  if (error) throw error;
  return { filas: data || [], total: count ?? 0 };
}

/* ---------- Carga, anulación y devolución de pagos (fase 6, RPC de la 066) ---------- */
/* Las RPC validan permisos y datos: el mensaje de error se muestra tal cual. */
async function rpc(nombre, args, escribe = true) {
  if (escribe) limpiarCache();
  const { data, error } = await sb.rpc(nombre, args);
  if (error) throw error;
  return data;
}

export const cargaOpciones = clienteId => rpc('fin_carga_opciones', { p_cliente: clienteId }, false);
export const pagoCargar = p => rpc('fin_pago_cargar', { p });
/* 075: alta de una opción de concepto, método de pago o quién recibe (devuelve {id, valor, nuevo}). */
export const catalogoAgregar = (clienteId, dimension, valor) =>
  rpc('fin_catalogo_agregar', { p_cliente: clienteId, p_dimension: dimension, p_valor: valor });
/* 116: alta de un closer nuevo (o asignación de uno existente) al cliente. Devuelve {id, nombre, nuevo, ya_asignado}. */
export const closerAgregar = (clienteId, nombre, esPersona = true) =>
  rpc('fin_closer_agregar', { p_cliente: clienteId, p_nombre: nombre, p_es_persona: esPersona });
export const pagoAnular = (clave, motivo) => rpc('fin_pago_anular', { p_clave: clave, p_motivo: motivo });
export const pagoDevolver = (clave, monto, fecha, motivo) =>
  rpc('fin_pago_devolver', { p_clave: clave, p_monto: monto, p_fecha: fecha, p_motivo: motivo });

/* Alertas de cobros a Discord (103, solo fundador: las RPC lo verifican). La vista previa NO envía. */
export const alertasCobrosEstado = () => rpc('fin_alertas_cobros_estado', {}, false);
export const alertasCobrosGuardar = (cliente, activo, hora, montos, hora2 = null) =>
  rpc('fin_alertas_cobros_config_guardar',
    { p_cliente: cliente, p_activo: activo, p_hora: hora, p_montos: montos, p_hora_2: hora2 });
export const alertasCobrosVistaPrevia = (cliente, semana = null) =>
  rpc('fin_alertas_cobros_vista_previa', { p_cliente: cliente, p_semana: semana }, false);

/* Vincular alumnos con su ficha de Producto (129). Las RPC verifican el permiso (fundador o quien edita
   pagos del cliente) y no traen montos. accion: 'vincular' (con csId) | 'desvincular' | 'no_producto'. */
export const vinculosResumen = cliente => rpc('fin_cs_resumen', { p_cliente: cliente }, false);
export const vinculosLista = (cliente, filtro) => rpc('fin_cs_lista', { p_cliente: cliente, p_filtro: filtro }, false);
export const vinculosBuscar = (cliente, q) => rpc('fin_cs_buscar', { p_cliente: cliente, p_q: q }, false);
export const vinculosMarcar = (cliente, alumnoNorm, accion, csId = null) =>
  rpc('fin_cs_marcar', { p_cliente: cliente, p_alumno_norm: alumnoNorm, p_accion: accion, p_cs_cliente_id: csId });
export const vinculosAuto = cliente => rpc('fin_cs_vincular_auto', { p_cliente: cliente });

/* Catálogos de Pagos (064) en un solo select; se resuelven en el cliente. */
export const catalogos = () =>
  todas(() => sb.from('fin_catalogos').select('id,cliente_id,dimension,valor')
    .in('dimension', ['programa', 'concepto', 'metodo_pago', 'quien_recibe']).order('id'));

/* Textos del Sheet sin valor de catálogo, por cliente y columna (064). */
export const aliasPendientes = () =>
  todas(() => sb.from('fin_v_alias_pendientes').select('cliente_id,columna,crudo,pagos,usd')
    .order('usd', { ascending: false }).order('cliente_id').order('columna').order('crudo'));

/* max(fecha) de fin_pagos por cliente: una fila por cliente, sin traer los pagos. */
export async function ultimoPagoPorCliente(clienteIds) {
  const pares = await Promise.all(clienteIds.map(async id => {
    const { data, error } = await sb.from('fin_pagos').select('fecha')
      .eq('cliente_id', id).order('fecha', { ascending: false }).limit(1);
    if (error) throw error;
    return [id, data && data[0] ? data[0].fecha : null];
  }));
  return new Map(pares);
}

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
  revenue: 'Revenue', staff: 'Personal', softwares: 'Software', others: 'Otros', sin_categoria: 'Sin categoría'
};

/* Net cash flow = Ingreso real (Pagos) - Gastos en TODOS los meses. La vista usa Opps
   como ingreso antes del primer pago de cada cliente (063); acá no se mezclan fuentes:
   el mes sin pagos se avisa con sinPagosCargados(). */
export const netCashFlow = f => (Number(f.ingreso_real) || 0) - (Number(f.gastos_total) || 0);
export const sinPagosCargados = f => f.fuente_ingreso === 'opps' && !(Number(f.ingreso_real) || 0) && (Number(f.revenue_declarado) || 0) !== 0;

/* Mes con pagos pero con Opps vacío (revenue y gastos en 0): Opps todavía no se cargó, así que
   el net cash flow (Pagos − 0 gastos) sale inflado. Se avisa, no se corrige. */
export const oppsSinCargar = f => !f.vacio && (Number(f.ingreso_real) || 0) !== 0
  && !(Number(f.revenue_declarado) || 0) && !(Number(f.gastos_total) || 0);

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
