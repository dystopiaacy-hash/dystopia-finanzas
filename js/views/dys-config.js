/* Configuración de Dystopia (solo quien edita gastos = fundador): porcentajes de cada cliente con vigencia desde / hasta
   (fin_comision_agencia) y gastos fijos propios de la agencia (sueldo de Joaquín, fin_dys_gastos_fijos). Migración 267. */
import { esc, abrirModal, toast, fmtFecha, fmtPct, hoyAR } from '../ui.js';
import { usd } from '../datos.js';
import { ENTIDADES, nombreEntidad, comisionGuardar, gastoFijoGuardar } from '../gastos.js';

const fila = (id, label, control, hint = '') =>
  `<div class="form-row"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${esc(hint)}</div>` : ''}</div>`;

export function tablaConfig(coms, fijos, puede) {
  const hasta = h => (h ? fmtFecha(h) : 'abierto');
  return `
    <div class="card-titulo">Porcentaje de Dystopia sobre la ganancia del cliente
      ${puede ? '<button type="button" class="btn btn-sm" id="cfg-pct-nuevo">+ Nuevo porcentaje</button>' : ''}</div>
    <div class="card table-card"><table class="data-table tabla-tarjetas">
      <thead><tr><th class="titulo">Cliente</th><th class="num clave">%</th><th>Desde</th><th>Hasta</th><th class="largo">Nota</th><th class="acciones"></th></tr></thead>
      <tbody>${coms.map(c => `<tr><td class="ajusta">${esc(nombreEntidad(c.cliente_id))}</td><td class="num">${fmtPct(c.porcentaje, 1)}</td>
        <td>${fmtFecha(c.desde)}</td><td>${hasta(c.hasta)}</td><td class="ajusta">${esc(c.nota || '')}</td>
        <td class="acciones">${puede ? `<button class="btn btn-sm" data-pct="${c.id}">Editar</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="6">Sin porcentajes cargados</td></tr>'}</tbody>
    </table></div>
    <div class="table-foot">Cada mes usa el porcentaje con «desde» más reciente que ya haya empezado. Un porcentaje nuevo cierra solo el anterior del mismo cliente.</div>
    <div class="card-titulo">Gastos fijos de Dystopia
      ${puede ? '<button type="button" class="btn btn-sm" id="cfg-fijo-nuevo">+ Nuevo gasto fijo</button>' : ''}</div>
    <div class="card table-card"><table class="data-table tabla-tarjetas">
      <thead><tr><th class="titulo">Concepto</th><th class="num clave">USD por mes</th><th>Desde</th><th>Hasta</th><th>Estado</th><th class="acciones"></th></tr></thead>
      <tbody>${fijos.map(f => `<tr><td class="ajusta">${esc(f.concepto)}</td><td class="num">${usd(f.monto_usd, { centavos: true })}</td>
        <td>${fmtFecha(f.desde)}</td><td>${hasta(f.hasta)}</td><td>${f.activo ? 'Activo' : 'Dado de baja'}</td>
        <td class="acciones">${puede ? `<button class="btn btn-sm" data-fijo="${f.id}">Editar</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="6">Sin gastos fijos</td></tr>'}</tbody>
    </table></div>`;
}

function modal({ titulo, cuerpo, leer, guardar, alGuardar, aviso }) {
  const m = abrirModal({ titulo, ancho: true,
    cuerpo: `<form class="form-grid2" novalidate onsubmit="return false">${cuerpo}<div class="campo-ancho"><span class="form-error" id="c-error" role="alert"></span></div></form>`,
    pie: '<button type="button" class="btn" id="c-cancelar">Cancelar</button><button type="button" class="btn btn-accent" id="c-guardar">Guardar</button>' });
  const q = id => m.el.querySelector('#' + id);
  q('c-cancelar').onclick = () => m.cerrar();
  q('c-guardar').onclick = async () => {
    const r = leer(q);
    if (typeof r === 'string') { q('c-error').textContent = r; return; }
    q('c-guardar').disabled = true;
    try { await guardar(r); m.cerrar(); toast(aviso); alGuardar(); } catch (e) {
      q('c-error').textContent = `No se pudo guardar: ${e.message}`; q('c-guardar').disabled = false;
    }
  };
}

export function abrirPorcentaje(c, alGuardar) {
  const v = c || { cliente_id: 'liam', desde: hoyAR().slice(0, 8) + '01' };
  const clientes = ENTIDADES.filter(e => e[0] !== 'dystopia');
  modal({
    titulo: c ? 'Editar porcentaje' : 'Nuevo porcentaje', alGuardar, aviso: 'Porcentaje guardado',
    cuerpo: `${fila('c-cli', 'Cliente', `<select id="c-cli"${c ? ' disabled' : ''}>${clientes.map(([k, n]) => `<option value="${k}"${k === v.cliente_id ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select>`)}
      ${fila('c-pct', '% sobre la ganancia del cliente', `<input type="number" id="c-pct" min="0" max="100" step="0.01" value="${v.porcentaje ?? ''}">`)}
      ${fila('c-desde', 'Vigente desde', `<input type="date" id="c-desde" value="${esc(v.desde || '')}">`, 'Se aplica desde el mes de esta fecha.')}
      ${fila('c-hasta', 'Hasta (opcional)', `<input type="date" id="c-hasta" value="${esc(v.hasta || '')}">`, 'Vacío = sigue vigente.')}
      <div class="campo-ancho">${fila('c-nota', 'Nota', `<input type="text" id="c-nota" maxlength="200" value="${esc(v.nota || '')}">`)}</div>`,
    leer: q => {
      const pct = Number(q('c-pct').value);
      if (q('c-pct').value === '' || !(pct >= 0 && pct <= 100)) return 'El porcentaje tiene que estar entre 0 y 100.';
      if (!q('c-desde').value) return 'Falta la fecha de inicio.';
      if (q('c-hasta').value && q('c-hasta').value < q('c-desde').value) return 'La fecha de fin no puede ser anterior al inicio.';
      const o = { porcentaje: pct, desde: q('c-desde').value, hasta: q('c-hasta').value || null, nota: q('c-nota').value.trim() || null };
      if (!c) o.cliente_id = q('c-cli').value;
      return o;
    },
    guardar: o => comisionGuardar(c ? c.id : null, o)
  });
}

export function abrirGastoFijo(f, alGuardar) {
  const v = f || { desde: hoyAR().slice(0, 8) + '01', activo: true };
  modal({
    titulo: f ? 'Editar gasto fijo' : 'Nuevo gasto fijo', alGuardar, aviso: 'Gasto fijo guardado',
    cuerpo: `${fila('f-con', 'Concepto', `<input type="text" id="f-con" maxlength="120" autocomplete="off" value="${esc(v.concepto || '')}">`)}
      ${fila('f-monto', 'USD por mes', `<input type="number" id="f-monto" min="0.01" step="0.01" value="${v.monto_usd ?? ''}">`)}
      ${fila('f-desde', 'Desde', `<input type="date" id="f-desde" value="${esc(v.desde || '')}">`)}
      ${fila('f-hasta', 'Hasta (opcional)', `<input type="date" id="f-hasta" value="${esc(v.hasta || '')}">`)}
      <div class="campo-ancho">${fila('f-act', 'Estado', `<label class="chk-linea"><input type="checkbox" id="f-act"${v.activo ? ' checked' : ''}> Activo (si se destilda, deja de contarse)</label>`)}</div>`,
    leer: q => {
      const m = Number(q('f-monto').value);
      if (!q('f-con').value.trim()) return 'Falta el concepto.';
      if (!(m > 0)) return 'El monto tiene que ser mayor que 0.';
      if (!q('f-desde').value) return 'Falta la fecha de inicio.';
      if (q('f-hasta').value && q('f-hasta').value < q('f-desde').value) return 'La fecha de fin no puede ser anterior al inicio.';
      return { concepto: q('f-con').value.trim(), monto_usd: m, desde: q('f-desde').value, hasta: q('f-hasta').value || null, activo: q('f-act').checked };
    },
    guardar: o => gastoFijoGuardar(f ? f.id : null, o)
  });
}
