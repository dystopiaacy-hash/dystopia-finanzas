/* Pagos (fase 5): grilla de SOLO LECTURA sobre fin_pagos. Paginada del lado
   del servidor, con los filtros en la query. Programa, concepto, método y
   quién recibe muestran el valor del catálogo; si todavía no hay alias, el
   texto crudo del Sheet en gris. */
import { esc, fmtFecha, fmtNum, hoyAR, diasEntre, urlSegura, plural } from '../ui.js';
import { yo } from '../sesion.js';
import {
  pagosGrilla, catalogos, aliasPendientes, ultimoPagoPorCliente, pnlMensual, fuentes, usd, numCelda
} from '../datos.js';
import { statCard, vacio, selectCliente, selectAnio, selectMes, anios, clienteChip, botonRecargar } from './comunes.js';

const POR_PAGINA = 50;
/* Mauro queda afuera de la reestructuración (V3): no tiene catálogos. */
const SIN_CATALOGO = 'mauro';
const COLUMNAS = { programa: 'Programa', concepto: 'Concepto', metodo_pago: 'Método', quien_recibe: 'Quién recibe' };

export async function vistaPagos(el, vigente) {
  const conCatalogo = yo.clientes.filter(c => c.id !== SIN_CATALOGO);
  const [cats, mapaFuentes, ultimos, pendientes, pnl] = await Promise.all([
    catalogos(), fuentes(), ultimoPagoPorCliente(conCatalogo.map(c => c.id)), aliasPendientes(), pnlMensual()
  ]);
  if (!vigente()) return;
  const cat = new Map(cats.map(c => [c.id, c.valor]));
  const conceptos = cats.filter(c => c.dimension === 'concepto');
  const hoy = hoyAR();
  const anioHoy = Number(hoy.slice(0, 4));

  const f = { cliente: '', anio: anioHoy, mes: null, concepto: '', pendientes: false };
  let pagina = 0;
  let turno = 0;

  /* Los catálogos son por cliente: el filtro va por nombre del concepto y se
     traduce a los ids de los clientes elegidos. */
  const conceptosVisibles = () => conceptos.filter(c => !f.cliente || c.cliente_id === f.cliente);
  const opcionesConcepto = () => {
    const nombres = [...new Set(conceptosVisibles().map(c => c.valor))].sort((a, b) => a.localeCompare(b, 'es'));
    if (!nombres.includes(f.concepto)) f.concepto = '';
    return `<option value="">Todos los conceptos</option>${nombres.map(v =>
      `<option value="${esc(v)}"${v === f.concepto ? ' selected' : ''}>${esc(v)}</option>`).join('')}`;
  };

  el.innerHTML = `
    <div class="section-title">Último pago cargado<span class="line"></span></div>
    <div class="stat-row stat-row-6">${conCatalogo.map(c => tarjetaUltimo(c, ultimos.get(c.id), hoy)).join('')}</div>
    <div class="filter-row">
      <span class="flabel">Cliente</span>${selectCliente('f-cliente', f.cliente)}
      <span class="flabel">Año</span>${selectAnio('f-anio', anios(pnl, anioHoy), f.anio)}
      <span class="flabel">Mes</span>${selectMes('f-mes', f.mes, { todos: true })}
      <span class="flabel">Concepto</span><select id="f-concepto">${opcionesConcepto()}</select>
      <label class="flabel"><input type="checkbox" id="f-pend"> Solo pendientes de catálogo</label>
      <span class="grow"></span>${botonRecargar()}
    </div>
    <div id="grilla"></div>
    <div id="pendientes"></div>`;

  const grilla = el.querySelector('#grilla');

  const cargar = async () => {
    const mio = ++turno;
    grilla.innerHTML = '<div class="loading-inline">Cargando pagos…</div>';
    let r;
    try {
      r = await pagosGrilla({
        clienteId: f.cliente || null, anio: f.anio, mes: f.mes,
        conceptoIds: f.concepto ? conceptosVisibles().filter(c => c.valor === f.concepto).map(c => c.id) : null,
        soloPendientes: f.pendientes, pagina, porPagina: POR_PAGINA
      });
    } catch (e) {
      if (vigente() && mio === turno) grilla.innerHTML = `<div class="card"><p class="aviso-texto">${esc(e.message)}</p></div>`;
      return;
    }
    if (!vigente() || mio !== turno) return;
    grilla.innerHTML = tablaPagos(r, { pagina, verCliente: !f.cliente, cat, mapaFuentes });
    const ir = d => () => { pagina += d; cargar(); };
    const ant = grilla.querySelector('#pg-ant'), sig = grilla.querySelector('#pg-sig');
    if (ant) ant.onclick = ir(-1);
    if (sig) sig.onclick = ir(1);
  };

  const pintarPendientes = () => {
    el.querySelector('#pendientes').innerHTML = tablaPendientes(pendientes.filter(p => !f.cliente || p.cliente_id === f.cliente));
  };
  const filtrar = () => { pagina = 0; cargar(); };

  el.querySelector('#f-cliente').onchange = e => {
    f.cliente = e.target.value;
    el.querySelector('#f-concepto').innerHTML = opcionesConcepto();
    pintarPendientes();
    filtrar();
  };
  el.querySelector('#f-anio').onchange = e => { f.anio = Number(e.target.value); filtrar(); };
  el.querySelector('#f-mes').onchange = e => { f.mes = Number(e.target.value) || null; filtrar(); };
  el.querySelector('#f-concepto').onchange = e => { f.concepto = e.target.value; filtrar(); };
  el.querySelector('#f-pend').onchange = e => { f.pendientes = e.target.checked; filtrar(); };
  el.querySelector('#btn-recargar').onclick = () => vistaPagos(el, vigente);

  pintarPendientes();
  await cargar();
}

