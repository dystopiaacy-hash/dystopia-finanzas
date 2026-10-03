/* Cargar pago (fase 6): alta de un pago desde la app con la RPC fin_pago_cargar.
   Acá solo se valida lo obvio (obligatorios y monto > 0); la validación real
   es la de la RPC y su mensaje se muestra tal cual.
   072: de fin_columnas_de(cliente, 'pagos') los campos del sistema toman solo la
   etiqueta y el orden: se muestran siempre, aunque estén ocultos en la grilla.
   Las columnas nuevas visibles van al final, opcionales, y se guardan después del
   pago con fin_pago_extra_guardar y la clave que devuelve fin_pago_cargar. */
import { esc, hoyAR } from '../ui.js';
import { yo, nombreCliente } from '../sesion.js';
import { cargaOpciones, pagoCargar, usd } from '../datos.js';
import { columnasDe, armarColumnas, pagoExtraGuardar, errorColumnas } from '../columnas.js';
import { vacio } from './comunes.js';
import { BASE_PAGOS } from './pagos-celdas.js';

/* Campo del formulario por columna del sistema. lab: nombre en el formulario
   mientras la columna no esté renombrada. sel: [clave en fin_carga_opciones, campo a mostrar].
   origen y fila_planilla no se cargan. */
const CAMPOS = {
  fecha: { id: 'c-fecha', obligatorio: true, tipo: 'date' },
  alumno: { id: 'c-alumno', obligatorio: true, tipo: 'text' },
  telefono: { id: 'c-telefono', tipo: 'tel' },
  monto_usd: { id: 'c-monto', obligatorio: true, tipo: 'number' },
  programa: { id: 'c-programa', obligatorio: true, sel: ['programas', 'valor'] },
  concepto: { id: 'c-concepto', obligatorio: true, sel: ['conceptos', 'valor'] },
  metodo_pago: { id: 'c-metodo', obligatorio: true, lab: 'Método de pago', sel: ['metodos', 'valor'] },
  quien_recibe: { id: 'c-recibe', sel: ['quien_recibe', 'valor'] },
  closer: { id: 'c-closer', sel: ['closers', 'nombre'] },
  setter: { id: 'c-setter', sel: ['setters', 'nombre'] },
  comprobante: { id: 'c-comprobante', lab: 'Comprobante (link)', tipo: 'url' },
  nota: { id: 'c-nota', tipo: 'textarea' }
};

const fila = (id, label, control, { hint = '', ancho = false } = {}) =>
  `<div class="form-row${ancho ? ' campo-ancho' : ''}"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${hint}</div>` : ''}</div>`;

function campoSistema(c, hoy) {
  const d = CAMPOS[c.k], label = c.lab === c.original && d.lab ? d.lab : c.lab;
  const hint = d.obligatorio ? '' : 'Opcional';
  if (d.sel) return fila(d.id, label, `<select id="${d.id}" disabled><option value="">—</option></select>`, { hint });
  if (d.tipo === 'textarea') return fila(d.id, label, `<textarea id="${d.id}" rows="2"></textarea>`, { hint, ancho: true });
  const extra = d.tipo === 'date' ? ` value="${hoy}" max="${hoy}"`
    : d.tipo === 'number' ? ' min="0.01" step="0.01" inputmode="decimal"'
    : d.tipo === 'url' ? ' placeholder="https://…" autocomplete="off"' : ' autocomplete="off"';
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
    sistema = cols.filter(c => c.sistema && CAMPOS[c.k]);
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
  selCliente.value = habilitados[0].cliente_id;

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

  selCliente.onchange = cargarOpciones;

  /* Un campo oculto (opcional) no está en el formulario: vale null. */
  const ctl = k => (sistema.some(c => c.k === k) ? $(CAMPOS[k].id) : null);
  const num = k => (ctl(k) && ctl(k).value ? Number(ctl(k).value) : null);
  const txt = k => (ctl(k) ? ctl(k).value.trim() : '');
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

    const cliente = selCliente.value, alumno = txt('alumno');
    const extras = nuevas.map(c => [c, valorExtra(c)]).filter(([, v]) => v != null);
    guardar.disabled = true;
    let r;
    try {
      r = await pagoCargar({
        cliente_id: cliente, fecha: txt('fecha'), alumno, telefono: txt('telefono') || null,
        monto_usd: monto, programa_id: num('programa'), concepto_id: num('concepto'), metodo_pago_id: num('metodo_pago'),
        quien_recibe_id: num('quien_recibe'), closer_id: num('closer'), setter_id: num('setter'),
        comprobante: txt('comprobante') || null, nota: txt('nota') || null
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
    listo.hidden = true;
    form.hidden = false;
    $('c-alumno').focus();
  };

  await cargarOpciones();
}
