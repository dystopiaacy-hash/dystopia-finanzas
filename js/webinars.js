/* Datos del apartado Webinars (migración 267). Lee fin_v_webinar_resultado (ingresos, gastos y resultado ya calculados)
   y las tablas fin_webinar_* para el detalle. Escribe con las policies de fin_gastos_puede_editar (fundador). */
import { sb } from './supabase.js';

export const CONCEPTOS = [
  ['ads_webinar', 'Ads webinar'], ['ads_replay', 'Ads replay'], ['zoom', 'Zoom'], ['landing', 'Landing'],
  ['ghl', 'GHL (mails / workflows)'], ['manychat', 'ManyChat'], ['whatsapp', 'WhatsApp'], ['addevent', 'AddEvent'],
  ['comision_closer', 'Comisión closer'], ['otros', 'Otros']
];
export const nombreConcepto = c => (CONCEPTOS.find(x => x[0] === c) || [c, c])[1];
export const TIPOS_AJUSTE = [['venta_probable', 'Venta probable (no es cash)'], ['pago_sin_fuente', 'Pago sin fuente asignado a mano'], ['otro', 'Otro ingreso']];
export const nombreTipo = t => (TIPOS_AJUSTE.find(x => x[0] === t) || [t, t])[1];

async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}
const ok = ({ error }) => { if (error) throw error; };

export const webinarsResultado = () =>
  todas(() => sb.from('fin_v_webinar_resultado').select('*').order('fecha', { ascending: false }).order('webinar_id'));
export const webinarGastos = id =>
  todas(() => sb.from('fin_webinar_gastos').select('*').eq('webinar_id', id).order('fecha').order('id'));
export const webinarAjustes = id =>
  todas(() => sb.from('fin_webinar_ajustes').select('*').eq('webinar_id', id).order('id'));
export const webinarReglas = () =>
  todas(() => sb.from('fin_webinar_reglas').select('*').order('cliente_id').order('concepto'));

/* Pagos de la ventana que no tienen fuente FINAL (regla de la 271/273: fin_v_pago_fuente), candidatos a asignar a mano.
   fuente_planilla = lo que trae la hoja, para auditar cuando la marca no valió. */
export async function pagosSinFuente(cliente, desde, hasta) {
  const filas = await todas(() => sb.from('fin_v_pago_fuente').select('pago_id, pago_clave, fecha, alumno, concepto, monto_usd, fuente_planilla')
    .eq('cliente_id', cliente).gte('fecha', desde).lte('fecha', hasta).is('fuente_final', null)
    .not('pago_clave', 'is', null).order('fecha').order('pago_id'));
  return filas.map(f => ({ ...f, clave: f.pago_clave }));
}

export async function webinarGuardar(id, campos) {
  ok(await (id ? sb.from('fin_webinars').update(campos).eq('id', id) : sb.from('fin_webinars').insert(campos)));
}
export async function webinarBaja(id) { ok(await sb.from('fin_webinars').update({ activo: false }).eq('id', id)); }
export async function gastoWebinarGuardar(id, campos) {
  ok(await (id ? sb.from('fin_webinar_gastos').update(campos).eq('id', id) : sb.from('fin_webinar_gastos').insert(campos)));
}
export async function gastoWebinarBaja(id, activo = false) { ok(await sb.from('fin_webinar_gastos').update({ activo }).eq('id', id)); }
export async function ajusteGuardar(id, campos) {
  ok(await (id ? sb.from('fin_webinar_ajustes').update(campos).eq('id', id) : sb.from('fin_webinar_ajustes').insert(campos)));
}
export async function ajusteBaja(id, activo = false) { ok(await sb.from('fin_webinar_ajustes').update({ activo }).eq('id', id)); }

/* Reglas fijas (Zoom, landings) como gastos del webinar. Las que ya figuran (mismo concepto) no se repiten.
   en_opps: lo que ya está en Opps del mes (el Zoom de octubre) se marca solo si se pide. */
export async function cargarReglas(web, reglas, existentes, enOpps = {}) {
  const ya = new Set(existentes.filter(g => g.activo).map(g => g.concepto));
  const filas = reglas.filter(r => r.cliente_id === web.cliente_id && !ya.has(r.concepto)).map(r => ({
    webinar_id: web.webinar_id, concepto: r.concepto, monto_usd: r.monto_usd, fecha: web.fecha,
    fuente: 'Regla fija', nota: r.nota || null, en_opps: !!enOpps[r.concepto]
  }));
  if (filas.length) ok(await sb.from('fin_webinar_gastos').insert(filas));
  return filas.length;
}
