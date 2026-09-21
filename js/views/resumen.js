/* Resumen agencia: un mes, todos los clientes visibles (fundador: los 5;
   cliente: los suyos por RLS). Ingreso real = suma de fin_pagos; revenue
   declarado = items de REVENUE en Opps. Sin reparto ni comisiones. */
import { esc, hoyAR } from '../ui.js';
import { navegar } from '../router.js';
import { yo, esFundador } from '../sesion.js';
import { pnlMensual, salud, usd, MESES, MESES_CORTOS, ultimoPeriodo } from '../datos.js';
import {
  statCard, vacio, selectAnio, selectMes, anios, clienteChip, estadoFuente, peorEstado,
  requiereAccion, badgeEstado, botonRecargar
} from './comunes.js';

let periodo = null;   // { anio, mes } elegido; se conserva entre visitas

const n = v => Number(v) || 0;
const claseDif = d => (Math.abs(d) > 1 ? ' txt-rojo' : '');

export async function vistaResumen(el, vigente) {
  const [filas, saludFilas] = await Promise.all([
    pnlMensual(),
    esFundador() ? salud() : Promise.resolve([])
  ]);
  if (!vigente()) return;
  if (!filas.length) {
    el.innerHTML = vacio('Todavía no hay datos sincronizados',
      esFundador() ? 'Mirá Salud de sincronización: si nunca corrió, falta deployar la Edge Function o correr 005.' : 'Volvé a intentar más tarde.');
    return;
  }
  if (!periodo) periodo = ultimoPeriodo(filas, hoyAR());
  const estadoPorCliente = new Map();
  for (const f of saludFilas) {
    const e = estadoFuente(f);
    if (e === 'inactiva') continue;
    estadoPorCliente.set(f.cliente_id, peorEstado([estadoPorCliente.get(f.cliente_id) || 'ok', e]));
  }
  const problemas = saludFilas.filter(f => requiereAccion(estadoFuente(f))).length;

  const pintar = () => {
    const { anio, mes } = periodo;
    const delMes = filas.filter(f => f.anio === anio && f.mes === mes);
    const porCliente = yo.clientes.map(c => delMes.find(f => f.cliente_id === c.id) || { cliente_id: c.id, vacio: true });
    const tot = k => delMes.reduce((s, f) => s + n(f[k]), 0);
    const difTotal = delMes.reduce((s, f) => s + Math.abs(n(f.revenue_declarado) - n(f.ingreso_real)), 0);

    const delAnio = filas.filter(f => f.anio === anio);
    const meses = [...new Set(delAnio.map(f => f.mes))].sort((a, b) => a - b);

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Periodo</span>${selectMes('f-mes', mes)}${selectAnio('f-anio', anios(filas, anio), anio)}
        <span class="grow"></span>${botonRecargar()}
      </div>
      <div class="stat-row stat-row-6">
        ${statCard(usd(tot('ingreso_real')), 'Ingreso real (Pagos)', { sub: `${tot('cantidad_pagos')} pagos` })}
        ${statCard(usd(tot('revenue_declarado')), 'Revenue declarado (Opps)')}
        ${statCard(usd(tot('gastos_total')), 'Gastos (Opps)')}
        ${statCard(usd(tot('net_cash_flow')), 'Net cash flow', { sub: 'Revenue declarado − gastos' })}
        ${statCard(usd(difTotal), 'Diferencia Opps vs Pagos', { sub: 'Suma de |diferencia| por cliente', alerta: difTotal > 1 })}
        ${esFundador() ? statCard(`<a href="#/salud" class="stat-link">${problemas}</a>`, 'Fuentes que requieren acción', { html: true, alerta: problemas > 0 }) : ''}
      </div>

      <div class="section-title">${esc(MESES[mes - 1])} ${anio} por cliente<span class="line"></span></div>
      <div class="card table-card">
        <table class="data-table">
          <thead><tr>
            <th>Cliente</th><th class="num">Ingreso real</th><th class="num">Revenue Opps</th><th class="num">Diferencia</th>
            <th class="num">Gastos</th><th class="num">Net cash flow</th><th class="num">Pagos</th>${esFundador() ? '<th>Sincronización</th>' : ''}
          </tr></thead>
          <tbody>
            ${porCliente.map(f => {
              const dif = n(f.revenue_declarado) - n(f.ingreso_real);
              return `<tr data-action="cliente" data-id="${esc(f.cliente_id)}">
                <td>${clienteChip(f.cliente_id)}</td>
                <td class="num">${f.vacio ? '—' : usd(f.ingreso_real)}</td>
                <td class="num">${f.vacio ? '—' : usd(f.revenue_declarado)}</td>
                <td class="num${claseDif(dif)}">${f.vacio ? '—' : usd(dif)}</td>
                <td class="num">${f.vacio ? '—' : usd(f.gastos_total)}</td>
                <td class="num">${f.vacio ? '—' : usd(f.net_cash_flow)}</td>
                <td class="num">${f.vacio ? '—' : n(f.cantidad_pagos)}</td>
                ${esFundador() ? `<td>${badgeEstado(estadoPorCliente.get(f.cliente_id) || 'sin_corridas')}</td>` : ''}
              </tr>`;
            }).join('')}
          </tbody>
        </table>
      </div>
      <div class="table-foot">Clic en un cliente para ver su P&amp;L y el detalle con link a cada celda.</div>

      <div class="section-title">${anio} mes a mes, todos los clientes<span class="line"></span></div>
      <div class="card table-card">
        <table class="data-table data-table-dense">
          <thead><tr><th></th>${meses.map(m => `<th class="num">${MESES_CORTOS[m - 1]}</th>`).join('')}</tr></thead>
          <tbody>
            ${[['ingreso_real', 'Ingreso real'], ['revenue_declarado', 'Revenue Opps'], ['gastos_total', 'Gastos'], ['net_cash_flow', 'Net cash flow']]
              .map(([k, label]) => `<tr><td>${label}</td>${meses.map(m => {
                const v = delAnio.filter(f => f.mes === m).reduce((s, f) => s + n(f[k]), 0);
                return `<td class="num">${usd(v)}</td>`;
              }).join('')}</tr>`).join('')}
          </tbody>
        </table>
      </div>`;

    el.querySelector('#f-mes').onchange = e => { periodo = { ...periodo, mes: Number(e.target.value) }; pintar(); };
    el.querySelector('#f-anio').onchange = e => { periodo = { ...periodo, anio: Number(e.target.value) }; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaResumen(el, vigente);
    for (const tr of el.querySelectorAll('tr[data-action="cliente"]')) {
      tr.onclick = () => navegar(`cliente/${encodeURIComponent(tr.dataset.id)}?anio=${periodo.anio}&mes=${periodo.mes}`);
    }
  };
  pintar();
}
