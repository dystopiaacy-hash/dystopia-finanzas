/* Panel lateral "Columnas" (072, solo fundador). Mismo patrón que el del Maestro
   de Producto: renombrar, mostrar u ocultar y reordenar con flechas. Con
   permiteNuevas (solo Pagos): agregar, archivar, recuperar y editar opciones.
   Los errores de la base ("fin: ...") se muestran tal cual adentro del panel, y
   archivar se confirma acá adentro: nunca alert, confirm ni prompt. */
import { esc, toast } from '../ui.js';
import {
  TIPO_COLUMNA_LABEL, columnaGuardar, columnaCrear, columnasOrdenar, columnaArchivar, opcionRenombrar, errorColumnas
} from '../columnas.js';

const lineas = t => Array.from(new Set(String(t || '').split('\n').map(s => s.trim()).filter(Boolean)));
const opcionesTipo = actual => Object.entries(TIPO_COLUMNA_LABEL).map(([v, l]) =>
  `<option value="${v}"${v === actual ? ' selected' : ''}>${esc(l)}</option>`).join('');

function editorOpciones(c) {
  const filas = c.opciones.map((o, i) => `
    <li class="mc-op"><input type="text" class="mc-input" id="mc-o-${esc(c.k)}-${i}" maxlength="60" value="${esc(o)}"
        data-mc-opcion="${esc(o)}" aria-label="${esc('Opción ' + o)}">
      <button type="button" class="btn btn-sm btn-ghost" data-mc="op-quitar" data-opcion="${esc(o)}"
        title="Quitar la opción" aria-label="${esc('Quitar la opción ' + o)}">✕</button></li>`).join('');
  return `<div class="mc-opciones">
      <ul>${filas || '<li class="mc-vacio">Sin opciones todavía.</li>'}</ul>
      <div class="mc-op"><input type="text" class="mc-input" id="mc-oa-${esc(c.k)}" maxlength="60" placeholder="Nueva opción"
          data-mc-agregar aria-label="Nueva opción">
        <button type="button" class="btn btn-sm" data-mc="op-agregar">Agregar</button></div>
      <div class="mc-nota">Renombrar una opción cambia también los pagos que ya la tienen.</div>
    </div>`;
}

function itemHtml(c, i, total, ui) {
  const extra = c.sistema ? '' : `
    <div class="mc-extra"><span class="mc-tipo">${esc(TIPO_COLUMNA_LABEL[c.tipo] || c.tipo)}</span>
      ${c.tipo === 'opcion' ? `<button type="button" class="btn btn-sm btn-ghost" data-mc="opciones" aria-expanded="${ui.opciones === c.k}">
        Opciones (${c.opciones.length})</button>` : ''}
      <button type="button" class="btn btn-sm btn-ghost" data-mc="archivar">Archivar</button></div>
    ${ui.archivar === c.k ? `<div class="mc-confirmar">
      <span>¿Archivar "${esc(c.lab)}"? Los valores cargados quedan guardados y se recupera desde Archivadas.</span>
      <div class="mc-acciones"><button type="button" class="btn btn-sm" data-mc="archivar-no">Cancelar</button>
        <button type="button" class="btn btn-sm btn-danger" data-mc="archivar-si">Archivar</button></div></div>` : ''}
    ${ui.opciones === c.k ? editorOpciones(c) : ''}`;
  return `<li class="mc-item${c.visible ? '' : ' mc-oculta'}" data-clave="${esc(c.k)}">
      <div class="mc-fila">
        <input type="text" class="mc-input mc-nombre" id="mc-n-${esc(c.k)}" maxlength="60" value="${esc(c.lab)}"
          placeholder="${esc(c.sistema ? c.original : 'Nombre')}" data-mc-nombre aria-label="${esc('Nombre de la columna ' + c.lab)}">
        <button type="button" class="btn btn-sm btn-ghost mc-ic" data-mc="subir" ${i === 0 ? 'disabled' : ''}
          title="Subir" aria-label="${esc('Subir ' + c.lab)}">↑</button>
        <button type="button" class="btn btn-sm btn-ghost mc-ic" data-mc="bajar" ${i === total - 1 ? 'disabled' : ''}
          title="Bajar" aria-label="${esc('Bajar ' + c.lab)}">↓</button>
        <label class="mc-switch" title="${c.fija ? esc(c.original + ' siempre se muestra') : c.visible ? 'Ocultar' : 'Mostrar'}">
          <input type="checkbox" data-mc-visible${c.visible ? ' checked' : ''}${c.fija ? ' disabled' : ''}
            aria-label="${esc('Mostrar ' + c.lab)}"><span></span></label>
      </div>${extra}</li>`;
}

