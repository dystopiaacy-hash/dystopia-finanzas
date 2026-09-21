/* Cliente: P&L mensual del año (desde fin_v_pnl_mensual) y, para el mes
   elegido, el detalle: cada item de Opps y cada pago, con link a su celda. */
import { esc, fmtFecha, hoyAR } from '../ui.js';
import { queryActual } from '../router.js';
import { cliente as datosCliente } from '../sesion.js';
import { setHeader } from '../layout.js';
import {
  pnlMensual, pnlItems, pagos, fuentes, usd, numCelda, MESES, MESES_CORTOS, CATEGORIAS, ultimoPeriodo
} from '../datos.js';
import { statCard, vacio, selectAnio, anios, botonRecargar } from './comunes.js';

const n = v => Number(v) || 0;

const FILAS_PNL = [
  ['revenue_declarado', 'Revenue declarado (Opps)', 'fuerte'],
  ['ingreso_real', 'Ingreso real (Pagos)', ''],
  ['staff', 'Staff', 'sub'],
  ['softwares', 'Softwares', 'sub'],
  ['others', 'Others', 'sub'],
  ['sin_categoria', 'Sin categoría', 'sub'],
  ['gastos_total', 'Gastos totales', 'fuerte'],
  ['net_cash_flow', 'Net cash flow', 'fuerte'],
  ['dividends_released', 'Dividends released', ''],
  ['opening_balance', 'Opening balance', ''],
  ['closing_balance', 'Closing balance', '']
];

