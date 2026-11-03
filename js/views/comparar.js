/* Comparar (solo fundador): dos meses lado a lado, para un cliente o todos. Números grandes A vs B con variación,
   barras por cliente y por categoría de gasto, comisiones por persona. Mes cerrado = foto del cierre; abierto = en vivo. */
import { esc, fmtPct, hoyAR } from '../ui.js';
import { usd } from '../datos.js';
import { mesesDe, etiquetaMes } from '../gastos.js';
import { botonRecargar } from './comunes.js';
import { CLIENTES, CATEGORIAS_GASTO, cargarBase, cargarMes, resumir, variacion } from '../comparar.js';

const u = v => usd(v, { centavos: false });
const ent = v => (v == null ? '—' : String(Math.round(v)));

function mesesAtras(k) {
  const d = new Date(`${hoyAR().slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - k);
  return d.toISOString().slice(0, 7);
}

/* Chip de variación de B contra A. suba = lo bueno: true (ingresos), false (gastos: subir es malo), null (neutro). */
function chip(a, b, suba) {
  const v = variacion(a, b);
  if (v == null) return '<span class="cmp-chip">sin base</span>';
  const signo = v > 0 ? '+' : '';
  const tono = Math.abs(v) < 0.05 || suba == null ? '' : ((v > 0) === suba ? ' cmp-chip-ok' : ' cmp-chip-mal');
  return `<span class="cmp-chip${tono}">${signo}${fmtPct(v, 1)}</span>`;
}

function kpi(titulo, a, b, { fmt = u, suba = true, sub = '' } = {}, rotA, rotB) {
  return `<div class="cmp-kpi">
    <div class="cmp-kpi-t">${esc(titulo)}</div>
    <div class="cmp-kpi-par">
      <div><div class="cmp-kpi-m">${esc(rotA)}</div><div class="cmp-kpi-n">${esc(fmt(a))}</div></div>
      <div><div class="cmp-kpi-m">${esc(rotB)}</div><div class="cmp-kpi-n cmp-kpi-b">${esc(fmt(b))}</div></div>
    </div>
    <div class="cmp-kpi-pie">${chip(a, b, suba)}${sub ? `<span class="cmp-kpi-sub">${esc(sub)}</span>` : ''}</div>
  </div>`;
}

/* Grupo de barras: una fila por etiqueta con dos barras (A suave, B acento). */
function barras(titulo, filas, rotA, rotB) {
  const max = Math.max(1, ...filas.flatMap(f => [Math.abs(f.a ?? 0), Math.abs(f.b ?? 0)]));
  const fila = f => {
    const resumen = `${f.etq}: ${rotA} ${u(f.a ?? 0)}, ${rotB} ${u(f.b ?? 0)}`;
    const barra = (v, cls) => `<div class="cmp-pista"><div class="cmp-relleno ${cls}${v < 0 ? ' cmp-neg' : ''}" style="width:${Math.max(v ? 1.5 : 0, (Math.abs(v ?? 0) / max) * 100)}%"></div><span class="cmp-val">${esc(f.nd && v == null ? 'sin dato' : u(v ?? 0))}</span></div>`;
    return `<div class="cmp-fila" role="img" aria-label="${esc(resumen)}">
      <div class="cmp-etq">${esc(f.etq)}</div>
      <div class="cmp-pistas" aria-hidden="true">${barra(f.a, 'cmp-a')}${barra(f.b, 'cmp-b')}</div></div>`;
  };
  return `<div class="card cmp-barras"><div class="cmp-card-t">${esc(titulo)}</div>
    <div class="cmp-leyenda" aria-hidden="true"><span><i class="cmp-a"></i>${esc(rotA)}</span><span><i class="cmp-b"></i>${esc(rotB)}</span></div>
    ${filas.map(fila).join('') || '<div class="small">Sin datos</div>'}</div>`;
}

export async function vistaComparar(el, vigente) {
  el.innerHTML = '<div class="card empty-state"><div class="small">Cargando la comparativa…</div></div>';
  let base;
  try { base = await cargarBase(); } catch (e) {
    el.innerHTML = `<div class="card nota aviso-ambar">No se pudo cargar: ${esc(e.message)}</div>`;
    return;
  }
  if (!vigente()) return;
  const meses = mesesDe(base.ganancia);
  const ultimo = mesesAtras(1);
  if (!meses.includes(ultimo)) meses.push(ultimo);
  meses.sort().reverse();
  let sel = { cli: '', a: meses.includes(mesesAtras(2)) ? mesesAtras(2) : (meses[1] || meses[0]), b: ultimo };

  const mostrar = async () => {
    const datos = {};
    try {
      [datos.a, datos.b] = await Promise.all([cargarMes(sel.a, base), cargarMes(sel.b, base)]);
    } catch (e) {
      el.innerHTML = `<div class="card nota aviso-ambar">No se pudo cargar la comparativa: ${esc(e.message)}</div>`;
      return;
    }
    if (!vigente()) return;
    const A = resumir(datos.a, sel.cli), B = resumir(datos.b, sel.cli);
    const rotA = etiquetaMes(sel.a), rotB = etiquetaMes(sel.b);
    const estado = d => (d.cerrado ? '<span class="badge">Cerrado</span>' : '<span class="badge badge-outline">Abierto</span>');
    const sinCat = !datos.a.gastosCat || !datos.b.gastosCat;
    const abiertos = [datos.a, datos.b].filter(d => !d.cerrado).map(d => etiquetaMes(d.ym));
    const opcion = (m, act) => `<option value="${m}"${m === act ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`;
    const pctTxt = v => (v == null ? '—' : fmtPct(v, 1));

    const porCliente = (campo) => CLIENTES.map(([id, nombre]) => ({ etq: nombre, a: resumir(datos.a, id)[campo], b: resumir(datos.b, id)[campo] }));
    const porCategoria = CATEGORIAS_GASTO.map(([k, nombre]) => ({ etq: nombre, a: A.categorias[k], b: B.categorias[k], nd: true }));
    const nombresPersona = [...new Set([...A.personas.keys(), ...B.personas.keys()])].sort((x, y) => x.localeCompare(y, 'es'));

    el.innerHTML = `
      <div class="filter-row cmp-filtros">
        <span class="flabel">Cliente</span>
        <select id="cmp-cli" aria-label="Cliente"><option value="">Todos</option>${CLIENTES.map(([id, nm]) => `<option value="${id}"${id === sel.cli ? ' selected' : ''}>${esc(nm)}</option>`).join('')}</select>
        <span class="flabel">Mes A</span>
        <select id="cmp-a" aria-label="Mes A">${meses.map(m => opcion(m, sel.a)).join('')}</select>
        ${estado(datos.a)}
        <span class="flabel">Mes B</span>
        <select id="cmp-b" aria-label="Mes B">${meses.map(m => opcion(m, sel.b)).join('')}</select>
        ${estado(datos.b)}
        <span class="grow"></span>
        ${botonRecargar()}
      </div>
      ${abiertos.length ? `<div class="card nota aviso-ambar">${esc(abiertos.join(' y '))}: mes abierto, los números pueden cambiar hasta el cierre.</div>` : ''}
      ${sinCat ? '<div class="card nota aviso-ambar">Falta correr la migración 280: sin ella Ads, Zoom y Landings no se abren y todo cae en «Otros».</div>' : ''}
      <div class="cmp-grid">
        ${kpi('Facturación', A.facturacion, B.facturacion, { suba: true }, rotA, rotB)}
        ${kpi('Gastos', A.gastos, B.gastos, { suba: false }, rotA, rotB)}
        ${kpi('Ganancia del cliente', A.ganancia, B.ganancia, { suba: true }, rotA, rotB)}
        ${kpi('Ganancia de Dystopia', A.gananciaDys, B.gananciaDys, { suba: true, sub: `% Dystopia: ${pctTxt(A.pct)} → ${pctTxt(B.pct)}` }, rotA, rotB)}
        ${kpi('Transferencias del cierre', A.transfTotal, B.transfTotal, { suba: null, sub: `${A.transfCantidad} → ${B.transfCantidad} líneas` }, rotA, rotB)}
        ${kpi('Ventas nuevas', A.ventasN, B.ventasN, { fmt: ent, suba: true, sub: `${u(A.ventasUsd)} → ${u(B.ventasUsd)}` }, rotA, rotB)}
        ${kpi('Cuotas', A.cuotasN, B.cuotasN, { fmt: ent, suba: true, sub: `${u(A.cuotasUsd)} → ${u(B.cuotasUsd)}` }, rotA, rotB)}
      </div>
      <div class="cmp-grid cmp-grid-barras">
        ${barras('Facturación por cliente', porCliente('facturacion'), rotA, rotB)}
        ${barras('Ganancia por cliente', porCliente('ganancia'), rotA, rotB)}
        ${barras('Gastos por categoría', porCategoria, rotA, rotB)}
      </div>
      <div class="card-titulo">Comisiones por persona</div>
      <div class="card table-card"><table class="data-table">
        <thead><tr><th>Persona</th><th class="num">${esc(rotA)}</th><th class="num">${esc(rotB)}</th><th class="num">Variación</th></tr></thead>
        <tbody>${nombresPersona.map(p => `<tr><td>${esc(p)}</td><td class="num">${u(A.personas.get(p) ?? 0)}</td><td class="num">${u(B.personas.get(p) ?? 0)}</td><td class="num">${chip(A.personas.get(p) ?? 0, B.personas.get(p) ?? 0, null)}</td></tr>`).join('')
          || '<tr><td colspan="4">Sin comisiones calculadas en estos meses. Se calculan en Cierre de mes.</td></tr>'}</tbody></table></div>
      <div class="table-foot">La variación es de ${esc(rotB)} contra ${esc(rotA)}. Los meses cerrados salen de la foto del cierre; en los abiertos, Facturación, Gastos y Ganancia salen en vivo.
        Transferencias y comisiones por persona son las líneas activas del cierre. Ventas nuevas y Cuotas cuentan pagos (concepto de cada pago).</div>`;

    const q = s => el.querySelector(s);
    q('#cmp-cli').onchange = e => { sel.cli = e.target.value; mostrar(); };
    q('#cmp-a').onchange = e => { sel.a = e.target.value; mostrar(); };
    q('#cmp-b').onchange = e => { sel.b = e.target.value; mostrar(); };
    q('#btn-recargar').onclick = async () => { try { base = await cargarBase(); } catch (e) { /* se queda con lo anterior */ } mostrar(); };
  };
  mostrar();
}
