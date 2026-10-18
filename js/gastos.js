/* Datos de Dystopia, Gastos y gasto de IA (migración 174). Todo lo filtra la base (RLS y las vistas con
   permiso adentro); el front solo decide qué pantallas ofrecer. Montos de las vistas en USD. */
import { sb } from './supabase.js';
import { yo } from './sesion.js';

/* Entidades: los 3 clientes y la propia agencia. La IA que no se pudo asignar a un cliente es de la entidad
   'dystopia' con sin_asignar = true (se ve como «Sin asignar → Dystopia» pero suma en Dystopia). */
export const ENTIDADES = [['liam', 'Liam'], ['agus', 'Agus'], ['teo', 'Teo'], ['dystopia', 'Dystopia']];
export const nombreEntidad = id => (ENTIDADES.find(e => e[0] === id) || [id, id])[1];
export const nombreFila = f => (f.sin_asignar ? 'Sin asignar → Dystopia' : nombreEntidad(f.entidad));
export const REPARTOS = [['comision', 'Compartido según comisión'], ['cliente', '100% cliente'], ['dystopia', '100% Dystopia']];
export const nombreReparto = id => (REPARTOS.find(r => r[0] === id) || [id, id])[1];
export const PROVEEDORES = { claude: 'Claude', gemini: 'Gemini', otro: 'Otro' };

async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}

/* Permisos del usuario (fundador = todo; el resto, lo que diga fin_dys_acceso). Si la 174 no está corrida, nada. */
export async function cargarAccesoDys() {
  const { data, error } = await sb.rpc('fin_dys_mi_acceso');
  if (error) { console.warn('fin_dys_mi_acceso', error.message); return { dystopia: false, gastos: false, edita: false }; }
  const f = (data && data[0]) || {};
  return { dystopia: !!f.dystopia, gastos: !!f.gastos, edita: !!f.edita };
}
export const veDystopia = () => !!(yo.dys && yo.dys.dystopia);
export const veGastos = () => !!(yo.dys && yo.dys.gastos);
export const editaGastos = () => !!(yo.dys && yo.dys.edita);
/* La pantalla de IA la ve quien ve Dystopia o Gastos. */
export const veIaUso = () => veDystopia() || veGastos();

/* ---------- Lecturas ---------- */
export const dysMes = () =>
  todas(() => sb.from('fin_v_dys_mes').select('*').order('mes', { ascending: false }).order('entidad'));

export const gastosMes = () =>
  todas(() => sb.from('fin_v_gastos_mes').select('*').order('mes', { ascending: false }).order('entidad').order('categoria'));

export const iaUsoMes = () =>
  todas(() => sb.from('fin_v_ia_uso_mes').select('*').order('mes', { ascending: false }).order('entidad').order('proveedor'));

export const categorias = () =>
  todas(() => sb.from('fin_gasto_categorias').select('*').order('orden').order('nombre'));

/* Gastos manuales tal cual se cargaron (sin expandir recurrentes): para editar. */
export const gastosCargados = () =>
  todas(() => sb.from('fin_gastos').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }));

/* Último tipo de cambio usado en un gasto en pesos (para pre-llenar el formulario). */
export async function ultimoTipoCambio() {
  const { data, error } = await sb.from('fin_gastos').select('tipo_cambio')
    .eq('moneda', 'ARS').not('tipo_cambio', 'is', null).order('creado_en', { ascending: false }).limit(1);
  if (error) { console.warn('ultimoTipoCambio', error.message); return null; }
  return data && data[0] ? Number(data[0].tipo_cambio) : null;
}

/* ---------- Escrituras (RLS: solo quien edita gastos) ---------- */
export async function gastoGuardar(id, campos) {
  const q = id ? sb.from('fin_gastos').update(campos).eq('id', id) : sb.from('fin_gastos').insert(campos);
  const { error } = await q;
  if (error) throw error;
}
export const gastoBaja = async (id, activo) => {
  const { error } = await sb.from('fin_gastos').update({ activo }).eq('id', id);
  if (error) throw error;
};
export async function categoriaGuardar(id, campos) {
  const q = id ? sb.from('fin_gasto_categorias').update(campos).eq('id', id) : sb.from('fin_gasto_categorias').insert(campos);
  const { error } = await q;
  if (error) throw error;
}

/* ---------- Cuentas ---------- */
export const sumar = (filas, campo) => filas.reduce((a, f) => a + (Number(f[campo]) || 0), 0);
export const claveMes = m => String(m).slice(0, 7);   // 'YYYY-MM-01' -> 'YYYY-MM'
export function mesesDe(filas) {
  return [...new Set(filas.map(f => claveMes(f.mes)))].sort().reverse();
}
export function etiquetaMes(ym) {
  const [a, m] = ym.split('-');
  const nombres = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  return `${nombres[Number(m) - 1]} ${a}`;
}
