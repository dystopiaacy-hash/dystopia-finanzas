/* Cargar pago (fase 6): alta de un pago desde la app con la RPC fin_pago_cargar.
   Acá solo se valida lo obvio (obligatorios y monto > 0); la validación real
   es la de la RPC y su mensaje se muestra tal cual. */
import { esc, hoyAR } from '../ui.js';
import { yo, nombreCliente } from '../sesion.js';
import { cargaOpciones, pagoCargar, usd } from '../datos.js';
import { vacio } from './comunes.js';

/* [id del select, clave en fin_carga_opciones, campo a mostrar, obligatorio] */
const DESPLEGABLES = [
  ['c-programa', 'programas', 'valor', true],
  ['c-concepto', 'conceptos', 'valor', true],
  ['c-metodo', 'metodos', 'valor', true],
  ['c-recibe', 'quien_recibe', 'valor', false],
  ['c-closer', 'closers', 'nombre', false],
  ['c-setter', 'setters', 'nombre', false]
];
/* Lo que "Cargar otro" limpia: todo menos cliente y fecha. */
const LIMPIAR = ['c-alumno', 'c-telefono', 'c-monto', 'c-comprobante', 'c-nota', ...DESPLEGABLES.map(d => d[0])];

export async function vistaCargar(el, vigente) {
  const habilitados = yo.carga.filter(c => c.habilitada);
  const hoy = hoyAR();
  let turno = 0;

  const opcionesCliente = yo.carga.map(c => {
    const nombre = nombreCliente(c.cliente_id);
    return c.habilitada
      ? `<option value="${esc(c.cliente_id)}">${esc(nombre)}</option>`
      : `<option value="${esc(c.cliente_id)}" disabled>${esc(nombre)} · la planilla todavía no está cortada</option>`;
  }).join('');
  const fila = (id, label, control, hint = '') =>
    `<div class="form-row"><label for="${id}">${label}</label>${control}${hint ? `<div class="hint">${hint}</div>` : ''}</div>`;
  const sel = id => `<select id="${id}" disabled><option value="">—</option></select>`;

  el.innerHTML = `
    ${habilitados.length ? '' : vacio('Todavía no se puede cargar', 'La planilla de tus clientes todavía no está cortada.')}
    <form id="form-cargar" class="card concepto-card" novalidate>
      <div class="form-grid2">
        ${fila('c-cliente', 'Cliente', `<select id="c-cliente">${opcionesCliente}</select>`)}
        ${fila('c-fecha', 'Fecha', `<input type="date" id="c-fecha" value="${hoy}" max="${hoy}">`)}
      </div>
      <div class="form-grid2">
        ${fila('c-alumno', 'Alumno', '<input type="text" id="c-alumno" autocomplete="off">')}
        ${fila('c-telefono', 'Teléfono', '<input type="tel" id="c-telefono" autocomplete="off">', 'Opcional')}
      </div>
      <div class="form-grid2">
        ${fila('c-monto', 'Monto USD', '<input type="number" id="c-monto" min="0.01" step="0.01" inputmode="decimal">')}
        ${fila('c-programa', 'Programa', sel('c-programa'))}
      </div>
      <div class="form-grid2">
        ${fila('c-concepto', 'Concepto', sel('c-concepto'))}
        ${fila('c-metodo', 'Método de pago', sel('c-metodo'))}
      </div>
      <div class="form-grid2">
        ${fila('c-recibe', 'Quién recibe', sel('c-recibe'), 'Opcional')}
        ${fila('c-closer', 'Closer', sel('c-closer'), 'Opcional')}
      </div>
      <div class="form-grid2">
        ${fila('c-setter', 'Setter', sel('c-setter'), 'Opcional')}
        ${fila('c-comprobante', 'Comprobante (link)', '<input type="url" id="c-comprobante" placeholder="https://…" autocomplete="off">', 'Opcional')}
      </div>
      ${fila('c-nota', 'Nota', '<textarea id="c-nota" rows="2"></textarea>', 'Opcional')}
      <div class="form-error" id="c-error" role="alert"></div>
      <button type="submit" class="btn btn-accent" id="c-guardar" disabled>Guardar pago</button>
    </form>
    <div class="card concepto-card empty-state" id="c-listo" hidden>
      <div class="big">Pago cargado</div>
      <div class="small" id="c-listo-detalle"></div>
      <button type="button" class="btn btn-accent" id="c-otro">Cargar otro</button>
    </div>`;

  const $ = id => el.querySelector('#' + id);
  const form = $('form-cargar'), listo = $('c-listo'), err = $('c-error'), guardar = $('c-guardar');
  const selCliente = $('c-cliente');

  if (!habilitados.length) {
    for (const c of form.querySelectorAll('input,select,textarea')) c.disabled = true;
    return;
  }
  selCliente.value = habilitados[0].cliente_id;

  /* Los desplegables son por cliente: se rearman con fin_carga_opciones. */
  const cargarOpciones = async () => {
    const mio = ++turno;
    err.textContent = '';
    guardar.disabled = true;
    for (const [id] of DESPLEGABLES) { $(id).disabled = true; $(id).innerHTML = '<option value="">Cargando…</option>'; }
    let o;
    try {
      o = await cargaOpciones(selCliente.value);
    } catch (e) {
      if (!vigente() || mio !== turno) return;
      for (const [id] of DESPLEGABLES) $(id).innerHTML = '<option value="">—</option>';
      err.textContent = e.message || String(e);
      return;
    }
    if (!vigente() || mio !== turno) return;
    for (const [id, clave, campo, obligatorio] of DESPLEGABLES) {
      const s = $(id);
      s.innerHTML = `<option value="">${obligatorio ? 'Elegir…' : 'Sin asignar'}</option>`
        + (o[clave] || []).map(x => `<option value="${esc(x.id)}">${esc(x[campo])}</option>`).join('');
      s.disabled = false;
    }
    guardar.disabled = false;
  };

  selCliente.onchange = cargarOpciones;

  const num = id => ($(id).value ? Number($(id).value) : null);
  const txt = id => $(id).value.trim();

  form.onsubmit = async ev => {
    ev.preventDefault();
    err.textContent = '';
    const monto = Number($('c-monto').value);
    const falta = [
      [!selCliente.value, 'el cliente'], [!$('c-fecha').value, 'la fecha'], [!txt('c-alumno'), 'el alumno'],
      [!num('c-programa'), 'el programa'], [!num('c-concepto'), 'el concepto'], [!num('c-metodo'), 'el método de pago']
    ].filter(([f]) => f).map(([, n]) => n);
    if (falta.length) { err.textContent = `Falta ${falta.join(', ')}.`; return; }
    if (!(monto > 0)) { err.textContent = 'El monto tiene que ser mayor a 0.'; return; }

    guardar.disabled = true;
    try {
      await pagoCargar({
        cliente_id: selCliente.value, fecha: $('c-fecha').value, alumno: txt('c-alumno'), telefono: txt('c-telefono') || null,
        monto_usd: monto, programa_id: num('c-programa'), concepto_id: num('c-concepto'), metodo_pago_id: num('c-metodo'),
        quien_recibe_id: num('c-recibe'), closer_id: num('c-closer'), setter_id: num('c-setter'),
        comprobante: txt('c-comprobante') || null, nota: txt('c-nota') || null
      });
    } catch (e) {
      if (!vigente()) return;
      err.textContent = e.message || String(e);
      guardar.disabled = false;
      return;
    }
    if (!vigente()) return;
    guardar.disabled = false;
    $('c-listo-detalle').textContent = `${txt('c-alumno')} · ${usd(monto, { centavos: true })} · ${nombreCliente(selCliente.value)}`;
    form.hidden = true;
    listo.hidden = false;
    $('c-otro').focus();
  };

  /* Mantiene cliente y fecha, limpia el resto. */
  $('c-otro').onclick = () => {
    for (const id of LIMPIAR) $(id).value = '';
    err.textContent = '';
    listo.hidden = true;
    form.hidden = false;
    $('c-alumno').focus();
  };

  await cargarOpciones();
}
