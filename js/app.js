/* Punto de entrada: gate de sesión, login, rol, layout y router.
   Login y logout replican a Dystopia y Seguimiento: signInWithPassword, mismo
   mensaje de error, logout = signOut + reload. Sin realtime: los datos cambian
   cada 15 min con el cron; cada vista tiene su botón para recargar. */
import { sb } from './supabase.js';
import { esc } from './ui.js';
import { ruta, rutaNoEncontrada, iniciarRouter, reemplazar } from './router.js';
import { yo, cargarSesion, rutaInicio, veFinanzas, veCobranzas, esFundador } from './sesion.js';
import { renderLayout, renderNav, setHeader } from './layout.js';
import { vistaResumen } from './views/resumen.js';
import { vistaCliente } from './views/cliente.js';
import { vistaConciliacion } from './views/conciliacion.js';
import { vistaCobranzas } from './views/cobranzas.js';
import { vistaMisNumeros } from './views/mis-numeros.js';
import { vistaSalud } from './views/salud.js';

const app = document.getElementById('app');
let appIniciada = false;
let rutasRegistradas = false;

async function salir() {
  await sb.auth.signOut();
  location.reload();
}

function renderLogin() {
  app.innerHTML = `
    <div class="login-wrap">
      <form id="login-form" class="card login-card">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="form-row"><label for="login-email">Email</label><input id="login-email" type="email" autocomplete="username" required></div>
        <div class="form-row"><label for="login-password">Contraseña</label><input id="login-password" type="password" autocomplete="current-password" required></div>
        <div id="login-error" class="login-error"></div>
        <button type="submit" class="btn btn-accent">Ingresar</button>
      </form>
    </div>`;
  const form = document.getElementById('login-form');
  form.onsubmit = async ev => {
    ev.preventDefault();
    const errEl = document.getElementById('login-error');
    const btn = form.querySelector('button[type=submit]');
    errEl.textContent = '';
    btn.disabled = true;
    const { error } = await sb.auth.signInWithPassword({
      email: document.getElementById('login-email').value.trim(),
      password: document.getElementById('login-password').value
    });
    if (error) {
      errEl.textContent = error.message === 'Invalid login credentials' ? 'Email o contraseña incorrectos.' : error.message;
      btn.disabled = false;
      return;
    }
    iniciarApp();
  };
  document.getElementById('login-email').focus();
}

function renderAviso(titulo, texto, { reintentar = false } = {}) {
  app.innerHTML = `
    <div class="login-wrap">
      <div class="card login-card aviso-card">
        <div class="brand-mark">DYS<span>TOPIA</span></div>
        <div class="aviso-titulo">${esc(titulo)}</div>
        <p class="aviso-texto">${esc(texto)}</p>
        <div class="aviso-acciones">
          ${reintentar ? '<button type="button" class="btn" id="btn-reintentar">Reintentar</button>' : ''}
          <button type="button" class="btn btn-accent" id="btn-salir">Salir</button>
        </div>
      </div>
    </div>`;
  document.getElementById('btn-salir').onclick = salir;
  const r = document.getElementById('btn-reintentar');
  if (r) r.onclick = () => location.reload();
}

/* Cada montaje invalida al anterior: una respuesta lenta de una vista vieja no pisa la nueva. */
let genVista = 0;
function montar(render) {
  const gen = ++genVista;
  const vigente = () => gen === genVista;
  const el = document.getElementById('view');
  el.innerHTML = '<div class="loading-inline">Cargando…</div>';
  Promise.resolve(render(el, vigente)).catch(e => {
    if (!vigente()) return;
    console.error(e);
    el.innerHTML = `<div class="card empty-state"><div class="big">No se pudo cargar</div><div class="small">${esc(e.message || String(e))}</div></div>`;
  });
}

function registrarRutas() {
  if (rutasRegistradas) return;
  rutasRegistradas = true;
  const guardia = (permitido, fn) => params => (permitido() ? fn(params) : reemplazar(rutaInicio()));

  ruta('', () => reemplazar(rutaInicio()));
  ruta('resumen', guardia(veFinanzas, () => {
    renderNav({ vista: 'resumen' });
    setHeader('Resumen agencia', 'Ingresos, gastos y conciliación por cliente');
    montar(vistaResumen);
  }));
  ruta('cliente/:id', guardia(veFinanzas, ({ id }) => {
    renderNav({ cliente: id });
    montar((el, vigente) => vistaCliente(el, id, vigente));
  }));
  ruta('conciliacion', guardia(veFinanzas, () => {
    renderNav({ vista: 'conciliacion' });
    setHeader('Conciliación', 'Total Revenue de Opps contra la suma de Pagos del mismo mes');
    montar(vistaConciliacion);
  }));
  ruta('cobranzas', guardia(veCobranzas, () => {
    renderNav({ vista: 'cobranzas' });
    setHeader('Cobranzas', 'Cuotas pendientes y vencidas');
    montar(vistaCobranzas);
  }));
  ruta('mis-numeros', () => {
    renderNav({ vista: 'mis-numeros' });
    setHeader('Mis números', esFundador() ? 'Closers y setters' : yo.nombre);
    montar(vistaMisNumeros);
  });
  ruta('salud', guardia(esFundador, () => {
    renderNav({ vista: 'salud' });
    setHeader('Salud de sincronización', 'Última corrida de cada planilla');
    montar(vistaSalud);
  }));

  rutaNoEncontrada(path => {
    renderNav({});
    setHeader('No existe esta sección');
    montar(el => {
      el.innerHTML = `
        <div class="card empty-state">
          <div class="big">No existe esta sección</div>
          <div class="small">${esc(path)} · <a href="#/">Volver al inicio</a></div>
        </div>`;
    });
  });
}

async function iniciarApp() {
  if (appIniciada) return;
  appIniciada = true;
  app.innerHTML = '<div class="loading">Cargando…</div>';
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { appIniciada = false; renderLogin(); return; }

  let puede;
  try {
    puede = await cargarSesion(session.user);
  } catch (e) {
    console.error('sesion', e);
    renderAviso('No se pudo cargar tu sesión', e.message || String(e), { reintentar: true });
    return;
  }
  if (!puede) {
    renderAviso('Sin acceso a esta app',
      `${yo.email} no tiene acceso a Finanzas. Si creés que es un error, pedíselo al fundador.`);
    return;
  }
  renderLayout(app, salir);
  registrarRutas();
  iniciarRouter();
}

sb.auth.onAuthStateChange(evento => {
  if (evento === 'SIGNED_OUT' && appIniciada) {
    appIniciada = false;
    renderLogin();
  }
});

(async function init() {
  const { data: { session } } = await sb.auth.getSession();
  if (session) iniciarApp(); else renderLogin();
})();