function tarjetaUltimo(c, fecha, hoy) {
  if (!fecha) return statCard('—', c.nombre, { sub: 'Sin pagos cargados' });
  const dias = diasEntre(fecha, hoy);
  const hace = dias === 0 ? 'hoy' : dias > 0 ? `hace ${plural(dias, 'día')}` : 'fecha futura';
  return statCard(fmtFecha(fecha), c.nombre, { sub: hace });
}

/* Valor del catálogo; sin *_id y con texto en el Sheet, el crudo en gris. */
function celdaCatalogo(p, columna, cat) {
  const valor = p[`${columna}_id`] != null ? cat.get(p[`${columna}_id`]) : null;
  if (valor) return esc(valor);
  const crudo = (p[columna] || '').trim();
  if (!crudo) return '—';
  if (p.cliente_id === SIN_CATALOGO) return esc(crudo);
  return `<span class="txt-gris" title="Sin valor de catálogo: pendiente">${esc(crudo)}</span>`;
}

function celdaComprobante(c) {
  if (!c) return '—';
  const url = urlSegura(c);
  return url ? `<a href="${esc(url)}" target="_blank" rel="noopener">abrir ↗</a>` : esc(c);
}

function tablaPagos({ filas, total }, { pagina, verCliente, cat, mapaFuentes }) {
  if (!total) return vacio('Sin pagos con estos filtros');
  const desde = pagina * POR_PAGINA;
  return `
    <div class="card table-card">
      <div class="card-titulo">Pagos <span class="txt-gris">· ${fmtNum(total)}</span></div>
      <table class="data-table data-table-dense">
        <thead><tr><th>Fecha</th>${verCliente ? '<th>Cliente</th>' : ''}<th>Alumno</th><th>Programa</th><th>Concepto</th>
          <th class="num">Monto USD</th><th>Método</th><th>Quién recibe</th><th>Closer</th><th>Setter</th>
          <th>Comprobante</th><th>Origen</th><th class="num">Fila</th></tr></thead>
        <tbody>${filas.map(p => `<tr>
          <td>${fmtFecha(p.fecha)}</td>${verCliente ? `<td>${clienteChip(p.cliente_id)}</td>` : ''}
          <td>${esc(p.alumno || '—')}</td>
          <td>${celdaCatalogo(p, 'programa', cat)}</td><td>${celdaCatalogo(p, 'concepto', cat)}</td>
          <td class="num">${usd(p.monto_usd, { centavos: true })}</td>
          <td>${celdaCatalogo(p, 'metodo_pago', cat)}</td><td>${celdaCatalogo(p, 'quien_recibe', cat)}</td>
          <td>${esc(p.closer || '—')}</td><td>${esc(p.setter || '—')}</td>
          <td>${celdaComprobante(p.comprobante)}</td>
          <td>${p.origen === 'app' ? 'App' : 'Sheet'}</td>
          <td class="num">${p.fila_planilla == null ? '—' : numCelda(String(p.fila_planilla), mapaFuentes.get(p.fuente_id), p.fila_planilla)}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>
    <div class="filter-row">
      <button type="button" class="btn btn-sm" id="pg-ant"${pagina === 0 ? ' disabled' : ''}>← Anterior</button>
      <span class="txt-gris">${fmtNum(desde + 1)} a ${fmtNum(desde + filas.length)} de ${fmtNum(total)}</span>
      <button type="button" class="btn btn-sm" id="pg-sig"${desde + filas.length >= total ? ' disabled' : ''}>Siguiente →</button>
    </div>`;
}

function tablaPendientes(lista) {
  const titulo = `<div class="section-title">Pendientes de catálogo<span class="line"></span></div>`;
  if (!lista.length) return `${titulo}${vacio('Sin pendientes de catálogo', 'Todos los textos del Sheet tienen valor de catálogo.')}`;
  return `${titulo}
    <div class="card table-card">
      <div class="card-titulo">Textos sin valor de catálogo <span class="txt-gris">· ${lista.length}</span></div>
      <table class="data-table data-table-dense">
        <thead><tr><th>Cliente</th><th>Columna</th><th>Texto en el Sheet</th><th class="num">Pagos</th><th class="num">USD</th></tr></thead>
        <tbody>${lista.map(p => `<tr>
          <td>${clienteChip(p.cliente_id)}</td><td>${esc(COLUMNAS[p.columna] || p.columna)}</td><td>${esc(p.crudo)}</td>
          <td class="num">${fmtNum(Number(p.pagos))}</td><td class="num">${usd(p.usd, { centavos: true })}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>
    <div class="table-foot">Se resuelven agregando un alias al catálogo. Ordenado por USD.</div>`;
}
