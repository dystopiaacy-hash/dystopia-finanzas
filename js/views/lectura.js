/* "Lectura del mes" (148): 5 a 8 bullets de IA sobre los números del mes de un cliente, con historial.
   Solo fundador y finanzas asignado (la base decide; sesion.js solo muestra u oculta la pantalla).
   Selector de cliente y de mes (últimos 12 meses + meses con lectura) y botón "Regenerar", que suma una lectura
   nueva al historial sin borrar las anteriores. */
import { esc, fmtFechaHora, hoyAR } from '../ui.js';
import { yo } from '../sesion.js';
import { lecturasDe, lecturaRegenerar } from '../lectura.js';
import { vacio } from './comunes.js';

const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const nombreMes = p => `${MESES[Number(p.slice(5)) - 1]} ${p.slice(0, 4)}`;

/* Últimos 12 meses terminados (el actual no: la lectura es del mes anterior). */
function ultimosMeses() {
  let [a, m] = hoyAR().split('-').map(Number);
  const out = [];
  for (let i = 0; i < 12; i++) {
    m -= 1;
    if (m === 0) { m = 12; a -= 1; }
    out.push(`${a}-${String(m).padStart(2, '0')}`);
  }
  return out;
}

const bullets = texto => `<ul class="lectura-lista">${String(texto).split('\n')
  .map(l => l.replace(/^[-*•]\s+/, '').trim()).filter(Boolean).map(l => `<li>${esc(l)}</li>`).join('')}</ul>`;

export async function vistaLectura(el, vigente) {
  const clientes = yo.lectura;
  let cliente = clientes[0].cliente_id, periodo = ultimosMeses()[0], historial = [], versionId = null;

  el.innerHTML = `<div id="l-raiz">
    <div class="filter-row">
      ${clientes.length > 1 ? `<label class="flabel" for="l-cliente">Cliente</label>
        <select id="l-cliente">${clientes.map(c => `<option value="${esc(c.cliente_id)}">${esc(c.nombre || c.cliente_id)}</option>`).join('')}</select>` : ''}
      <label class="flabel" for="l-mes">Mes</label><select id="l-mes"></select>
      <span class="grow"></span>
      <button type="button" class="btn btn-accent" id="l-regenerar">Regenerar</button>
    </div>
    <div class="form-error" id="l-error" role="alert"></div>
    <div id="l-cuerpo"></div></div>`;
  const raiz = el.querySelector('#l-raiz'), cuerpo = raiz.querySelector('#l-cuerpo'), err = raiz.querySelector('#l-error');
  const selMes = raiz.querySelector('#l-mes'), btn = raiz.querySelector('#l-regenerar');

  const delMes = () => historial.filter(h => h.periodo === periodo);   // ya viene la más nueva primero

  const pintarMeses = () => {
    const conLectura = new Set(historial.map(h => h.periodo));
    const lista = [...new Set([...ultimosMeses(), ...conLectura])].sort().reverse();
    selMes.innerHTML = lista.map(p => `<option value="${p}"${p === periodo ? ' selected' : ''}>${nombreMes(p)}${conLectura.has(p) ? '' : ' (sin lectura)'}</option>`).join('');
  };

  const pintar = () => {
    const versiones = delMes();
    const v = versiones.find(x => x.id === versionId) || versiones[0];
    if (!v) {
      cuerpo.innerHTML = vacio(`Todavía no hay lectura de ${nombreMes(periodo)}`, 'Se genera sola el día 1 de cada mes a las 8:31, o con "Regenerar".');
      return;
    }
    cuerpo.innerHTML = `<div class="card lectura-card">
      <div class="lectura-cab"><strong>${esc(nombreMes(periodo))}</strong>
        <span class="small">Generada el ${esc(fmtFechaHora(v.generado_en))} · ${v.origen === 'cron' ? 'automática' : 'manual'}</span></div>
      ${bullets(v.texto)}
      <p class="small">Lectura hecha por IA a partir de los números cargados en la app. Revisala antes de tomar decisiones.</p>
      ${versiones.length > 1 ? `<div class="filter-row"><label class="flabel" for="l-version">Versiones de este mes</label>
        <select id="l-version">${versiones.map(x => `<option value="${x.id}"${x.id === v.id ? ' selected' : ''}>${esc(fmtFechaHora(x.generado_en))}${x.origen === 'cron' ? ' · automática' : ''}</option>`).join('')}</select></div>` : ''}
    </div>`;
  };

  const cargar = async () => {
    err.textContent = '';
    cuerpo.innerHTML = '<div class="loading-inline">Cargando…</div>';
    try { historial = await lecturasDe(cliente); }
    catch (e) { if (vigente()) cuerpo.innerHTML = `<div class="form-error">${esc(e.message || String(e))}</div>`; return; }
    if (!vigente()) return;
    versionId = null;
    pintarMeses(); pintar();
  };

  raiz.onchange = ev => {
    if (ev.target.id === 'l-cliente') { cliente = ev.target.value; cargar(); }
    else if (ev.target.id === 'l-mes') { periodo = ev.target.value; versionId = null; err.textContent = ''; pintar(); }
    else if (ev.target.id === 'l-version') { versionId = Number(ev.target.value); pintar(); }
  };

  btn.onclick = async () => {
    err.textContent = '';
    btn.disabled = true; btn.textContent = 'Generando…';
    cuerpo.insertAdjacentHTML('afterbegin', '<div class="loading-inline" id="l-gen">La IA está leyendo los números, puede tardar un minuto…</div>');
    try {
      await lecturaRegenerar(cliente, periodo);
      if (!vigente()) return;
      historial = await lecturasDe(cliente);
      versionId = null;
      pintarMeses(); pintar();
    } catch (e) {
      if (!vigente()) return;
      err.textContent = e.message || String(e);
      const g = cuerpo.querySelector('#l-gen'); if (g) g.remove();
    } finally {
      btn.disabled = false; btn.textContent = 'Regenerar';
    }
  };

  await cargar();
}
