/* Dystopia (solo fundador, o quien figure en fin_dys_acceso): por mes, el ingreso de la agencia (comisión de
   cada cliente sobre su ingreso real de Pagos), sus gastos (propios + su % de los compartidos) y la ganancia
   neta, con el desglose por cliente. Todo sale de fin_v_dys_mes y fin_v_ia_uso_mes (migración 174). */
import { esc, fmtPct } from '../ui.js';
import { usd } from '../datos.js';
import { dysMes, iaUsoMes, nombreEntidad, sumar, claveMes, mesesDe, etiquetaMes, veGastos, veIaUso, llamadas } from '../gastos.js';
import { statCard, vacio, botonRecargar, etiquetarTablas } from './comunes.js';

const ORDEN_CLI = ['liam', 'agus', 'teo'];
const neto = n => `<span class="${n < 0 ? 'txt-rojo' : ''}">${usd(n, { centavos: true })}</span>`;

export async function vistaDystopia(el, vigente) {
  const [filas, ia] = await Promise.all([dysMes(), iaUsoMes().catch(() => [])]);
  if (!vigente()) return;
  if (!filas.length) {
    el.innerHTML = vacio('Todavía no hay datos de Dystopia', 'Aparecen cuando hay pagos de los clientes con su porcentaje de comisión cargado, o gastos cargados.');
    return;
  }
  const meses = mesesDe(filas);
  let mes = meses[0];

  const pintar = () => {
    const delMes = filas.filter(f => claveMes(f.mes) === mes);
    const clientes = delMes.filter(f => f.entidad !== 'dystopia');
    const propia = delMes.find(f => f.entidad === 'dystopia');
    const ingreso = sumar(delMes, 'ingreso_usd');
    const gastos = sumar(delMes, 'gasto_dystopia_usd');
    const sinAsig = ia.filter(f => claveMes(f.mes) === mes && f.sin_asignar);
    const iaSinAsignar = sumar(sinAsig, 'costo_usd');
    const sinPct = clientes.filter(f => f.base_usd && f.porcentaje == null);

    const filaTabla = f => `<tr>
      <td class="ajusta">${esc(nombreEntidad(f.entidad))}</td>
      <td class="num">${f.entidad === 'dystopia' ? '—' : usd(f.base_usd, { centavos: true })}</td>
      <td class="num">${f.porcentaje == null ? '—' : fmtPct(f.porcentaje, 1)}</td>
      <td class="num">${usd(f.ingreso_usd, { centavos: true })}</td>
      <td class="num">${usd(f.gasto_dystopia_usd, { centavos: true })}</td>
      <td class="num">${usd(f.gasto_ia_dystopia_usd, { centavos: true })}</td>
      <td class="num">${neto(Number(f.neto_usd) || 0)}</td></tr>`;

    /* Todos los meses del año del mes elegido, con el ingreso de cada cliente y un total del año (suma de valores sin redondear). */
    const anio = mes.slice(0, 4);
    const delAnio = filas.filter(f => claveMes(f.mes).slice(0, 4) === anio);
    const cols = ORDEN_CLI.filter(c => delAnio.some(f => f.entidad === c));
    const celdas = d => `${cols.map(c => `<td class="num">${usd(sumar(d.filter(f => f.entidad === c), 'ingreso_usd'), { centavos: true })}</td>`).join('')}
        <td class="num">${usd(sumar(d, 'ingreso_usd'), { centavos: true })}</td><td class="num">${usd(sumar(d, 'gasto_dystopia_usd'), { centavos: true })}</td>
        <td class="num">${usd(sumar(d, 'gasto_ia_dystopia_usd'), { centavos: true })}</td>
        <td class="num">${neto(sumar(d, 'ingreso_usd') - sumar(d, 'gasto_dystopia_usd'))}</td>`;
    const hist = meses.filter(m => m.slice(0, 4) === anio).map(m => `<tr class="${m === mes ? 'fila-activa' : ''}" data-mes="${m}" style="cursor:pointer">
        <td class="ajusta">${esc(etiquetaMes(m))}</td>${celdas(filas.filter(f => claveMes(f.mes) === m))}</tr>`).join('')
      + `<tr class="pnl-fuerte"><td>Total ${esc(anio)}</td>${celdas(delAnio)}</tr>`;

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Mes</span>
        <select id="dys-mes">${meses.map(m => `<option value="${m}"${m === mes ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('')}</select>
        <span class="grow"></span>
        ${veGastos() ? '<a class="btn btn-sm" href="#/gastos">Gastos</a>' : ''}
        ${veIaUso() ? '<a class="btn btn-sm" href="#/ia-uso">Gasto de IA</a>' : ''}
        ${botonRecargar()}
      </div>
      ${iaSinAsignar > 0 ? `<div class="card nota aviso-ambar">IA sin asignar a un cliente en ${esc(etiquetaMes(mes))}:
        <strong>${usd(iaSinAsignar, { centavos: true })}</strong> (${llamadas(sumar(sinAsig, 'llamadas'))}). Está cargado 100% a Dystopia (fila Dystopia, «de los cuales IA»).</div>` : ''}
      ${sinPct.length ? `<div class="card nota aviso-ambar">Falta el porcentaje de comisión de ${esc(sinPct.map(f => nombreEntidad(f.entidad)).join(', '))}
        en este mes: su ingreso figura en 0 hasta que se cargue su porcentaje de comisión.</div>` : ''}
      <div class="grid-3 stat-grid">
        ${statCard(usd(ingreso, { centavos: true }), 'Ingreso de Dystopia', { sub: 'Comisión sobre el ingreso real de cada cliente' })}
        ${statCard(usd(gastos, { centavos: true }), 'Gastos de Dystopia', { sub: 'Propios + su % de los compartidos' })}
        ${statCard(usd(ingreso - gastos, { centavos: true }), 'Ganancia neta', { alerta: ingreso - gastos < 0 })}
      </div>
      <div class="card-titulo">${esc(etiquetaMes(mes))} por cliente</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Cliente</th><th class="num">Base (ingreso real)</th><th class="num">% Dystopia</th><th class="num">Ingreso</th>
          <th class="num">Gastos Dystopia</th><th class="num">de los cuales IA</th><th class="num clave">Neto</th></tr></thead>
        <tbody>${clientes.map(filaTabla).join('')}${propia ? filaTabla(propia) : ''}
          <tr class="pnl-fuerte"><td>Total</td><td></td><td></td><td class="num">${usd(ingreso, { centavos: true })}</td>
            <td class="num">${usd(gastos, { centavos: true })}</td><td class="num">${usd(sumar(delMes, 'gasto_ia_dystopia_usd'), { centavos: true })}</td>
            <td class="num">${neto(ingreso - gastos)}</td></tr></tbody>
      </table></div>
      <div class="table-foot">Base = ingreso real del cliente en Pagos del mes (el mismo de su P&amp;L). Ingreso = base × % de comisión vigente ese mes.
        Gastos Dystopia = gastos propios + el % de Dystopia de los gastos de cada cliente (reparto «compartido según comisión»: ese mismo %;
        «100% Dystopia»: todo; «100% cliente»: nada). El detalle está en Gastos.</div>
      <div class="card-titulo">Todos los meses de ${esc(anio)}</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Mes</th>${cols.map(c => `<th class="num">Ingreso ${esc(nombreEntidad(c))}</th>`).join('')}<th class="num">Ingreso</th>
          <th class="num">Gastos</th><th class="num">de los cuales IA</th><th class="num clave">Neto</th></tr></thead>
        <tbody>${hist}</tbody></table></div>`;
    etiquetarTablas(el);

    el.querySelector('#dys-mes').onchange = e => { mes = e.target.value; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaDystopia(el, vigente);
    for (const tr of el.querySelectorAll('tr[data-mes]')) tr.onclick = () => { mes = tr.dataset.mes; pintar(); };
  };
  pintar();
}
