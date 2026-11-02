/* Cierre de mes: detalle de las ventas de cada comisión y porcentajes (migración 269).
   Prioridad del %: el de la venta > el de la persona (de un cliente o de todos) > el por defecto (closer 10 / setter 5). */
import { esc, abrirModal, toast, fmtFecha, fmtPct } from '../ui.js';
import { usd } from '../datos.js';
import { ENTIDADES, nombreEntidad } from '../gastos.js';
import { pctVentaGuardar, parametroGuardar, pctPersonaGuardar, pctPersonaBorrar } from '../cierre.js';

const u = n => usd(n, { centavos: true });
const origen = v => (v.pct_venta != null ? 'venta' : v.pct_persona != null ? 'persona' : 'por defecto');

/* clave = «com:<cliente>:<persona_norm>» (la de la transferencia automática). */
export function abrirVentas(clave, ventas, cerrado, alCambiar) {
  const [, cliente, ...resto] = clave.split(':');
  const persona = resto.join(':');
  const mias = ventas.filter(v => v.cliente_id === cliente && v.persona_norm === persona && !v.no_comisiona);
  const nombre = mias[0] ? mias[0].persona : persona;
  const total = mias.reduce((a, v) => a + Number(v.comision_usd), 0);
  const m = abrirModal({
    titulo: `Ventas de ${nombre} · ${nombreEntidad(cliente)}`, ancho: true,
    cuerpo: `<div class="table-card"><table class="data-table"><thead><tr><th>Fecha</th><th>Alumno</th><th>Rol</th><th class="num">Monto</th>
        <th class="num">%</th><th>De dónde</th><th class="num">Comisión</th>${cerrado ? '' : '<th>% de esta venta</th>'}</tr></thead>
      <tbody>${mias.map((v, i) => `<tr><td>${fmtFecha(v.fecha)}</td><td class="ajusta">${esc(v.alumno)}</td><td>${esc(v.rol)}</td>
          <td class="num">${u(v.monto_usd)}</td><td class="num">${fmtPct(v.pct_aplicado, 2)}</td><td>${origen(v)}</td><td class="num">${u(v.comision_usd)}</td>
          ${cerrado ? '' : `<td><input type="number" min="0" max="100" step="0.01" data-i="${i}" value="${v.pct_venta ?? ''}" placeholder="${v.pct_persona ?? v.pct_base ?? ''}" style="width:90px">
            <button type="button" class="btn btn-sm" data-g="${i}">Guardar</button></td>`}</tr>`).join('') || '<tr><td colspan="8">Sin ventas</td></tr>'}
        <tr class="pnl-fuerte"><td colspan="6">Total</td><td class="num">${u(total)}</td>${cerrado ? '' : '<td></td>'}</tr></tbody></table></div>
      <div class="table-foot">Un % vacío vuelve al de la persona o al por defecto. <span class="form-error" id="v-error" role="alert"></span></div>`,
    pie: '<button type="button" class="btn" id="v-cerrar">Cerrar</button>'
  });
  m.el.querySelector('#v-cerrar').onclick = () => m.cerrar();
  for (const b of m.el.querySelectorAll('[data-g]')) b.onclick = async () => {
    const v = mias[Number(b.dataset.g)];
    const txt = m.el.querySelector(`input[data-i="${b.dataset.g}"]`).value.trim();
    const pct = txt === '' ? null : Number(txt);
    if (pct != null && !(pct >= 0 && pct <= 100)) { m.el.querySelector('#v-error').textContent = 'El porcentaje tiene que estar entre 0 y 100.'; return; }
    b.disabled = true;
    try { await pctVentaGuardar(v, pct); m.cerrar(); toast('Porcentaje de la venta guardado'); alCambiar(clave); } catch (e) {
      m.el.querySelector('#v-error').textContent = `No se pudo guardar: ${e.message}`; b.disabled = false;
    }
  };
}

