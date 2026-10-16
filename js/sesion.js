/* Usuario actual: rol (de crm_members, igual que Dystopia y Seguimiento) y
   clientes visibles. La RLS recorta todo lo demás: esta app nunca decide
   permisos, solo qué pantallas ofrecer.
   075: el rol también es el ÁREA (finanzas, ventas, producto, contenido) en los
   clientes que están en fin_clientes_areas (hoy liam). producto y contenido no
   entran a Finanzas. */
import { sb } from './supabase.js';
import { lecturaClientes } from './lectura.js';

/* carga: filas de fin_clientes_carga() {cliente_id, habilitada, puede_anular, puede_extras}.
   areas: clientes con permisos por área (fin_clientes_por_areas, 075). */
/* comp: filas de fin_comp_clientes() {cliente_id, nombre, puede_confirmar} (143): clientes donde sube comprobantes.
   lectura: filas de fin_lectura_clientes() {cliente_id, nombre} (148): clientes con "Lectura del mes". */
export const yo = { userId: null, email: '', rol: null, nombre: '', clientes: [], carga: [], areas: [], comp: [], lectura: [] };

const ROLES = ['fundador', 'cliente', 'closer', 'setter', 'finanzas', 'ventas'];
/* Mismo orden que las cuentas en Dystopia. */
const ORDEN = ['liam', 'agus', 'teo'];

async function cargarClientes() {
  const { data, error } = await sb.from('crm_clients').select('id,nombre,color,orden');
  if (error) { console.warn('crm_clients', error.message); return []; }
  const pos = id => { const i = ORDEN.indexOf(id); return i < 0 ? ORDEN.length : i; };
  return (data || []).sort((a, b) => (pos(a.id) - pos(b.id)) || String(a.nombre).localeCompare(b.nombre, 'es'));
}

/* Clientes donde el usuario puede cargar pagos (066). Si falla, no se ofrece la carga. */
async function cargarCarga() {
  const { data, error } = await sb.rpc('fin_clientes_carga');
  if (error) { console.warn('fin_clientes_carga', error.message); return []; }
  return data || [];
}

/* Clientes con permisos por área (075). Si la 075 no está corrida, ninguno. */
async function cargarAreas() {
  const { data, error } = await sb.rpc('fin_clientes_por_areas');
  if (error) { console.warn('fin_clientes_por_areas', error.message); return []; }
  return (data || []).map(x => (typeof x === 'string' ? x : Object.values(x)[0]));
}

/* Clientes donde el usuario sube comprobantes de pago (143). Si la 143 no está corrida, ninguno. */
async function cargarComp() {
  const { data, error } = await sb.rpc('fin_comp_clientes');
  if (error) { console.warn('fin_comp_clientes', error.message); return []; }
  return data || [];
}

/* Devuelve true si el usuario puede usar la app. */
export async function cargarSesion(user) {
  yo.userId = user.id;
  yo.email = user.email || '';
  const { data: mem, error } = await sb.from('crm_members')
    .select('rol,nombre').eq('user_id', user.id).maybeSingle();
  if (error) throw error;
  yo.rol = mem ? mem.rol : null;
  yo.nombre = (mem && mem.nombre) || yo.email;
  if (!ROLES.includes(yo.rol)) return false;
  [yo.clientes, yo.carga, yo.areas, yo.comp, yo.lectura] = await Promise.all([cargarClientes(), cargarCarga(), cargarAreas(), cargarComp(), lecturaClientes()]);
  return true;
}

export const esFundador = () => yo.rol === 'fundador';
/* Cliente al que se limita un usuario que no es fundador y tiene uno solo; si no, null.
   Solo para textos de interfaz: no cambia permisos ni datos. */
export const clienteUnico = () => (!esFundador() && yo.clientes.length === 1 ? yo.clientes[0] : null);
/* Cliente de un cliente por áreas que no carga pagos: ve solo el panel, solo lectura. */
export const soloPanel = () => yo.rol === 'cliente' && yo.areas.length > 0 && yo.carga.length === 0
  && yo.clientes.length > 0 && yo.clientes.every(c => yo.areas.includes(c.id));
/* P&L (y con él el bloque Staff = sueldos): fundador, cliente y finanzas. */
export const veFinanzas = () => ['fundador', 'cliente', 'finanzas'].includes(yo.rol);
/* Conciliación y Cash por concepto: lo ve quien ve Finanzas, menos el cliente de solo panel. */
export const veAnalisis = () => veFinanzas() && !soloPanel();
export const veCobranzas = () => !['setter', 'ventas'].includes(yo.rol) && !soloPanel();
export const veMisNumeros = () => yo.rol !== 'ventas' && !soloPanel();
export const esEquipo = () => yo.rol === 'closer' || yo.rol === 'setter';
/* Carga de pagos: cualquiera con al menos un cliente en fin_clientes_carga(). */
export const puedeCargar = () => yo.carga.length > 0;
/* Grilla de Pagos: fundador, o cliente/finanzas con sus clientes de fin_clientes_carga(). */
export const vePagos = () => esFundador() || ((yo.rol === 'cliente' || yo.rol === 'finanzas') && puedeCargar());
export const puedeAnular = clienteId => yo.carga.some(c => c.cliente_id === clienteId && c.puede_anular);
/* Vincular alumnos con Producto (129): quien puede editar pagos (fundador, o cliente en clientes sin áreas). */
export const clientesVinculables = () => yo.carga.filter(c => c.puede_anular).map(c => c.cliente_id);
export const puedeVincular = () => clientesVinculables().length > 0;
/* Comprobantes (143): sube quien tiene algún cliente en fin_comp_clientes(); confirma fundador y finanzas. */
export const puedeSubirComprobante = () => yo.comp.length > 0;
export const puedeConfirmarComprobante = () => yo.comp.some(c => c.puede_confirmar);
export const confirmaComprobante = clienteId => yo.comp.some(c => c.cliente_id === clienteId && c.puede_confirmar);
/* Pantalla mínima "Subir comprobante": quien sube pero no confirma (closer, setter, cliente). */
export const soloSubeComprobante = () => puedeSubirComprobante() && !puedeConfirmarComprobante();
/* Lectura del mes con IA (148): solo fundador y finanzas, en los clientes que ven (fin_lectura_clientes). */
/* Chat interno / Dystopita: todos los roles que entran a Finanzas (los permisos de datos los impone la base). */
export const puedeUsarChatIa = () => ROLES.includes(yo.rol);
export const puedeVerLectura = () => ['fundador', 'finanzas'].includes(yo.rol) && yo.lectura.length > 0;
/* Valores de las columnas nuevas: en un cliente por áreas solo fundador (075). */
export const puedeExtras = clienteId => yo.carga.some(c => c.cliente_id === clienteId && c.puede_extras !== false);

export function cliente(id) {
  return yo.clientes.find(c => c.id === id) || { id, nombre: id, color: null };
}

export function nombreCliente(id) {
  return cliente(id).nombre || id;
}

export function rutaInicio() {
  if (yo.rol === 'ventas') return 'cargar';
  return esEquipo() ? 'mis-numeros' : 'resumen';
}

export function etiquetaRol() {
  return {
    fundador: 'Fundador', cliente: soloPanel() ? 'Cliente · solo lectura' : 'Cliente', closer: 'Closer', setter: 'Setter',
    finanzas: 'Finanzas', ventas: 'Ventas'
  }[yo.rol] || '';
}
