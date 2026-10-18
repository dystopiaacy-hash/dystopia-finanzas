/* Gasto de IA por cliente (migración 174): ia_uso agrupado por mes x cliente x proveedor, con el detalle por
   app y función. Lo que no se pudo asignar a un cliente aparece como «Sin asignar → Dystopia», se marca y suma en Dystopia. */
import { esc, fmtNum } from '../ui.js';
import { usd } from '../datos.js';
import { iaUsoMes, nombreFila, sumar, claveMes, mesesDe, etiquetaMes, PROVEEDORES } from '../gastos.js';
import { vacio, botonRecargar } from './comunes.js';

const ORDEN_ENT = ['liam', 'agus', 'teo', 'dystopia'];
/* Dystopia propia primero, la IA sin asignar (también de Dystopia) justo después. */
const cmp = (a, b) => ORDEN_ENT.indexOf(a.entidad) - ORDEN_ENT.indexOf(b.entidad) || (!!a.sin_asignar - !!b.sin_asignar);

export async function vistaIaUso(el, vigente) {
  const filas = await iaUsoMes();
  if (!vigente()) return;
  if (!filas.length) { el.innerHTML = vacio('Todavía no hay uso de IA registrado', 'Se llena solo con lo que escriben las apps en ia_uso.'); return; }
  const meses = mesesDe(filas);
  let mes = meses[0];

  const pintar = () => {
    const delMes = filas.filter(f => claveMes(f.mes) === mes);
    /* Mes x cliente x proveedor */
    const claves = new Map();
    for (const f of delMes) {
      const k = `${f.entidad}|${!!f.sin_asignar}|${f.proveedor}`;
      const a = claves.get(k) || { entidad: f.entidad, sin_asignar: !!f.sin_asignar, proveedor: f.proveedor, llamadas: 0, sin_costo: 0, usd: 0 };
      a.llamadas += Number(f.llamadas) || 0; a.sin_costo += Number(f.sin_costo) || 0; a.usd += Number(f.costo_usd) || 0;
      claves.set(k, a);
    }
    const resumen = [...claves.values()].sort((a, b) => cmp(a, b) || a.proveedor.localeCompare(b.proveedor));
    const sinAsig = resumen.filter(r => r.sin_asignar);
    const totalUsd = sumar(resumen, 'usd'), sinCosto = sumar(resumen, 'sin_costo'), llam = sumar(resumen, 'llamadas');

    const fila = r => `<tr class="${r.sin_asignar ? 'fila-alerta' : ''}">
      <td>${esc(nombreFila(r))}</td><td>${esc(PROVEEDORES[r.proveedor] || r.proveedor)}</td>
      <td class="num">${fmtNum(r.llamadas)}</td>
      <td class="num">${r.sin_costo ? `<span class="txt-ambar">${fmtNum(r.sin_costo)}</span>` : '0'}</td>
      <td class="num">${usd(r.usd, { centavos: true })}</td></tr>`;

    const detalle = [...delMes].sort((a, b) => cmp(a, b) || a.proveedor.localeCompare(b.proveedor)
      || String(a.app).localeCompare(String(b.app)) || String(a.funcion).localeCompare(String(b.funcion)));

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Mes</span>
        <select id="ia-mes">${meses.map(m => `<option value="${m}"${m === mes ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('')}</select>
        <span class="grow"></span>${botonRecargar()}
      </div>
      ${sinAsig.length ? `<div class="card nota aviso-ambar"><strong>Sin asignar: ${usd(sumar(sinAsig, 'usd'), { centavos: true })}</strong>
        (${fmtNum(sumar(sinAsig, 'llamadas'))} llamadas) en ${esc(etiquetaMes(mes))}. El cliente de esas llamadas no es liam, agus, teo ni dystopia
        (vacío o un identificador que no es un cliente). Se carga 100% a Dystopia (categoría IA) y suma en sus gastos.</div>` : ''}
      ${sinCosto ? `<div class="card nota aviso-ambar">${fmtNum(sinCosto)} de ${fmtNum(llam)} llamadas del mes figuran con costo 0 o vacío:
        el total puede estar subestimado.</div>` : ''}
      <div class="card-titulo">${esc(etiquetaMes(mes))}: cliente × proveedor · Total ${usd(totalUsd, { centavos: true })}</div>
      <div class="card table-card"><table class="data-table">
        <thead><tr><th>Cliente</th><th>Proveedor</th><th class="num">Llamadas</th><th class="num">Sin costo</th><th class="num">Costo (USD)</th></tr></thead>
        <tbody>${resumen.map(fila).join('')}</tbody></table></div>
      <div class="card-titulo">Detalle por app y función</div>
      <div class="card table-card"><table class="data-table">
        <thead><tr><th>Cliente</th><th>Proveedor</th><th>App</th><th>Función</th><th class="num">Llamadas</th><th class="num">Con error</th>
          <th class="num">Tokens (ent. / sal.)</th><th class="num">Costo (USD)</th></tr></thead>
        <tbody>${detalle.map(f => `<tr class="${f.sin_asignar ? 'fila-alerta' : ''}">
          <td>${esc(nombreFila(f))}</td><td>${esc(PROVEEDORES[f.proveedor] || f.proveedor)}</td>
          <td>${esc(f.app)}</td><td>${esc(f.funcion)}</td><td class="num">${fmtNum(f.llamadas)}</td><td class="num">${fmtNum(f.con_error)}</td>
          <td class="num">${fmtNum(f.tokens_entrada)} / ${fmtNum(f.tokens_salida)}</td>
          <td class="num">${usd(f.costo_usd, { centavos: true })}</td></tr>`).join('')}</tbody></table></div>
      <div class="table-foot">Sale de ia_uso (hora de Argentina). Proveedor según el modelo: claude* = Claude, gemini* = Gemini. En Gastos, el costo asignado
        aparece solo como categoría IA de cada cliente, con el reparto según comisión.</div>`;

    el.querySelector('#ia-mes').onchange = e => { mes = e.target.value; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => vistaIaUso(el, vigente);
  };
  pintar();
}
