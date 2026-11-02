/* Datos del Cierre de mes (migración 269). Solo fundador: lo exige la base (RLS, vistas y funciones con es_fundador()). */
import { sb } from './supabase.js';
import { esFundador } from './sesion.js';

export const veCierre = () => esFundador();

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

export const PAGADORES = [['dystopia', 'Dystopia'], ['cliente', 'El cliente'], ['otro', 'Otro']];
export const TIPOS_MANUALES = [['editor', 'Editor'], ['equipo', 'Equipo'], ['comision', 'Comisión'], ['otro', 'Otro']];
export const TIPOS = { sueldo: 'Sueldo', comision: 'Comisión', editor: 'Editor', equipo: 'Equipo', socio: 'Socio', cliente: 'Cliente a Dystopia', otro: 'Otro' };
export const AVISOS = {
  pago_sin_fuente: 'Pagos sin fuente', sin_closer: 'Ventas sin closer', sin_setter: 'Ventas sin setter',
  sin_gastos: 'Clientes sin gastos cargados', sin_porcentaje: 'Clientes sin % de Dystopia',
  comision_desde_opps: 'Comisiones tomadas de Opps (el mes no tiene comisiones calculadas: tocá «Calcular transferencias»)',
  transferencia_pendiente: 'Transferencias pendientes', diferencia_con_calculo: 'Transferencias hechas con otro monto que el calculado'
};

export const mesISO = ym => `${ym}-01`;

export async function estadoMes(ym) {
  const { data, error } = await sb.from('fin_cierre_meses').select('*').eq('mes', mesISO(ym)).maybeSingle();
  if (error) throw error;
  return data;
}
export const logMes = ym => todas(() => sb.from('fin_cierre_log').select('*').eq('mes', mesISO(ym)).order('en', { ascending: false }));
export const transferencias = ym =>
  todas(() => sb.from('fin_cierre_transferencias').select('*').eq('mes', mesISO(ym)).order('tipo').order('destinatario').order('id'));
export const ventasMes = ym =>
  todas(() => sb.from('fin_v_cierre_ventas').select('*').eq('mes', mesISO(ym)).order('cliente_id').order('fecha').order('pago_clave'));
export const avisosMes = ym => todas(() => sb.from('fin_v_cierre_avisos').select('*').eq('mes', mesISO(ym)));
export const socios = () => todas(() => sb.from('fin_cierre_socios').select('*').order('desde', { ascending: false }).order('id'));
export const parametros = () => todas(() => sb.from('fin_cierre_parametros').select('*'));
export const pctPersonas = () => todas(() => sb.from('fin_cierre_comision_persona').select('*').order('persona_norm').order('rol'));

/* ---------- Escrituras ---------- */
export const generar = async ym => { const { data, error } = await sb.rpc('fin_cierre_generar', { p_mes: mesISO(ym) }); if (error) throw error; return data; };
export const cerrarMes = async (ym, nota) => ok(await sb.rpc('fin_cierre_cerrar', { p_mes: mesISO(ym), p_nota: nota || null }));
export const reabrirMes = async (ym, nota) => ok(await sb.rpc('fin_cierre_reabrir', { p_mes: mesISO(ym), p_nota: nota || null }));

export async function transferenciaGuardar(id, campos) {
  ok(await (id ? sb.from('fin_cierre_transferencias').update({ ...campos, actualizado_en: new Date().toISOString() }).eq('id', id)
    : sb.from('fin_cierre_transferencias').insert(campos)));
}
export async function socioGuardar(id, campos) {
  ok(await (id ? sb.from('fin_cierre_socios').update(campos).eq('id', id) : sb.from('fin_cierre_socios').insert(campos)));
}
export async function parametroGuardar(clave, valor) {
  ok(await sb.from('fin_cierre_parametros').update({ valor }).eq('clave', clave));
}
/* El índice único de la persona usa coalesce(cliente_id): no sirve para upsert, así que se actualiza por id o se inserta. */
export async function pctPersonaGuardar(id, campos) {
  ok(await (id ? sb.from('fin_cierre_comision_persona').update(campos).eq('id', id) : sb.from('fin_cierre_comision_persona').insert(campos)));
}
export const pctPersonaBorrar = async id => ok(await sb.from('fin_cierre_comision_persona').delete().eq('id', id));
/* % de una venta: porcentaje null = volver al de la persona / por defecto. */
export async function pctVentaGuardar(v, porcentaje) {
  if (porcentaje == null) {
    ok(await sb.from('fin_cierre_comision_venta').delete().eq('cliente_id', v.cliente_id).eq('pago_clave', v.pago_clave).eq('rol', v.rol));
    return;
  }
  ok(await sb.from('fin_cierre_comision_venta').upsert(
    { mes: v.mes, cliente_id: v.cliente_id, pago_clave: v.pago_clave, rol: v.rol, porcentaje }, { onConflict: 'cliente_id,pago_clave,rol' }));
}
