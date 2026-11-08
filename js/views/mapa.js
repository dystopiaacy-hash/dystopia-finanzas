/* Mapa (solo fundador): tarjetas por área en el orden del recorrido del cliente, unidas con flechas.
   Cada tarjeta: número grande, 1 o 2 secundarios, regla del área y botón «Abrir». Solo lectura. */
import { esc, hoyAR, fmtPct } from '../ui.js';
import { usd } from '../datos.js';
import { mesesDe, etiquetaMes } from '../gastos.js';
import { botonRecargar } from './comunes.js';
import { CLIENTES, AREAS, PROXIMAMENTE, cargarBaseMapa, cargarMapa } from '../mapa.js';

const u = v => usd(v, { centavos: false });
const ent = v => String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
const SIN = 'sin dato';
const val = (v, fmt) => (v == null ? SIN : fmt(v));

const FLECHA = '<svg viewBox="0 0 48 16" aria-hidden="true"><path d="M2 8h38M32 2l8 6-8 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

/* dir: 'der' | 'abajo' | 'izq' (en celular todas apuntan hacia abajo). */
function flecha(clase, dir, rotulo) {
  return `<div class="mapa-flecha ${clase} mapa-${dir}" role="presentation">
    <span class="mapa-flecha-svg">${FLECHA}</span>${rotulo ? `<span class="mapa-flecha-txt">${esc(rotulo)}</span>` : ''}</div>`;
}

function boton(a) {
  if (a.url) return `<a class="btn btn-sm mapa-abrir" href="${esc(a.url)}" target="_blank" rel="noopener noreferrer">${esc(a.abrir)} ↗</a>`;
  return `<a class="btn btn-sm mapa-abrir" href="${esc(a.ruta)}">${esc(a.abrir)}</a>`;
}

/* sec: lista de [etiqueta, valorTexto]. */
function tarjeta(clase, area, { numero, etiqueta, sec = [], nota = '' }) {
  const a = AREAS[area];
  const nd = numero === SIN;
  return `<article class="card mapa-card ${clase}">
    <div class="mapa-card-t">${esc(a.titulo)}</div>
    <div class="mapa-num${nd ? ' mapa-sd' : ''}">${esc(numero)}</div>
    <div class="mapa-etq">${esc(etiqueta)}</div>
    <ul class="mapa-sec">${sec.map(([k, v]) => `<li><span>${esc(k)}</span><b class="${v === SIN ? 'mapa-sd' : ''}">${esc(v)}</b></li>`).join('')}</ul>
    ${nota ? `<div class="mapa-nota">${esc(nota)}</div>` : ''}
    <p class="mapa-regla">${esc(a.regla)}</p>
    ${a.responsable ? `<div class="mapa-resp">Responsable: ${esc(a.responsable)}</div>` : ''}
    ${boton(a)}
  </article>`;
}

function gris(titulo, clase) {
  return `<article class="card mapa-card mapa-gris ${clase}">
    <div class="mapa-card-t">${esc(titulo)}</div>
    <div class="mapa-prox">Próximamente</div>
    <p class="mapa-regla">Todavía no existe esta área.</p></article>`;
}

