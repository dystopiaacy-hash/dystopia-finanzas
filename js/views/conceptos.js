/* Cash collected por concepto: torta de fin_v_cash_collected_concepto para un
   mes, un cliente o todos los visibles (la vista es security_invoker: respeta
   la RLS de fin_pagos). Las 4 categorías se muestran siempre, aunque valgan 0;
   sin_clasificar va en gris para que se vea cuánto falta mapear en 031.
   El total es la suma real de las 4, con signo (ver conceptos-calculo.js). */
import { esc, hoyAR, fmtPct, plural } from '../ui.js';
import { cashPorConcepto, usd, MESES } from '../datos.js';
import { calcularTorta } from '../conceptos-calculo.js';
import { vacio, selectCliente, selectMes, selectAnio, anios, clienteChip, botonRecargar } from './comunes.js';

let filtro = { cliente: '', anio: null, mes: null };   // se conserva entre visitas

export async function vistaConceptos(el, vigente) {
  const filas = await cashPorConcepto();
  if (!vigente()) return;
  const [ha, hm] = hoyAR().split('-').map(Number);
  if (!filtro.anio) filtro = { ...filtro, anio: ha, mes: hm };

  const pintar = () => {
    const { cliente, anio, mes } = filtro;
    const delMes = filas.filter(f => Number(f.anio) === anio && Number(f.mes) === mes && (!cliente || f.cliente_id === cliente));
    const t = calcularTorta(delMes);
    const devoluciones = t.categorias.filter(c => c.devolucion);

    el.innerHTML = `
      <div class="filter-row">
        ${selectCliente('f-cliente', cliente)}
        <span class="flabel">Periodo</span>${selectMes('f-mes', mes)}${selectAnio('f-anio', anios(filas, anio), anio)}
        <span class="grow"></span>${botonRecargar()}
      </div>
      ${filas.length ? '' : vacio('Todavía no hay pagos categorizados', 'La vista fin_v_cash_collected_concepto volvió vacía.')}
      <div class="section-title">${esc(MESES[mes - 1])} ${anio} · ${cliente ? clienteChip(cliente) : 'Todos los clientes'}<span class="line"></span></div>
      <div class="card chart-card concepto-card">
        <div class="chart-title">Cash collected por concepto</div>
        <div class="chart-sub">Suma de pagos del mes (USD), según la categoría de su concepto</div>
        <div class="concepto-wrap">
          ${torta(t)}
          ${leyenda(t)}
        </div>
      </div>
      ${devoluciones.length ? `<div class="table-foot">${devoluciones.map(c => esc(c.label)).join(', ')} suma negativo en el mes
        (devoluciones): resta del total y en la torta ocupa su valor absoluto, rayado.</div>` : ''}
      ${t.pagos ? '' : `<div class="table-foot">Sin pagos en ${esc(MESES[mes - 1])} ${anio} para este filtro.</div>`}`;

    el.querySelector('#f-cliente').onchange = e => { filtro.cliente = e.target.value; pintar(); };
    el.querySelector('#f-mes').onchange = e => { filtro.mes = Number(e.target.value); pintar(); };
    el.querySelector('#f-anio').onchange = e => { filtro.anio = Number(e.target.value); pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaConceptos(el, vigente);
  };
  pintar();
}

const pct = c => (c.pct == null ? '—' : fmtPct(c.pct, 1));
const etiqueta = c => (c.devolucion ? `${c.label} (devolución)` : c.label);
const detalle = c => `${etiqueta(c)}: ${usd(c.monto)} · ${plural(c.pagos, 'pago')} · ${pct(c)}`;

/* Donut en SVG a mano (mismo método que los gráficos de Dystopia). Cada
   porción ocupa |monto|; las devoluciones van rayadas sobre su color. */
function torta(t) {
  const R = 70, ANCHO = 24, C = 2 * Math.PI * R;
  let offset = 0;
  const arco = (c, stroke, largo, desde) => `<circle cx="100" cy="100" r="${R}" fill="none" stroke="${stroke}" stroke-width="${ANCHO}"
      stroke-dasharray="${largo} ${C - largo}" stroke-dashoffset="${-desde}" transform="rotate(-90 100 100)">
      <title>${esc(detalle(c))}</title></circle>`;
  const arcos = t.pesoTotal > 0 ? t.categorias.filter(c => c.peso > 0).map(c => {
    const largo = (c.peso / t.pesoTotal) * C;
    const s = arco(c, c.color, largo, offset) + (c.devolucion ? arco(c, 'url(#concepto-rayado)', largo, offset) : '');
    offset += largo;
    return s;
  }).join('') : '';
  return `
    <svg class="donut-svg" viewBox="0 0 200 200" width="220" height="220" role="img"
      aria-label="${esc(`Total ${usd(t.total)}. ` + t.categorias.map(detalle).join('; '))}">
      <defs><pattern id="concepto-rayado" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="6" height="6" fill="var(--danger)" fill-opacity=".35"/><rect width="3" height="6" fill="var(--surface)"/>
      </pattern></defs>
      <circle cx="100" cy="100" r="${R}" fill="none" stroke="var(--surface-2)" stroke-width="${ANCHO}"/>
      ${arcos}
      <text class="donut-total${t.total < 0 ? ' concepto-negativo' : ''}" x="100" y="102" text-anchor="middle"
        style="font-size:${Math.min(24, Math.floor(180 / usd(t.total).length))}px">${esc(usd(t.total))}</text>
      <text class="donut-sub" x="100" y="122" text-anchor="middle">${esc(plural(t.pagos, 'pago'))}</text>
    </svg>`;
}

function leyenda(t) {
  return `
    <div class="donut-legend concepto-legend">
      <div class="concepto-legend-item concepto-legend-head">
        <span></span><span>Concepto</span><span>Monto</span><span>Pagos</span><span>%</span>
      </div>
      ${t.categorias.map(c => `<div class="concepto-legend-item${c.clave === 'sin_clasificar' ? ' concepto-sin-clasificar' : ''}${c.devolucion ? ' concepto-devolucion' : ''}" title="${esc(detalle(c))}">
          <span class="dot" style="background:${c.color}"></span>
          <span class="donut-legend-label">${esc(c.label)}${c.devolucion ? '<span class="concepto-ayuda">Devolución: resta del total</span>'
            : c.ayuda ? `<span class="concepto-ayuda">${esc(c.ayuda)}</span>` : ''}</span>
          <span class="donut-legend-val">${esc(usd(c.monto))}</span>
          <span class="donut-legend-val">${c.pagos}</span>
          <span class="donut-legend-pct">${esc(pct(c))}</span>
        </div>`).join('')}
      <div class="concepto-legend-item concepto-legend-total">
        <span></span><span>Total</span>
        <span class="${t.total < 0 ? 'concepto-negativo' : ''}">${esc(usd(t.total))}</span><span>${t.pagos}</span><span></span>
      </div>
    </div>`;
}
