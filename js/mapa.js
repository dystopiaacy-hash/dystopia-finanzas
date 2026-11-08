/* Mapa (solo fundador): una tarjeta por área en el orden del recorrido del cliente, con números vivos.
   Solo lectura: nada se escribe desde acá. Datos y cuentas, sin DOM.
   De dónde sale cada número (para controlar contra Cierre / Comparar):
   - Marketing:   crm_publicaciones, estado_publicacion = 'PUBLICADO' y fecha_publicacion dentro del mes (como el dashboard del CRM).
   - Ventas:      fin_v_metricas_ventas (periodo = mes): agendadas, presentadas, cerradas. Clientes sin fila (Agus no tiene Data)
                  usan fin_cierres (cierres del mes con estado vacío o «Cliente», igual que Ventas) y quedan «sin dato» en llamadas.
   - Finanzas:    las mismas cuentas de Comparar (cargarMes/resumir de comparar.js): facturación y gastos del cliente de
                  fin_v_dys_ganancia_mes (mes cerrado = foto de fin_cierre_meses).
   - Dystopia:    ganancia_dystopia_usd de fin_v_dys_ganancia_mes (suma de los clientes elegidos).
   - Seguimiento: cs_clientes (programa_id = cliente) con estado activo / onboarding / en_renovacion. No depende del mes: es la foto de hoy. */
import { sb } from './supabase.js';
import { cargarBase, cargarMes, resumir } from './comparar.js';
import { esFundador } from './sesion.js';

export const veMapa = () => esFundador();   // mismo control que Cierre / Comparar

export const CLIENTES = [['liam', 'Liam'], ['agus', 'Agus'], ['teo', 'Teo']];

/* Texto editable de cada área: la regla en una frase y quién responde. Si responsable queda vacío no se muestra.
   Las URLs son las de js/nav-areas.js (dominios propios; los *.vercel.app siguen vivos como respaldo). */
export const AREAS = {
  marketing:   { titulo: 'Marketing',   regla: 'Cada pieza publicada tiene que traer gente nueva a la agenda.', responsable: '', url: 'https://mkt.dystopia.com.ar', abrir: 'Abrir Marketing' },
  ventas:      { titulo: 'Ventas',      regla: 'Toda llamada agendada se atiende, y toda venta queda cargada el mismo día.', responsable: '', url: 'https://ventas.dystopia.com.ar', abrir: 'Abrir Ventas' },
  finanzas:    { titulo: 'Finanzas',    regla: 'Lo cobrado y lo gastado del mes se cierra con números reales, no estimados.', responsable: '', ruta: '#/cierre', abrir: 'Abrir Cierre' },
  seguimiento: { titulo: 'Seguimiento', regla: 'Ningún alumno pasa más de una semana sin que alguien lo contacte.', responsable: '', url: 'https://producto.dystopia.com.ar', abrir: 'Abrir Seguimiento' },
  dystopia:    { titulo: 'Dystopia',    regla: 'La ganancia de la agencia es su porcentaje de lo que gana cada cliente.', responsable: '', ruta: '#/dystopia', abrir: 'Abrir Dystopia' }
};
export const PROXIMAMENTE = ['Setting', 'Dirección', 'Soporte'];

const SEGUIMIENTO_ACTIVOS = ['activo', 'onboarding', 'en_renovacion'];
const n = v => Number(v) || 0;
const redondear = v => Math.round(v * 100) / 100;

async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}

/* Cada lectura se protege sola: si falla o no existe, el área queda en «sin dato» y el resto sigue. */
async function seguro(nombre, fn) {
  try { return await fn(); } catch (e) { console.warn(`mapa ${nombre}:`, e && e.message ? e.message : e); return null; }
}

const finMes = ym => {
  const [a, m] = ym.split('-').map(Number);
  const sig = m === 12 ? `${a + 1}-01` : `${a}-${String(m + 1).padStart(2, '0')}`;
  return { desde: `${ym}-01`, hasta: `${sig}-01` };   // [desde, hasta)
};

