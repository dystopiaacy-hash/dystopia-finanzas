/* Pagos: grilla sobre fin_pagos. Paginada del lado del servidor, con los
   filtros en la query. Programa, concepto, método y quién recibe muestran el
   valor del catálogo; si todavía no hay alias, el texto crudo del Sheet en gris.
   Fase 6: donde fin_clientes_carga() da puede_anular, cada pago positivo se
   puede devolver y los cargados en la app se pueden anular (RPC de la 066).
   El rol cliente ve solo sus clientes de fin_clientes_carga(), sin pendientes.
   072: con un cliente elegido, las columnas salen de fin_columnas_de(cliente,
   'pagos') y se editan en la celda (pagos-celdas.js). Con "Todos los clientes",
   las del sistema con su nombre por defecto, sin columnas nuevas ni edición. */
import { esc, fmtFecha, fmtNum, hoyAR, diasEntre, plural, abrirModal, toast } from '../ui.js';
import { yo, esFundador, puedeAnular, nombreCliente } from '../sesion.js';
import {
  pagosGrilla, catalogos, aliasPendientes, ultimoPagoPorCliente, pnlMensual, fuentes, usd,
  pagoAnular, pagoDevolver, cargaOpciones
} from '../datos.js';
import { columnasDe, pagosExtra, extrasHuerfanos, armarColumnas } from '../columnas.js';
import { statCard, vacio, selectAnio, selectMes, anios, clienteChip, botonRecargar } from './comunes.js';
import { BASE_PAGOS, SIN_CATALOGO, thPago, tdPago, manejarCambio, manejarTecla } from './pagos-celdas.js';
import { abrirPanelColumnas, botonColumnas } from './columnas-panel.js';

const POR_PAGINA = 50;
const COLUMNAS = { programa: 'Programa', concepto: 'Concepto', metodo_pago: 'Método', quien_recibe: 'Quién recibe' };

