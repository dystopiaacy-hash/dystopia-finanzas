/* Piezas compartidas por las vistas: tarjetas, selects, estados de sync y vacíos. */
import { esc, semaforo } from '../ui.js';
import { yo, nombreCliente } from '../sesion.js';
import { MESES } from '../datos.js';
import { COLGADA_MIN, DESACTUALIZADA_MIN } from '../config.js';

export function statCard(valor, label, { sub = '', alerta = false, html = false } = {}) {
  return `
    <div class="stat-card${alerta ? ' stat-alerta' : ''}">
      <div class="stat-num">${html ? valor : esc(valor)}</div>
      <div class="stat-label">${esc(label)}</div>
      ${sub ? `<div class="stat-sub">${esc(sub)}</div>` : ''}
    </div>`;
}

export function vacio(titulo, texto = '') {
  return `<div class="card empty-state"><div class="big">${esc(titulo)}</div>${texto ? `<div class="small">${esc(texto)}</div>` : ''}</div>`;
}

export function selectCliente(id, actual, { todos = true } = {}) {
  const ops = yo.clientes.map(c => `<option value="${esc(c.id)}"${c.id === actual ? ' selected' : ''}>${esc(c.nombre)}</option>`);
  return `<select id="${esc(id)}">${todos ? `<option value="">Todos los clientes</option>` : ''}${ops.join('')}</select>`;
}

export function selectAnio(id, anios, actual) {
  return `<select id="${esc(id)}">${anios.map(a => `<option value="${a}"${a === actual ? ' selected' : ''}>${a}</option>`).join('')}</select>`;
}

export function selectMes(id, actual, { todos = false } = {}) {
  const ops = MESES.map((m, i) => `<option value="${i + 1}"${i + 1 === actual ? ' selected' : ''}>${m}</option>`);
  return `<select id="${esc(id)}">${todos ? `<option value="">Todo el año</option>` : ''}${ops.join('')}</select>`;
}

export function anios(filas, extra) {
  const s = new Set(filas.map(f => f.anio).filter(Boolean));
  if (extra) s.add(extra);
  return [...s].sort((a, b) => b - a);
}

export function clienteChip(id) {
  return `<span class="cli-chip"><span class="sem-dot" style="--badge-color:var(--c-${esc(id)}, var(--text-faint))"></span>${esc(nombreCliente(id))}</span>`;
}

/* Estados de corrida. error y parcial en rojo, revisar en ámbar: los tres
   son "requiere acción" y se muestran con el mismo peso visual. */
export const ESTADOS = {
  error: { nivel: 'rojo', texto: 'Error', orden: 0 },
  colgada: { nivel: 'rojo', texto: 'Colgada', orden: 0 },
  parcial: { nivel: 'rojo', texto: 'Parcial', orden: 1 },
  revisar: { nivel: 'amarillo', texto: 'Revisar', orden: 2 },
  sin_corridas: { nivel: 'rojo', texto: 'Nunca corrió', orden: 1 },
  desactualizada: { nivel: 'amarillo', texto: 'Desactualizada', orden: 3 },
  en_curso: { nivel: 'gris', texto: 'En curso', orden: 4 },
  ok: { nivel: 'verde', texto: 'OK', orden: 5 },
  inactiva: { nivel: 'gris', texto: 'Inactiva', orden: 6 }
};

/* Estado efectivo de una fila de fin_v_salud_sync. requiere_revision de la
   vista solo mira 'revisar': acá error, parcial, colgada y nunca corrió
   pesan igual o más. */
export function estadoFuente(f, ahora = Date.now()) {
  if (!f.activo) return 'inactiva';
  if (!f.corrida_id) return 'sin_corridas';
  const min = (ahora - new Date(f.inicio).getTime()) / 60000;
  if (f.estado === 'en_curso') return min > COLGADA_MIN ? 'colgada' : 'en_curso';
  if (f.estado === 'ok' && min > DESACTUALIZADA_MIN) return 'desactualizada';
  return ESTADOS[f.estado] ? f.estado : 'error';
}

export const requiereAccion = clave => ESTADOS[clave].orden <= 3;

export function peorEstado(claves) {
  return claves.reduce((peor, c) => (ESTADOS[c].orden < ESTADOS[peor].orden ? c : peor), 'ok');
}

export function badgeEstado(clave) {
  const e = ESTADOS[clave] || ESTADOS.ok;
  return semaforo(e.nivel, e.texto);
}

export function botonRecargar(id = 'btn-recargar') {
  return `<button type="button" class="btn btn-sm" id="${id}">↻ Recargar</button>`;
}
