/* Dystopia (solo fundador, o quien figure en fin_dys_acceso). Desde la migración 267 el porcentaje de Dystopia es sobre la
   GANANCIA de cada cliente: ganancia del cliente = facturación del mes - todos los gastos del cliente (Opps, gastos cargados,
   gastos de webinar). Ganancia bruta de Dystopia = suma de lo que le toca de cada cliente; neta = bruta - sus gastos propios
   (sueldo de Joaquín incluido). Datos de fin_v_dys_ganancia_mes. */
import { esc, fmtPct } from '../ui.js';
import { usd } from '../datos.js';
import { dysGananciaMes, iaUsoMes, comisiones, gastosFijosDys, nombreEntidad, editaGastos, sumar, claveMes, mesesDe, etiquetaMes,
  veGastos, veIaUso, llamadas } from '../gastos.js';
import { statCard, vacio, botonRecargar, etiquetarTablas } from './comunes.js';
import { tablaConfig, abrirPorcentaje, abrirGastoFijo } from './dys-config.js';

const ORDEN_CLI = ['liam', 'agus', 'teo'];
const u = n => usd(n, { centavos: true });
const neto = n => `<span class="${n < 0 ? 'txt-rojo' : ''}">${u(n)}</span>`;

export async function vistaDystopia(el, vigente) {
  const [filas, ia, coms, fijos] = await Promise.all([dysGananciaMes(), iaUsoMes().catch(() => []), comisiones().catch(() => []), gastosFijosDys().catch(() => [])]);
  if (!vigente()) return;
  if (!filas.length) {
    el.innerHTML = vacio('Todavía no hay datos de Dystopia', 'Aparecen cuando hay pagos o gastos de los clientes con su porcentaje cargado.');
    return;
  }
  const meses = mesesDe(filas);
  let mes = meses[0];
  const puede = editaGastos();
  const recargar = () => vistaDystopia(el, vigente);

  const pintar = () => {
    const delMes = filas.filter(f => claveMes(f.mes) === mes);
    const clientes = delMes.filter(f => f.entidad !== 'dystopia');
    const propia = delMes.find(f => f.entidad === 'dystopia');
    const bruta = sumar(clientes, 'ganancia_dystopia_usd');
    const gastoPropio = propia ? Number(propia.gasto_propio_usd) : 0;
    const sueldo = propia ? Number(propia.sueldo_usd) : 0;
    const sinAsig = ia.filter(f => claveMes(f.mes) === mes && f.sin_asignar);
    const iaSinAsignar = sumar(sinAsig, 'costo_usd');
    const sinGastos = clientes.filter(f => f.sin_gastos);
    const sinPct = clientes.filter(f => f.falta_porcentaje && Number(f.facturacion_usd));

    const filaCli = f => `<tr>
      <td class="ajusta">${esc(nombreEntidad(f.entidad))}${f.sin_gastos ? ' <span class="badge" title="Sin gastos cargados: la ganancia está sobreestimada">⚠ sin gastos</span>' : ''}${f.comision_modo === 'opps' && Number(f.comision_opps_vigente_usd) ? ' <span class="badge" title="Este mes no tiene comisiones calculadas en el Cierre de mes: las comisiones salen de las líneas de Opps">comisiones de Opps</span>' : ''}</td>
      <td class="num">${u(f.facturacion_usd)}</td>
      <td class="num">${u(f.gastos_cliente_usd)}</td>
      <td class="num">${neto(Number(f.ganancia_cliente_usd))}</td>
      <td class="num">${f.porcentaje == null ? '—' : fmtPct(f.porcentaje, 1)}</td>
      <td class="num">${u(f.ganancia_dystopia_usd)}</td>
      <td class="num">${u(f.ingreso_viejo_usd)}</td></tr>`;

    /* Todos los meses del año del mes elegido: ganancia de Dystopia por cliente, gastos propios y neta; total del año. */
    const anio = mes.slice(0, 4);
    const delAnio = filas.filter(f => claveMes(f.mes).slice(0, 4) === anio);
    const cols = ORDEN_CLI.filter(c => delAnio.some(f => f.entidad === c));
    const celdas = d => {
      const b = sumar(d.filter(f => f.entidad !== 'dystopia'), 'ganancia_dystopia_usd'), g = sumar(d, 'gasto_propio_usd');
      return `${cols.map(c => `<td class="num">${u(sumar(d.filter(f => f.entidad === c), 'ganancia_dystopia_usd'))}</td>`).join('')}
        <td class="num">${u(b)}</td><td class="num">${u(g)}</td><td class="num">${neto(b - g)}</td>`;
    };
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
      ${sinGastos.length ? `<div class="card nota aviso-ambar">Sin gastos cargados en ${esc(etiquetaMes(mes))}: <strong>${esc(sinGastos.map(f => nombreEntidad(f.entidad)).join(', '))}</strong>.
        Ganancia sobreestimada: se calcula sobre toda la facturación hasta que se carguen sus gastos (Opps, Gastos o Webinars).</div>` : ''}
      ${sinPct.length ? `<div class="card nota aviso-ambar">Falta el porcentaje de ${esc(sinPct.map(f => nombreEntidad(f.entidad)).join(', '))} en este mes: su ganancia para Dystopia figura en 0 hasta cargarlo (abajo).</div>` : ''}
      ${iaSinAsignar > 0 ? `<div class="card nota aviso-ambar">IA sin asignar a un cliente en ${esc(etiquetaMes(mes))}:
        <strong>${u(iaSinAsignar)}</strong> (${llamadas(sumar(sinAsig, 'llamadas'))}). Está cargado 100% a Dystopia (gastos propios).</div>` : ''}
      <div class="grid-3 stat-grid">
        ${statCard(u(bruta), 'Ganancia bruta de Dystopia', { sub: 'Lo que le toca de la ganancia de cada cliente' })}
        ${statCard(u(gastoPropio), 'Gastos de Dystopia', { sub: sueldo ? `Incluye sueldo de Joaquín ${u(sueldo)}` : 'Propios (sin sueldo cargado este mes)' })}
        ${statCard(u(bruta - gastoPropio), 'Ganancia neta', { alerta: bruta - gastoPropio < 0 })}
      </div>
      <div class="card-titulo">${esc(etiquetaMes(mes))} por cliente</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Cliente</th><th class="num">Facturación</th><th class="num">Gastos del cliente</th><th class="num">Ganancia del cliente</th>
          <th class="num">% Dystopia</th><th class="num clave">Ganancia Dystopia</th><th class="num">Antes (% s/ facturación)</th></tr></thead>
        <tbody>${clientes.map(filaCli).join('')}
          <tr class="pnl-fuerte"><td>Total clientes</td><td class="num">${u(sumar(clientes, 'facturacion_usd'))}</td><td class="num">${u(sumar(clientes, 'gastos_cliente_usd'))}</td>
            <td class="num">${neto(sumar(clientes, 'ganancia_cliente_usd'))}</td><td></td><td class="num">${u(bruta)}</td><td class="num">${u(sumar(clientes, 'ingreso_viejo_usd'))}</td></tr></tbody>
      </table></div>
      <div class="table-foot">Ganancia del cliente = facturación - gastos (Opps + gastos cargados + webinars que no estén ya en Opps). Ganancia Dystopia = ganancia × %.
        La última columna es el cálculo anterior, solo para comparar. Gastos propios de Dystopia: ${u(gastoPropio)}${sueldo ? ` (sueldo ${u(sueldo)})` : ''}.</div>
      <div class="card-titulo">Todos los meses de ${esc(anio)}</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Mes</th>${cols.map(c => `<th class="num">Ganancia ${esc(nombreEntidad(c))}</th>`).join('')}<th class="num">Bruta</th>
          <th class="num">Gastos propios</th><th class="num clave">Neta</th></tr></thead>
        <tbody>${hist}</tbody></table></div>
      ${tablaConfig(coms, fijos, puede)}`;
    etiquetarTablas(el);

    el.querySelector('#dys-mes').onchange = e => { mes = e.target.value; pintar(); };
    el.querySelector('#btn-recargar').onclick = recargar;
    for (const tr of el.querySelectorAll('tr[data-mes]')) tr.onclick = () => { mes = tr.dataset.mes; pintar(); };
    const q = s => el.querySelector(s);
    if (q('#cfg-pct-nuevo')) q('#cfg-pct-nuevo').onclick = () => abrirPorcentaje(null, recargar);
    if (q('#cfg-fijo-nuevo')) q('#cfg-fijo-nuevo').onclick = () => abrirGastoFijo(null, recargar);
    for (const b of el.querySelectorAll('[data-pct]')) b.onclick = () => abrirPorcentaje(coms.find(c => c.id === Number(b.dataset.pct)), recargar);
    for (const b of el.querySelectorAll('[data-fijo]')) b.onclick = () => abrirGastoFijo(fijos.find(f => f.id === Number(b.dataset.fijo)), recargar);
  };
  pintar();
}
