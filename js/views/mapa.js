/* Mapa (solo fundador): cinta con la cadena del mes, una fila de 4 tarjetas iguales (Marketing, Ventas, Finanzas,
   Seguimiento), franja de resultado Dystopia y «Próximamente» compacto. Solo lectura. */
import { esc, hoyAR, fmtPct } from '../ui.js';
import { usd } from '../datos.js';
import { mesesDe, etiquetaMes } from '../gastos.js';
import { botonRecargar } from './comunes.js';
import { CLIENTES, AREAS, PROXIMAMENTE, cargarBaseMapa, cargarMapa } from '../mapa.js';

const ent = v => String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
const SIN = 'sin dato';
const val = (v, fmt) => (v == null ? SIN : fmt(v));
const dec1 = v => (Math.round(v * 10) / 10).toFixed(1).replace('.', ',').replace(/,0$/, '');

/* Monto compacto: US$ 29,4k / US$ 1,2M; debajo de 1.000 con centavos si los tiene. El exacto va en title. */
function uc(v) {
  const a = Math.abs(v), s = v < 0 ? '-' : '';
  if (a >= 1e6) return `${s}US$ ${dec1(a / 1e6)}M`;
  if (a >= 1e3) return `${s}US$ ${dec1(a / 1e3)}k`;
  return usd(v, { centavos: false });
}
const exacto = v => usd(v, { centavos: true });
/* Devuelve {t: texto visible, title: exacto} para montos, o solo texto para enteros. */
const money = v => (v == null ? { t: SIN } : { t: uc(v), title: exacto(v) });
const count = v => (v == null ? { t: SIN } : { t: ent(v) });

const titulo = o => (o.title ? ` title="${esc(o.title)}"` : '');

function boton(a) {
  if (a.url) return `<a class="btn btn-sm mapa-abrir" href="${esc(a.url)}" target="_blank" rel="noopener noreferrer">Abrir ↗</a>`;
  return `<a class="btn btn-sm mapa-abrir" href="${esc(a.ruta)}">Abrir</a>`;
}

/* sec: lista de [etiqueta, {t, title?}] (siempre 3 filas para alinear la fila de tarjetas). */
function tarjeta(clase, area, { num, etiqueta, sec = [], aviso = '', nota = '' }) {
  const a = AREAS[area];
  const filas = sec.slice(0, 3);
  while (filas.length < 3) filas.push([' ', { t: '' }]);
  return `<article class="card mapa-card ${clase}">
    <div class="mapa-card-t">${esc(a.titulo)}</div>
    <div class="mapa-num${num.t === SIN ? ' mapa-sd' : ''}"${titulo(num)}>${esc(num.t)}</div>
    <div class="mapa-etq">${esc(etiqueta)}</div>
    <ul class="mapa-sec">${filas.map(([k, v]) => `<li><span>${esc(k)}</span><b class="${v.t === SIN ? 'mapa-sd' : ''}"${titulo(v)}>${esc(v.t)}</b></li>`).join('')}</ul>
    <div class="mapa-avisos">${aviso ? `<div class="mapa-aviso">${esc(aviso)}</div>` : ''}${nota ? `<div class="mapa-nota">${esc(nota)}</div>` : ''}</div>
    <p class="mapa-regla">${esc(a.regla)}</p>
    ${a.responsable ? `<div class="mapa-resp">Responsable: ${esc(a.responsable)}</div>` : ''}
    ${boton(a)}
  </article>`;
}

/* Cadena del mes en una línea: solo los eslabones con dato. */
function cinta(d) {
  const m = d.marketing, v = d.ventas, f = d.finanzas;
  const eslabones = [];
  const add = (cond, t, title) => { if (cond) eslabones.push(`<span class="mapa-chip"${title ? ` title="${esc(title)}"` : ''}>${esc(t)}</span>`); };
  add(m, `${ent(m && m.piezas)} piezas`);
  add(v && v.agendadas != null, `${ent(v && v.agendadas)} agendas`);
  add(v && v.cerradas != null, `${ent(v && v.cerradas)} cierres`);
  add(f, `${f ? uc(f.cash) : ''} cobrado`, f && exacto(f.cash));
  add(f, `${f ? uc(f.gananciaDys) : ''} Dystopia`, f && exacto(f.gananciaDys));
  if (!eslabones.length) return '';
  return `<div class="mapa-cinta" role="list" aria-label="Cadena del mes">${eslabones.join('<span class="mapa-sep" aria-hidden="true">→</span>')}</div>`;
}

