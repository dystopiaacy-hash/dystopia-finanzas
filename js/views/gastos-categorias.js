/* Categorías de gasto editables: alta, renombrar y desactivar/activar (modal). La categoría con clave 'ia' es
   donde cae el gasto de IA automático: se puede renombrar pero no desactivar. */
import { esc, abrirModal, toast } from '../ui.js';
import { categoriaGuardar } from '../gastos.js';

export function abrirCategorias(cats, alCambiar) {
  const m = abrirModal({
    titulo: 'Categorías de gasto',
    cuerpo: `<div id="cat-lista"></div>
      <div class="form-row" style="margin-top:var(--sp-3)"><label for="cat-nueva">Nueva categoría</label>
        <div class="filter-row"><input type="text" id="cat-nueva" maxlength="60" autocomplete="off" placeholder="Nombre">
          <button type="button" class="btn btn-accent btn-sm" id="cat-alta">Agregar</button></div></div>
      <span class="form-error" id="cat-error" role="alert"></span>`
  });
  const q = id => m.el.querySelector('#' + id);
  const error = t => { q('cat-error').textContent = t; };
  let actuales = cats;

  const pintar = () => {
    q('cat-lista').innerHTML = `<table class="data-table"><tbody>${actuales.map(c => `<tr data-id="${c.id}">
      <td><input type="text" value="${esc(c.nombre)}" maxlength="60" data-nombre aria-label="Nombre"></td>
      <td>${c.clave === 'ia' ? '<span class="hint">IA automática</span>' : ''}</td>
      <td>${c.activa ? '' : '<span class="txt-ambar">Desactivada</span>'}</td>
      <td><button type="button" class="btn btn-sm" data-guardar>Renombrar</button>
        ${c.clave === 'ia' ? '' : `<button type="button" class="btn btn-sm" data-toggle>${c.activa ? 'Desactivar' : 'Activar'}</button>`}</td></tr>`).join('')}</tbody></table>`;
    for (const tr of q('cat-lista').querySelectorAll('tr[data-id]')) {
      const c = actuales.find(x => x.id === Number(tr.dataset.id));
      tr.querySelector('[data-guardar]').onclick = () => cambiar(c, { nombre: tr.querySelector('[data-nombre]').value.trim() });
      const t = tr.querySelector('[data-toggle]');
      if (t) t.onclick = () => cambiar(c, { activa: !c.activa });
    }
  };
  async function cambiar(c, campos) {
    if ('nombre' in campos && !campos.nombre) return error('El nombre no puede quedar vacío.');
    try {
      await categoriaGuardar(c.id, campos);
      Object.assign(c, campos);
      error(''); toast('Categoría guardada'); pintar(); alCambiar();
    } catch (e) {
      error(/duplicate|unique/i.test(e.message) ? 'Ya existe una categoría con ese nombre.' : `No se pudo guardar: ${e.message}`);
    }
  }
  q('cat-alta').onclick = async () => {
    const nombre = q('cat-nueva').value.trim();
    if (!nombre) return error('Escribí un nombre.');
    try {
      await categoriaGuardar(null, { nombre, orden: Math.max(0, ...actuales.map(c => c.orden)) + 10 });
      q('cat-nueva').value = ''; error('');
      toast('Categoría agregada');
      alCambiar(true);   // recarga desde la base y vuelve a abrir con la lista nueva
      m.cerrar();
    } catch (e) {
      error(/duplicate|unique/i.test(e.message) ? 'Ya existe una categoría con ese nombre.' : `No se pudo guardar: ${e.message}`);
    }
  };
  pintar();
}
