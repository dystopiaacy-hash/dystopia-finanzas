/* Cargar pago (fase 6): alta de un pago desde la app con la RPC fin_pago_cargar.
   Acá solo se valida lo obvio (obligatorios y monto > 0); la validación real
   es la de la RPC y su mensaje se muestra tal cual.
   072: de fin_columnas_de(cliente, 'pagos') los campos del sistema toman solo la
   etiqueta y el orden: se muestran siempre, aunque estén ocultos en la grilla.
   Las columnas nuevas visibles van al final, opcionales, y se guardan después del
   pago con fin_pago_extra_guardar y la clave que devuelve fin_pago_cargar. */
import { esc, hoyAR } from '../ui.js';
import { yo, nombreCliente, puedeConfirmarComprobante } from '../sesion.js';
import { tomarPrecarga } from '../comprobantes.js';
import { cajaComprobante, enlazarComprobante } from './cargar-comprobante.js';
import { cargaOpciones, pagoCargar, catalogoAgregar, usd } from '../datos.js';
import { puedeAgregarCloser, cajaCloser, closerNuevoClick } from './closer-nuevo.js';
import { columnasDe, armarColumnas, pagoExtraGuardar, errorColumnas } from '../columnas.js';
import { vacio } from './comunes.js';
import { BASE_PAGOS, FUENTES_INGRESO } from './pagos-celdas.js';

/* Campo del formulario por columna del sistema. lab: nombre en el formulario
   mientras la columna no esté renombrada. sel: [clave en fin_carga_opciones, campo a mostrar].
   origen y fila_planilla no se cargan. */
const CAMPOS = {
  fecha: { id: 'c-fecha', obligatorio: true, tipo: 'date' },
  alumno: { id: 'c-alumno', obligatorio: true, tipo: 'text' },
  telefono: { id: 'c-telefono', tipo: 'tel' },
  monto_usd: { id: 'c-monto', obligatorio: true, tipo: 'number' },
  programa: { id: 'c-programa', obligatorio: true, sel: ['programas', 'valor'] },
  concepto: { id: 'c-concepto', obligatorio: true, sel: ['conceptos', 'valor'], dim: 'concepto' },
  metodo_pago: { id: 'c-metodo', obligatorio: true, lab: 'Método de pago', sel: ['metodos', 'valor'], dim: 'metodo_pago' },
  quien_recibe: { id: 'c-recibe', sel: ['quien_recibe', 'valor'], dim: 'quien_recibe' },
  closer: { id: 'c-closer', sel: ['closers', 'nombre'] },
  setter: { id: 'c-setter', sel: ['setters', 'nombre'] },
  comprobante: { id: 'c-comprobante', lab: 'Comprobante (link)', tipo: 'url' },
  nota: { id: 'c-nota', tipo: 'textarea' },
  /* 211 (DCAC): opcionales; solo se muestran si la columna está visible en la config de Pagos del cliente (Agus). */
  email: { id: 'c-email', lab: 'Mail', tipo: 'email', soloVisible: true },
  fuente_email: { id: 'c-fuente-email', tipo: 'text', soloVisible: true },
  fuente_lead: { id: 'c-fuente', tipo: 'text', soloVisible: true },
  /* 228: fuente de ingreso, lista fija y opcional, para los 3 clientes (distinta de fuente_lead, texto libre de Agus). */
  fuente_ingreso: { id: 'c-fuente-ingreso', lab: 'Fuente de ingreso', fija: FUENTES_INGRESO }
};

