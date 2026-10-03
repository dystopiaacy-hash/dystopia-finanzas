/* Celdas de la grilla de Pagos (072): cómo se dibuja cada columna y la edición
   en la celda. Se guarda con Enter o al salir; si la base rechaza el cambio, la
   celda vuelve al valor guardado y el mensaje ("fin: ...") queda adentro.
   - Columnas nuevas: editables si el cliente está en yo.carga (también en pagos
     de la planilla): van por fin_pago_extra_guardar.
   - Columnas del sistema: solo filas 'app' con puede_anular, por fin_pago_editar.
     Nunca monto, cliente, origen ni fila. */
import { esc, fmtFecha, fmtNum, hoyAR, urlSegura } from '../ui.js';
import { yo, puedeAnular } from '../sesion.js';
import { usd, numCelda } from '../datos.js';
import { pagoEditar, pagoExtraGuardar, errorColumnas } from '../columnas.js';

/* Mauro queda afuera de la reestructuración (V3): no tiene catálogos. */
export const SIN_CATALOGO = 'mauro';

/* Las columnas del sistema, en el orden de siempre (fin_columnas_sistema('pagos')). */
export const BASE_PAGOS = [
  { k: 'fecha', lab: 'Fecha' }, { k: 'alumno', lab: 'Alumno', fija: true }, { k: 'telefono', lab: 'Teléfono', oculta: true },
  { k: 'programa', lab: 'Programa' }, { k: 'concepto', lab: 'Concepto' }, { k: 'monto_usd', lab: 'Monto USD' },
  { k: 'metodo_pago', lab: 'Método' }, { k: 'quien_recibe', lab: 'Quién recibe' }, { k: 'closer', lab: 'Closer' },
  { k: 'setter', lab: 'Setter' }, { k: 'comprobante', lab: 'Comprobante' }, { k: 'nota', lab: 'Nota', oculta: true },
  { k: 'origen', lab: 'Origen' }, { k: 'fila_planilla', lab: 'Fila' }
];

/* Control de edición de cada columna del sistema, y de dónde salen sus opciones en fin_carga_opciones. */
const EDITOR = {
  fecha: 'fecha', alumno: 'texto', telefono: 'texto', comprobante: 'link', nota: 'texto',
  programa: 'catalogo', concepto: 'catalogo', metodo_pago: 'catalogo', quien_recibe: 'catalogo',
  closer: 'vendedor', setter: 'vendedor'
};
const OPCIONES_DE = {
  programa: 'programas', concepto: 'conceptos', metodo_pago: 'metodos', quien_recibe: 'quien_recibe',
  closer: 'closers', setter: 'setters'
};
const NUMERICAS = ['monto_usd', 'fila_planilla'];
/* Una devolución solo deja cambiar nota y comprobante. */
const EN_DEVOLUCION = ['nota', 'comprobante'];
const FUERA = '__actual';

export const editaExtras = clienteId => yo.carga.some(c => c.cliente_id === clienteId);

function editaSistema(col, p, ctx) {
  return !!ctx.opciones && !!EDITOR[col.k] && p.origen === 'app' && puedeAnular(p.cliente_id)
    && (!p.pago_original_clave || EN_DEVOLUCION.includes(col.k));
}

function attrs(col, p, tipo, prev) {
  return `id="pc-${esc(col.k)}-${esc(p.id)}" data-campo="${esc(col.k)}" data-tipo="${tipo}" data-id="${esc(p.id)}"
    data-prev="${esc(prev)}" aria-label="${esc(col.lab + ' de ' + (p.alumno || 'sin alumno'))}"`;
}
const opciones = (ops, actual) => ops.map(([v, l]) =>
  `<option value="${esc(v)}"${String(v) === String(actual) ? ' selected' : ''}>${esc(l)}</option>`).join('');
const abrir = (v, lab) => {
  const href = v ? urlSegura(v) : '';
  return href ? `<a class="m-abrir" href="${esc(href)}" target="_blank" rel="noopener noreferrer"
    title="Abrir en una pestaña nueva" aria-label="${esc('Abrir ' + lab)}">↗</a>` : '';
};