/* Porcentajes por defecto y por persona. personas = [{persona, persona_norm}] de las ventas del mes. */
export function abrirPorcentajes(params, pcts, personas, alCambiar) {
  const val = c => (params.find(p => p.clave === c) || {}).valor ?? '';
  const clientes = ENTIDADES.filter(e => e[0] !== 'dystopia');
  const m = abrirModal({
    titulo: 'Porcentajes de comisión', ancho: true,
    cuerpo: `<div class="form-grid2">
        <div class="form-row"><label for="p-closer">Closer por defecto (%)</label><input type="number" id="p-closer" min="0" max="100" step="0.01" value="${val('comision_closer_pct')}"></div>
        <div class="form-row"><label for="p-setter">Setter por defecto (%)</label><input type="number" id="p-setter" min="0" max="100" step="0.01" value="${val('comision_setter_pct')}"></div>
        <div class="campo-ancho"><button type="button" class="btn btn-accent btn-sm" id="p-def">Guardar por defecto</button></div></div>
      <div class="card-titulo">Por persona</div>
      <div class="table-card"><table class="data-table"><thead><tr><th>Persona</th><th>Rol</th><th>Cliente</th><th class="num">%</th><th></th></tr></thead>
        <tbody>${pcts.map(p => `<tr><td>${esc(p.persona)}</td><td>${esc(p.rol)}</td><td>${p.cliente_id ? esc(nombreEntidad(p.cliente_id)) : 'Todos'}</td>
          <td class="num">${fmtPct(p.porcentaje, 2)}</td><td><button type="button" class="btn btn-sm" data-del="${p.id}">Quitar</button></td></tr>`).join('') || '<tr><td colspan="5">Sin porcentajes por persona</td></tr>'}</tbody></table></div>
      <div class="form-grid2">
        <div class="form-row"><label for="p-per">Persona</label><select id="p-per">${personas.map(p => `<option value="${esc(p.persona)}">${esc(p.persona)}</option>`).join('')}</select></div>
        <div class="form-row"><label for="p-rol">Rol</label><select id="p-rol"><option value="closer">Closer</option><option value="setter">Setter</option></select></div>
        <div class="form-row"><label for="p-cli">Cliente</label><select id="p-cli"><option value="">Todos</option>${clientes.map(([k, n]) => `<option value="${k}">${esc(n)}</option>`).join('')}</select></div>
        <div class="form-row"><label for="p-pct">%</label><input type="number" id="p-pct" min="0" max="100" step="0.01"></div>
        <div class="campo-ancho"><button type="button" class="btn btn-sm" id="p-add">Agregar / actualizar</button></div></div>
      <span class="form-error" id="p-error" role="alert"></span>`,
    pie: '<button type="button" class="btn" id="p-cerrar">Cerrar</button>'
  });
  const q = id => m.el.querySelector('#' + id);
  const falla = e => { q('p-error').textContent = `No se pudo guardar: ${e.message}`; };
  const listo = aviso => { m.cerrar(); toast(aviso); alCambiar(); };
  q('p-cerrar').onclick = () => m.cerrar();
  q('p-def').onclick = async () => {
    const c = Number(q('p-closer').value), s = Number(q('p-setter').value);
    if (q('p-closer').value === '' || q('p-setter').value === '' || !(c >= 0 && c <= 100 && s >= 0 && s <= 100)) { q('p-error').textContent = 'Los porcentajes tienen que estar entre 0 y 100.'; return; }
    try { await parametroGuardar('comision_closer_pct', c); await parametroGuardar('comision_setter_pct', s); listo('Porcentajes por defecto guardados'); } catch (e) { falla(e); }
  };
  for (const b of m.el.querySelectorAll('[data-del]')) b.onclick = async () => {
    try { await pctPersonaBorrar(Number(b.dataset.del)); listo('Porcentaje quitado'); } catch (e) { falla(e); }
  };
  q('p-add').onclick = async () => {
    const pct = Number(q('p-pct').value);
    if (!q('p-per').value) { q('p-error').textContent = 'No hay personas en las ventas de este mes.'; return; }
    if (q('p-pct').value === '' || !(pct >= 0 && pct <= 100)) { q('p-error').textContent = 'El porcentaje tiene que estar entre 0 y 100.'; return; }
    const persona = q('p-per').value, rol = q('p-rol').value, cli = q('p-cli').value || null;
    const norm = (personas.find(p => p.persona === persona) || {}).persona_norm;
    const ya = pcts.find(p => p.persona_norm === norm && p.rol === rol && (p.cliente_id || null) === cli);
    try { await pctPersonaGuardar(ya ? ya.id : null, ya ? { porcentaje: pct } : { persona, rol, cliente_id: cli, porcentaje: pct }); listo('Porcentaje guardado'); } catch (e) { falla(e); }
  };
}