const fila = (id, label, control, { hint = '', ancho = false } = {}) =>
  `<div class="form-row${ancho ? ' campo-ancho' : ''}"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${hint}</div>` : ''}</div>`;

function campoSistema(c, hoy) {
  const d = CAMPOS[c.k], label = c.lab === c.original && d.lab ? d.lab : c.lab;
  const hint = d.obligatorio ? '' : 'Opcional';
  if (d.sel && d.dim) {
    /* Concepto, método y quién recibe: lista del catálogo + alta de una opción nueva (075). */
    const nuevo = `<div class="opcion-nueva"><button type="button" class="btn-link" data-nuevo="${c.k}">+ Agregar opción</button>
      <span id="${d.id}-nuevo" hidden>
        <input type="text" id="${d.id}-nuevo-txt" maxlength="60" autocomplete="off" placeholder="Nueva opción">
        <button type="button" class="btn" data-nuevo-ok="${c.k}">Agregar</button>
        <button type="button" class="btn" data-nuevo-no="${c.k}">Cancelar</button>
        <span class="form-error" id="${d.id}-nuevo-msg" role="alert"></span>
      </span></div>`;
    return fila(d.id, label, `<select id="${d.id}" disabled><option value="">—</option></select>${nuevo}`, { hint });
  }
  if (c.k === 'closer' && puedeAgregarCloser()) {
    /* 116: alta de un closer nuevo (fundador y finanzas; la RPC lo vuelve a verificar). */
    const nuevo = `<div class="opcion-nueva"><button type="button" class="btn-link" data-closer-nuevo>+ Agregar closer</button>
      ${cajaCloser(d.id)}</div>`;
    return fila(d.id, label, `<select id="${d.id}" disabled><option value="">—</option></select>${nuevo}`, { hint });
  }
  if (d.fija) {
    return fila(d.id, label, `<select id="${d.id}"><option value="">Sin asignar</option>${d.fija.map(o => `<option value="${esc(o)}">${esc(o)}</option>`).join('')}</select>`, { hint });
  }
  if (d.sel) return fila(d.id, label, `<select id="${d.id}" disabled><option value="">—</option></select>`, { hint });
  if (d.tipo === 'textarea') return fila(d.id, label, `<textarea id="${d.id}" rows="2"></textarea>`, { hint, ancho: true });
  const extra = d.tipo === 'date' ? ` value="${hoy}" max="${hoy}"`
    : d.tipo === 'number' ? ' min="0.01" step="0.01" inputmode="decimal"'
    : d.tipo === 'url' ? ' placeholder="https://…" autocomplete="off"' : d.soloVisible ? ' maxlength="200" autocomplete="off"' : ' autocomplete="off"';
  return fila(d.id, label, `<input type="${d.tipo}" id="${d.id}"${extra}>`, { hint });
}

const idExtra = c => `c-x-${c.k}`;
function campoExtra(c) {
  const id = esc(idExtra(c));
  const control = {
    texto: `<input type="text" id="${id}" maxlength="2000" autocomplete="off">`,
    numero: `<input type="number" id="${id}" step="any" inputmode="decimal">`,
    fecha: `<input type="date" id="${id}">`,
    casilla: `<input type="checkbox" id="${id}" class="m-check">`,
    link: `<input type="url" id="${id}" maxlength="2000" placeholder="https://…" autocomplete="off">`,
    opcion: `<select id="${id}"><option value="">—</option>${c.opciones.map(o => `<option value="${esc(o)}">${esc(o)}</option>`).join('')}</select>`
  }[c.tipo];
  return fila(idExtra(c), c.lab, control, { hint: 'Opcional' });
}

export async function vistaCargar(el, vigente) {
  const habilitados = yo.carga.filter(c => c.habilitada);
  const hoy = hoyAR();
  let turno = 0;
  /* Campos en pantalla: columnas del sistema (en su orden) y, al final, las nuevas. */
  let sistema = [], nuevas = [];

  const opcionesCliente = yo.carga.map(c => {
    const nombre = nombreCliente(c.cliente_id);
    return c.habilitada
      ? `<option value="${esc(c.cliente_id)}">${esc(nombre)}</option>`
      : `<option value="${esc(c.cliente_id)}" disabled>${esc(nombre)} · la planilla todavía no está cortada</option>`;
  }).join('');

  el.innerHTML = `
    ${habilitados.length ? '' : vacio('Todavía no se puede cargar', 'La planilla de tus clientes todavía no está cortada.')}
    <form id="form-cargar" class="card concepto-card" novalidate>
      ${fila('c-cliente', 'Cliente', `<select id="c-cliente">${opcionesCliente}</select>`)}
      ${puedeConfirmarComprobante() ? cajaComprobante() : ''}
      <div class="form-grid2" id="c-campos"></div>
      <div class="form-error" id="c-error" role="alert"></div>
      <button type="submit" class="btn btn-accent" id="c-guardar" disabled>Guardar pago</button>
    </form>
    <div class="card concepto-card empty-state" id="c-listo" hidden>
      <div class="big">Pago cargado</div>
      <div class="small" id="c-listo-detalle"></div>
      <div class="form-error" id="c-listo-error" role="alert"></div>
      <button type="button" class="btn btn-accent" id="c-otro">Cargar otro</button>
    </div>`;

  const $ = id => el.querySelector('#' + CSS.escape(id));
  const form = $('form-cargar'), listo = $('c-listo'), err = $('c-error'), guardar = $('c-guardar');
  const selCliente = $('c-cliente'), campos = $('c-campos');

  /* config null = columnas y nombres por defecto. La fecha elegida se conserva. */
  const pintarCampos = config => {
    const fecha = $('c-fecha') ? $('c-fecha').value : hoy;
    const cols = armarColumnas(BASE_PAGOS, config).todas;
    sistema = cols.filter(c => c.sistema && CAMPOS[c.k] && (!CAMPOS[c.k].soloVisible || c.visible));
    nuevas = cols.filter(c => !c.sistema && c.visible);
    campos.innerHTML = sistema.map(c => campoSistema(c, hoy)).join('') + nuevas.map(campoExtra).join('');
    $('c-fecha').value = fecha;
  };
  const desplegables = () => sistema.filter(c => CAMPOS[c.k].sel).map(c => [$(CAMPOS[c.k].id), CAMPOS[c.k]]);

  pintarCampos(null);
  if (!habilitados.length) {
    for (const c of form.querySelectorAll('input,select,textarea')) c.disabled = true;
    return;
  }
  /* 143: comprobante elegido en la bandeja (se consume una vez); si su cliente no se puede cargar, se ignora la precarga. */
  const pre = tomarPrecarga();
  const preOk = pre && habilitados.some(c => c.cliente_id === pre.cliente_id);
  selCliente.value = preOk ? pre.cliente_id : habilitados[0].cliente_id;
  const comp = puedeConfirmarComprobante()
    ? enlazarComprobante({ $, ids: CAMPOS, cliente: () => selCliente.value, vigente }) : null;

  /* Los campos y los desplegables son por cliente: se rearman con fin_columnas_de y fin_carga_opciones. */
  const cargarOpciones = async () => {
    const mio = ++turno;
    err.textContent = '';
    guardar.disabled = true;
    for (const [s] of desplegables()) { s.disabled = true; s.innerHTML = '<option value="">Cargando…</option>'; }
    let o, config;
    try {
      [o, config] = await Promise.all([cargaOpciones(selCliente.value), columnasDe(selCliente.value, 'pagos')]);
    } catch (e) {
      if (!vigente() || mio !== turno) return;
      for (const [s] of desplegables()) s.innerHTML = '<option value="">—</option>';
      err.textContent = errorColumnas(e);
      return;
    }
    if (!vigente() || mio !== turno) return;
    pintarCampos(config);
    for (const [s, d] of desplegables()) {
      const [clave, campo] = d.sel;
      s.innerHTML = `<option value="">${d.obligatorio ? 'Elegir…' : 'Sin asignar'}</option>`
        + (o[clave] || []).map(x => `<option value="${esc(x.id)}">${esc(x[campo])}</option>`).join('');
      s.disabled = false;
    }
    guardar.disabled = false;
  };

  selCliente.onchange = () => { if (comp) comp.limpiar(); cargarOpciones(); };

  /* Alta de una opción nueva del catálogo (concepto, método, quién recibe) y de un closer (116, closer-nuevo.js). */
  campos.onclick = async ev => {
    const bc = ev.target.closest('[data-closer-nuevo],[data-closer-ok],[data-closer-no]');
    if (bc) { await closerNuevoClick(bc, el, CAMPOS.closer.id, selCliente.value); return; }
    const b = ev.target.closest('[data-nuevo],[data-nuevo-ok],[data-nuevo-no]');
    if (!b) return;
    const d = CAMPOS[b.dataset.nuevo || b.dataset.nuevoOk || b.dataset.nuevoNo];
    const caja = $(`${d.id}-nuevo`), txtNuevo = $(`${d.id}-nuevo-txt`), msg = $(`${d.id}-nuevo-msg`);
    if (b.dataset.nuevo) { caja.hidden = false; txtNuevo.value = ''; msg.textContent = ''; txtNuevo.focus(); return; }
    if (b.dataset.nuevoNo) { caja.hidden = true; return; }
    const valor = txtNuevo.value.trim();
    if (valor.length < 2) { msg.textContent = 'Escribí al menos 2 letras.'; return; }
    b.disabled = true;
    try {
      const r = await catalogoAgregar(selCliente.value, d.dim, valor);
      const s = $(d.id);
      if (![...s.options].some(o => o.value === String(r.id))) {
        s.insertAdjacentHTML('beforeend', `<option value="${esc(r.id)}">${esc(r.valor)}</option>`);
      }
      s.value = String(r.id);
      caja.hidden = true;
    } catch (e) {
      msg.textContent = e.message || String(e);
    }
    b.disabled = false;
  };

  const ctl = k => $(CAMPOS[k].id);
  const num = k => (ctl(k).value ? Number(ctl(k).value) : null);
  const txt = k => ctl(k).value.trim();
  /* 211: campo opcional que puede no estar en pantalla (columna oculta del cliente): null si no está o está vacío. */
  const opc = k => (ctl(k) ? txt(k) : '') || null;
  const valorExtra = c => {
    const x = $(idExtra(c));
    if (c.tipo === 'casilla') return x.checked || null;
    const v = x.value.trim();
    return v === '' ? null : c.tipo === 'numero' ? Number(v) : v;
  };

  form.onsubmit = async ev => {
    ev.preventDefault();
    err.textContent = '';
    const monto = Number(txt('monto_usd'));
    const falta = sistema.filter(c => CAMPOS[c.k].obligatorio && c.k !== 'monto_usd' && !txt(c.k)).map(c => c.lab);
    if (!selCliente.value) falta.unshift('Cliente');
    if (falta.length) { err.textContent = `Falta: ${falta.join(', ')}.`; return; }
    if (!(monto > 0)) { err.textContent = 'El monto tiene que ser mayor a 0.'; return; }
    if (comp && comp.faltaRevisarDuplicado()) { err.textContent = 'Posible duplicado: marcá "Revisé: es otro pago" para guardar igual.'; return; }

    const cliente = selCliente.value, alumno = txt('alumno');
    const extras = nuevas.map(c => [c, valorExtra(c)]).filter(([, v]) => v != null);
    guardar.disabled = true;
    let r;
    try {
      r = await pagoCargar({
        cliente_id: cliente, fecha: txt('fecha'), alumno, telefono: txt('telefono') || null,
        monto_usd: monto, programa_id: num('programa'), concepto_id: num('concepto'), metodo_pago_id: num('metodo_pago'),
        quien_recibe_id: num('quien_recibe'), closer_id: num('closer'), setter_id: num('setter'),
        comprobante: txt('comprobante') || null, nota: txt('nota') || null,
        email: opc('email'), fuente_email: opc('fuente_email'), fuente_lead: opc('fuente_lead'),
        fuente_ingreso: opc('fuente_ingreso')
      });
    } catch (e) {
      if (!vigente()) return;
      err.textContent = e.message || String(e);
      guardar.disabled = false;
      return;
    }
    /* El pago ya está: lo que falle de las columnas nuevas se avisa sin perderlo. */
    const fallas = [];
    for (const [c, v] of extras) {
      try { await pagoExtraGuardar(cliente, r.clave, c.k, v); }
      catch (e) { fallas.push(`${c.lab}: ${errorColumnas(e)}`); }
    }
    /* 143: recién con el pago guardado se vincula el comprobante (confirmado por quien guarda). */
    const falloComp = comp ? await comp.confirmar(r.clave) : '';
    if (falloComp) fallas.push(`el comprobante no quedó vinculado: ${falloComp}`);
    if (!vigente()) return;
    guardar.disabled = false;
    $('c-listo-detalle').textContent = `${alumno} · ${usd(monto, { centavos: true })} · ${nombreCliente(cliente)}`;
    $('c-listo-error').textContent = fallas.length ? `El pago se cargó, pero no se guardó ${fallas.join(' · ')}` : '';
    form.hidden = true;
    listo.hidden = false;
    $('c-otro').focus();
  };

  /* Mantiene cliente y fecha, limpia el resto. */
  $('c-otro').onclick = () => {
    for (const c of campos.querySelectorAll('input,select,textarea')) {
      if (c.id === 'c-fecha') continue;
      if (c.type === 'checkbox') c.checked = false;
      else c.value = '';
    }
    err.textContent = '';
    if (comp) comp.limpiar();
    listo.hidden = true;
    form.hidden = false;
    $('c-alumno').focus();
  };

  await cargarOpciones();
  if (preOk && comp && vigente()) comp.cargar(pre);
}
