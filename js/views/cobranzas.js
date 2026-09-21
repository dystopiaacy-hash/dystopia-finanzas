/* Cobranzas: cuotas pendientes (fin_v_cobranzas). Fundador y cliente ven las
   de sus clientes; un closer solo las suyas (RLS); un setter no entra. */
import { esc, fmtFecha, semaforo } from '../ui.js';
import { cobranzas, fuentePorCuota, fuentes, usd, numCelda } from '../datos.js';
import { statCard, vacio, selectCliente, clienteChip, botonRecargar } from './comunes.js';

const n = v => Number(v) || 0;
let filtro = { cliente: '', ver: 'todas', texto: '' };

function nivel(c) {
  if (c.vencida) return ['rojo', `Vencida · ${Math.abs(c.dias_al_vencimiento)} d`];
  if (c.dias_al_vencimiento == null) return ['gris', 'Sin fecha'];
  if (c.dias_al_vencimiento <= 7) return ['amarillo', c.dias_al_vencimiento === 0 ? 'Vence hoy' : `En ${c.dias_al_vencimiento} d`];
  return ['verde', `En ${c.dias_al_vencimiento} d`];
}

export async function vistaCobranzas(el, vigente) {
  const [filas, cuotaFuente, mapaFuentes] = await Promise.all([cobranzas(), fuentePorCuota(), fuentes()]);
  if (!vigente()) return;
  if (!filas.length) {
    el.innerHTML = vacio('No hay cuotas pendientes', 'O todavía no se sincronizó ninguna hoja de cuotas.');
    return;
  }

  const pintar = () => {
    const t = filtro.texto.trim().toLowerCase();
    const lista = filas
      .filter(c => !filtro.cliente || c.cliente_id === filtro.cliente)
      .filter(c => filtro.ver === 'todas'
        || (filtro.ver === 'vencidas' && c.vencida)
        || (filtro.ver === 'semana' && !c.vencida && c.dias_al_vencimiento != null && c.dias_al_vencimiento <= 7))
      .filter(c => !t || `${c.alumno} ${c.programa || ''} ${c.closer || ''}`.toLowerCase().includes(t));
    const base = filas.filter(c => !filtro.cliente || c.cliente_id === filtro.cliente);
    const pendiente = c => n(c.monto) - n(c.monto_cobrado);
    const suma = arr => arr.reduce((s, c) => s + pendiente(c), 0);
    const vencidas = base.filter(c => c.vencida);
    const semana = base.filter(c => !c.vencida && c.dias_al_vencimiento != null && c.dias_al_vencimiento <= 7);

    el.innerHTML = `
      <div class="filter-row">
        ${selectCliente('f-cliente', filtro.cliente)}
        <select id="f-ver">
          ${[['todas', 'Todas las pendientes'], ['vencidas', 'Vencidas'], ['semana', 'Vencen en 7 días']]
            .map(([v, l]) => `<option value="${v}"${filtro.ver === v ? ' selected' : ''}>${l}</option>`).join('')}
        </select>
        <input type="search" class="search-input" id="f-texto" placeholder="Buscar alumno, programa o closer" value="${esc(filtro.texto)}">
        ${botonRecargar()}
      </div>
      <div class="stat-row">
        ${statCard(usd(suma(base)), 'Pendiente de cobro', { sub: `${base.length} cuotas` })}
        ${statCard(usd(suma(vencidas)), 'Vencido', { sub: `${vencidas.length} cuotas`, alerta: vencidas.length > 0 })}
        ${statCard(usd(suma(semana)), 'Vence en 7 días', { sub: `${semana.length} cuotas` })}
      </div>
      <div class="card table-card">
        <table class="data-table">
          <thead><tr><th>Cliente</th><th>Alumno</th><th>Programa</th><th>Cuota</th><th>Vence</th><th>Estado</th>
            <th>Closer</th><th class="num">Monto</th><th class="num">Cobrado</th></tr></thead>
          <tbody>
            ${lista.map(c => {
              const f = mapaFuentes.get(cuotaFuente.get(c.id));
              const [niv, txt] = nivel(c);
              return `<tr>
                <td>${clienteChip(c.cliente_id)}</td>
                <td title="${esc(c.alumno)}">${esc(c.alumno)}</td>
                <td title="${esc(c.programa || '')}">${esc(c.programa || '—')}</td>
                <td>${esc(c.tipo_cuota || (c.numero_cuota ? `Cuota ${c.numero_cuota}` : '—'))}</td>
                <td>${fmtFecha(c.fecha_pago)} ${semaforo(niv, txt)}</td>
                <td title="${esc(c.contexto || '')}">${esc(c.estado || '—')}</td>
                <td>${esc(c.closer || '—')}</td>
                <td class="num">${c.monto == null ? '—' : numCelda(usd(c.monto), f, c.fila_planilla)}</td>
                <td class="num">${c.monto_cobrado == null ? '—' : usd(c.monto_cobrado)}</td>
              </tr>`;
            }).join('') || `<tr><td colspan="9" class="muted-empty">Sin cuotas para este filtro.</td></tr>`}
          </tbody>
        </table>
      </div>
      <div class="table-foot">Pendiente = estado vacío o distinto de pagado, churn, pausado o cancelado (supuesto a validar con la agencia).</div>`;

    el.querySelector('#f-cliente').onchange = e => { filtro.cliente = e.target.value; pintar(); };
    el.querySelector('#f-ver').onchange = e => { filtro.ver = e.target.value; pintar(); };
    const inp = el.querySelector('#f-texto');
    inp.oninput = e => {
      filtro.texto = e.target.value;
      const pos = e.target.selectionStart;
      pintar();
      const nuevo = el.querySelector('#f-texto');
      nuevo.focus();
      nuevo.setSelectionRange(pos, pos);
    };
    el.querySelector('#btn-recargar').onclick = () => vistaCobranzas(el, vigente);
  };
  pintar();
}