/* Un control por tipo. v = valor guardado ('' si no hay). */
const CONTROL = {
  texto: (col, p, v, x) => `<input type="text" class="m-edit" maxlength="2000" autocomplete="off" value="${esc(v)}"
    title="${esc(v)}" placeholder="—" ${attrs(col, p, 'texto', v)}${x}>`,
  numero: (col, p, v, x) => `<input type="number" step="any" class="m-edit m-x-num" value="${esc(v)}" placeholder="—"
    ${attrs(col, p, 'numero', v)}${x}>`,
  fecha: (col, p, v, x) => `<input type="date" class="m-edit" value="${esc(v)}" ${attrs(col, p, 'fecha', v)}${x}>`,
  casilla: (col, p, v, x) => `<input type="checkbox" class="m-check"${v === true ? ' checked' : ''}
    ${attrs(col, p, 'casilla', v === true ? '1' : '')}${x}>`,
  opcion: (col, p, v, x) => {
    const ops = [['', '—']].concat(col.opciones.map(o => [o, o]));
    if (v && !col.opciones.includes(v)) ops.push([v, v + ' (fuera de lista)']);
    return `<select class="m-edit" ${attrs(col, p, 'opcion', v)}${x}>${opciones(ops, v)}</select>`;
  },
  link: (col, p, v, x) => `<span class="m-link"><input type="url" class="m-edit" maxlength="2000" autocomplete="off"
    value="${esc(v)}" title="${esc(v)}" placeholder="https://…" ${attrs(col, p, 'link', v)}${x}>${abrir(v, col.lab)}</span>`
};

/* Catálogo: el valor es el id. Sin id y con texto del Sheet, ese texto queda como "fuera de lista". */
function selectCatalogo(col, p, ctx) {
  const lista = (ctx.opciones[OPCIONES_DE[col.k]] || []).map(o => [String(o.id), o.valor]);
  const id = p[`${col.k}_id`], crudo = (p[col.k] || '').trim();
  let actual = id == null ? '' : String(id);
  if (actual && !lista.some(([v]) => v === actual)) lista.push([actual, ctx.cat.get(id) || crudo || actual]);
  if (!actual && crudo) { actual = FUERA; lista.push([FUERA, crudo + ' (fuera de lista)']); }
  if (!actual || col.k === 'quien_recibe') lista.unshift(['', col.k === 'quien_recibe' ? 'Sin asignar' : '—']);
  return `<select class="m-edit" ${attrs(col, p, 'catalogo', actual)}>${opciones(lista, actual)}</select>`;
}

/* Closer y setter: el pago guarda el nombre y la RPC recibe el id del vendedor. */
function selectVendedor(col, p, ctx) {
  const lista = (ctx.opciones[OPCIONES_DE[col.k]] || []).map(o => [String(o.id), o.nombre]);
  const nombre = (p[col.k] || '').trim();
  const hallado = lista.find(([, n]) => n.trim().toLowerCase() === nombre.toLowerCase());
  let actual = hallado ? hallado[0] : '';
  if (nombre && !hallado) { actual = FUERA; lista.push([FUERA, nombre + ' (fuera de lista)']); }
  lista.unshift(['', 'Sin asignar']);
  return `<select class="m-edit" ${attrs(col, p, 'vendedor', actual)}>${opciones(lista, actual)}</select>`;
}

/* ---------- Solo lectura ---------- */

/* Valor del catálogo; sin *_id y con texto en el Sheet, el crudo en gris. */
function celdaCatalogo(p, columna, cat) {
  const valor = p[`${columna}_id`] != null ? cat.get(p[`${columna}_id`]) : null;
  if (valor) return esc(valor);
  const crudo = (p[columna] || '').trim();
  if (!crudo) return '—';
  if (p.cliente_id === SIN_CATALOGO) return esc(crudo);
  return `<span class="txt-gris" title="Sin valor de catálogo: pendiente">${esc(crudo)}</span>`;
}