function cuerpo(d, rotuloMes) {
  const m = d.marketing, v = d.ventas, f = d.finanzas, s = d.seguimiento;
  const plat = m ? Object.entries(m.porPlataforma).sort((a, b) => b[1] - a[1]).map(([k, c]) => `${k} ${c}`).join(' · ') : '';
  const marketing = tarjeta('mapa-c-mkt', 'marketing', {
    numero: val(m && m.piezas, ent), etiqueta: `piezas publicadas en ${rotuloMes}`,
    sec: [['Por plataforma', m ? (plat || '0') : SIN]]
  });
  const ventas = tarjeta('mapa-c-vta', 'ventas', {
    numero: val(v && v.agendadas, ent), etiqueta: `llamadas agendadas en ${rotuloMes}`,
    sec: [['Hechas (presentadas)', val(v && v.presentadas, ent)], ['Cierres', val(v && v.cerradas, ent)]]
  });
  const finanzas = tarjeta('mapa-c-fin', 'finanzas', {
    numero: val(f && f.cash, u), etiqueta: `cash cobrado en ${rotuloMes}`,
    sec: [['Gastos', val(f && f.gastos, u)], ['Ganancia del cliente', val(f && f.ganancia, u)]]
  });
  const seguimiento = tarjeta('mapa-c-seg', 'seguimiento', {
    numero: val(s && s.activos, ent), etiqueta: 'alumnos en seguimiento hoy',
    sec: [['En onboarding', val(s && s.onboarding, ent)], ['En renovación', val(s && s.renovacion, ent)]],
    nota: 'No cambia con el mes: es la foto de hoy.'
  });
  const dystopia = tarjeta('mapa-c-dys', 'dystopia', {
    numero: val(f && f.gananciaDys, u), etiqueta: `ganancia de Dystopia en ${rotuloMes}`,
    sec: [['% sobre la ganancia', f && f.pct != null ? fmtPct(f.pct, 0) : SIN]]
  });

  /* Rótulos que encadenan el recorrido (solo los números que existen). */
  const hechas = v && v.presentadas != null ? `${ent(v.presentadas)} llamadas` : null;
  const rVentas = [hechas, v && v.cerradas != null ? `${ent(v.cerradas)} cierres` : null, f ? `${u(f.cash)} cobrado` : null].filter(Boolean).join(' → ');
  const r1 = m && v && v.agendadas != null ? `${ent(m.piezas)} piezas → ${ent(v.agendadas)} agendas` : '';
  const r3 = s ? `${ent(s.activos)} alumnos activos` : '';
  const r4 = f ? `${u(f.gananciaDys)} para Dystopia` : '';

  return `<div class="mapa-grid">
      ${marketing}
      ${flecha('mapa-f1', 'der', r1)}
      ${ventas}
      ${flecha('mapa-f2', 'der', rVentas)}
      ${finanzas}
      ${flecha('mapa-f3', 'abajo', 'Del cobro al acompañamiento')}
      ${seguimiento}
      ${flecha('mapa-f4', 'izq', r3 || r4 ? [r3, r4].filter(Boolean).join(' · ') : '')}
      ${dystopia}
    </div>
    <div class="card-titulo">Próximamente</div>
    <div class="mapa-prox-fila">${PROXIMAMENTE.map(t => gris(t, '')).join('')}</div>`;
}

function mesesDisponibles(base) {
  const meses = mesesDe(base.ganancia);
  const hoy = hoyAR().slice(0, 7);
  if (!meses.includes(hoy)) meses.push(hoy);
  return meses.sort().reverse();
}

export async function vistaMapa(el, vigente) {
  el.innerHTML = '<div class="card empty-state"><div class="small">Cargando el mapa…</div></div>';
  let base;
  try { base = await cargarBaseMapa(); } catch (e) {
    el.innerHTML = `<div class="card nota aviso-ambar">No se pudo cargar: ${esc(e.message)}</div>`;
    return;
  }
  if (!vigente()) return;
  const meses = mesesDisponibles(base);
  const sel = { cli: '', ym: hoyAR().slice(0, 7) };

  const mostrar = async () => {
    el.classList.add('mapa-cargando');
    let datos;
    try { datos = await cargarMapa(sel.ym, sel.cli, base); } catch (e) {
      el.classList.remove('mapa-cargando');
      el.innerHTML = `<div class="card nota aviso-ambar">No se pudo cargar el mapa: ${esc(e.message)}</div>`;
      return;
    }
    if (!vigente()) return;
    el.classList.remove('mapa-cargando');
    const opcion = m => `<option value="${m}"${m === sel.ym ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`;
    const abierto = sel.ym >= hoyAR().slice(0, 7);
    el.innerHTML = `
      <div class="filter-row cmp-filtros">
        <span class="flabel">Cliente</span>
        <select id="mapa-cli" aria-label="Cliente"><option value="">Todos</option>${CLIENTES.map(([id, nm]) => `<option value="${id}"${id === sel.cli ? ' selected' : ''}>${esc(nm)}</option>`).join('')}</select>
        <span class="flabel">Mes</span>
        <select id="mapa-mes" aria-label="Mes">${meses.map(opcion).join('')}</select>
        <span class="grow"></span>
        ${botonRecargar()}
      </div>
      ${abierto ? '<div class="card nota aviso-ambar">Mes en curso: los números cambian hasta el cierre.</div>' : ''}
      ${cuerpo(datos, etiquetaMes(sel.ym))}
      <div class="table-foot">Solo lectura. Finanzas y Dystopia usan las mismas cuentas que Comparar y Cierre (mes cerrado = foto del cierre). Ventas sale de las métricas de Ventas; Marketing cuenta piezas con estado PUBLICADO por fecha de publicación; Seguimiento cuenta alumnos activos, en onboarding o en renovación de hoy.</div>`;

    const q = s => el.querySelector(s);
    q('#mapa-cli').onchange = e => { sel.cli = e.target.value; mostrar(); };
    q('#mapa-mes').onchange = e => { sel.ym = e.target.value; mostrar(); };
    q('#btn-recargar').onclick = async () => {
      try { base = await cargarBaseMapa(); } catch (e) { /* se queda con lo anterior */ }
      mostrar();
    };
  };
  mostrar();
}
