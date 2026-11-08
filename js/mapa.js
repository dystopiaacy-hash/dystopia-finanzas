/* Mapa (solo fundador): datos del canvas de sistemas. Solo lectura, sin DOM. Se carga UNA vez por cliente+mes
   (cache en memoria) y cada área falla aislada: si una lectura falla queda null («sin dato») y el resto sigue.
   De dónde sale cada número (para controlar contra Cierre / Comparar):
   - Marketing:   crm_publicaciones, estado_publicacion = 'PUBLICADO' y fecha_publicacion dentro del mes.
   - Ventas:      fin_v_metricas_ventas (por cliente), fin_v_metricas_closer (por closer), fin_cierres para clientes sin llamadas (Agus).
   - Seguimiento: cs_clientes (programa_id = cliente) activo / onboarding / en_renovacion. Foto de hoy, no depende del mes.
   - Finanzas:    cargarMes/resumir de Comparar (fin_v_dys_ganancia_mes; mes cerrado = foto de fin_cierre_meses) + fin_pagos del mes
                  (por día y últimos pagos) + cash por concepto.
   - Dystopia:    ganancia_dystopia_usd de esa vista, por cliente, y las transferencias del cierre (solo lectura). */
import { sb } from './supabase.js';
import { cargarBase, cargarMes, resumir } from './comparar.js';
import { esFundador } from './sesion.js';

export const veMapa = () => esFundador();   // mismo control que Cierre / Comparar
export const CLIENTES = [['liam', 'Liam'], ['agus', 'Agus'], ['teo', 'Teo']];
export const nombreCliente = id => (CLIENTES.find(c => c[0] === id) || [id, id || '—'])[1];

/* Qué app abre cada área: dominios de js/nav-areas.js (url = otra app, ruta = pantalla de esta). */
export const ABRIR = {
  marketing:   { url: 'https://mkt.dystopia.com.ar', txt: 'Abrir Marketing' },
  setting:     { url: 'https://mkt.dystopia.com.ar', txt: 'Abrir el CRM' },
  ventas:      { url: 'https://ventas.dystopia.com.ar', txt: 'Abrir Ventas' },
  seguimiento: { url: 'https://producto.dystopia.com.ar', txt: 'Abrir Seguimiento' },
  soporte:     null,
  finanzas:    { ruta: '#/cierre', txt: 'Abrir Cierre de mes' },
  dystopia:    { ruta: '#/dystopia', txt: 'Abrir Dystopia' },
  direccion:   { ruta: '#/comparar', txt: 'Abrir Comparar' }
};

const SEGUIMIENTO_ACTIVOS = ['activo', 'onboarding', 'en_renovacion'];
const n = v => Number(v) || 0;
const redondear = v => Math.round(v * 100) / 100;
const contar = (filas, clave) => {
  const m = {};
  for (const f of filas) { const k = clave(f); if (k) m[k] = (m[k] || 0) + 1; }
  return Object.entries(m).sort((a, b) => b[1] - a[1]);
};

async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}
async function seguro(nombre, fn) {
  try { return await fn(); } catch (e) { console.warn(`mapa ${nombre}:`, e && e.message ? e.message : e); return null; }
}
export const mesAnterior = ym => {
  const [a, m] = ym.split('-').map(Number);
  return m === 1 ? `${a - 1}-12` : `${a}-${String(m - 1).padStart(2, '0')}`;
};
const finMes = ym => {
  const [a, m] = ym.split('-').map(Number);
  const sig = m === 12 ? `${a + 1}-01` : `${a}-${String(m + 1).padStart(2, '0')}`;
  return { desde: `${ym}-01`, hasta: `${sig}-01` };   // [desde, hasta)
};
const filtroCli = (q, cli, col = 'cliente_id') => (cli ? q.eq(col, cli) : q);

export const cargarBaseMapa = () => cargarBase();

