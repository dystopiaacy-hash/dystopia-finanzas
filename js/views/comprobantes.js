/* Bandeja de comprobantes (143), para fundador y finanzas: los que subió el equipo y todavía no son un pago.
   Desde acá: ver el archivo, releer con IA, "Cargar como pago" (abre Cargar pago con el formulario precargado)
   o descartar con motivo. Confirmar = cargar el pago en Cargar pago; esta pantalla nunca crea pagos. */
import { esc, fmtFechaHora, semaforo } from '../ui.js';
import { nombreCliente, yo } from '../sesion.js';
import { navegar } from '../router.js';
import {
  comprobantesBandeja, comprobanteDescartar, leerComprobante, urlComprobante, dejarPrecarga, resumenLeido
} from '../comprobantes.js';

const FILTROS = [['pendientes', 'Pendientes'], ['confirmados', 'Cargados'], ['descartados', 'Descartados']];
const ESTADO = {
  subido: ['gris', 'Sin leer'], leyendo: ['gris', 'Leyendo'], leido: ['amarillo', 'Para confirmar'],
  error: ['rojo', 'No se pudo leer'], confirmado: ['verde', 'Cargado como pago'], descartado: ['rojo', 'Descartado']
};
const ROL = { cliente: 'cliente', closer: 'closer', setter: 'setter', finanzas: 'finanzas', fundador: 'fundador' };

const fmtFecha = f => (f ? String(f).slice(0, 10).split('-').reverse().join('/') : '');
const fmtMonto = (m, mon) => `${mon || ''} ${new Intl.NumberFormat('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(m)}`.trim();

function tarjeta(c) {
  const [nivel, texto] = ESTADO[c.estado] || ['gris', c.estado];
  const ex = c.extraido || {}, prop = c.propuesta || {}, dups = c.duplicados || [];
  const conf = c.confianza ? semaforo({ alta: 'verde', media: 'amarillo', baja: 'rojo' }[c.confianza], `Confianza ${c.confianza}`) : '';
  const pendiente = ['subido', 'leyendo', 'leido', 'error'].includes(c.estado);
  /* Cargar pago solo si la persona puede cargar en ese cliente (reglas de la 066/075, no las de esta pantalla). */
  const puedeCargar = yo.carga.some(x => x.cliente_id === c.cliente_id && x.habilitada);
  return `<div class="card concepto-card comp-item" data-id="${esc(c.id)}">
    <div class="comp-cab">
      <strong>${esc(nombreCliente(c.cliente_id))}</strong>
      ${semaforo(nivel, texto)} ${conf}
      <span class="small">Subido por ${esc(c.subido_por_nombre || 'sin nombre')}${c.subido_rol ? ` (${esc(ROL[c.subido_rol] || c.subido_rol)})` : ''} · ${esc(fmtFechaHora(c.subido_en))}</span>
    </div>
    ${c.estado === 'leido' || ex.monto != null ? `<div>${esc(resumenLeido(ex))}</div>` : ''}
    ${ex.pagador_nombre ? `<div class="small">Pagó: ${esc(ex.pagador_nombre)}${ex.pagador_documento ? ` · ${esc(ex.pagador_documento)}` : ''}${ex.numero_operacion ? ` · Operación ${esc(ex.numero_operacion)}` : ''}</div>` : ''}
    ${prop.alumno ? `<div class="small">Alumno propuesto: <strong>${esc(prop.alumno)}</strong> (${esc(prop.motivo || '')})${prop.cuota ? ` · cuota ${prop.cuota.numero ? `n° ${esc(prop.cuota.numero)} ` : ''}${esc(prop.cuota.programa || '')}${prop.cuota.vence ? ` vence ${esc(fmtFecha(prop.cuota.vence))}` : ''}` : ''}</div>` : (c.estado === 'leido' ? '<div class="small">No se encontró un alumno parecido.</div>' : '')}
    ${ex.es_comprobante === false ? '<div class="small comp-aviso">No parece un comprobante de pago.</div>' : ''}
    ${c.error ? `<div class="small comp-aviso">${esc(c.error)}</div>` : ''}
    ${dups.length ? `<div class="comp-dup" role="alert"><strong>Posible duplicado</strong>${dups.map(d =>
      `<div>${d.donde === 'pago' ? `Pago de ${esc(d.alumno)} por ${esc(fmtMonto(d.monto, d.moneda))} del ${esc(fmtFecha(d.fecha))}` : `Otro comprobante (${esc(d.estado)})`} · ${d.tipo === 'operacion' ? 'mismo número de operación' : 'mismo monto, fecha y pagador'}</div>`).join('')}</div>` : ''}
    ${c.estado === 'descartado' && c.descartado_motivo ? `<div class="small">Motivo: ${esc(c.descartado_motivo)}</div>` : ''}
    <div class="comp-acciones">
      <button type="button" class="btn btn-sm" data-ver>Ver comprobante</button>
      ${pendiente ? `<button type="button" class="btn btn-sm" data-releer>${c.estado === 'leido' ? 'Releer con IA' : 'Leer con IA'}</button>` : ''}
      ${pendiente && puedeCargar ? '<button type="button" class="btn btn-sm btn-accent" data-cargar>Cargar como pago</button>' : ''}
      ${pendiente && !puedeCargar ? '<span class="small">No tenés permiso para cargar pagos de este cliente.</span>' : ''}
      ${pendiente ? '<button type="button" class="btn btn-sm" data-descartar>Descartar</button>' : ''}
    </div>
    <div class="comp-descartar" hidden>
      <input type="text" maxlength="300" placeholder="Motivo del descarte" aria-label="Motivo del descarte">
      <button type="button" class="btn btn-sm btn-danger" data-descartar-ok>Descartar</button>
      <button type="button" class="btn btn-sm" data-descartar-no>Cancelar</button>
    </div>
    <div class="form-error" role="alert"></div>
  </div>`;
}