export async function cargarBaseMapa() {
  return cargarBase();
}

async function marketing(ym, cli) {
  const { desde, hasta } = finMes(ym);
  const filas = await todas(() => {
    let q = sb.from('crm_publicaciones').select('cliente_id,plataforma')
      .eq('estado_publicacion', 'PUBLICADO').gte('fecha_publicacion', desde).lt('fecha_publicacion', hasta).order('id');
    if (cli) q = q.eq('cliente_id', cli);
    return q;
  });
  const porPlat = {};
  for (const f of filas) porPlat[f.plataforma] = (porPlat[f.plataforma] || 0) + 1;
  return { piezas: filas.length, porPlataforma: porPlat };
}

async function ventas(ym, cli) {
  const { desde, hasta } = finMes(ym);
  const [met, cierres] = await Promise.all([
    todas(() => {
      let q = sb.from('fin_v_metricas_ventas').select('cliente_id,periodo,agendadas,presentadas,cerradas,sin_show_up,agendadas_a_futuro').eq('periodo', ym).order('cliente_id');
      if (cli) q = q.eq('cliente_id', cli);
      return q;
    }),
    seguro('fin_cierres', () => todas(() => {
      let q = sb.from('fin_cierres').select('cliente_id,fecha_cierre,estado').gte('fecha_cierre', desde).lt('fecha_cierre', hasta).order('id');
      if (cli) q = q.eq('cliente_id', cli);
      return q;
    }))
  ]);
  const conLlamadas = new Set(met.map(f => f.cliente_id));
  const cuenta = f => { const e = String(f.estado ?? '').trim().toLowerCase(); return !e || e === 'cliente'; };
  /* Clientes sin llamadas cargadas: sus cierres salen de fin_cierres (como el dashboard de Ventas). */
  const soloCierres = (cierres || []).filter(f => !conLlamadas.has(f.cliente_id) && cuenta(f)).length;
  const hayAlgo = met.length > 0 || soloCierres > 0;
  if (!hayAlgo) return { agendadas: null, presentadas: null, cerradas: null, sinShowUp: null, futuras: null };
  const suma = campo => (met.length ? met.reduce((a, f) => a + n(f[campo]), 0) : null);
  return {
    agendadas: suma('agendadas'),
    presentadas: suma('presentadas'),
    cerradas: (suma('cerradas') ?? 0) + soloCierres,
    sinShowUp: suma('sin_show_up'),        // agendadas con la columna «Show up» vacía (se completa días después)
    futuras: suma('agendadas_a_futuro')    // agendadas con fecha posterior a hoy
  };
}

async function seguimiento(cli) {
  const filas = await todas(() => {
    let q = sb.from('cs_clientes').select('programa_id,estado').in('estado', SEGUIMIENTO_ACTIVOS).order('id');
    if (cli) q = q.eq('programa_id', cli);
    return q;
  });
  return {
    activos: filas.length,
    onboarding: filas.filter(f => f.estado === 'onboarding').length,
    renovacion: filas.filter(f => f.estado === 'en_renovacion').length
  };
}

/* Todas las áreas del mes `ym` y el cliente `cli` ('' = todos). `base` = cargarBaseMapa(). */
export async function cargarMapa(ym, cli, base) {
  const [mkt, vta, seg, mes] = await Promise.all([
    seguro('marketing', () => marketing(ym, cli)),
    seguro('ventas', () => ventas(ym, cli)),
    seguro('seguimiento', () => seguimiento(cli)),
    seguro('finanzas', async () => resumir(await cargarMes(ym, base), cli))
  ]);
  const fin = mes && {
    cash: redondear(mes.facturacion), gastos: redondear(mes.gastos),
    ganancia: redondear(mes.ganancia), gananciaDys: redondear(mes.gananciaDys), pct: mes.pct
  };
  return { ym, cli, marketing: mkt, ventas: vta, finanzas: fin, seguimiento: seg, dystopia: fin };
}