function celdaLink(v) {
  if (!v) return '—';
  const url = urlSegura(v);
  return url ? `<a href="${esc(url)}" target="_blank" rel="noopener">abrir ↗</a>` : esc(v);
}

const LECTURA = {
  fecha: p => fmtFecha(p.fecha),
  monto_usd: p => usd(p.monto_usd, { centavos: true }),
  comprobante: p => celdaLink(p.comprobante),
  origen: p => (p.origen === 'app' ? 'App' : 'Sheet'),
  fila_planilla: (p, ctx) => (p.fila_planilla == null ? '—'
    : numCelda(String(p.fila_planilla), ctx.mapaFuentes.get(p.fuente_id), p.fila_planilla)),
  programa: (p, ctx) => celdaCatalogo(p, 'programa', ctx.cat),
  concepto: (p, ctx) => celdaCatalogo(p, 'concepto', ctx.cat),
  metodo_pago: (p, ctx) => celdaCatalogo(p, 'metodo_pago', ctx.cat),
  quien_recibe: (p, ctx) => celdaCatalogo(p, 'quien_recibe', ctx.cat)
};

function lecturaExtra(col, v) {
  if (v == null || v === '') return '—';
  if (col.tipo === 'casilla') return v === true ? '✓' : '—';
  if (col.tipo === 'link') return celdaLink(v);
  if (col.tipo === 'fecha') return fmtFecha(v);
  if (col.tipo === 'numero') return fmtNum(Number(v));
  return esc(v);
}

/* ---------- Encabezado y celda ---------- */

const esNum = col => (col.sistema ? NUMERICAS.includes(col.k) : col.tipo === 'numero');
const clase = col => `pc-c-${col.sistema ? esc(col.k) : 'x pc-x-' + col.tipo}${esNum(col) ? ' num' : ''}`;

export const thPago = col => `<th class="${clase(col)}">${esc(col.lab)}</th>`;

/* ctx: { cat, mapaFuentes, opciones (fin_carga_opciones del cliente, null con "Todos"), extras (Map clave -> valores) } */
export function tdPago(col, p, ctx) {
  if (!col.sistema) {
    const v = (ctx.extras.get(p.clave) || {})[col.k];
    if (!editaExtras(p.cliente_id)) return `<td class="${clase(col)}">${lecturaExtra(col, v)}</td>`;
    return `<td class="${clase(col)} pc-edit">${CONTROL[col.tipo](col, p, v ?? '', ' data-extra="1"')}</td>`;
  }
  if (!editaSistema(col, p, ctx)) {
    const html = LECTURA[col.k] ? LECTURA[col.k](p, ctx) : esc(p[col.k] || '—');
    return `<td class="${clase(col)}">${html}</td>`;
  }
  const tipo = EDITOR[col.k];
  const control = tipo === 'catalogo' ? selectCatalogo(col, p, ctx)
    : tipo === 'vendedor' ? selectVendedor(col, p, ctx)
    : CONTROL[tipo](col, p, p[col.k] || '', col.k === 'fecha' ? ` max="${hoyAR()}"` : '');
  return `<td class="${clase(col)} pc-edit">${control}</td>`;
}

/* ---------- Guardado por celda ---------- */

function marcar(ctl, estado, mensaje = '') {
  const td = ctl.closest('td');
  if (!td) return;
  td.classList.remove('m-guardando', 'm-ok', 'm-error');
  const viejo = td.querySelector('.pc-error');
  if (viejo) viejo.remove();
  if (estado) td.classList.add('m-' + estado);
  if (estado === 'ok') setTimeout(() => td.classList.remove('m-ok'), 1200);
  /* El error queda en la celda hasta el próximo intento. */
  if (estado === 'error') {
    const div = document.createElement('div');
    div.className = 'pc-error';
    div.setAttribute('role', 'alert');
    div.textContent = mensaje;
    td.appendChild(div);
  }
}

