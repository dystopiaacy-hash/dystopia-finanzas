/* Alta y edición de un gasto (modal). El tipo de cambio de los gastos en pesos sale pre-llenado con el último usado
   y se puede editar. La base valida de nuevo todo (checks de fin_gastos). */
import { esc, abrirModal, toast, hoyAR } from '../ui.js';
import { usd } from '../datos.js';
import { ENTIDADES, REPARTOS, gastoGuardar, ultimoTipoCambio } from '../gastos.js';

const fila = (id, label, control, hint = '') =>
  `<div class="form-row"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${esc(hint)}</div>` : ''}</div>`;

/* g = gasto cargado (fila de fin_gastos) o null para uno nuevo. cats = categorías. alGuardar() recarga la pantalla. */
export async function abrirFormGasto(g, cats, alGuardar) {
  const nuevo = !g;
  const tc0 = g && g.tipo_cambio != null ? g.tipo_cambio : await ultimoTipoCambio();
  const activas = cats.filter(c => c.activa || (g && c.id === g.categoria_id));
  const v = g || { entidad: 'liam', categoria_id: activas[0] && activas[0].id, moneda: 'USD', fecha: hoyAR(), reparto: 'comision', recurrente: false };
  const opt = (arr, sel) => arr.map(([k, n]) => `<option value="${esc(k)}"${k === sel ? ' selected' : ''}>${esc(n)}</option>`).join('');

  const m = abrirModal({
    titulo: nuevo ? 'Nuevo gasto' : 'Editar gasto', ancho: true,
    cuerpo: `<form id="g-form" class="form-grid2" novalidate>
      ${fila('g-entidad', 'Entidad', `<select id="g-entidad">${opt(ENTIDADES, v.entidad)}</select>`)}
      ${fila('g-cat', 'Categoría', `<select id="g-cat">${activas.map(c => `<option value="${c.id}"${c.id === v.categoria_id ? ' selected' : ''}>${esc(c.nombre)}${c.activa ? '' : ' (desactivada)'}</option>`).join('')}</select>`)}
      <div class="campo-ancho">${fila('g-desc', 'Descripción', `<input type="text" id="g-desc" maxlength="200" autocomplete="off" value="${esc(v.descripcion || '')}">`)}</div>
      ${fila('g-monto', 'Monto', `<input type="number" id="g-monto" min="0" step="0.01" value="${v.monto ?? ''}">`)}
      ${fila('g-moneda', 'Moneda', `<select id="g-moneda">${opt([['USD', 'USD'], ['ARS', 'ARS (pesos)']], v.moneda)}</select>`)}
      <div id="g-tc-wrap">${fila('g-tc', 'Tipo de cambio (pesos por 1 USD)', `<input type="number" id="g-tc" min="0" step="0.01" value="${tc0 ?? ''}">`,
        tc0 != null && nuevo ? 'Pre-llenado con el último usado.' : '')}</div>
      ${fila('g-fecha', 'Fecha', `<input type="date" id="g-fecha" value="${esc(v.fecha || '')}">`)}
      <div class="form-row"><label>&nbsp;</label><div class="hint" id="g-eq"></div></div>
      <div>${fila('g-rec', 'Recurrente', `<label class="chk-linea"><input type="checkbox" id="g-rec"${v.recurrente ? ' checked' : ''}> Se repite todos los meses</label>`)}</div>
      <div id="g-hasta-wrap">${fila('g-hasta', 'Termina (opcional)', `<input type="date" id="g-hasta" value="${esc(v.recurrente_hasta || '')}">`, 'Si se deja vacío, sigue hasta que se dé de baja.')}</div>
      <div id="g-reparto-wrap" class="campo-ancho">${fila('g-reparto', 'Reparto', `<select id="g-reparto">${opt(REPARTOS, v.reparto)}</select>`,
        'Compartido: Dystopia paga su % de comisión de ese mes y el cliente el resto.')}</div>
      <div class="campo-ancho">${fila('g-nota', 'Nota', `<textarea id="g-nota" rows="2">${esc(v.nota || '')}</textarea>`)}</div>
      <div class="campo-ancho"><span class="form-error" id="g-error" role="alert"></span></div>
    </form>`,
    pie: `<button type="button" class="btn" id="g-cancelar">Cancelar</button>
          <button type="button" class="btn btn-accent" id="g-guardar">${nuevo ? 'Guardar gasto' : 'Guardar cambios'}</button>`
  });
  const q = id => m.el.querySelector('#' + id);

  const refrescar = () => {
    const ars = q('g-moneda').value === 'ARS';
    q('g-tc-wrap').hidden = !ars;
    q('g-hasta-wrap').hidden = !q('g-rec').checked;
    q('g-reparto-wrap').hidden = q('g-entidad').value === 'dystopia';
    const monto = Number(q('g-monto').value), tc = Number(q('g-tc').value);
    q('g-eq').textContent = monto > 0 && (!ars || tc > 0) ? `Equivale a ${usd(ars ? monto / tc : monto, { centavos: true })}` : '';
  };
  for (const id of ['g-moneda', 'g-rec', 'g-entidad', 'g-monto', 'g-tc']) { q(id).oninput = refrescar; q(id).onchange = refrescar; }
  refrescar();
  q('g-cancelar').onclick = () => m.cerrar();

  q('g-guardar').onclick = async () => {
    const err = t => { q('g-error').textContent = t; };
    const ars = q('g-moneda').value === 'ARS';
    const entidad = q('g-entidad').value;
    const monto = Number(q('g-monto').value), tc = Number(q('g-tc').value);
    const rec = q('g-rec').checked, hasta = q('g-hasta').value;
    if (!q('g-desc').value.trim()) return err('Falta la descripción.');
    if (!(monto > 0)) return err('El monto tiene que ser mayor que 0.');
    if (ars && !(tc > 0)) return err('Falta el tipo de cambio.');
    if (!q('g-fecha').value) return err('Falta la fecha.');
    if (rec && hasta && hasta < q('g-fecha').value) return err('La fecha de fin no puede ser anterior a la fecha del gasto.');
    err('');
    q('g-guardar').disabled = true;
    try {
      await gastoGuardar(g ? g.id : null, {
        entidad, categoria_id: Number(q('g-cat').value), descripcion: q('g-desc').value.trim(),
        monto, moneda: q('g-moneda').value, tipo_cambio: ars ? tc : null, fecha: q('g-fecha').value,
        recurrente: rec, recurrente_hasta: rec && hasta ? hasta : null,
        reparto: entidad === 'dystopia' ? 'dystopia' : q('g-reparto').value, nota: q('g-nota').value.trim() || null
      });
      m.cerrar();
      toast(nuevo ? 'Gasto guardado' : 'Cambios guardados');
      alGuardar();
    } catch (e) {
      err(`No se pudo guardar: ${e.message}`);
      q('g-guardar').disabled = false;
    }
  };
}
