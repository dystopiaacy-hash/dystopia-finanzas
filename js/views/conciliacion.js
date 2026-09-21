/* Conciliación: por cliente y mes, el Total Revenue de Opps (suma de items
   de REVENUE) contra la suma de fin_pagos. diferencia > 0: Opps declara más
   de lo que figura en Pagos. Clic en una fila: los items y los pagos del mes,
   cada uno con link a su celda. */
import { esc, hoyAR } from '../ui.js';
import { conciliacion, pnlItems, pagos, fuentes, usd, MESES } from '../datos.js';
import { statCard, vacio, selectCliente, selectAnio, anios, clienteChip, botonRecargar } from './comunes.js';
import { tablaItems, tablaPagos } from './cliente.js';

const n = v => Number(v) || 0;
const UMBRAL = 1;   // USD: diferencias de centavos por redondeo no cuentan
let filtro = { cliente: '', anio: null, soloDif: false };

export async function vistaConciliacion(el, vigente) {
  const [filas, mapaFuentes] = await Promise.all([conciliacion(), fuentes()]);
  if (!vigente()) return;
  if (!filas.length) { el.innerHTML = vacio('Todavía no hay datos sincronizados'); return; }
  const hoy = hoyAR();
  const [ha, hm] = hoy.split('-').map(Number);
  if (!filtro.anio) filtro.anio = anios(filas, null)[0];

  const pintar = () => {
    const lista = filas
      .filter(f => f.anio === filtro.anio && (!filtro.cliente || f.cliente_id === filtro.cliente))
      .filter(f => !filtro.soloDif || Math.abs(n(f.diferencia)) > UMBRAL)
      .sort((a, b) => (b.mes - a.mes) || a.cliente_id.localeCompare(b.cliente_id));
    const conDif = lista.filter(f => Math.abs(n(f.diferencia)) > UMBRAL);
    const futuros = lista.filter(f => f.anio > ha || (f.anio === ha && f.mes > hm));

    el.innerHTML = `
      <div class="filter-row">
        ${selectCliente('f-cliente', filtro.cliente)}${selectAnio('f-anio', anios(filas, filtro.anio), filtro.anio)}
        <label class="check-inline"><input type="checkbox" id="f-dif"${filtro.soloDif ? ' checked' : ''}> Solo con diferencia</label>
        <span class="grow"></span>${botonRecargar()}
      </div>
      <div class="stat-row">
        ${statCard(String(conDif.length), 'Meses con diferencia', { sub: `de ${lista.length} meses-cliente`, alerta: conDif.length > 0 })}
        ${statCard(usd(conDif.reduce((s, f) => s + Math.abs(n(f.diferencia)), 0)), 'Suma de |diferencia|')}
        ${statCard(usd(lista.reduce((s, f) => s + n(f.revenue_opps), 0)), 'Revenue declarado (Opps)')}
        ${statCard(usd(lista.reduce((s, f) => s + n(f.revenue_pagos), 0)), 'Suma de Pagos')}
      </div>
      ${conDif.length ? '' : `<div class="card nota">${explicarSinDiferencias(lista)}</div>`}
      ${futuros.length ? `<div class="table-foot">Hay ${futuros.length} meses posteriores a hoy con valores en Opps: suelen ser proyecciones o fechas mal cargadas.</div>` : ''}
      <div class="card table-card">
        <table class="data-table">
          <thead><tr><th>Cliente</th><th>Mes</th><th class="num">Revenue Opps</th><th class="num">Suma Pagos</th>
            <th class="num">Pagos</th><th class="num">Diferencia</th><th class="num">%</th></tr></thead>
          <tbody>
            ${lista.map((f, i) => {
              const dif = n(f.diferencia);
              const mal = Math.abs(dif) > UMBRAL;
              return `<tr data-action="ver" data-i="${i}">
                <td>${clienteChip(f.cliente_id)}</td>
                <td>${esc(MESES[f.mes - 1])} ${f.anio}</td>
                <td class="num">${usd(f.revenue_opps)}</td>
                <td class="num">${usd(f.revenue_pagos)}</td>
                <td class="num">${n(f.cantidad_pagos)}</td>
                <td class="num${mal ? ' txt-rojo' : ''}">${usd(dif, { centavos: true })}</td>
                <td class="num${mal ? ' txt-rojo' : ''}">${f.diferencia_pct == null ? '—' : `${String(f.diferencia_pct).replace('.', ',')}%`}</td>
              </tr>`;
            }).join('') || `<tr><td colspan="7" class="muted-empty">Sin filas para este filtro.</td></tr>`}
          </tbody>
        </table>
      </div>
      <div id="concilia-detalle"></div>`;

    el.querySelector('#f-cliente').onchange = e => { filtro.cliente = e.target.value; pintar(); };
    el.querySelector('#f-anio').onchange = e => { filtro.anio = Number(e.target.value); pintar(); };
    el.querySelector('#f-dif').onchange = e => { filtro.soloDif = e.target.checked; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaConciliacion(el, vigente);
    for (const tr of el.querySelectorAll('tr[data-action="ver"]')) {
      tr.onclick = () => verDetalle(el, lista[Number(tr.dataset.i)], mapaFuentes, vigente);
    }
  };
  pintar();
}

function explicarSinDiferencias(lista) {
  if (!lista.length) return 'No hay meses para este filtro.';
  const soloOpps = lista.filter(f => n(f.revenue_opps) && !n(f.cantidad_pagos)).length;
  return `Todo cuadra (|diferencia| ≤ ${UMBRAL} USD) en los ${lista.length} meses del filtro: la suma de los pagos
    de cada mes es igual al Total Revenue que declara Opps.${soloOpps ? ` Ojo: ${soloOpps} meses tienen revenue en Opps y ningún pago.` : ''}`;
}

async function verDetalle(el, f, mapaFuentes, vigente) {
  const cont = el.querySelector('#concilia-detalle');
  cont.innerHTML = `<div class="section-title">${esc(MESES[f.mes - 1])} ${f.anio} · ${clienteChip(f.cliente_id)}<span class="line"></span></div>
    <div class="loading-inline">Cargando…</div>`;
  cont.scrollIntoView({ behavior: 'smooth', block: 'start' });
  const [items, lista] = await Promise.all([pnlItems(f.cliente_id, f.anio, f.mes), pagos({ clienteId: f.cliente_id, anio: f.anio, mes: f.mes })]);
  if (!vigente()) return;
  const revenue = items.filter(i => i.categoria === 'revenue');
  cont.innerHTML = `<div class="section-title">${esc(MESES[f.mes - 1])} ${f.anio} · ${clienteChip(f.cliente_id)}
      <span class="line"></span><span class="txt-${Math.abs(n(f.diferencia)) > UMBRAL ? 'rojo' : 'gris'}">Diferencia ${usd(f.diferencia, { centavos: true })}</span></div>
    <div class="grid-2 detalle-grid">${tablaItems(revenue, mapaFuentes)}${tablaPagos(lista, mapaFuentes)}</div>`;
}