/* Falló: la celda vuelve al último valor guardado y el error se ve adentro. */
function revertir(ctl, e) {
  if (ctl.type === 'checkbox') ctl.checked = ctl.dataset.prev === '1';
  else ctl.value = ctl.dataset.prev;
  marcar(ctl, 'error', errorColumnas(e));
}

function refrescarLink(ctl, valor, lab) {
  const caja = ctl.closest('.m-link');
  if (!caja) return;
  const a = caja.querySelector('.m-abrir');
  if (a) a.remove();
  caja.insertAdjacentHTML('beforeend', abrir(valor, lab));
}

async function guardarExtra(ctl, p, col, ctx) {
  const tipo = ctl.dataset.tipo;
  const actual = tipo === 'casilla' ? (ctl.checked ? '1' : '') : ctl.value.trim();
  if (actual === ctl.dataset.prev) return;
  const valor = tipo === 'casilla' ? (ctl.checked || null)
    : actual === '' ? null : tipo === 'numero' ? Number(actual) : actual;
  marcar(ctl, 'guardando');
  ctl.disabled = true;
  try {
    await pagoExtraGuardar(p.cliente_id, p.clave, col.k, valor);
    const valores = { ...(ctx.extras.get(p.clave) || {}) };
    if (valor == null) delete valores[col.k];
    else valores[col.k] = valor;
    ctx.extras.set(p.clave, valores);
    ctl.dataset.prev = actual;
    if (tipo !== 'casilla') ctl.title = actual;
    if (tipo === 'link') refrescarLink(ctl, actual, col.lab);
    marcar(ctl, 'ok');
  } catch (e) {
    revertir(ctl, e);
  } finally {
    ctl.disabled = false;
  }
}

async function guardarSistema(ctl, p, col, ctx) {
  const tipo = ctl.dataset.tipo, valor = ctl.value.trim();
  if (valor === ctl.dataset.prev || valor === FUERA) { ctl.value = ctl.dataset.prev; return; }
  marcar(ctl, 'guardando');
  ctl.disabled = true;
  try {
    await pagoEditar(p.clave, col.k, valor || null);
    const texto = ctl.tagName === 'SELECT' && valor ? ctl.selectedOptions[0].textContent : null;
    if (tipo === 'catalogo') { p[`${col.k}_id`] = valor ? Number(valor) : null; p[col.k] = texto; }
    else if (tipo === 'vendedor') p[col.k] = texto;
    else p[col.k] = valor || null;
    ctl.dataset.prev = valor;
    if (ctl.tagName === 'SELECT') {
      const fuera = ctl.querySelector(`option[value="${FUERA}"]`);
      if (fuera) fuera.remove();
    } else if (tipo !== 'fecha') ctl.title = valor;
    if (tipo === 'link') refrescarLink(ctl, valor, col.lab);
    marcar(ctl, 'ok');
    /* La fecha mueve el pago de lugar (orden y filtros): se vuelve a pedir la página. */
    if (col.k === 'fecha') ctx.recargar();
  } catch (e) {
    revertir(ctl, e);
  } finally {
    ctl.disabled = false;
  }
}

/* change de un control editable. ctx suma porId (Map id -> pago), cols (Map clave -> columna) y recargar(). */
export async function manejarCambio(ev, ctx) {
  const ctl = ev.target.closest('[data-campo]');
  if (!ctl) return;
  const p = ctx.porId.get(ctl.dataset.id), col = ctx.cols.get(ctl.dataset.campo);
  if (!p || !col) return;
  if (ctl.dataset.extra) await guardarExtra(ctl, p, col, ctx);
  else await guardarSistema(ctl, p, col, ctx);
}

/* Enter guarda (sale del campo, dispara change); Escape descarta lo escrito. */
export function manejarTecla(ev) {
  const ctl = ev.target.closest('input[data-campo]');
  if (!ctl || ctl.type === 'checkbox') return;
  if (ev.key === 'Enter') { ev.preventDefault(); ctl.blur(); }
  if (ev.key === 'Escape') { ctl.value = ctl.dataset.prev; ctl.blur(); }
}
