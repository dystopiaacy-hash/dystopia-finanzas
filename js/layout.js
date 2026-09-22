/* Layout (replica Seguimiento): sidebar con marca (y nav-areas),
   navegación y pie (email + Salir); header con título de la vista y rol. */
import { esc } from './ui.js';
import { yo, esFundador, veFinanzas, veCobranzas, etiquetaRol } from './sesion.js';

/* [ruta, etiqueta, subtítulo, visible()] */
const VISTAS = [
  ['resumen', 'Resumen agencia', 'Todos los clientes', veFinanzas],
  ['conciliacion', 'Conciliación', 'Opps contra Pagos', veFinanzas],
  ['cobranzas', 'Cobranzas', 'Cuotas pendientes', veCobranzas],
  ['mis-numeros', 'Mis números', 'Closers y setters', () => true],
  ['salud', 'Salud de sincronización', 'Planillas y corridas', esFundador]
];

export function renderLayout(app, onSalir) {
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="brand-sub">Finanzas</div>
      </div>
      <nav id="nav-areas"></nav>
      <nav class="nav-list" id="nav" aria-label="Navegación"></nav>
      <div class="sidebar-foot">
        <span id="user-email" title="${esc(yo.email)}">${esc(yo.email)}</span>
        <button type="button" class="refresh-btn" id="btn-logout">Salir</button>
      </div>
    </aside>
    <main class="main">
      <div class="main-inner">
        <header class="topbar view-head">
          <div class="client-head">
            <h1 id="view-title"></h1>
            <div class="consultora" id="view-sub"></div>
          </div>
          <div class="view-head-meta">
            <span class="badge">${esc(etiquetaRol())}</span>
          </div>
        </header>
        <div id="view"></div>
      </div>
    </main>`;
  document.getElementById('btn-logout').onclick = onSalir;
}

export function setHeader(titulo, sub = '') {
  document.getElementById('view-title').textContent = titulo || '';
  document.getElementById('view-sub').textContent = sub || '';
  document.title = titulo ? `${titulo} — Finanzas` : 'Dystopia — Finanzas';
}

/* activo = { vista } | { cliente } */
export function renderNav(activo = {}) {
  const nav = document.getElementById('nav');
  if (!nav) return;
  let html = '';
  for (const [ruta, label, sub, visible] of VISTAS) {
    if (!visible()) continue;
    html += `
      <a class="nav-item${activo.vista === ruta ? ' active' : ''}" href="#/${ruta}">
        <span class="nav-icon">◆</span>
        <span class="nav-text"><div class="nav-name">${esc(label)}</div><div class="nav-niche">${esc(sub)}</div></span>
      </a>`;
  }
  if (veFinanzas() && yo.clientes.length) {
    html += `<div class="nav-eyebrow">${yo.clientes.length === 1 ? 'Cliente' : 'Clientes'}</div>`;
    for (const c of yo.clientes) {
      const color = c.color || `var(--c-${c.id}, var(--text-faint))`;
      html += `
        <a class="nav-item${activo.cliente === c.id ? ' active' : ''}" href="#/cliente/${encodeURIComponent(c.id)}">
          <span class="nav-dot" style="--badge-color:${esc(color)}"></span>
          <span class="nav-text"><div class="nav-name">${esc(c.nombre)}</div><div class="nav-niche">P&amp;L mensual y detalle</div></span>
        </a>`;
    }
  }
  nav.innerHTML = html;
}
