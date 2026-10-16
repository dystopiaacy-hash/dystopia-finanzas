/* "Subir comprobante" dentro de Cargar pago (143): sube el archivo, lo lee la IA y precarga el formulario.
   Solo se ofrece a quien confirma (fundador, finanzas). NO guarda ningún pago: la persona revisa y aprieta
   "Guardar pago"; recién entonces cargar.js llama a confirmar() para vincular el comprobante con ese pago.
   Si la IA no pudo leerlo, el comprobante queda igual y se vincula cuando se cargue a mano. */
import { esc, semaforo } from '../ui.js';
import { confirmaComprobante } from '../sesion.js';
import {
  ACCEPT, validarArchivo, subirComprobante, leerComprobante, comprobanteConfirmar, resumenLeido
} from '../comprobantes.js';

export const cajaComprobante = () => `<div class="comp-caja">
  <div class="form-row"><label for="comp-archivo">Comprobante de la transferencia</label>
    <input type="file" id="comp-archivo" accept="${ACCEPT}">
    <div class="hint">Opcional. Imagen (jpg, png, webp) o PDF: se lee con IA y se precarga el formulario. Revisá todo antes de guardar.</div></div>
  <div class="small" id="comp-estado" role="status"></div>
  <div id="comp-info" class="comp-info" hidden></div>
</div>`;

const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const fmtMonto = (m, mon) => `${mon || ''} ${new Intl.NumberFormat('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(m)}`.trim();
const fmtFecha = f => (f ? String(f).slice(0, 10).split('-').reverse().join('/') : '');

function textoDuplicado(d) {
  const que = d.tipo === 'operacion' ? 'el mismo número de operación' : 'mismo monto, fecha y pagador';
  if (d.donde === 'pago') {
    return `Ya hay un pago de ${d.alumno} por ${fmtMonto(d.monto, d.moneda)} del ${fmtFecha(d.fecha)} (${que}).`;
  }
  return `Ya hay otro comprobante ${d.estado === 'confirmado' ? 'confirmado' : 'subido'} el ${fmtFecha(d.subido_en)} (${que}).`;
}

