/* Gastos > Desglose y ROAS. Por cliente y mes: de dónde sale cada gasto (Opps, gastos cargados, IA, webinars, Cierre),
   ROAS total, por webinar y por funnel. Solo lectura; las cuentas están en js/gastos-desglose-calc.js. */
import { esc } from '../ui.js';
import { usd } from '../datos.js';
import { etiquetaMes } from '../gastos.js';
import { cargarDesglose } from '../gastos-desglose.js';
import { CLIENTES, BUCKETS, nombreCli, nombreBucket, armarLineas, resumenPorMes, roasWebinars, roasFunnels, avisosDuplicados } from '../gastos-desglose-calc.js';
import { vacio, etiquetarTablas } from './comunes.js';

const u = v => usd(v, { centavos: true });
const sd = '<span class="hint">sin dato</span>';
const rx = v => (v == null ? sd : `${v.toFixed(2).replace('.', ',')}x`);
const uOrSd = v => (v == null ? sd : u(v));
const tabla = (cab, cuerpo, vacioTxt) => `<div class="card table-card"><table class="data-table tabla-tarjetas"><thead><tr>${cab}</tr></thead>
  <tbody>${cuerpo || `<tr><td colspan="30">${esc(vacioTxt)}</td></tr>`}</tbody></table></div>`;
const th = (t, num = false) => `<th${num ? ' class="num"' : ''}>${esc(t)}</th>`;