function cuerpo(d, rotuloMes) {
  const m = d.marketing, v = d.ventas, f = d.finanzas, s = d.seguimiento;
  const plat = m ? Object.entries(m.porPlataforma).sort((a, b) => b[1] - a[1]).slice(0, 3) : [];
  const secMkt = !m ? [['Por plataforma', { t: SIN }]] : plat.length ? plat.map(([k, c]) => [k, { t: ent(c) }]) : [['Por plataforma', { t: '0' }]];

  const marketing = tarjeta('mapa-c-mkt', 'marketing', {
    num: count(m && m.piezas), etiqueta: `piezas publicadas en ${rotuloMes}`, sec: secMkt
  });
  const faltanLlamadas = v && v.agendadas > 0 && v.presentadas === 0;
  const ventas = tarjeta('mapa-c-vta', 'ventas', {
    num: count(v && v.agendadas), etiqueta: `llamadas agendadas en ${rotuloMes}`,
    sec: [['Presentadas', count(v && v.presentadas)], ['Cierres', count(v && v.cerradas)], ['Show up sin marcar', count(v && v.sinShowUp)]],
    aviso: faltanLlamadas ? `Faltan cargar llamadas de ${rotuloMes}: hay agendadas pero ninguna marcada como presentada.` : ''
  });
  const gastosBajos = f && f.cash > 0 && f.gastos < f.cash * 0.01;
  const finanzas = tarjeta('mapa-c-fin', 'finanzas', {
    num: money(f && f.cash), etiqueta: `cash cobrado en ${rotuloMes}`,
    sec: [['Gastos', money(f && f.gastos)], ['Ganancia del cliente', money(f && f.ganancia)]],
    aviso: gastosBajos ? 'Gastos del mes sin cargar: la ganancia está sobreestimada.' : ''
  });
  const seguimiento = tarjeta('mapa-c-seg', 'seguimiento', {
    num: count(s && s.activos), etiqueta: 'alumnos en seguimiento hoy',
    sec: [['En onboarding', count(s && s.onboarding)], ['En renovación', count(s && s.renovacion)]],
    nota: 'No cambia con el mes: es la foto de hoy.'
  });

  const a = AREAS.dystopia;
  const dg = money(f && f.gananciaDys);
  const resultado = `<section class="card mapa-dys">
      <div class="mapa-dys-izq">
        <div class="mapa-card-t">${esc(a.titulo)}</div>
        <div class="mapa-dys-fila">
          <div class="mapa-num mapa-dys-num${dg.t === SIN ? ' mapa-sd' : ''}"${titulo(dg)}>${esc(dg.t)}</div>
          <div class="mapa-dys-pct">${f && f.pct != null ? `${esc(fmtPct(f.pct, 0))} <span>de la ganancia del cliente</span>` : ''}</div>
        </div>
        <div class="mapa-etq">ganancia de Dystopia en ${esc(rotuloMes)}</div>
      </div>
      <p class="mapa-regla mapa-dys-regla">${esc(a.regla)}</p>
      ${boton(a)}
    </section>`;

  const prox = PROXIMAMENTE.map(t => `<span class="mapa-prox-chip"><b>${esc(t)}</b> · Próximamente</span>`).join('');

  return `${cinta(d)}
    <div class="mapa-grid">${marketing}${ventas}${finanzas}${seguimiento}</div>
    ${resultado}
    <div class="mapa-prox-fila" aria-label="Próximamente">${prox}</div>`;
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
      <div class="table-foot">Solo lectura. Montos compactos: pasá el mouse (o mantené apretado) para ver el exacto. Finanzas y Dystopia usan las mismas cuentas que Comparar y Cierre (mes cerrado = foto del cierre). Ventas sale de las métricas de Ventas (presentadas = columna Show up marcada «sí», que se completa días después de la llamada); Marketing cuenta piezas con estado PUBLICADO por fecha de publicación; Seguimiento cuenta alumnos activos, en onboarding o en renovación de hoy.</div>`;

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
