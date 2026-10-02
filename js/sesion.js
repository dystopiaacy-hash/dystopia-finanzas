/* Usuario actual: rol (de crm_members, igual que Dystopia y Seguimiento) y
   clientes visibles. La RLS recorta todo lo demás: esta app nunca decide
   permisos, solo qué pantallas ofrecer. */
import { sb } from './supabase.js';

/* carga: filas de fin_clientes_carga() {cliente_id, habilitada, puede_anular}. */
export const yo = { userId: null, email: '', rol: null, nombre: '', clientes: [], carga: [] };

const ROLES = ['fundador', 'cliente', 'closer', 'setter'];
/* Mismo orden que las cuentas en Dystopia. */
const ORDEN = ['liam', 'agus', 'teo', 'mauro', 'lucas'];

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
  [yo.clientes, yo.carga] = await Promise.all([cargarClientes(), cargarCarga()]);
  return true;
}

export const esFundador = () => yo.rol === 'fundador';
/* P&L (y con él el bloque Staff = sueldos): solo fundador y cliente. */
export const veFinanzas = () => yo.rol === 'fundador' || yo.rol === 'cliente';
export const veCobranzas = () => yo.rol !== 'setter';
export const esEquipo = () => yo.rol === 'closer' || yo.rol === 'setter';
/* Carga de pagos: cualquiera con al menos un cliente en fin_clientes_carga(). */
export const puedeCargar = () => yo.carga.length > 0;
/* Grilla de Pagos: fundador, o cliente con sus clientes de fin_clientes_carga(). */
export const vePagos = () => esFundador() || (yo.rol === 'cliente' && puedeCargar());
export const puedeAnular = clienteId => yo.carga.some(c => c.cliente_id === clienteId && c.puede_anular);

export function cliente(id) {
  return yo.clientes.find(c => c.id === id) || { id, nombre: id, color: null };
}

export function nombreCliente(id) {
  return cliente(id).nombre || id;
}

export function rutaInicio() {
  return esEquipo() ? 'mis-numeros' : 'resumen';
}

export function etiquetaRol() {
  return { fundador: 'Fundador', cliente: 'Cliente', closer: 'Closer', setter: 'Setter' }[yo.rol] || '';
}
