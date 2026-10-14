/* "+ Agregar closer" (116), común a Cargar pago y a la edición en celda de Pagos.
   El select del closer tiene id `id`; la caja de alta cuelga de `${id}-nuevo`.
   La RPC fin_closer_agregar vuelve a verificar el permiso: acá solo se decide si se ofrece. */
import { esc } from '../ui.js';
import { yo, esFundador } from '../sesion.js';
import { closerAgregar } from '../datos.js';

export const puedeAgregarCloser = () => esFundador() || yo.rol === 'finanzas';

/* Valor del select que dispara el alta (solo en la grilla, donde no hay botón aparte). */
export const CLOSER_NUEVO = '__closer_nuevo';

/* Caja oculta con nombre, "Es una persona", Agregar y Cancelar. */
export const cajaCloser = id => `<span id="${esc(id)}-nuevo" hidden>
  <input type="text" id="${esc(id)}-nuevo-txt" maxlength="60" autocomplete="off" placeholder="Nombre del closer">
  <label><input type="checkbox" id="${esc(id)}-nuevo-persona" checked> Es una persona</label>
  <button type="button" class="btn" data-closer-ok>Agregar</button>
  <button type="button" class="btn" data-closer-no>Cancelar</button>
  <span class="form-error" id="${esc(id)}-nuevo-msg" role="alert"></span>
</span>`;

export function abrirCajaCloser(raiz, id) {
  const $ = x => raiz.querySelector('#' + CSS.escape(x));
  $(`${id}-nuevo`).hidden = false;
  $(`${id}-nuevo-txt`).value = '';
  $(`${id}-nuevo-msg`).textContent = '';
  $(`${id}-nuevo-txt`).focus();
}

/* Click en abrir / Agregar / Cancelar. Devuelve el closer {id, nombre} recién agregado y ya
   elegido en el select (si ya existía, solo se asigna), o null si no hay nada que guardar. */
export async function closerNuevoClick(b, raiz, id, cliente) {
  const $ = x => raiz.querySelector('#' + CSS.escape(x));
  const caja = $(`${id}-nuevo`), txt = $(`${id}-nuevo-txt`), msg = $(`${id}-nuevo-msg`);
  if (b.hasAttribute('data-closer-nuevo')) { abrirCajaCloser(raiz, id); return null; }
  if (b.hasAttribute('data-closer-no')) { caja.hidden = true; return null; }
  const nombre = txt.value.trim();
  if (nombre.length < 2) { msg.textContent = 'Escribí al menos 2 letras.'; return null; }
  b.disabled = true;
  try {
    const r = await closerAgregar(cliente, nombre, $(`${id}-nuevo-persona`).checked);
    const s = $(id);
    if (![...s.options].some(o => o.value === String(r.id))) {
      s.insertAdjacentHTML('beforeend', `<option value="${esc(r.id)}">${esc(r.nombre)}</option>`);
    }
    s.value = String(r.id);
    caja.hidden = true;
    return r;
  } catch (e) {
    msg.textContent = e.message || String(e);
    return null;
  } finally {
    b.disabled = false;
  }
}