export async function vistaPagos(el, vigente) {
  const fundador = esFundador();
  /* El fundador ve todo; el cliente, solo sus clientes de fin_clientes_carga(). */
  const clientes = fundador ? yo.clientes : yo.clientes.filter(c => yo.carga.some(x => x.cliente_id === c.id));
  const conCatalogo = clientes.filter(c => c.id !== SIN_CATALOGO);
  const [cats, mapaFuentes, ultimos, pendientes, pnl, huerfanos] = await Promise.all([
    catalogos(), fuentes(), ultimoPagoPorCliente(conCatalogo.map(c => c.id)),
    fundador ? aliasPendientes() : Promise.resolve([]), pnlMensual(),
    fundador ? extrasHuerfanos() : Promise.resolve([])
  ]);
  if (!vigente()) return;
  const cat = new Map(cats.map(c => [c.id, c.valor]));
  const conceptos = cats.filter(c => c.dimension === 'concepto');
  const hoy = hoyAR();
  const anioHoy = Number(hoy.slice(0, 4));

  /* Sin "Todos" fuera del fundador: la grilla siempre queda en un cliente propio. */
  const f = { cliente: fundador ? '' : (clientes[0] ? clientes[0].id : ''), anio: anioHoy, mes: null, concepto: '', pendientes: false };
  const selCliente = `<select id="f-cliente">${fundador ? '<option value="">Todos los clientes</option>' : ''}${clientes.map(c =>
    `<option value="${esc(c.id)}"${c.id === f.cliente ? ' selected' : ''}>${esc(c.nombre)}</option>`).join('')}</select>`;
  let pagina = 0;
  let turno = 0;

  /* Configuración de columnas y desplegables de las celdas, por cliente. */
  const configs = new Map(), opcionesCarga = new Map();
  let cols = armarColumnas(BASE_PAGOS, null);
  let ctx = null;
  const traerConfig = async (cliente, forzar = false) => {
    if (forzar || !configs.has(cliente)) configs.set(cliente, await columnasDe(cliente, 'pagos'));
    return configs.get(cliente);
  };
  /* Solo donde se pueden editar las columnas del sistema. */
  const traerOpciones = async cliente => {
    if (!puedeAnular(cliente)) return null;
    if (!opcionesCarga.has(cliente)) opcionesCarga.set(cliente, await cargaOpciones(cliente));
    return opcionesCarga.get(cliente);
  };

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
      <span class="flabel">Cliente</span>${selCliente}
      <span class="flabel">Año</span>${selectAnio('f-anio', anios(pnl, anioHoy), f.anio)}
      <span class="flabel">Mes</span>${selectMes('f-mes', f.mes, { todos: true })}
      <span class="flabel">Concepto</span><select id="f-concepto">${opcionesConcepto()}</select>
      ${fundador ? '<label class="flabel"><input type="checkbox" id="f-pend"> Solo pendientes de catálogo</label>' : ''}
      <span class="grow"></span>${fundador ? `<span id="huerfanos"></span>${botonColumnas('btn-columnas', !f.cliente)}` : ''}${botonRecargar()}
    </div>
    <div id="grilla"></div>
    <div id="pendientes"></div>`;

  const grilla = el.querySelector('#grilla');

  const cargar = async () => {
    const mio = ++turno;
    grilla.innerHTML = '<div class="loading-inline">Cargando pagos…</div>';
    const cliente = f.cliente;
    let r, config, opciones, extras = new Map();
    try {
      [r, config, opciones] = await Promise.all([
        pagosGrilla({
          clienteId: cliente || null, anio: f.anio, mes: f.mes,
          conceptoIds: f.concepto ? conceptosVisibles().filter(c => c.valor === f.concepto).map(c => c.id) : null,
          soloPendientes: f.pendientes, pagina, porPagina: POR_PAGINA
        }),
        cliente ? traerConfig(cliente) : null, cliente ? traerOpciones(cliente) : null
      ]);
      /* Valores de las columnas nuevas: solo los de las claves de esta página. */
      if (cliente && r.filas.length && config.some(c => !c.sistema && !c.archivada && c.visible !== false)) {
        extras = await pagosExtra(cliente, r.filas.map(p => p.clave));
      }
    } catch (e) {
      if (vigente() && mio === turno) grilla.innerHTML = `<div class="card"><p class="aviso-texto">${esc(e.message)}</p></div>`;
      return;
    }
    if (!vigente() || mio !== turno) return;
    /* Anular la última fila de la última página la deja vacía: se vuelve una atrás. */
    if (!r.filas.length && r.total && pagina > 0) { pagina--; return cargar(); }
    cols = armarColumnas(BASE_PAGOS, config);
    ctx = {
      cat, mapaFuentes, opciones, extras, recargar: cargar,
      porId: new Map(r.filas.map(p => [String(p.id), p])), cols: new Map(cols.visibles.map(c => [c.k, c]))
    };
    grilla.innerHTML = tablaPagos(r, { pagina, verCliente: !cliente, cols: cols.visibles, ctx });
    const ir = d => () => { pagina += d; cargar(); };
    const ant = grilla.querySelector('#pg-ant'), sig = grilla.querySelector('#pg-sig');
    if (ant) ant.onclick = ir(-1);
    if (sig) sig.onclick = ir(1);
    /* Después de anular o devolver se recarga la página actual. */
    for (const b of grilla.querySelectorAll('[data-accion]')) {
      const p = r.filas.find(x => String(x.id) === b.dataset.id);
      b.onclick = () => (b.dataset.accion === 'anular' ? modalAnular : modalDevolver)(p, cat, cargar);
    }
  };

  const pintarPendientes = () => {
    el.querySelector('#pendientes').innerHTML = fundador
      ? tablaPendientes(pendientes.filter(p => !f.cliente || p.cliente_id === f.cliente)) : '';
  };
  const filtrar = () => { pagina = 0; cargar(); };

  /* Edición en la celda: un solo listener para toda la grilla. */
  grilla.addEventListener('change', ev => { if (ctx) manejarCambio(ev, ctx); });
  grilla.addEventListener('keydown', manejarTecla);

  /* Valores de columnas nuevas cuyo pago ya no existe: contador chico para el fundador. */
  const pintarHuerfanos = () => {
    const caja = el.querySelector('#huerfanos');
    if (!caja) return;
    const n = huerfanos.filter(h => !f.cliente || h.cliente_id === f.cliente).length;
    caja.innerHTML = n ? `<span class="badge pc-huerfanos" title="Valores de columnas nuevas cuyo pago ya no existe: se corrigió en el Sheet o se anuló. Están en fin_v_pagos_extra_huerfanos.">${plural(n, 'valor huérfano', 'valores huérfanos')}</span>` : '';
  };
  const btnColumnas = el.querySelector('#btn-columnas');
  if (btnColumnas) btnColumnas.onclick = () => {
    const cliente = f.cliente;
    if (!cliente) return;
    abrirPanelColumnas({
      clienteId: cliente, vista: 'pagos', titulo: `Columnas de Pagos · ${nombreCliente(cliente)}`, permiteNuevas: true,
      nota: 'Usá las flechas para ordenar. Vale para todos los usuarios de este cliente, en Pagos y en Cargar pago.',
      estado: () => cols,
      recargar: async () => { await traerConfig(cliente, true); if (f.cliente === cliente) await cargar(); }
    });
  };

  el.querySelector('#f-cliente').onchange = e => {
    f.cliente = e.target.value;
    el.querySelector('#f-concepto').innerHTML = opcionesConcepto();
    if (btnColumnas) btnColumnas.hidden = !f.cliente;
    pintarHuerfanos();
    pintarPendientes();
    filtrar();
  };
  el.querySelector('#f-anio').onchange = e => { f.anio = Number(e.target.value); filtrar(); };
  el.querySelector('#f-mes').onchange = e => { f.mes = Number(e.target.value) || null; filtrar(); };
  el.querySelector('#f-concepto').onchange = e => { f.concepto = e.target.value; filtrar(); };
  const pend = el.querySelector('#f-pend');
  if (pend) pend.onchange = e => { f.pendientes = e.target.checked; filtrar(); };
  el.querySelector('#btn-recargar').onclick = () => vistaPagos(el, vigente);

  pintarHuerfanos();
  pintarPendientes();
  await cargar();
}

function tarjetaUltimo(c, fecha, hoy) {
  if (!fecha) return statCard('—', c.nombre, { sub: 'Sin pagos cargados' });
  const dias = diasEntre(fecha, hoy);
  const hace = dias === 0 ? 'hoy' : dias > 0 ? `hace ${plural(dias, 'día')}` : 'fecha futura';
  return statCard(fmtFecha(fecha), c.nombre, { sub: hace });
}

/* Devolver: cualquier pago positivo. Anular: solo lo cargado en la app. */
function celdaAcciones(p) {
  if (!puedeAnular(p.cliente_id) || !yo.carga.some(c => c.cliente_id === p.cliente_id && c.habilitada)) return '';
  const boton = (accion, texto, clase = '') =>
    `<button type="button" class="btn btn-sm${clase}" data-accion="${accion}" data-id="${esc(p.id)}">${texto}</button>`;
  return (Number(p.monto_usd) > 0 ? boton('devolver', 'Devolver') : '')
    + (p.origen === 'app' ? boton('anular', 'Anular', ' btn-danger') : '');
}

function resumenPago(p, cat) {
  const concepto = (p.concepto_id != null && cat.get(p.concepto_id)) || p.concepto || '';
  return `<p class="aviso-texto">${clienteChip(p.cliente_id)} · ${esc(p.alumno || 'Sin alumno')} · ${fmtFecha(p.fecha)}
    · <strong>${usd(p.monto_usd, { centavos: true })}</strong>${concepto ? ` · ${esc(concepto)}` : ''}</p>`;
}

/* Modal con formulario: enviar() devuelve el texto del toast; si la RPC falla,
   su mensaje queda en el modal tal cual. */
function modalAccion({ titulo, cuerpo, ok, peligro, enviar, alListo }) {
  const m = abrirModal({
    titulo,
    cuerpo: `<form id="form-accion" novalidate>${cuerpo}<div class="form-error" id="a-error" role="alert"></div></form>`,
    pie: `<span></span><div class="right"><button type="button" class="btn" id="a-cancelar">Cancelar</button>
          <button type="submit" form="form-accion" class="btn ${peligro ? 'btn-danger' : 'btn-accent'}" id="a-ok">${ok}</button></div>`
  });
  const form = m.el.querySelector('#form-accion'), err = m.el.querySelector('#a-error'), btn = m.el.querySelector('#a-ok');
  m.el.querySelector('#a-cancelar').onclick = m.cerrar;
  form.onsubmit = async ev => {
    ev.preventDefault();
    err.textContent = '';
    btn.disabled = true;
    try {
      const aviso = await enviar(form);
      if (!aviso) { btn.disabled = false; return; }
      m.cerrar();
      toast(aviso);
      alListo();
    } catch (e) {
      err.textContent = e.message || String(e);
      btn.disabled = false;
    }
  };
  const primero = form.querySelector('input,textarea');
  if (primero) primero.focus();
  return { err };
}

function modalAnular(p, cat, alListo) {
  const { err } = modalAccion({
    titulo: 'Anular pago', ok: 'Anular pago', peligro: true, alListo,
    cuerpo: `${resumenPago(p, cat)}
      <div class="form-row"><label for="a-motivo">Motivo</label><textarea id="a-motivo" rows="2"></textarea>
        <div class="hint">El pago se saca de la grilla y queda guardado con el motivo.</div></div>`,
    enviar: async form => {
      const motivo = form.querySelector('#a-motivo').value.trim();
      if (!motivo) { err.textContent = 'Falta el motivo.'; return null; }
      await pagoAnular(p.clave, motivo);
      return 'Pago anulado';
    }
  });
}

function modalDevolver(p, cat, alListo) {
  const hoy = hoyAR();
  const { err } = modalAccion({
    titulo: 'Devolver pago', ok: 'Cargar devolución', peligro: false, alListo,
    cuerpo: `${resumenPago(p, cat)}
      <div class="form-grid2">
        <div class="form-row"><label for="a-monto">Monto a devolver (USD)</label>
          <input type="number" id="a-monto" min="0.01" step="0.01" inputmode="decimal" value="${esc(p.monto_usd)}"></div>
        <div class="form-row"><label for="a-fecha">Fecha</label>
          <input type="date" id="a-fecha" value="${hoy}" min="${esc(p.fecha)}" max="${hoy}"></div>
      </div>
      <div class="form-row"><label for="a-motivo">Motivo</label><textarea id="a-motivo" rows="2"></textarea></div>`,
    enviar: async form => {
      const monto = Number(form.querySelector('#a-monto').value);
      const fecha = form.querySelector('#a-fecha').value;
      const motivo = form.querySelector('#a-motivo').value.trim();
      if (!(monto > 0)) { err.textContent = 'El monto a devolver tiene que ser mayor a 0.'; return null; }
      if (!fecha) { err.textContent = 'Falta la fecha.'; return null; }
      if (!motivo) { err.textContent = 'Falta el motivo.'; return null; }
      await pagoDevolver(p.clave, monto, fecha, motivo);
      return 'Devolución cargada';
    }
  });
}

function tablaPagos({ filas, total }, { pagina, verCliente, cols, ctx }) {
  if (!total) return vacio('Sin pagos con estos filtros');
  const desde = pagina * POR_PAGINA;
  const conAcciones = yo.carga.some(c => c.habilitada && c.puede_anular);
  /* Con "Todos los clientes", la columna Cliente va después de la fecha, como siempre. */
  const conCliente = (col, html, extra) => html + (verCliente && col.k === 'fecha' ? extra : '');
  return `
    <div class="card table-card">
      <div class="card-titulo">Pagos <span class="txt-gris">· ${fmtNum(total)}</span></div>
      <table class="data-table data-table-dense tabla-pagos">
        <thead><tr>${cols.map(c => conCliente(c, thPago(c), '<th>Cliente</th>')).join('')}${conAcciones ? '<th></th>' : ''}</tr></thead>
        <tbody>${filas.map(p => `<tr>
          ${cols.map(c => conCliente(c, tdPago(c, p, ctx), `<td>${clienteChip(p.cliente_id)}</td>`)).join('')}
          ${conAcciones ? `<td>${celdaAcciones(p)}</td>` : ''}
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