/* ctx: { el, $, ids (CAMPOS de cargar.js), cliente(): id elegido, vigente() }. */
export function enlazarComprobante({ $, ids, cliente, vigente }) {
  const inp = $('comp-archivo'), estado = $('comp-estado'), info = $('comp-info');
  let compId = null, hayDuplicado = false;
  const dupOk = () => $('comp-dup-ok');

  const limpiar = () => {
    compId = null; hayDuplicado = false;
    inp.value = ''; estado.textContent = ''; info.hidden = true; info.innerHTML = '';
  };
  const poner = (id, v) => { const x = $(ids[id].id); if (x && v != null && v !== '') x.value = v; };

  function notaDe(ex) {
    const partes = [];
    if (ex.banco_o_billetera) partes.push(ex.banco_o_billetera);
    if (ex.numero_operacion) partes.push(`op ${ex.numero_operacion}`);
    if (ex.pagador_nombre) partes.push(`pagó ${ex.pagador_nombre}${ex.pagador_documento ? ` (${ex.pagador_documento})` : ''}`);
    if (ex.monto != null && ex.moneda && ex.moneda !== 'USD') partes.push(`${fmtMonto(ex.monto, ex.moneda)} (cargar el equivalente en USD)`);
    return partes.length ? `Comprobante: ${partes.join(' · ')}` : '';
  }

  /* Lleva lo leído al formulario (pisa lo que había: la persona acaba de subir el archivo) y muestra el panel de revisión. */
  function aplicar(comp) {
    const ex = comp.extraido || {}, prop = comp.propuesta || {}, dups = comp.duplicados || [];
    compId = comp.id;
    hayDuplicado = dups.length > 0;
    const fecha = $(ids.fecha.id);
    if (ex.fecha && fecha) fecha.value = ex.fecha;          // la fecha del comprobante manda sobre "hoy"
    poner('alumno', prop.alumno || ex.pagador_nombre);
    poner('telefono', prop.telefono);
    if (ex.monto != null && (!ex.moneda || ex.moneda === 'USD')) poner('monto_usd', ex.monto);
    const prog = $(ids.programa.id);
    if (prog && prop.programa) {
      const op = [...prog.options].find(o => o.value && norm(o.textContent) === norm(prop.programa));
      if (op) prog.value = op.value;
    }
    poner('nota', notaDe(ex));

    const nivel = { alta: 'verde', media: 'amarillo', baja: 'rojo' }[comp.confianza] || 'gris';
    const avisos = [];
    if (ex.es_comprobante === false) avisos.push('No parece un comprobante de pago.');
    if (ex.legibilidad === 'baja') avisos.push('Se lee mal: revisá todos los datos.');
    if (ex.monto != null && ex.moneda && ex.moneda !== 'USD') avisos.push(`El comprobante está en ${ex.moneda}: cargá el monto equivalente en USD.`);
    if (ex.notas) avisos.push(ex.notas);
    if (prop.busqueda_ok === false) avisos.push('No se pudo buscar el alumno: elegilo a mano.');
    const cuota = prop.cuota;
    const otros = (prop.candidatos || []).slice(1).map(c => c.alumno);
    info.innerHTML = `
      <div>${semaforo(nivel, `Confianza ${comp.confianza || 'sin dato'}`)} <strong>${esc(resumenLeido(ex))}</strong></div>
      ${ex.pagador_nombre ? `<div class="small">Pagó: ${esc(ex.pagador_nombre)}${ex.pagador_documento ? ` · ${esc(ex.pagador_documento)}` : ''}${ex.pagador_alias ? ` · ${esc(ex.pagador_alias)}` : ''}${ex.numero_operacion ? ` · Operación ${esc(ex.numero_operacion)}` : ''}</div>` : ''}
      <div class="small">${prop.alumno ? `Alumno propuesto: <strong>${esc(prop.alumno)}</strong> (${esc(prop.motivo || '')})` : 'No se encontró un alumno parecido: elegilo o escribilo.'}${otros.length ? ` · Otros posibles: ${esc(otros.join(', '))}` : ''}</div>
      ${cuota ? `<div class="small">Cuota que podría corresponder: ${cuota.numero ? `n° ${esc(cuota.numero)} · ` : ''}${esc(cuota.programa || '')}${cuota.vence ? ` · vence ${esc(fmtFecha(cuota.vence))}` : ''}${cuota.monto != null ? ` · ${esc(fmtMonto(cuota.monto, 'USD'))}` : ''}${cuota.coincide_monto ? ' (el monto coincide)' : ''}</div>` : ''}
      ${avisos.map(a => `<div class="small comp-aviso">${esc(a)}</div>`).join('')}
      ${dups.length ? `<div class="comp-dup" role="alert"><strong>Posible duplicado</strong>
        ${dups.map(d => `<div>${esc(textoDuplicado(d))}</div>`).join('')}
        <label><input type="checkbox" id="comp-dup-ok"> Revisé: es otro pago, guardar igual</label></div>` : ''}
      <div class="small">Nada se guardó todavía: revisá el formulario y apretá "Guardar pago".</div>`;
    info.hidden = false;
    estado.textContent = '';
  }

  inp.onchange = async () => {
    const f = inp.files[0];
    if (!f) return;
    const cli = cliente();
    const falla = validarArchivo(f) || (!cli || !confirmaComprobante(cli) ? 'No podés subir comprobantes para este cliente.' : '');
    if (falla) { estado.textContent = falla; estado.classList.add('form-error'); inp.value = ''; return; }
    estado.classList.remove('form-error');
    inp.disabled = true;
    info.hidden = true;
    estado.textContent = 'Subiendo el comprobante…';
    let id;
    try { id = await subirComprobante(cli, f); }
    catch (e) {
      if (!vigente()) return;
      estado.textContent = e.message || String(e); estado.classList.add('form-error');
      inp.disabled = false; inp.value = '';
      return;
    }
    if (!vigente()) return;
    compId = id; hayDuplicado = false;
    estado.textContent = 'Leyendo el comprobante con IA (unos segundos)…';
    try {
      const r = await leerComprobante(id);
      if (!vigente()) return;
      if (r && r.ok && r.extraido) aplicar({ id, ...r });
      else { estado.textContent = (r && r.error) || 'No se pudo leer. Cargalo a mano: el comprobante queda vinculado igual.'; estado.classList.add('form-error'); }
    } catch (e) {
      if (!vigente()) return;
      estado.textContent = `No se pudo leer (${e.message || e}). Cargalo a mano: el comprobante queda vinculado igual.`;
      estado.classList.add('form-error');
    }
    inp.disabled = false;
  };

  return {
    limpiar,
    cargar: aplicar,                                    // desde la bandeja: el comprobante ya está leído
    /* Aviso para el submit: hay posible duplicado y la persona no marcó que lo revisó. */
    faltaRevisarDuplicado: () => hayDuplicado && !(dupOk() && dupOk().checked),
    /* Después de guardar el pago: vincula el comprobante. Devuelve '' o el motivo si falló. */
    async confirmar(pagoClave) {
      if (!compId) return '';
      try { await comprobanteConfirmar(compId, pagoClave); return ''; }
      catch (e) { return e.message || String(e); }
    }
  };
}