export async function vistaComprobantes(el, vigente) {
  let filtro = 'pendientes', filas = [];
  el.innerHTML = `<div id="b-raiz">
    <div class="filter-row" id="b-filtros" role="group" aria-label="Filtro">
      ${FILTROS.map(([k, t]) => `<button type="button" class="btn btn-sm" data-filtro="${k}">${t}</button>`).join('')}
    </div>
    <div id="b-lista"></div></div>`;
  /* El click va en la raíz de esta vista, no en #view (que comparten todas las pantallas). */
  const raiz = el.querySelector('#b-raiz'), lista = el.querySelector('#b-lista');

  const pintar = async () => {
    for (const b of el.querySelectorAll('[data-filtro]')) b.classList.toggle('btn-accent', b.dataset.filtro === filtro);
    lista.innerHTML = '<div class="loading-inline">Cargando…</div>';
    try { filas = await comprobantesBandeja(filtro); }
    catch (e) { if (vigente()) lista.innerHTML = `<div class="form-error">${esc(e.message || String(e))}</div>`; return; }
    if (!vigente()) return;
    lista.innerHTML = filas.length ? filas.map(tarjeta).join('')
      : `<div class="card empty-state"><div class="big">${filtro === 'pendientes' ? 'No hay comprobantes pendientes' : 'Nada para mostrar'}</div></div>`;
  };

  raiz.onclick = async ev => {
    const f = ev.target.closest('[data-filtro]');
    if (f) { filtro = f.dataset.filtro; await pintar(); return; }
    const card = ev.target.closest('.comp-item');
    const b = ev.target.closest('button');
    if (!card || !b) return;
    const c = filas.find(x => x.id === card.dataset.id);
    const err = card.querySelector('.form-error');
    err.textContent = '';
    const caja = card.querySelector('.comp-descartar');
    try {
      if (b.hasAttribute('data-ver')) {
        const w = window.open('', '_blank');           // se abre antes del await para que no lo bloquee el navegador
        try {
          const url = await urlComprobante(c.archivo_path);
          if (w) { w.opener = null; w.location = url; } else err.textContent = 'El navegador bloqueó la ventana: permitila e intentá de nuevo.';
        } catch (e) { if (w) w.close(); throw e; }
      } else if (b.hasAttribute('data-releer')) {
        b.disabled = true; b.textContent = 'Leyendo…';
        const r = await leerComprobante(c.id, true);
        if (r && r.ok === false) throw new Error(r.error || 'No se pudo leer.');
        await pintar();
      } else if (b.hasAttribute('data-cargar')) {
        dejarPrecarga(c);
        navegar('cargar');
      } else if (b.hasAttribute('data-descartar')) {
        caja.hidden = false; caja.querySelector('input').focus();
      } else if (b.hasAttribute('data-descartar-no')) {
        caja.hidden = true;
      } else if (b.hasAttribute('data-descartar-ok')) {
        b.disabled = true;
        await comprobanteDescartar(c.id, caja.querySelector('input').value);
        await pintar();
      }
    } catch (e) {
      if (!vigente()) return;
      err.textContent = e.message || String(e);
      b.disabled = false;
      if (b.hasAttribute('data-releer')) b.textContent = 'Releer con IA';
    }
  };

  await pintar();
}