function cuerpoHtml({ todas, archivadas }, ui, { nota, permiteNuevas }) {
  const arch = archivadas.map(c => `
    <li class="mc-fila" data-clave="${esc(c.k)}"><span class="mc-arch-nombre">${esc(c.lab)}</span>
      <span class="mc-tipo">${esc(TIPO_COLUMNA_LABEL[c.tipo] || c.tipo)}</span>
      <button type="button" class="btn btn-sm" data-mc="recuperar">Recuperar</button></li>`).join('');
  const n = ui.nueva;
  return `
    <p class="mc-nota">${esc(nota)} En las del sistema, dejar el nombre vacío vuelve al original.</p>
    <div class="form-error mc-error" role="alert">${esc(ui.error)}</div>
    <ul class="mc-lista">${todas.map((c, i) => itemHtml(c, i, todas.length, ui)).join('')}</ul>
    ${archivadas.length ? `<details class="mc-archivadas"${ui.archivadas ? ' open' : ''}>
      <summary>Archivadas (${archivadas.length})</summary><ul>${arch}</ul></details>` : ''}
    ${permiteNuevas ? `<div class="mc-nueva">
      ${n ? `<div class="form-row"><label for="mc-nv-nombre">Nombre</label>
          <input type="text" id="mc-nv-nombre" maxlength="60" value="${esc(n.nombre)}" data-mc-nueva="nombre"></div>
        <div class="form-row"><label for="mc-nv-tipo">Tipo</label>
          <select id="mc-nv-tipo" data-mc-nueva="tipo">${opcionesTipo(n.tipo)}</select></div>
        ${n.tipo === 'opcion' ? `<div class="form-row"><label for="mc-nv-ops">Opciones (una por línea)</label>
          <textarea id="mc-nv-ops" rows="4" data-mc-nueva="opciones">${esc(n.opciones)}</textarea></div>` : ''}
        <div class="mc-acciones"><button type="button" class="btn" data-mc="nueva-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" data-mc="crear">Crear columna</button></div>`
      : '<button type="button" class="btn" data-mc="nueva">+ Agregar columna</button>'}
    </div>` : ''}`;
}

/* Repinta sin perder lo que se está escribiendo ni el foco. */
function repintarConservandoFoco(raiz, pintar) {
  const act = document.activeElement;
  const editable = act && act.id && raiz.contains(act) && /^(INPUT|TEXTAREA)$/.test(act.tagName) && act.type !== 'checkbox';
  const estado = editable ? { id: act.id, valor: act.value } : null;
  pintar();
  const nuevo = estado && document.getElementById(estado.id);
  if (!nuevo) return;
  if (nuevo.value !== estado.valor) nuevo.value = estado.valor;
  nuevo.focus();
}

/* clienteId null en las vistas globales. estado() -> { todas, archivadas } vigente;
   recargar() vuelve a pedir la configuración y repinta la pantalla de atrás. */
