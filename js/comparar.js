/* Comparar mes a mes (solo fundador). Datos y cuentas, sin DOM. Todo sale de lo que ya existe:
   fin_v_dys_ganancia_mes (267/270), fin_cierre_meses (foto de un mes cerrado), fin_cierre_transferencias (269),
   fin_v_cash_collected_concepto (032) y, para abrir el gasto en ads / Zoom / landings, fin_comparar_gastos (280).
   Un mes cerrado usa la foto guardada al cerrar (clientes y transferencias); uno abierto, los datos en vivo. */
import { sb } from './supabase.js';
import { dysGananciaMes, claveMes, sumar } from './gastos.js';
import { estadoMes, transferencias } from './cierre.js';
import { cashPorConcepto } from './datos.js';

export const CLIENTES = [['liam', 'Liam'], ['agus', 'Agus'], ['teo', 'Teo']];
export const CATEGORIAS_GASTO = [['ads', 'Ads'], ['zoom', 'Zoom'], ['landings', 'Landings'], ['comisiones', 'Comisiones'], ['otros', 'Otros']];

/* Lecturas que no dependen del mes: se piden una vez por pantalla. */
export async function cargarBase() {
  const [ganancia, concepto] = await Promise.all([dysGananciaMes(), cashPorConcepto()]);
  return { ganancia, concepto };
}

/* Gasto en ads / zoom / landings (migración 280). Si todavía no está corrida devuelve null y la pantalla lo avisa. */
async function gastosCategoria(ym) {
  const { data, error } = await sb.rpc('fin_comparar_gastos', { p_mes: `${ym}-01` });
  if (error) { console.warn('fin_comparar_gastos', error.message); return null; }
  return data || [];
}

export async function cargarMes(ym, base) {
  const est = await estadoMes(ym);
  const cerrado = !!est && est.estado === 'cerrado' && !!est.snapshot;
  const [trans, gastosCat] = await Promise.all([
    cerrado ? Promise.resolve(est.snapshot.transferencias || []) : transferencias(ym),
    gastosCategoria(ym)
  ]);
  const clientes = cerrado
    ? (est.snapshot.clientes || [])
    : base.ganancia.filter(f => claveMes(f.mes) === ym && f.entidad !== 'dystopia');
  const [anio, mes] = ym.split('-').map(Number);
  return {
    ym, cerrado, clientes, gastosCat,
    trans: trans.filter(t => t.activo !== false),
    concepto: base.concepto.filter(c => Number(c.anio) === anio && Number(c.mes) === mes)
  };
}

const n = v => Number(v) || 0;
const redondear = v => Math.round(v * 100) / 100;

/* Métricas de un mes para un cliente ('liam' | 'agus' | 'teo') o todos (cli vacío). */
export function resumir(m, cli) {
  const cs = m.clientes.filter(f => !cli || f.entidad === cli);
  const facturacion = sumar(cs, 'facturacion_usd');
  const gastos = sumar(cs, 'gastos_cliente_usd');
  const ganancia = sumar(cs, 'ganancia_cliente_usd');
  const gananciaDys = sumar(cs, 'ganancia_dystopia_usd');
  /* Comisiones del cliente: las del cierre más, si el mes no las calculó, las líneas de Opps (comision_modo = 'opps'). */
  const comisiones = sumar(cs, 'gastos_comision_usd') + sumar(cs, 'comision_opps_vigente_usd');
  const cat = clave => (m.gastosCat
    ? redondear(m.gastosCat.filter(r => (!cli || r.cliente_id === cli) && r.categoria === clave).reduce((a, r) => a + n(r.monto_usd), 0))
    : null);
  const ads = cat('ads'), zoom = cat('zoom'), landings = cat('landings');
  const clasificado = (ads ?? 0) + (zoom ?? 0) + (landings ?? 0) + comisiones;
  const otros = Math.max(0, redondear(gastos - clasificado));

  const tr = m.trans.filter(t => !cli || t.cliente_id === cli);
  const personas = new Map();
  for (const t of tr.filter(x => x.tipo === 'comision')) {
    personas.set(t.destinatario, redondear((personas.get(t.destinatario) || 0) + n(t.monto_usd)));
  }
  const conc = (clave, campo) => m.concepto.filter(c => (!cli || c.cliente_id === cli) && c.categoria === clave).reduce((a, c) => a + n(c[campo]), 0);

  return {
    facturacion, gastos, ganancia, gananciaDys,
    pct: cli ? (cs[0] && cs[0].porcentaje != null ? n(cs[0].porcentaje) : null) : (ganancia > 0 ? (gananciaDys / ganancia) * 100 : null),
    ads, zoom, landings, comisiones, otros,
    categorias: { ads, zoom, landings, comisiones, otros },
    transfTotal: redondear(tr.reduce((a, t) => a + n(t.monto_usd), 0)),
    transfCantidad: tr.length,
    transfHechas: tr.filter(t => t.estado === 'hecha').length,
    personas,
    ventasN: conc('venta_nueva', 'pagos'), ventasUsd: redondear(conc('venta_nueva', 'monto_usd')),
    cuotasN: conc('cuota', 'pagos'), cuotasUsd: redondear(conc('cuota', 'monto_usd'))
  };
}

/* Variación porcentual de b contra a (a es la base). null si no se puede calcular. */
export function variacion(a, b) {
  if (a == null || b == null) return null;
  if (n(a) === 0) return n(b) === 0 ? 0 : null;
  return ((n(b) - n(a)) / Math.abs(n(a))) * 100;
}