async function piezas(ym, cli) {
  const { desde, hasta } = finMes(ym);
  return todas(() => filtroCli(sb.from('crm_publicaciones').select('*')
    .eq('estado_publicacion', 'PUBLICADO').gte('fecha_publicacion', desde).lt('fecha_publicacion', hasta)
    .order('fecha_publicacion', { ascending: false }).order('id'), cli));
}
function marketing(filas) {
  const titulo = f => String(f.titulo || f.nombre || f.tema || f.hook || f.formato || f.tipo || '').trim();
  const dias = {};
  for (const f of filas) { const d = String(f.fecha_publicacion || '').slice(8, 10); if (d) dias[+d] = (dias[+d] || 0) + 1; }
  return {
    piezas: filas.length,
    porPlataforma: contar(filas, f => f.plataforma || 'Sin plataforma'),
    porCliente: contar(filas, f => f.cliente_id),
    porDia: dias,
    ultimas: filas.slice(0, 10).map(f => ({ fecha: f.fecha_publicacion, plataforma: f.plataforma || '—', cliente: f.cliente_id, titulo: titulo(f) }))
  };
}

async function ventas(ym, cli) {
  const { desde, hasta } = finMes(ym);
  const [met, clo, cierres] = await Promise.all([
    todas(() => filtroCli(sb.from('fin_v_metricas_ventas').select('cliente_id,periodo,agendadas,presentadas,cerradas,no_show,sin_show_up,agendadas_a_futuro').eq('periodo', ym).order('cliente_id'), cli)),
    seguro('closers', () => todas(() => filtroCli(sb.from('fin_v_metricas_closer').select('cliente_id,vendedor,agendadas,presentadas,cerradas').eq('periodo', ym).order('cliente_id'), cli))),
    seguro('fin_cierres', () => todas(() => filtroCli(sb.from('fin_cierres').select('cliente_id,fecha_cierre,estado').gte('fecha_cierre', desde).lt('fecha_cierre', hasta).order('id'), cli)))
  ]);
  const conLlamadas = new Set(met.map(f => f.cliente_id));
  const cuenta = f => { const e = String(f.estado ?? '').trim().toLowerCase(); return !e || e === 'cliente'; };
  const soloCierres = (cierres || []).filter(f => !conLlamadas.has(f.cliente_id) && cuenta(f));
  if (!met.length && !soloCierres.length) return null;
  const suma = campo => met.reduce((a, f) => a + n(f[campo]), 0);
  const porCliente = met.map(f => ({ cliente: f.cliente_id, agendadas: n(f.agendadas), presentadas: n(f.presentadas), cerradas: n(f.cerradas) }));
  for (const [c, k] of contar(soloCierres, f => f.cliente_id)) porCliente.push({ cliente: c, agendadas: null, presentadas: null, cerradas: k });
  /* Un mismo closer puede estar en varios clientes: se junta por nombre. */
  const mapa = new Map();
  for (const f of clo || []) {
    const k = String(f.vendedor || 'Sin closer');
    const x = mapa.get(k) || { closer: k, agendadas: 0, presentadas: 0, cerradas: 0 };
    x.agendadas += n(f.agendadas); x.presentadas += n(f.presentadas); x.cerradas += n(f.cerradas);
    mapa.set(k, x);
  }
  const cerradas = suma('cerradas') + soloCierres.length;
  return {
    agendadas: met.length ? suma('agendadas') : null, presentadas: met.length ? suma('presentadas') : null, cerradas,
    noShow: met.length ? suma('no_show') : null, sinShowUp: met.length ? suma('sin_show_up') : null,
    futuras: met.length ? suma('agendadas_a_futuro') : null, porCliente,
    closers: [...mapa.values()].sort((a, b) => b.cerradas - a.cerradas || b.agendadas - a.agendadas)
  };
}

async function seguimiento(cli) {
  const filas = await todas(() => filtroCli(sb.from('cs_clientes').select('*').in('estado', SEGUIMIENTO_ACTIVOS).order('id', { ascending: false }), cli, 'programa_id'));
  const nombre = f => String(f.nombre || f.nombre_completo || f.alumno || f.cliente || f.email || `Alumno ${f.id}`);
  return {
    activos: filas.length,
    onboarding: filas.filter(f => f.estado === 'onboarding').length,
    renovacion: filas.filter(f => f.estado === 'en_renovacion').length,
    porCliente: contar(filas, f => f.programa_id),
    lista: filas.slice(0, 10).map(f => ({ nombre: nombre(f), estado: f.estado, cliente: f.programa_id }))
  };
}

