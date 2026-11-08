/* Mapa (solo fundador): canvas navegable de sistemas a pantalla completa. Cada área es un marco con su "pantalla" y
   datos reales; filtros globales de cliente y mes. Solo lectura: nada se edita desde acá.
   El overlay se agrega al <body> (tapa el menú de la app) y se retira al salir de #/mapa. */
import { esc, hoyAR } from '../ui.js';
import { mesesDe, etiquetaMes } from '../gastos.js';
import { aplicarTema, temaActual } from '../tema.js';
import { CLIENTES, cargarBaseMapa, cargarMapa, limpiarCache } from '../mapa.js';
import { AREAS, INTRO, BOUNDS, posicion, enlaces, htmlMarco, htmlIntro, poolDe } from '../mapa-marcos2.js';
import { crearMotor, rellenar } from '../mapa-motor.js';

const I = (d, w = 17) => `<svg viewBox="0 0 24 24" width="${w}" height="${w}" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const IC = {
  marcos: I('<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>'),
  luna: I('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>'),
  play: I('<path d="M7 4.5v15l12-7.5z"/>'), todo: I('<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>'),
  izq: I('<path d="m15 5-7 7 7 7"/>'), der: I('<path d="m9 5 7 7-7 7"/>'), rec: I('<path d="M20 11a8 8 0 0 0-14-4.5L4 9M4 4v5h5M4 13a8 8 0 0 0 14 4.5L20 15M20 20v-5h-5"/>')
};

let actual = null;   // el overlay montado (uno solo)

function esqueleto() {
  const r = document.createElement('div');
  r.id = 'mapa-root';
  r.innerHTML = `
    <div id="board"><div id="world">
      <div class="glow" style="left:-1800px;top:-1600px"></div><div class="glow" style="left:2600px;top:600px"></div>
      <div class="band" style="left:-90px;top:-300px;width:6040px;height:2580px"><span>Recorrido del cliente</span></div>
      <svg id="links" aria-hidden="true"></svg><div id="frames"></div>
    </div></div>
    <header id="topbar" class="chrome">
      <a class="ib" id="b-volver" href="#/resumen" title="Volver a la app">${IC.izq}<span class="tx">Volver</span></a>
      <span class="vsep"></span><span class="logo big">D</span>
      <div class="tt"><b>Mapa de sistemas</b><span id="tsub">Cargando…</span></div>
      <span class="vsep"></span>
      <select id="mapa-cli" aria-label="Cliente"><option value="">Todos</option>${CLIENTES.map(([id, n]) => `<option value="${id}">${esc(n)}</option>`).join('')}</select>
      <select id="mapa-mes" aria-label="Mes"></select>
      <button type="button" class="ib" id="b-rec" title="Recargar los datos">${IC.rec}<span class="tx">Recargar</span></button>
      <button type="button" class="ib" id="b-marcos" title="Marcos (F)">${IC.marcos}<span class="tx">Marcos</span></button>
      <button type="button" class="ib" id="b-tema" title="Tema claro / oscuro">${IC.luna}</button>
      <button type="button" class="ib p" id="b-pres" title="Presentar (P)">${IC.play}<span class="tx">Presentar</span></button>
    </header>
    <div id="hint" class="chrome"><span><kbd>Arrastrá</kbd> para moverte</span><span><kbd>Ctrl</kbd> + rueda o pellizco = zoom</span><span><kbd>1</kbd>–<kbd>8</kbd> salta a un marco</span></div>
    <div id="tools" class="chrome">
      <button type="button" class="ib sq" id="t-todo" data-tip="Ver todo (0)" aria-label="Ver todo">${IC.todo}</button>
      <button type="button" class="ib sq" id="t-ant" data-tip="Marco anterior (←)" aria-label="Marco anterior">${IC.izq}</button>
      <button type="button" class="ib sq" id="t-sig" data-tip="Marco siguiente (→)" aria-label="Marco siguiente">${IC.der}</button>
    </div>
    <aside id="panel" class="chrome" hidden>
      <header><b>Marcos del tablero</b><button type="button" class="ib sq" id="panel-x" aria-label="Cerrar">×</button></header>
      <input id="pbuscar" type="search" placeholder="Buscar un área…" aria-label="Buscar un área" autocomplete="off">
      <div id="plist"><button type="button" class="pitem" data-go="0"><span class="pnum">00</span><span class="pn">Empieza aquí</span><kbd>←</kbd></button>
        ${AREAS.map((a, i) => `<button type="button" class="pitem" data-go="${i + 1}"><span class="pnum">${String(i + 1).padStart(2, '0')}</span><span class="pn">${esc(a.nombre)}</span><kbd>${i + 1}</kbd></button>`).join('')}</div>
    </aside>
    <div id="mini" class="chrome"><canvas id="minic" width="420" height="256" style="width:210px;height:128px"></canvas></div>
    <div id="zoom" class="chrome"><button type="button" class="ib sq" id="z-menos" aria-label="Alejar">−</button><button type="button" id="zpct" class="zp" title="Ver todo">100%</button><button type="button" class="ib sq" id="z-mas" aria-label="Acercar">+</button></div>
    <div id="pres" class="chrome"><button type="button" class="ib sq" id="p-ant" aria-label="Anterior">${IC.izq}</button><span id="pcont">1 / 9</span><button type="button" class="ib sq" id="p-sig" aria-label="Siguiente">${IC.der}</button><span class="vsep"></span><button type="button" class="ib" id="p-salir">Salir</button></div>`;
  return r;
}

function desmontar() {
  if (!actual) return;
  const a = actual; actual = null;
  a.motor.destroy();
  window.removeEventListener('hashchange', a.onHash);
  a.root.remove();
  document.body.classList.remove('mapa-abierto');
}

export async function vistaMapa(el, vigente) {
  desmontar();
  el.innerHTML = '<div class="loading-inline">Abriendo el mapa…</div>';
  const root = esqueleto();
  document.body.appendChild(root);
  document.body.classList.add('mapa-abierto');

  const rects = [{ ...INTRO }, ...AREAS.map((_, i) => posicion(i))];
  const motor = crearMotor(root, { rects, bounds: BOUNDS });
  const onHash = () => { if (!/^#\/mapa/.test(location.hash)) desmontar(); };
  window.addEventListener('hashchange', onHash);
  actual = { root, motor, onHash };

  const q = s => root.querySelector(s);
  const sel = { cli: '', ym: hoyAR().slice(0, 7) };
  const tabs = {};          // área -> pestaña elegida (se conserva al recargar)
  let base = null, pools = {}, primera = true, gen = 0;

  const aTema = () => aplicarTema(temaActual() === 'dark' ? 'light' : 'dark');
  q('#b-tema').onclick = aTema;

  function mostrarTab(marco, id) {
    const area = AREAS.find(a => `f-${a.id}` === marco.id);
    if (!area) return;
    tabs[area.id] = id;
    marco.querySelectorAll('.tab').forEach(t => t.classList.toggle('on', t.dataset.tab === id));
    marco.querySelectorAll('.view').forEach(v => { v.hidden = v.dataset.view !== id; });
    const v = marco.querySelector(`.view[data-view="${id}"]`);
    if (v) rellenar(v, (pools[area.id] || {})[id]);
  }
  root.addEventListener('click', e => {
    const t = e.target.closest('.tab');
    if (t) mostrarTab(t.closest('.frame'), t.dataset.tab);
  });
  const rellenarTodo = () => root.querySelectorAll('.frame').forEach(f => {
    const area = AREAS.find(a => `f-${a.id}` === f.id);
    const v = f.querySelector('.view:not([hidden])');
    if (area && v) rellenar(v, (pools[area.id] || {})[v.dataset.view]);
  });

  function pintar(datos) {
    const D = { d: datos, mesTxt: etiquetaMes(sel.ym), cliTxt: sel.cli ? (CLIENTES.find(c => c[0] === sel.cli) || [0, sel.cli])[1] : 'Todos los clientes' };
    D.diasMes = new Date(+sel.ym.slice(0, 4), +sel.ym.slice(5, 7), 0).getDate();
    pools = Object.fromEntries(AREAS.map(a => [a.id, poolDe(a, D)]));
    q('#frames').innerHTML = htmlIntro(D) + AREAS.map((a, i) => htmlMarco(a, i, D)).join('');
    for (const a of AREAS) {
      const m = q(`#f-${a.id}`), t = tabs[a.id];
      if (t && m.querySelector(`.tab[data-tab="${t}"]`)) {
        m.querySelectorAll('.tab').forEach(x => x.classList.toggle('on', x.dataset.tab === t));
        m.querySelectorAll('.view').forEach(v => { v.hidden = v.dataset.view !== t; });
      }
    }
    motor.flechas(enlaces(D));
    rellenarTodo();
    q('#tsub').textContent = `Datos reales · ${D.mesTxt} · ${D.cliTxt}`;
    if (primera) { primera = false; motor.inicial(); setTimeout(() => q('#hint') && q('#hint').classList.add('off'), 9000); }
    else motor.apply();
  }

  async function cargar() {
    const mi = ++gen;
    root.classList.add('cargando');
    q('#tsub').textContent = 'Cargando datos…';
    try {
      const datos = await cargarMapa(sel.ym, sel.cli, base);
      if (mi !== gen || !actual || actual.root !== root) return;
      pintar(datos);
    } catch (e) {
      console.error(e);
      if (mi === gen) q('#tsub').textContent = `No se pudo cargar: ${e.message || e}`;
    }
    if (mi === gen) root.classList.remove('cargando');
  }

  try { base = await cargarBaseMapa(); } catch (e) {
    q('#tsub').textContent = `No se pudo cargar: ${e.message || e}`;
    return;
  }
  if (!vigente() || !actual || actual.root !== root) return;
  const meses = mesesDe(base.ganancia), hoy = hoyAR().slice(0, 7);
  if (!meses.includes(hoy)) meses.push(hoy);
  meses.sort().reverse();
  q('#mapa-mes').innerHTML = meses.map(m => `<option value="${m}"${m === sel.ym ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('');
  q('#mapa-cli').onchange = e => { sel.cli = e.target.value; cargar(); };
  q('#mapa-mes').onchange = e => { sel.ym = e.target.value; cargar(); };
  q('#b-rec').onclick = async () => {
    limpiarCache();
    try { base = await cargarBaseMapa(); } catch (e) { /* se queda con lo anterior */ }
    cargar();
  };
  document.fonts && document.fonts.ready.then(() => { if (actual && actual.root === root) rellenarTodo(); });
  cargar();
}
