/* Mis números.
   - closer: sus cierres, pagos y monto por mes (fin_v_ranking_closers, la RLS
     deja solo sus filas) y el detalle de sus pagos.
   - setter: sus pagos (la RLS de fin_pagos deja solo donde figura como setter).
   - fundador y cliente: el ranking de closers y de setters del mes.
   El vínculo usuario -> nombre en la planilla es fin_personas. */
import { esc, fmtFecha, hoyAR } from '../ui.js';
import { yo, esEquipo } from '../sesion.js';
import { rankingClosers, pagosVisibles, pagos, fuentes, usd, numCelda, MESES, MESES_CORTOS } from '../datos.js';
import { statCard, vacio, selectCliente, selectMes, selectAnio, anios, clienteChip, botonRecargar } from './comunes.js';

const n = v => Number(v) || 0;
let filtro = { cliente: '', anio: null, mes: null };

export function vistaMisNumeros(el, vigente) {
  return esEquipo() ? vistaPropia(el, vigente) : vistaRanking(el, vigente);
}

/* ---------- closer / setter ---------- */
async function vistaPropia(el, vigente) {
  const esCloser = yo.rol === 'closer';
  const [lista, ranking, mapaFuentes] = await Promise.all([
    pagosVisibles(), esCloser ? rankingClosers() : Promise.resolve([]), fuentes()
  ]);
  if (!vigente()) return;
  if (!lista.length) {
    el.innerHTML = vacio('Todavía no hay pagos a tu nombre',
      'Si ya cerraste ventas, pedile al fundador que vincule tu usuario con el nombre con el que figurás en la planilla.');
    return;
  }
  const porMes = new Map();
  for (const p of lista) {
    const k = p.fecha.slice(0, 7);
    const m = porMes.get(k) || { pagos: 0, monto: 0, alumnos: new Set(), cierres: null };
    m.pagos++; m.monto += n(p.monto_usd); m.alumnos.add(String(p.alumno).trim().toLowerCase());
    porMes.set(k, m);
  }
  for (const r of ranking) {
    const k = `${r.anio}-${String(r.mes).padStart(2, '0')}`;
    const m = porMes.get(k);
    if (m) m.cierres = (m.cierres || 0) + n(r.cierres);
  }
  const claves = [...porMes.keys()].sort().reverse();
  const actual = porMes.get(hoyAR().slice(0, 7)) || { pagos: 0, monto: 0, alumnos: new Set(), cierres: 0 };

  el.innerHTML = `
    <div class="filter-row"><span class="grow"></span>${botonRecargar()}</div>
    <div class="stat-row">
      ${esCloser ? statCard(String(n(actual.cierres)), 'Cierres este mes', { sub: 'Alumnos con FEE o PIF' }) : ''}
      ${statCard(String(actual.pagos), 'Pagos este mes')}
      ${statCard(usd(actual.monto), 'Monto este mes')}
      ${statCard(usd(lista.reduce((s, p) => s + n(p.monto_usd), 0)), 'Monto total histórico', { sub: `${lista.length} pagos` })}
    </div>
    <div class="section-title">Mes a mes<span class="line"></span></div>
    <div class="card table-card">
      <table class="data-table">
        <thead><tr><th>Mes</th>${esCloser ? '<th class="num">Cierres</th>' : ''}<th class="num">Alumnos</th><th class="num">Pagos</th><th class="num">Monto</th></tr></thead>
        <tbody>${claves.map(k => {
          const m = porMes.get(k);
          const [a, mm] = k.split('-').map(Number);
          return `<tr><td>${MESES[mm - 1]} ${a}</td>${esCloser ? `<td class="num">${n(m.cierres)}</td>` : ''}
            <td class="num">${m.alumnos.size}</td><td class="num">${m.pagos}</td><td class="num">${usd(m.monto)}</td></tr>`;
        }).join('')}</tbody>
      </table>
    </div>
    <div class="section-title">Tus pagos<span class="line"></span></div>
    ${tablaPagosPersona(lista.slice(0, 200), mapaFuentes)}
    ${lista.length > 200 ? `<div class="table-foot">Se muestran los 200 más recientes de ${lista.length}.</div>` : ''}`;
  el.querySelector('#btn-recargar').onclick = () => vistaPropia(el, vigente);
}