export function abrirPanelColumnas({ clienteId = null, vista, titulo = 'Columnas', nota, estado, recargar, permiteNuevas = false }) {
  const ui = { opciones: null, archivadas: false, nueva: null, archivar: null, error: '' };
  const overlay = document.createElement('div');
  overlay.className = 'mc-overlay';
  overlay.innerHTML = `<aside class="mc-panel" role="dialog" aria-modal="true" aria-label="${esc(titulo)}">
      <div class="mc-head"><h2>${esc(titulo)}</h2>
        <button type="button" class="modal-close" data-mc="cerrar" aria-label="Cerrar">✕</button></div>
      <div class="mc-body"></div></aside>`;
  const body = overlay.querySelector('.mc-body');
  const col = k => estado().todas.find(c => c.k === k);
  const claveDe = nodo => { const li = nodo.closest('[data-clave]'); return li ? li.dataset.clave : ''; };
  /* Lo que se manda como etiqueta: en las del sistema, null = nombre por defecto. */
  const etiquetaDe = c => (c.sistema && c.lab === c.original ? null : c.lab);

  function pintar() {
    if (!overlay.isConnected) return;
    const y = body.scrollTop;
    repintarConservandoFoco(body, () => { body.innerHTML = cuerpoHtml(estado(), ui, { nota, permiteNuevas }); });
    body.scrollTop = y;
  }
  const avisar = msg => { ui.error = msg; pintar(); };

  let cola = Promise.resolve();
  function operar(fn, ok) {
    cola = cola.then(async () => {
      overlay.classList.add('mc-ocupado');
      ui.error = '';
      try {
        await fn();
        if (ok) toast(ok);
      } catch (e) {
        ui.error = errorColumnas(e);
      }
      try { await recargar(); } catch (e) { if (!ui.error) ui.error = errorColumnas(e); }
      overlay.classList.remove('mc-ocupado');
      pintar();
    });
    return cola;
  }

  const guardarCol = (c, cambios, ok) => operar(() => columnaGuardar(clienteId, vista, c.k,
    { etiqueta: etiquetaDe(c), visible: c.visible, ...cambios }), ok);

  function cerrar() {
    if (!overlay.isConnected) return;
    overlay.remove();
    document.removeEventListener('keydown', onKey);
    window.removeEventListener('hashchange', cerrar);
  }
  const onKey = e => { if (e.key === 'Escape') cerrar(); };
  /* El panel cuelga de body: si se cambia de pantalla, se va con ella. */
  window.addEventListener('hashchange', cerrar);
  overlay.addEventListener('mousedown', e => { if (e.target === overlay) cerrar(); });

  overlay.addEventListener('click', ev => {
    const b = ev.target.closest('[data-mc]');
    if (!b) return;
    const accion = b.dataset.mc, k = claveDe(b), c = col(k);
    if (accion === 'cerrar') return cerrar();
    if (accion === 'nueva') { ui.nueva = { nombre: '', tipo: 'texto', opciones: '' }; pintar(); body.querySelector('#mc-nv-nombre').focus(); return; }
    if (accion === 'nueva-cancelar') { ui.nueva = null; pintar(); return; }
    if (accion === 'crear') {
      const nombre = ui.nueva.nombre.trim(), ops = lineas(ui.nueva.opciones);
      if (!nombre) { avisar('La columna necesita nombre.'); body.querySelector('#mc-nv-nombre').focus(); return; }
      if (ui.nueva.tipo === 'opcion' && !ops.length) { avisar('Cargá al menos una opción.'); return; }
      /* El formulario se cierra recién si la base la creó: un error no pierde lo escrito. */
      operar(async () => { await columnaCrear(clienteId, nombre, ui.nueva.tipo, ops); ui.nueva = null; }, `Columna "${nombre}" creada.`);
      return;
    }
    if (accion === 'recuperar') { operar(() => columnaArchivar(clienteId, k, false), 'Columna recuperada.'); return; }
    if (!c) return;
    if (accion === 'subir' || accion === 'bajar') {
      const claves = estado().todas.map(x => x.k), i = claves.indexOf(k), j = i + (accion === 'subir' ? -1 : 1);
      if (j < 0 || j >= claves.length) return;
      [claves[i], claves[j]] = [claves[j], claves[i]];
      operar(() => columnasOrdenar(clienteId, vista, claves));
    } else if (accion === 'opciones') {
      ui.opciones = ui.opciones === k ? null : k;
      pintar();
    } else if (accion === 'archivar') {
      ui.archivar = k;
      pintar();
    } else if (accion === 'archivar-no') {
      ui.archivar = null;
      pintar();
    } else if (accion === 'archivar-si') {
      ui.archivar = null;
      ui.archivadas = true;
      operar(() => columnaArchivar(clienteId, k, true), 'Columna archivada.');
    } else if (accion === 'op-quitar') {
      guardarCol(c, { opciones: c.opciones.filter(o => o !== b.dataset.opcion) }, 'Opción quitada.');
    } else if (accion === 'op-agregar') {
      const inp = b.parentElement.querySelector('[data-mc-agregar]'), v = inp.value.trim();
      if (!v) { inp.focus(); return; }
      if (c.opciones.includes(v)) { avisar('Esa opción ya está.'); return; }
      inp.value = '';
      guardarCol(c, { opciones: c.opciones.concat(v) }, 'Opción agregada.');
    }
  });

  overlay.addEventListener('change', ev => {
    const t = ev.target, c = col(claveDe(t));
    if (!c) return;
    if (t.matches('[data-mc-visible]')) { guardarCol(c, { visible: t.checked }); return; }
    const v = t.value.trim();
    if (t.matches('[data-mc-nombre]')) {
      if (!v && !c.sistema) { t.value = c.lab; return; }
      const etiqueta = c.sistema && (!v || v === c.original) ? null : v;
      if ((etiqueta || c.original) === c.lab) { t.value = c.lab; return; }
      operar(() => columnaGuardar(clienteId, vista, c.k, { etiqueta, visible: c.visible }), 'Columna renombrada.');
    } else if (t.matches('[data-mc-opcion]')) {
      const viejo = t.dataset.mcOpcion;
      if (!v || v === viejo) { t.value = viejo; return; }
      if (c.opciones.includes(v)) { t.value = viejo; avisar('Esa opción ya está.'); return; }
      operar(() => opcionRenombrar(clienteId, c.k, viejo, v), 'Opción renombrada.');
    }
  });

  overlay.addEventListener('input', ev => {
    const campo = ev.target.dataset.mcNueva;
    if (!campo || !ui.nueva) return;
    ui.nueva[campo] = ev.target.value;
    if (campo === 'tipo') pintar();
  });

  overlay.addEventListener('toggle', ev => {
    if (ev.target.matches('.mc-archivadas')) ui.archivadas = ev.target.open;
  }, true);

  overlay.addEventListener('keydown', ev => {
    if (ev.key !== 'Enter' || ev.target.tagName !== 'INPUT' || ev.target.type === 'checkbox') return;
    ev.preventDefault();
    if (ev.target.matches('[data-mc-agregar]')) ev.target.parentElement.querySelector('[data-mc="op-agregar"]').click();
    else if (ev.target.id === 'mc-nv-nombre') body.querySelector('[data-mc="crear"]').click();
    else ev.target.blur();
  });

  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  pintar();
  overlay.querySelector('[data-mc="cerrar"]').focus();
  return { cerrar, pintar };
}

/* Botón "Columnas" de las pantallas (solo fundador). */
export const botonColumnas = (id = 'btn-columnas', oculto = false) =>
  `<button type="button" class="btn btn-sm" id="${id}"${oculto ? ' hidden' : ''}>Columnas</button>`;
