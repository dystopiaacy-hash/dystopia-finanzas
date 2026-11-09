/* Lecturas del desglose de gastos y ROAS. Cada fuente se lee por separado: si una falla (permiso o migración sin correr)
   queda null y la pantalla lo avisa («sin dato»); las demás siguen. Solo lectura. */
import { sb } from './supabase.js';
import { gastosMes, dysGananciaMes } from './gastos.js';
import { webinarsResultado } from './webinars.js';

async function todas(armar, pagina = 1000) {
  const out = [];
  for (let desde = 0; ; desde += pagina) {
    const { data, error } = await armar().range(desde, desde + pagina - 1);
    if (error) throw error;
    out.push(...(data || []));
    if (!data || data.length < pagina) return out;
  }
}

const opps = () => todas(() => sb.from('fin_pnl').select('cliente_id,anio,mes,categoria,item,monto_usd')
  .in('cliente_id', ['liam', 'agus', 'teo']).neq('categoria', 'revenue').order('anio').order('mes').order('id'));
const webGastos = () => todas(() => sb.from('fin_webinar_gastos').select('id,webinar_id,concepto,monto_usd,fecha,en_opps,fuente,nota').eq('activo', true).order('fecha').order('id'));
const pagosFuente = () => todas(() => sb.from('fin_v_pago_fuente').select('pago_id,cliente_id,fecha,monto_usd,fuente_final,es_webinar').order('pago_id'));

export async function cargarDesglose() {
  const fuentes = { opps, gastos: gastosMes, webGastos, webs: webinarsResultado, ganancia: dysGananciaMes, pagos: pagosFuente };
  const claves = Object.keys(fuentes);
  const res = await Promise.allSettled(claves.map(k => fuentes[k]()));
  const datos = {}; const fallas = [];
  claves.forEach((k, i) => {
    if (res[i].status === 'fulfilled') datos[k] = res[i].value;
    else { datos[k] = null; fallas.push(k); console.warn('desglose', k, res[i].reason && res[i].reason.message); }
  });
  return { datos, fallas };
}