function tablaPagosPersona(lista, mapaFuentes) {
  return `
    <div class="card table-card">
      <table class="data-table data-table-dense">
        <thead><tr><th>Fecha</th><th>Cliente</th><th>Alumno</th><th>Concepto</th><th>Closer</th><th>Setter</th><th class="num">Monto</th></tr></thead>
        <tbody>${lista.map(p => `<tr>
          <td>${fmtFecha(p.fecha)}</td><td>${clienteChip(p.cliente_id)}</td>
          <td title="${esc(p.alumno)}">${esc(p.alumno)}</td><td>${esc(p.concepto || '—')}</td>
          <td>${esc(p.closer || '—')}</td><td>${esc(p.setter || '—')}</td>
          <td class="num">${numCelda(usd(p.monto_usd), mapaFuentes.get(p.fuente_id), p.fila_planilla)}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>`;
}

/* ---------- fundador / cliente: ranking ---------- */
async function vistaRanking(el, vigente) {
  const ranking = await rankingClosers();
  if (!vigente()) return;
  if (!ranking.length) { el.innerHTML = vacio('Todavía no hay pagos con closer sincronizados'); return; }
  if (!filtro.anio) {
    const [ha, hm] = hoyAR().split('-').map(Number);
    const pasados = ranking.filter(r => r.anio < ha || (r.anio === ha && r.mes <= hm));
    const u = (pasados.length ? pasados : ranking).reduce((a, b) => (b.anio * 12 + b.mes > a.anio * 12 + a.mes ? b : a));
    filtro.anio = u.anio; filtro.mes = u.mes;
  }

  let turno = 0;
  const pintar = async () => {
    const mio = ++turno;
    const delMes = ranking.filter(r => r.anio === filtro.anio && r.mes === filtro.mes && (!filtro.cliente || r.cliente_id === filtro.cliente));
    const closers = agrupar(delMes, r => r.closer, r => ({ cierres: n(r.cierres), pagos: n(r.pagos), monto: n(r.monto_usd), clientes: [r.cliente_id] }));

    el.innerHTML = `
      <div class="filter-row">
        ${selectCliente('f-cliente', filtro.cliente)}${selectMes('f-mes', filtro.mes)}${selectAnio('f-anio', anios(ranking, filtro.anio), filtro.anio)}
        <span class="grow"></span>${botonRecargar()}
      </div>
      <div class="grid-2 detalle-grid">
        <div>
          <div class="section-title">Closers · ${esc(MESES_CORTOS[filtro.mes - 1])} ${filtro.anio}<span class="line"></span></div>
          ${tablaRanking(closers, true)}
        </div>
        <div>
          <div class="section-title">Setters · ${esc(MESES_CORTOS[filtro.mes - 1])} ${filtro.anio}<span class="line"></span></div>
          <div id="setters"><div class="loading-inline">Cargando…</div></div>
        </div>
      </div>
      <div class="table-foot">Cierre = alumno distinto con un pago cuyo concepto contiene FEE o PIF (supuesto a validar con la agencia).
        El detalle con link a cada fila está en la vista de cada cliente.</div>`;

    el.querySelector('#f-cliente').onchange = e => { filtro.cliente = e.target.value; pintar(); };
    el.querySelector('#f-mes').onchange = e => { filtro.mes = Number(e.target.value); pintar(); };
    el.querySelector('#f-anio').onchange = e => { filtro.anio = Number(e.target.value); pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaRanking(el, vigente);

    const lista = await pagos({ clienteId: filtro.cliente || null, anio: filtro.anio, mes: filtro.mes });
    if (!vigente() || mio !== turno || !el.querySelector('#setters')) return;
    const setters = agrupar(lista.filter(p => p.setter && p.setter.trim()), p => p.setter,
      p => ({ pagos: 1, monto: n(p.monto_usd), clientes: [p.cliente_id] }));
    el.querySelector('#setters').innerHTML = tablaRanking(setters, false);
  };
  await pintar();
}

/* Agrupa por nombre normalizado (la planilla trae "Agus", "agus ", "AGUS"). */
function agrupar(filas, nombre, valores) {
  const m = new Map();
  for (const f of filas) {
    const crudo = String(nombre(f) || '').trim();
    const k = crudo.toLowerCase();
    const v = valores(f);
    const a = m.get(k) || { nombre: crudo, cierres: 0, pagos: 0, monto: 0, clientes: new Set() };
    a.cierres += v.cierres || 0; a.pagos += v.pagos; a.monto += v.monto;
    v.clientes.forEach(c => a.clientes.add(c));
    m.set(k, a);
  }
  return [...m.values()].sort((a, b) => b.monto - a.monto);
}

function tablaRanking(lista, conCierres) {
  if (!lista.length) return vacio('Sin datos en este mes');
  return `
    <div class="card table-card">
      <table class="data-table">
        <thead><tr><th>#</th><th>Nombre</th><th>Clientes</th>${conCierres ? '<th class="num">Cierres</th>' : ''}<th class="num">Pagos</th><th class="num">Monto</th></tr></thead>
        <tbody>${lista.map((r, i) => `<tr>
          <td>${i + 1}</td><td>${esc(r.nombre)}</td><td>${[...r.clientes].map(clienteChip).join(' ')}</td>
          ${conCierres ? `<td class="num">${r.cierres}</td>` : ''}<td class="num">${r.pagos}</td><td class="num">${usd(r.monto)}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>`;
}