export async function vistaDesglose(el, vigente) {
  el.innerHTML = '<div class="card nota">Cargando desglose…</div>';
  const { datos, fallas } = await cargarDesglose();
  if (!vigente()) return;
  const lineas = armarLineas({ opps: datos.opps || [], gastos: datos.gastos || [], webGastos: datos.webGastos || [], webs: datos.webs || [], ganancia: datos.ganancia || [] });
  const filas = resumenPorMes(lineas, datos.ganancia || []);
  const meses = [...new Set(filas.map(f => f.ym))].sort().reverse();
  const estado = { cli: '', ym: meses[0] || '' };

  const pintar = () => {
    const fs = filas.filter(f => (!estado.cli || f.cli === estado.cli) && (!estado.ym || f.ym === estado.ym));
    const ls = lineas.filter(l => (!estado.cli || l.cli === estado.cli) && (!estado.ym || l.ym === estado.ym));
    const ing = fs.reduce((a, f) => a + (f.ingresos || 0), 0), imp = fs.reduce((a, f) => a + f.imputable, 0);
    const totAds = fs.reduce((a, f) => a + f.b.ads, 0);
    const webs = roasWebinars(datos.webs || [], datos.webGastos || []).filter(w => (!estado.cli || w.cli === estado.cli) && (!estado.ym || String(w.fecha).slice(0, 7) === estado.ym));
    const funnels = datos.pagos ? roasFunnels(datos.pagos, lineas, datos.webs || [], estado.cli, estado.ym) : null;
    const dup = avisosDuplicados(lineas).filter(a => (!estado.cli || a.cli === estado.cli) && (!estado.ym || a.ym === estado.ym));
    const nombres = { opps: 'Opps (gastos del cliente)', gastos: 'Gastos cargados e IA', webGastos: 'Gastos de webinars', webs: 'Webinars', ganancia: 'Cierre (ganancia por mes)', pagos: 'Fuente de los pagos' };

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Cliente</span>
        <select id="d-cli"><option value="">Todos</option>${CLIENTES.map(([k, nm]) => `<option value="${k}"${k === estado.cli ? ' selected' : ''}>${esc(nm)}</option>`).join('')}</select>
        <span class="flabel">Mes</span>
        <select id="d-mes"><option value="">Todos</option>${meses.map(m => `<option value="${m}"${m === estado.ym ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('')}</select>
      </div>
      <div class="card nota"><strong>Cómo se calcula el ROAS:</strong> ingresos atribuidos ÷ gasto imputable (ads + herramientas: ManyChat, Bunny, IA, Zoom, landings y otras;
        sin comisiones ni «Otros»). Ingresos del cliente = facturación del Cierre; del webinar = cash de su ventana; del funnel = pagos por fuente.</div>
      ${fallas.length ? `<div class="card nota aviso-ambar">Sin dato (no se pudo leer): ${fallas.map(k => esc(nombres[k] || k)).join(', ')}. Lo demás sigue calculado.</div>` : ''}
      ${dup.length ? `<div class="card nota aviso-ambar">ManyChat figura como gasto mensual y también como gasto de webinar en ${dup.map(a => `${esc(nombreCli(a.cli))} ${esc(etiquetaMes(a.ym))}`).join(', ')}: puede estar contado dos veces. Revisar.</div>` : ''}
      <div class="grid-3 stat-grid">
        <div class="stat-card"><div class="stat-num">${u(ing)}</div><div class="stat-label">Ingresos (facturación)</div></div>
        <div class="stat-card"><div class="stat-num">${u(imp)}</div><div class="stat-label">Gasto imputable (ads ${u(totAds)})</div></div>
        <div class="stat-card"><div class="stat-num">${imp > 0 ? rx(ing / imp) : sd}</div><div class="stat-label">ROAS total</div></div>
      </div>

      <div class="card-titulo">Por cliente y mes</div>
      ${tabla(`${th('Mes')}${th('Cliente')}${BUCKETS.map(([, nm]) => th(nm, true)).join('')}${th('Total', true)}${th('Imputable', true)}${th('Ingresos', true)}${th('ROAS', true)}`,
        fs.map(f => `<tr><td>${esc(etiquetaMes(f.ym))}</td><td>${esc(nombreCli(f.cli))}</td>${BUCKETS.map(([k]) => `<td class="num">${f.b[k] ? u(f.b[k]) : '—'}</td>`).join('')}
          <td class="num clave">${u(f.total)}</td><td class="num">${u(f.imputable)}</td><td class="num">${uOrSd(f.ingresos)}</td><td class="num">${rx(f.roas)}</td></tr>`).join(''),
        'Sin gastos para este filtro')}

      <div class="card-titulo">De dónde sale cada número del Cierre</div>
      ${tabla(`${th('Mes')}${th('Cliente')}${th('Opps', true)}${th('Gastos cargados e IA', true)}${th('Webinars fuera de Opps', true)}${th('Comisiones', true)}${th('Suma del desglose', true)}${th('Gastos en el Cierre', true)}${th('Diferencia', true)}`,
        fs.map(f => { const dif = f.cierre == null ? null : Math.round((f.cierre - f.total) * 100) / 100;
          return `<tr${dif ? ' class="fila-alerta"' : ''}><td>${esc(etiquetaMes(f.ym))}</td><td>${esc(nombreCli(f.cli))}</td><td class="num">${u(f.op)}</td><td class="num">${u(f.ca)}</td>
          <td class="num">${u(f.wb)}</td><td class="num">${u(f.cm)}</td><td class="num clave">${u(f.total)}</td><td class="num">${uOrSd(f.cierre)}</td><td class="num">${dif == null ? sd : u(dif)}</td></tr>`; }).join(''),
        'Sin datos')}
      <div class="table-foot">Los webinars marcados «ya en Opps» no suman de nuevo. Una diferencia distinta de cero es un gasto que el desglose no clasifica igual que el Cierre
        (por ejemplo un ítem de Opps de comisión que el Cierre reemplaza, o un mes cerrado con foto): se revisa en el detalle de abajo.</div>

      <div class="card-titulo">ROAS por webinar</div>
      ${tabla(`${th('Webinar')}${th('Cliente')}${th('Fecha')}${th('Cash', true)}${th('Gasto imputable', true)}${th('ROAS', true)}${th('ROAS solo ads', true)}`,
        webs.map(w => `<tr><td class="ajusta">${esc(w.nombre)}${w.sinGastos ? ' <span class="badge">Sin gastos cargados</span>' : ''}</td><td>${esc(nombreCli(w.cli))}</td><td>${esc(String(w.fecha).slice(0, 10))}</td>
          <td class="num">${u(w.cash)}${w.probable ? `<div class="hint">+ ${u(w.probable)} probables</div>` : ''}</td><td class="num">${u(w.imputable)}</td><td class="num clave">${rx(w.roas)}</td><td class="num">${rx(w.roasAds)}</td></tr>`).join(''),
        datos.webs ? 'No hay webinars en este filtro' : 'Sin dato')}

      <div class="card-titulo">ROAS por funnel</div>
      ${funnels ? tabla(`${th('Funnel')}${th('Ingresos atribuidos', true)}${th('Pagos', true)}${th('Gasto atribuible', true)}${th('ROAS', true)}${th('Nota')}`,
        funnels.map(f => `<tr><td>${esc(f.funnel)}</td><td class="num">${uOrSd(f.ingresos)}</td><td class="num">${f.pagos}</td><td class="num">${uOrSd(f.gasto)}</td><td class="num clave">${rx(f.roas)}</td><td class="ajusta">${esc(f.motivo)}</td></tr>`).join(''), 'Sin datos')
        : vacio('Sin dato', 'No se pudo leer la fuente de los pagos.')}
      <div class="table-foot">Solo el webinar y la landing tienen gasto que se puede atribuir con los datos de hoy. VSL y los canales sin gasto propio quedan «sin dato»; el resto del gasto
        (ads de Opps, herramientas generales) no está asignado a un funnel y se ve arriba por cliente y mes.</div>

      <div class="card-titulo">Detalle de líneas</div>
      ${tabla(`${th('Mes')}${th('Cliente')}${th('Origen')}${th('Tipo')}${th('Concepto')}${th('Monto', true)}${th('Nota')}`,
        ls.map(l => `<tr${l.suma ? '' : ' class="fila-activa"'}><td>${esc(etiquetaMes(l.ym))}</td><td>${esc(nombreCli(l.cli))}</td><td>${esc(l.origen)}</td><td>${esc(nombreBucket(l.bucket))}</td>
          <td class="ajusta">${esc(l.concepto)}</td><td class="num">${u(l.monto)}</td><td class="ajusta">${esc(l.nota || '')}</td></tr>`).join(''), 'Sin líneas')}`;
    etiquetarTablas(el);
    el.querySelector('#d-cli').onchange = e => { estado.cli = e.target.value; pintar(); };
    el.querySelector('#d-mes').onchange = e => { estado.ym = e.target.value; pintar(); };
  };
  pintar();
}