export async function vistaCliente(el, clienteId, vigente) {
  const c = datosCliente(clienteId);
  setHeader(c.nombre, 'P&L mensual y detalle');
  const [todas, mapaFuentes] = await Promise.all([pnlMensual(), fuentes()]);
  if (!vigente()) return;
  const filas = todas.filter(f => f.cliente_id === clienteId);
  if (!filas.length) { el.innerHTML = vacio('Sin datos para este cliente', 'No hay Opps ni Pagos sincronizados todavía.'); return; }

  const q = queryActual();
  const ult = ultimoPeriodo(filas, hoyAR());
  let anio = Number(q.get('anio')) || ult.anio;
  let mes = Number(q.get('mes')) || ult.mes;

  let turno = 0;
  const pintar = async () => {
    const mio = ++turno;
    const delAnio = filas.filter(f => f.anio === anio);
    const meses = [...new Set(delAnio.map(f => f.mes))].sort((a, b) => a - b);
    if (!meses.includes(mes) && meses.length) mes = meses[meses.length - 1];
    const fm = delAnio.find(f => f.mes === mes) || {};
    const valor = (m, k) => { const f = delAnio.find(x => x.mes === m); return f ? f[k] : null; };

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Año</span>${selectAnio('f-anio', anios(filas, anio), anio)}
        <span class="grow"></span>${botonRecargar()}
      </div>
      <div class="stat-row stat-row-6">
        ${statCard(usd(fm.ingreso_real), `Ingreso real · ${MESES[mes - 1]}`, { sub: `${n(fm.cantidad_pagos)} pagos` })}
        ${statCard(usd(fm.revenue_declarado), 'Revenue declarado (Opps)')}
        ${statCard(usd(n(fm.revenue_declarado) - n(fm.ingreso_real)), 'Diferencia Opps − Pagos', { alerta: Math.abs(n(fm.revenue_declarado) - n(fm.ingreso_real)) > 1 })}
        ${statCard(usd(fm.gastos_total), 'Gastos')}
        ${statCard(usd(fm.net_cash_flow), 'Net cash flow')}
      </div>

      <div class="section-title">P&amp;L ${anio}<span class="line"></span></div>
      <div class="card table-card">
        <table class="data-table data-table-dense pnl-tabla">
          <thead><tr><th></th>${meses.map(m => `<th class="num"><button type="button" class="mes-btn${m === mes ? ' activo' : ''}" data-mes="${m}">${MESES_CORTOS[m - 1]}</button></th>`).join('')}</tr></thead>
          <tbody>
            ${FILAS_PNL.map(([k, label, estilo]) => `<tr class="pnl-${estilo || 'normal'}"><td>${label}</td>${meses.map(m => {
              const v = valor(m, k);
              return `<td class="num${m === mes ? ' col-activa' : ''}">${v == null ? '—' : usd(v)}</td>`;
            }).join('')}</tr>`).join('')}
          </tbody>
        </table>
      </div>
      <div class="table-foot">Los números son siempre la suma de los items, nunca el total de la planilla. Clic en un mes para ver el detalle.</div>

      <div class="section-title">Detalle de ${esc(MESES[mes - 1])} ${anio}<span class="line"></span></div>
      <div id="detalle"><div class="loading-inline">Cargando detalle…</div></div>`;

    el.querySelector('#f-anio').onchange = e => { anio = Number(e.target.value); pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaCliente(el, clienteId, vigente);
    for (const b of el.querySelectorAll('.mes-btn')) b.onclick = () => { mes = Number(b.dataset.mes); pintar(); };

    const [items, pagosMes] = await Promise.all([pnlItems(clienteId, anio, mes), pagos({ clienteId, anio, mes })]);
    if (!vigente() || mio !== turno) return;
    const det = el.querySelector('#detalle');
    if (!det) return;
    det.innerHTML = `<div class="grid-2 detalle-grid">${tablaItems(items, mapaFuentes)}${tablaPagos(pagosMes, mapaFuentes)}</div>`;
  };
  await pintar();
}

function tablaItems(items, mapaFuentes) {
  if (!items.length) return `<div class="card">${vacio('Sin items de Opps en este mes')}</div>`;
  const grupos = Object.keys(CATEGORIAS).map(cat => [cat, items.filter(i => i.categoria === cat)]).filter(([, l]) => l.length);
  return `
    <div class="card table-card">
      <div class="card-titulo">Items de Opps <span class="txt-gris">· ${items.length}</span></div>
      <table class="data-table data-table-dense">
        <thead><tr><th>Categoría</th><th>Item</th><th class="num">Monto</th></tr></thead>
        <tbody>
          ${grupos.map(([cat, lista]) => `
            ${lista.map(i => `<tr>
              <td>${esc(CATEGORIAS[cat])}</td>
              <td title="${esc(i.item || '')}">${esc(i.item || '—')}</td>
              <td class="num">${numCelda(usd(i.monto_usd), mapaFuentes.get(i.fuente_id), i.fila_planilla, i.columna_planilla)}</td>
            </tr>`).join('')}
            <tr class="total-row"><td colspan="2">Total ${esc(CATEGORIAS[cat])}</td><td class="num">${usd(lista.reduce((s, i) => s + n(i.monto_usd), 0))}</td></tr>`).join('')}
        </tbody>
      </table>
    </div>`;
}

function tablaPagos(lista, mapaFuentes) {
  if (!lista.length) return `<div class="card">${vacio('Sin pagos en este mes')}</div>`;
  const total = lista.reduce((s, p) => s + n(p.monto_usd), 0);
  return `
    <div class="card table-card">
      <div class="card-titulo">Pagos <span class="txt-gris">· ${lista.length} · ${usd(total)}</span></div>
      <table class="data-table data-table-dense">
        <thead><tr><th>Fecha</th><th>Alumno</th><th>Concepto</th><th>Closer</th><th class="num">Monto</th></tr></thead>
        <tbody>
          ${lista.map(p => `<tr>
            <td>${fmtFecha(p.fecha)}</td>
            <td title="${esc(p.alumno)}">${esc(p.alumno)}</td>
            <td title="${esc(p.concepto || '')}">${esc(p.concepto || '—')}</td>
            <td>${esc(p.closer || '—')}</td>
            <td class="num">${numCelda(usd(p.monto_usd), mapaFuentes.get(p.fuente_id), p.fila_planilla)}</td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div>`;
}

export { tablaItems, tablaPagos };
