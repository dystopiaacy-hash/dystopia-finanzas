/* Chat interno "Preguntale a la IA" que abre Dystopita en Finanzas. SOLO LECTURA: la función ia-preguntar (la misma que usa
   Producto) elige consultas ya armadas en la base y la base responde con los permisos de quien pregunta (ver
   docs/dystopita-herramientas.md). La conversación vive solo en esta pantalla (no se guarda). */
import { esc, toast } from '../ui.js';
import { puedeUsarChatIa } from '../sesion.js';
import { preguntarIa } from '../datos-ia-chat.js';

/* Nombre en castellano de cada herramienta, para la línea "Consultó: ..." (las que no figuran se muestran tal cual). */
const HERRAMIENTA = {
  alumnos_atrasados: 'alumnos atrasados',
  en_que_esta_alumno: 'en qué está un alumno',
  por_renovar_o_deuda: 'por renovar o deuda',
  alumnos_cantidad: 'cantidad de alumnos',
  mkt_piezas_publicadas: 'piezas publicadas',
  mkt_pendientes_produccion: 'pendientes de producción',
  mkt_analisis_semanal: 'análisis semanal',
  ventas_llamadas: 'llamadas',
  ventas_por_persona: 'llamadas por closer o setter',
  ventas_leads: 'leads',
  fin_cobros: 'cobros',
  fin_ingresos_gastos: 'ingresos y gastos',
  fin_deudas: 'deudas',
  fin_pagos: 'pagos'
};

/* Conserva la conversación mientras no se recargue la página. */
let hilo = [];

function mensajeError(e) {
  const msg = (e && e.message) || String(e || '');
  if (/jwt|sesi[oó]n/i.test(msg)) return 'Tu sesión venció. Recargá la página.';
  return msg || 'Error desconocido.';
}

export function vistaPreguntar(el, clienteId, vigente) {
  if (!puedeUsarChatIa()) {
    el.innerHTML = '<div class="card empty-state"><div class="big">No tenés acceso a esta sección.</div></div>';
    return null;
  }
  const ejemplos = [
    clienteId ? `¿Cuánto cobramos este mes de ${clienteId}?` : '¿Cuánto cobramos este mes?',
    '¿Cuántas llamadas se agendaron este mes?',
    '¿Quién debe plata?'
  ];
  let esperando = false;

  function mensajes() {
    return hilo.map(m => m.rol === 'yo'
      ? `<div class="chat-ia-msg chat-ia-msg-yo">${esc(m.texto)}</div>`
      : `<div class="chat-ia-msg chat-ia-msg-ia">${esc(m.texto)}${m.consultas && m.consultas.length
          ? `<div class="chat-ia-meta">Consultó: ${esc(m.consultas.map(c => `${HERRAMIENTA[c.herramienta] || c.herramienta}${c.filas == null ? '' : ` (${c.filas} ${c.filas === 1 ? 'fila' : 'filas'})`}`).join(', '))}</div>` : ''}</div>`
    ).join('');
  }

  function pintar() {
    el.innerHTML = `
      <div class="chat-ia">
        <div class="card">
          <p><strong>Preguntale a la IA</strong> · solo lectura: no modifica nada.</p>
          <p class="hint">Responde de Producto, Marketing, Ventas y Finanzas, con los datos que vos tenés permiso de ver. Si no tiene la herramienta para tu pregunta, te lo dice.</p>
          <div class="chat-ia-ejemplos">
            ${ejemplos.map((t, i) => `<button type="button" class="btn btn-sm" data-ia-ejemplo="${i}">${esc(t)}</button>`).join('')}
          </div>
        </div>
        <div class="chat-ia-hilo" id="ia-hilo" aria-live="polite">${mensajes()}</div>
        <div class="chat-ia-form">
          <textarea id="ia-pregunta" rows="2" maxlength="600" placeholder="Escribí tu pregunta…" aria-label="Pregunta"></textarea>
          <button type="button" class="btn btn-accent" id="ia-enviar">Preguntar</button>
        </div>
        <div class="hint" id="ia-estado"></div>
      </div>`;
  }

  async function enviar(texto) {
    const t = (texto || '').trim();
    if (!t || esperando) return;
    esperando = true;
    hilo.push({ rol: 'yo', texto: t });
    pintar();
    const estado = el.querySelector('#ia-estado');
    const enviarBtn = el.querySelector('#ia-enviar');
    if (enviarBtn) enviarBtn.disabled = true;
    if (estado) estado.textContent = 'Pensando…';
    window.dispatchEvent(new CustomEvent('ia-chat-pensando', { detail: { pensando: true } }));   // Dystopita
    try {
      const r = await preguntarIa(t, clienteId);
      hilo.push({ rol: 'ia', texto: r.respuesta, consultas: r.consultas || [] });
    } catch (e) {
      toast(mensajeError(e), 'error');
      hilo.push({ rol: 'ia', texto: 'No pude responder: ' + mensajeError(e) });
    }
    window.dispatchEvent(new CustomEvent('ia-chat-pensando', { detail: { pensando: false } }));
    esperando = false;
    if (!vigente()) return;
    pintar();
  }

  el.addEventListener('click', ev => {
    const ej = ev.target.closest('[data-ia-ejemplo]');
    if (ej) { enviar(ejemplos[Number(ej.dataset.iaEjemplo)]); return; }
    if (ev.target.closest('#ia-enviar')) enviar(el.querySelector('#ia-pregunta').value);
  });
  el.addEventListener('keydown', ev => {
    if (ev.target.id === 'ia-pregunta' && ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault();
      enviar(ev.target.value);
    }
  });

  pintar();
  return null;
}