async function pagos(ym, cli) {
  const { desde, hasta } = finMes(ym);
  const filas = await todas(() => filtroCli(sb.from('fin_pagos').select('cliente_id,fecha,alumno,concepto,monto_usd').gte('fecha', desde).lt('fecha', hasta).order('fecha', { ascending: false }).order('id'), cli));
  const dias = {};
  for (const f of filas) { const d = +String(f.fecha).slice(8, 10); dias[d] = (dias[d] || 0) + n(f.monto_usd); }
  return { cantidad: filas.length, total: redondear(filas.reduce((a, f) => a + n(f.monto_usd), 0)), porDia: dias, ultimos: filas.slice(0, 10) };
}

/* Finanzas + Dystopia de un mes (mismas cuentas que Comparar). */
async function plata(ym, cli, base) {
  const m = await cargarMes(ym, base);
  const r = resumir(m, cli);
  const cs = m.clientes.filter(f => !cli || f.entidad === cli);
  const tr = m.trans.filter(t => !cli || t.cliente_id === cli);
  const conc = {};
  for (const c of m.concepto.filter(c => !cli || c.cliente_id === cli)) conc[c.categoria || 'sin clasificar'] = (conc[c.categoria || 'sin clasificar'] || 0) + n(c.monto_usd);
  return {
    cash: redondear(r.facturacion), gastos: redondear(r.gastos), ganancia: redondear(r.ganancia),
    gananciaDys: redondear(r.gananciaDys), pct: r.pct, categorias: r.categorias, cerrado: m.cerrado,
    porConcepto: Object.entries(conc).map(([k, v]) => [k, redondear(v)]).filter(x => x[1] > 0).sort((a, b) => b[1] - a[1]),
    porCliente: cs.map(f => ({ cliente: f.entidad, fact: n(f.facturacion_usd), gastos: n(f.gastos_cliente_usd), ganancia: n(f.ganancia_cliente_usd), pct: f.porcentaje != null ? n(f.porcentaje) : null, dys: n(f.ganancia_dystopia_usd) })),
    trans: tr.map(t => ({ destinatario: t.destinatario, concepto: t.concepto, cliente: t.cliente_id, monto: n(t.monto_usd), estado: t.estado, tipo: t.tipo })),
    transTotal: r.transfTotal, transHechas: r.transfHechas
  };
}

/* Lo mínimo de un mes para compararlo (Dirección). */
async function nucleo(ym, cli, base) {
  const [mk, vt, pl] = await Promise.all([
    seguro('mkt-prev', async () => (await piezas(ym, cli)).length),
    seguro('vta-prev', () => ventas(ym, cli)),
    seguro('fin-prev', () => plata(ym, cli, base))
  ]);
  return { ym, piezas: mk, agendadas: vt && vt.agendadas, cerradas: vt && vt.cerradas, cash: pl && pl.cash, ganancia: pl && pl.ganancia, gananciaDys: pl && pl.gananciaDys };
}

const cache = new Map();
export const limpiarCache = () => cache.clear();

/* Todo el mapa de `ym` para `cli` ('' = todos). `base` = cargarBaseMapa(). Una sola carga por cliente+mes. */
export function cargarMapa(ym, cli, base) {
  const k = `${ym}|${cli}`;
  if (!cache.has(k)) {
    cache.set(k, (async () => {
      const [pz, vta, seg, pg, pl, prev] = await Promise.all([
        seguro('marketing', piezas.bind(null, ym, cli)), seguro('ventas', () => ventas(ym, cli)), seguro('seguimiento', () => seguimiento(cli)),
        seguro('pagos', () => pagos(ym, cli)), seguro('finanzas', () => plata(ym, cli, base)),
        seguro('mes anterior', () => nucleo(mesAnterior(ym), cli, base))
      ]);
      return { ym, cli, marketing: pz && marketing(pz), ventas: vta, seguimiento: seg, pagos: pg, plata: pl, prev };
    })().catch(e => { cache.delete(k); throw e; }));
  }
  return cache.get(k);
}
