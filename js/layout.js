/* Layout (mismo diseño que Producto): sidebar con marca (y nav-areas), perfil,
   navegación y pie (tema + Salir); header con título de la vista y rol. */
import { esc } from './ui.js';
import { yo, esFundador, clienteUnico, veFinanzas, veAnalisis, veCobranzas, veMisNumeros, puedeCargar, vePagos, puedeVincular, soloSubeComprobante, puedeConfirmarComprobante, puedeVerLectura, etiquetaRol } from './sesion.js';
import { botonTemaHtml, activarBotonTema } from './tema.js';
import { veDystopia, veGastos, veIaUso } from './gastos.js';

/* Íconos lineales (24x24, trazo fino) de cada pantalla. */
const ico = d => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const ICONOS = {
  resumen: ico('<rect x="3" y="3" width="7" height="9" rx="1.5"/><rect x="14" y="3" width="7" height="5" rx="1.5"/><rect x="14" y="12" width="7" height="9" rx="1.5"/><rect x="3" y="16" width="7" height="5" rx="1.5"/>'),
  conciliacion: ico('<path d="M7 4 3 8l4 4M3 8h14M17 20l4-4-4-4M21 16H7"/>'),
  conceptos: ico('<path d="M21 12a9 9 0 1 1-9-9v9z"/><path d="M15 3.5A9 9 0 0 1 20.5 9H15z"/>'),
  cobranzas: ico('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18M7 15h4"/>'),
  'mis-numeros': ico('<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>'),
  cargar: ico('<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>'),
  comprobante: ico('<path d="M12 16V4M7 9l5-5 5 5M4 20h16"/>'),
  comprobantes: ico('<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 13h7M9 17h5"/>'),
  lectura: ico('<path d="M4 5h16v11H9l-5 4z"/>'),
  pagos: ico('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>'),
  vincular: ico('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
  dystopia: ico('<path d="M3 20h18M5 20V9l7-5 7 5v11M9 20v-6h6v6"/>'),
  gastos: ico('<path d="M4 7h16v12H4zM4 7l2-3h12l2 3M9 13h6"/>'),
  'ia-uso': ico('<path d="M12 3v3M12 18v3M3 12h3M18 12h3M6 6l2 2M16 16l2 2M18 6l-2 2M8 16l-2 2"/><circle cx="12" cy="12" r="3"/>'),
  alertas: ico('<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4zM10 21h4"/>'),
  salud: ico('<path d="M20 11a8 8 0 0 0-14-4.5L4 9M4 4v5h5M4 13a8 8 0 0 0 14 4.5L20 15M20 20v-5h-5"/>')
};

/* [ruta, etiqueta, subtítulo, visible()] */
const VISTAS = [
  ['resumen', 'Resumen agencia', 'Todos los clientes', veFinanzas],
  ['conciliacion', 'Conciliación', 'Opps contra Pagos', veAnalisis],
  ['conceptos', 'Cash por concepto', 'Torta por categoría', veAnalisis],
  ['cobranzas', 'Cobranzas', 'Cuotas pendientes', veCobranzas],
  ['mis-numeros', 'Mis números', 'Closers y setters', veMisNumeros],
  ['cargar', 'Cargar pago', 'Alta de un pago', puedeCargar],
  ['comprobante', 'Subir comprobante', 'Foto o PDF de la transferencia', soloSubeComprobante],
  ['comprobantes', 'Comprobantes', 'Pendientes de confirmar', puedeConfirmarComprobante],
  ['lectura', 'Lectura del mes', 'Resumen con IA', puedeVerLectura],
  ['pagos', 'Pagos', 'Grilla y catálogos', vePagos],
  ['dystopia', 'Dystopia', 'Ingreso y ganancia de la agencia', veDystopia],
  ['gastos', 'Gastos', 'Por entidad y categoría', veGastos],
  ['ia-uso', 'Gasto de IA', 'Por cliente y proveedor', veIaUso],
  ['vincular', 'Vincular alumnos', 'Finanzas con Producto', puedeVincular],
  ['alertas', 'Alertas de cobros', 'Aviso diario a Discord', esFundador],
  ['salud', 'Salud de sincronización', 'Planillas y corridas', esFundador]
];

export function renderLayout(app, onSalir) {
  const inicial = esc((yo.nombre || yo.email || '?').trim().charAt(0));
  app.innerHTML = `
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-logo" aria-hidden="true">D</div>
        <div class="brand-txt">
          <div class="brand-mark">DYS<span>TOPIA</span></div>
          <div class="brand-sub">Finanzas</div>
        </div>
      </div>
      <button type="button" class="menu-toggle" id="btn-menu" aria-label="Menú" aria-expanded="false" aria-controls="nav">☰</button>
      <nav id="nav-areas"></nav>
      <div class="perfil" title="${esc(yo.email)}">
        <div class="perfil-avatar" aria-hidden="true">${inicial}</div>
        <div class="perfil-txt">
          <div class="perfil-nombre" id="user-email">${esc(yo.nombre || yo.email)}</div>
          <div class="perfil-dato">${esc(etiquetaRol())}</div>
        </div>
      </div>
      <nav class="nav-list" id="nav" aria-label="Navegación"></nav>
      <div class="sidebar-foot">
        <div class="sidebar-foot-acc">
          ${botonTemaHtml()}
          <button type="button" class="refresh-btn" id="btn-logout">Salir</button>
        </div>
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
  activarBotonTema();
  /* Celular: el menú arranca plegado (☰) y se cierra al elegir una pantalla. */
  const aside = app.querySelector('.sidebar');
  const btnMenu = document.getElementById('btn-menu');
  const fijarMenu = abierto => {
    aside.classList.toggle('menu-abierto', abierto);
    btnMenu.setAttribute('aria-expanded', String(abierto));
  };
  btnMenu.onclick = () => fijarMenu(!aside.classList.contains('menu-abierto'));
  aside.addEventListener('click', e => { if (e.target.closest('a[href]')) fijarMenu(false); });
  window.addEventListener('hashchange', () => fijarMenu(false));
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
  const unico = clienteUnico();
  for (let [ruta, label, sub, visible] of VISTAS) {
    if (!visible()) continue;
    if (ruta === 'resumen' && unico) { label = 'Resumen'; sub = unico.nombre; }
    html += `
      <a class="nav-item${activo.vista === ruta ? ' active' : ''}" href="#/${ruta}">
        <span class="nav-icon">${ICONOS[ruta] || ''}</span>
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
