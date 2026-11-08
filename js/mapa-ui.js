/* Mapa: piezas de interfaz de los marcos (HTML por plantilla, SVG a mano, sin librerías). Todo texto va escapado. */
import { esc } from './ui.js';

export const SIN = 'sin dato';
export const ent = v => String(Math.round(v)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
const dec = (v, d = 1) => (Math.round(v * 10 ** d) / 10 ** d).toFixed(d).replace('.', ',').replace(/,0+$/, '');
export const pct = v => (v == null ? SIN : `${dec(v)}%`);
const exactoUsd = v => `US$ ${(v < 0 ? '-' : '')}${ent(Math.abs(v))}${Math.abs(v) % 1 ? ',' + String(Math.round((Math.abs(v) % 1) * 100)).padStart(2, '0') : ''}`;

/* Monto compacto (US$ 29,4k); el exacto va en title. */
export function uc(v) {
  const a = Math.abs(v), s = v < 0 ? '-' : '';
  if (a >= 1e6) return `${s}US$ ${dec(a / 1e6)}M`;
  if (a >= 1e4) return `${s}US$ ${dec(a / 1e3)}k`;
  return `${s}US$ ${ent(a)}`;
}
/* {t, title?} listo para kpi/celdas. */
export const money = v => (v == null ? { t: SIN } : { t: uc(v), title: exactoUsd(v) });
export const count = v => (v == null ? { t: SIN } : { t: ent(v) });
const tt = o => (o && o.title ? ` title="${esc(o.title)}"` : '');
export const fecha = f => { const p = String(f || '').slice(0, 10).split('-'); return p.length === 3 ? `${p[2]}/${p[1]}` : '—'; };

export const chip = (tono, txt) => `<span class="chip ${tono}">${esc(txt)}</span>`;
export const delta = (act, prev, { invertir = false } = {}) => {
  if (act == null || prev == null) return '<span class="kd flat">sin mes anterior</span>';
  if (prev === 0) return `<span class="kd flat">${act === 0 ? 'igual que el mes anterior' : 'mes anterior en 0'}</span>`;
  const p = ((act - prev) / Math.abs(prev)) * 100;
  if (Math.abs(p) < 0.05) return '<span class="kd flat">= igual al mes anterior</span>';
  const sube = p > 0, bien = invertir ? !sube : sube;
  return `<span class="kd ${bien ? 'up' : 'dn'}">${sube ? '▲' : '▼'} ${dec(Math.abs(p))}% vs mes anterior</span>`;
};

/* v = {t, title?}; sub = HTML (delta o texto); primary = relleno accent. */
export const kpi = (label, v, sub = '', primary = false) => `<div class="kpi${primary ? ' pri' : ''}">
  <div class="kl">${esc(label)}</div><div class="kv${v.t === SIN ? ' sd' : ''}"${tt(v)}>${esc(v.t)}</div><div class="ksub">${sub}</div></div>`;
export const kpis = (items, cols) => `<div class="kpis" style="--cols:${cols || items.length}">${items.join('')}</div>`;

export const vh = (titulo, sub, tools = '') => `<div class="vh"><div><h3>${esc(titulo)}</h3><div class="vs">${esc(sub)}</div></div><div class="vtools">${tools}</div></div>`;
export const card = (titulo, extra, cuerpo, { flush = false, cls = '' } = {}) => `<section class="mcard ${cls}"><header><h4>${esc(titulo)}</h4><span class="x">${esc(extra || '')}</span></header><div class="cb${flush ? ' flush' : ''}">${cuerpo}</div></section>`;
export const aviso = (txt, tono = 'warn') => `<div class="mnote ${tono}">${esc(txt)}</div>`;
export const grid = (cols, ...bloques) => `<div class="mgrid" style="--g:${cols}">${bloques.join('')}</div>`;

/* Estado vacío elegante («Sin datos todavía» + qué falta). */
export const vacio = (titulo, falta, items = []) => `<div class="mvacio"><div class="mv-ico" aria-hidden="true">
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M3 9h18M8 14h4"/></svg></div>
  <div class="mv-t">${esc(titulo)}</div><p>${esc(falta)}</p>${items.length ? `<ul>${items.map(i => `<li>${esc(i)}</li>`).join('')}</ul>` : ''}</div>`;

/* cols: [{h, k?, num?, fmt?}] ; filas: arrays de celdas ya formateadas ({t,title?,html?} o string). */
export function tabla(cols, filas, { foot = null, vacioTxt = 'Sin filas este mes' } = {}) {
  const celda = (c, i, col) => {
    const o = typeof c === 'object' && c !== null ? c : { t: c };
    return `<td class="${col.num ? 'r num' : ''}${i === 0 ? ' f' : ''}"${tt(o)}>${o.html != null ? o.html : esc(o.t ?? '')}</td>`;
  };
  const cuerpo = filas.length ? filas.map(f => `<tr>${f.map((c, i) => celda(c, i, cols[i])).join('')}</tr>`).join('')
    : `<tr><td colspan="${cols.length}" class="vacio-td">${esc(vacioTxt)}</td></tr>`;
  const pie = foot ? `<tfoot><tr>${foot.map((c, i) => celda(c, i, cols[i])).join('')}</tr></tfoot>` : '';
  return `<table class="t"><thead><tr>${cols.map(c => `<th class="${c.num ? 'r' : ''}">${esc(c.h)}</th>`).join('')}</tr></thead><tbody>${cuerpo}</tbody>${pie}</table>`;
}

/* items: [[etiqueta, valor, textoValor?]] */
export function hbars(items, { fmt = ent, vacioTxt = 'Sin datos este mes' } = {}) {
  if (!items.length) return `<div class="mvacio-mini">${esc(vacioTxt)}</div>`;
  const max = Math.max(...items.map(i => i[1]), 1);
  return `<div class="hbars">${items.map(([k, v, txt]) => `<div class="hb"><span class="hl" title="${esc(k)}">${esc(k)}</span>
    <span class="ht"><i style="width:${Math.max(2, (v / max) * 100)}%"></i></span><b class="num">${esc(txt ?? fmt(v))}</b></div>`).join('')}</div>`;
}

/* Embudo: [[etapa, valor]] (la primera etapa es la base). */
export function embudo(etapas) {
  const base = Math.max(...etapas.map(e => e[1] || 0), 1);
  return `<div class="funnel">${etapas.map(([k, v], i) => {
    const prev = i ? etapas[i - 1][1] : null;
    const w = Math.max(8, ((v || 0) / base) * 100);
    const r = i === 0 ? 'base' : prev ? `${dec((v / prev) * 100)}%` : '—';
    return `<div class="fr"><span class="fl">${esc(k)}</span><span class="fb"><i style="width:${w}%;opacity:${1 - i * 0.11}">${esc(ent(v || 0))}</i></span><span class="fp">${r}</span></div>`;
  }).join('')}</div>`;
}

export const strip = items => `<div class="strip">${items.map(([k, v, extra]) => `<div class="si"><div class="sl">${esc(k)}</div><div class="sv"${tt(v)}>${esc(v.t)}</div>${extra || ''}</div>`).join('')}</div>`;
export const prog = (p, tono = '') => `<div class="prog ${tono}"><i style="width:${Math.max(0, Math.min(100, p))}%"></i></div>`;
export const lista = filas => `<ul class="mlist">${filas.map(([tono, txt, der]) => `<li><span class="li-i ${tono}"></span><span class="li-t">${esc(txt)}</span><span class="li-d">${esc(der || '')}</span></li>`).join('')}</ul>`;

/* Línea/área acumulada. puntos = [[x(día), y]]; viewBox 620x180. */
export function linea(puntos, { fmt = ent, vacioTxt = 'Sin datos este mes' } = {}) {
  if (puntos.length < 2) return `<div class="mvacio-mini">${esc(vacioTxt)}</div>`;
  const W = 620, H = 180, L = 40, R = 14, T = 14, B = 24;
  const xs = puntos.map(p => p[0]), x0 = Math.min(...xs), x1 = Math.max(...xs);
  const my = Math.max(...puntos.map(p => p[1]), 1);
  const X = x => L + ((x - x0) / Math.max(1, x1 - x0)) * (W - L - R), Y = y => T + (1 - y / my) * (H - T - B);
  const pts = puntos.map(p => `${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`);
  const grid = [0, 1, 2, 3, 4].map(i => { const y = T + (i / 4) * (H - T - B); return `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}" class="gl"/><text x="${L - 6}" y="${y + 4}" class="ga" text-anchor="end">${esc(compacto(my * (1 - i / 4)))}</text>`; }).join('');
  const last = puntos[puntos.length - 1];
  return `<svg viewBox="0 0 ${W} ${H}" class="chart" role="img" aria-label="Gráfico de línea">${grid}
    <text x="${L}" y="${H - 6}" class="ga">día ${x0}</text><text x="${W - R}" y="${H - 6}" class="ga" text-anchor="end">día ${x1}</text>
    <polygon points="${X(x0)},${H - B} ${pts.join(' ')} ${X(x1)},${H - B}" class="ar"/><polyline points="${pts.join(' ')}" class="ln"/>
    <circle cx="${X(last[0])}" cy="${Y(last[1])}" r="5" class="pt"/><text x="${Math.min(X(last[0]), W - 60)}" y="${Math.max(12, Y(last[1]) - 10)}" class="gv">${esc(fmt(last[1]))}</text></svg>`;
}
const compacto = v => (v >= 1e3 ? `${dec(v / 1e3)}k` : String(Math.round(v)));

/* Acumulado por día a partir de {dia: monto}. */
export function acumulado(porDia) {
  const dias = Object.keys(porDia).map(Number).sort((a, b) => a - b);
  let s = 0;
  return dias.map(d => [d, (s += porDia[d])]);
}
