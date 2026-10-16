/* "Subir comprobante" (143): pantalla mínima para closer, setter y cliente (y para quien no tenga Cargar pago).
   Solo sube el archivo de una transferencia de sus clientes (crm_asignaciones): queda "en revisión" hasta que
   fundador o finanzas lo confirmen. No muestra pagos ni montos de nadie más: solo lo que subió esta persona. */
import { esc, fmtFechaHora, semaforo } from '../ui.js';
import { yo, nombreCliente } from '../sesion.js';
import {
  ACCEPT, validarArchivo, subirComprobante, leerComprobante, comprobantesMios
} from '../comprobantes.js';

const ESTADOS = {
  en_revision: ['amarillo', 'En revisión'],
  confirmado: ['verde', 'Cargado como pago'],
  descartado: ['rojo', 'Descartado']
};

const fmtMonto = (m, mon) => `${mon || ''} ${new Intl.NumberFormat('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(m)}`.trim();

function listaHtml(filas) {
  if (!filas.length) return '<div class="small">Todavía no subiste comprobantes.</div>';
  return `<table class="data-table"><thead><tr><th>Subido</th><th>Cliente</th><th>Archivo</th><th>Monto</th><th>Estado</th></tr></thead><tbody>
    ${filas.map(f => {
      const [nivel, texto] = ESTADOS[f.estado] || ['gris', f.estado];
      return `<tr><td>${esc(fmtFechaHora(f.subido_en))}</td><td>${esc(nombreCliente(f.cliente_id))}</td>
        <td>${esc(f.archivo_nombre || '')}</td><td>${f.monto != null ? esc(fmtMonto(f.monto, f.moneda)) : '—'}</td>
        <td>${semaforo(nivel, texto)}${f.motivo ? `<div class="small">${esc(f.motivo)}</div>` : ''}</td></tr>`;
    }).join('')}</tbody></table>`;
}

export async function vistaSubirComprobante(el, vigente) {
  const opciones = yo.comp.map(c => `<option value="${esc(c.cliente_id)}">${esc(c.nombre || nombreCliente(c.cliente_id))}</option>`).join('');
  el.innerHTML = `
    <div class="card concepto-card">
      <p class="small">Subí la foto, la captura o el PDF de la transferencia. Finanzas lo revisa y carga el pago: hasta entonces no se guarda nada.</p>
      <div class="form-row"><label for="s-cliente">Cliente</label><select id="s-cliente">${opciones}</select></div>
      <div class="form-row"><label for="s-archivo">Comprobante</label>
        <input type="file" id="s-archivo" accept="${ACCEPT}">
        <div class="hint">Imagen (jpg, png, webp) o PDF, hasta 10 MB.</div></div>
      <div class="form-error" id="s-error" role="alert"></div>
      <div class="small" id="s-estado" role="status"></div>
      <button type="button" class="btn btn-accent" id="s-enviar">Enviar comprobante</button>
    </div>
    <div class="card concepto-card"><div class="field-label">Mis comprobantes</div><div id="s-lista"><div class="loading-inline">Cargando…</div></div></div>`;

  const $ = id => el.querySelector('#' + CSS.escape(id));
  const err = $('s-error'), estado = $('s-estado'), boton = $('s-enviar'), inp = $('s-archivo');

  const pintarLista = async () => {
    try {
      const filas = await comprobantesMios();
      if (vigente()) $('s-lista').innerHTML = listaHtml(filas || []);
    } catch (e) {
      if (vigente()) $('s-lista').innerHTML = `<div class="form-error">${esc(e.message || String(e))}</div>`;
    }
  };

  boton.onclick = async () => {
    err.textContent = '';
    const f = inp.files[0];
    const falla = validarArchivo(f);
    if (falla) { err.textContent = falla; return; }
    boton.disabled = true; inp.disabled = true;
    estado.textContent = 'Subiendo el comprobante…';
    let id;
    try { id = await subirComprobante($('s-cliente').value, f); }
    catch (e) {
      if (!vigente()) return;
      err.textContent = e.message || String(e); estado.textContent = '';
      boton.disabled = false; inp.disabled = false;
      return;
    }
    if (!vigente()) return;
    /* Ya está registrado: si la lectura falla, igual queda pendiente para Finanzas (puede releerlo). */
    estado.textContent = 'Enviando a revisión…';
    try { await leerComprobante(id); } catch (e) { console.warn('comprobante-leer', e.message || e); }
    if (!vigente()) return;
    estado.textContent = 'Listo: Finanzas lo va a revisar.';
    inp.value = ''; inp.disabled = false; boton.disabled = false;
    await pintarLista();
  };

  await pintarLista();
}
