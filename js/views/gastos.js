/* Panel Gastos (fundador; quien tenga gastos / edita_gastos en fin_dys_acceso). Lista del mes con el reparto
   Dystopia / cliente, totales por mes, entidad y categoría (USD; ARS convertido con el tipo de cambio de cada
   gasto) y alta / edición / baja lógica. El gasto de IA aparece solo (fila «Automático») como categoría IA de
   cada cliente: no se carga ni se edita acá. Datos de fin_v_gastos_mes (migración 174). */
import { esc, fmtPct, confirmar, toast, fmtFecha } from '../ui.js';
import { usd } from '../datos.js';
import { gastosMes, gastosCargados, categorias, gastoBaja, editaGastos, nombreEntidad, nombreFila, nombreReparto, sumar, claveMes, mesesDe,
  etiquetaMes, ENTIDADES, descGasto, llamadas } from '../gastos.js';
import { vacio, botonRecargar, etiquetarTablas } from './comunes.js';
import { abrirFormGasto } from './gastos-form.js';
import { abrirCategorias } from './gastos-categorias.js';

const u = n => usd(n, { centavos: true });
/* Filas de IA automática: hasta 4 decimales (US$ 0,0034), mínimo 2. El resto y los totales, 2 decimales. */
const fmtIa = new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'USD', minimumFractionDigits: 2, maximumFractionDigits: 4 });
const uf = (x, n) => (x.origen === 'ia_auto' && n != null && !isNaN(n) ? fmtIa.format(Number(n)) : u(n));

function totales(filas, clave, etiqueta) {
  const m = new Map();
  for (const f of filas) {
    const k = clave(f);
    const a = m.get(k) || { k, total: 0, dys: 0, cli: 0 };
    a.total += Number(f.monto_usd) || 0; a.dys += Number(f.usd_dystopia) || 0; a.cli += Number(f.usd_cliente) || 0;
    m.set(k, a);
  }
  return [...m.values()].map(a => `<tr><td class="ajusta">${esc(etiqueta(a.k))}</td><td class="num">${u(a.total)}</td><td class="num">${u(a.dys)}</td><td class="num">${u(a.cli)}</td></tr>`).join('');
}
const tablaTot = (titulo, cabecera, cuerpo) => `<div><div class="card-titulo">${esc(titulo)}</div><div class="card table-card"><table class="data-table tabla-tarjetas">
  <thead><tr><th>${esc(cabecera)}</th><th class="num clave">Total</th><th class="num">Dystopia</th><th class="num">Cliente</th></tr></thead>
  <tbody>${cuerpo || '<tr><td colspan="4">Sin gastos</td></tr>'}</tbody></table></div></div>`;

export async function vistaGastos(el, vigente) {
  const [filas, cargados, cats] = await Promise.all([gastosMes(), gastosCargados(), categorias()]);
  if (!vigente()) return;
  const puede = editaGastos();
  const porId = new Map(cargados.map(g => [g.id, g]));
  const meses = mesesDe(filas);
  const estado = { mes: meses[0] || '', entidad: '', cat: '' };

  const recargar = (reabrirCats = false) => vistaGastos(el, vigente).then(() => { if (reabrirCats) botonCats(); });
  const botonCats = () => { const b = el.querySelector('#btn-cats'); if (b) b.click(); };

  const pintar = () => {
    const f = filas.filter(x => (!estado.mes || claveMes(x.mes) === estado.mes)
      && (!estado.entidad || (estado.entidad === 'sin_asignar' ? x.sin_asignar : x.entidad === estado.entidad))
      && (!estado.cat || String(x.categoria_id) === estado.cat));
    const asignados = f;   // la IA sin asignar es de Dystopia y suma como cualquier gasto suyo
    const sinAsig = f.filter(x => x.sin_asignar);
    const sinCom = f.filter(x => x.falta_comision);
    const bajas = cargados.filter(g => !g.activo);

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Mes</span>
        <select id="f-mes"><option value="">Todos</option>${meses.map(m => `<option value="${m}"${m === estado.mes ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('')}</select>
        <span class="flabel">Entidad</span>
        <select id="f-ent"><option value="">Todas</option>${ENTIDADES.map(([k, n]) => `<option value="${k}"${k === estado.entidad ? ' selected' : ''}>${esc(n)}</option>`).join('')}<option value="sin_asignar"${estado.entidad === 'sin_asignar' ? ' selected' : ''}>Sin asignar → Dystopia</option></select>
        <span class="flabel">Categoría</span>
        <select id="f-cat"><option value="">Todas</option>${cats.map(c => `<option value="${c.id}"${String(c.id) === estado.cat ? ' selected' : ''}>${esc(c.nombre)}</option>`).join('')}</select>
        <span class="grow"></span>
        <button type="button" class="btn btn-sm" id="btn-cats">${puede ? 'Categorías' : 'Ver categorías'}</button>
        ${puede ? '<button type="button" class="btn btn-sm btn-accent" id="btn-nuevo">+ Nuevo gasto</button>' : ''}
        ${botonRecargar()}
      </div>
      ${sinAsig.length ? `<div class="card nota aviso-ambar">IA sin asignar a un cliente: <strong>${u(sumar(sinAsig, 'monto_usd'))}</strong>.
        Está cargada 100% a Dystopia y ya suma en los totales de abajo. Ver detalle en <a href="#/ia-uso">Gasto de IA</a>.</div>` : ''}
      ${sinCom.length ? `<div class="card nota aviso-ambar">Hay gastos compartidos sin porcentaje de comisión vigente en su mes: Dystopia figura en 0.</div>` : ''}
      <div class="grid-3 stat-grid">
        <div class="stat-card"><div class="stat-num">${u(sumar(asignados, 'monto_usd'))}</div><div class="stat-label">Total de gastos</div></div>
        <div class="stat-card"><div class="stat-num">${u(sumar(asignados, 'usd_dystopia'))}</div><div class="stat-label">Paga Dystopia</div></div>
        <div class="stat-card"><div class="stat-num">${u(sumar(asignados, 'usd_cliente'))}</div><div class="stat-label">Pagan los clientes</div></div>
      </div>
      <div class="grid-2">
        ${tablaTot('Por entidad', 'Entidad', totales(asignados, x => x.entidad, nombreEntidad))}        ${tablaTot('Por categoría', 'Categoría', totales(asignados, x => x.categoria || 'Sin categoría', n => n))}
      </div>
      ${estado.mes ? '' : tablaTot('Por mes', 'Mes', totales(asignados, x => claveMes(x.mes), etiquetaMes))}
      <div class="card-titulo">Detalle</div>
      ${f.length ? `<div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Mes</th><th>Entidad</th><th>Categoría</th><th>Descripción</th><th class="num">Monto</th><th class="num clave">USD</th>
          <th>Reparto</th><th class="num">Dystopia</th><th class="num">Cliente</th><th></th></tr></thead>
        <tbody>${f.map(x => `<tr class="${x.sin_asignar ? 'fila-alerta' : ''}">
          <td>${esc(etiquetaMes(claveMes(x.mes)))}</td><td>${esc(nombreFila(x))}</td><td class="ajusta">${esc(x.categoria || '—')}</td>
          <td class="ajusta">${esc(descGasto(x))}${x.recurrente ? ' <span class="badge">Mensual</span>' : ''}${x.origen === 'ia_auto' ? ' <span class="badge">Automático</span>' : ''}
            ${x.llamadas_sin_costo > 0 ? `<div class="hint">${llamadas(x.llamadas_sin_costo)} sin costo registrado</div>` : ''}
            ${x.nota ? `<div class="hint">${esc(x.nota)}</div>` : ''}</td>
          <td class="num">${x.moneda === 'ARS' ? `ARS ${Number(x.monto_original).toLocaleString('es-AR')}<div class="hint">a ${Number(x.tipo_cambio).toLocaleString('es-AR')}</div>` : uf(x, x.monto_original)}</td>
          <td class="num">${uf(x, x.monto_usd)}</td>
          <td>${esc(nombreReparto(x.reparto))}${x.reparto === 'comision' ? `<div class="hint">${fmtPct(x.porcentaje_dystopia, 1)} Dystopia</div>` : ''}</td>
          <td class="num">${uf(x, x.usd_dystopia)}</td><td class="num">${uf(x, x.usd_cliente)}</td>
          <td>${puede && x.origen === 'manual' ? `<button type="button" class="btn btn-sm" data-editar="${x.gasto_id}">Editar</button>
            <button type="button" class="btn btn-sm btn-danger" data-baja="${x.gasto_id}">Dar de baja</button>` : ''}</td></tr>`).join('')}</tbody>
      </table></div>` : vacio('No hay gastos con estos filtros', puede ? 'Cargá uno con «Nuevo gasto».' : '')}
      <div class="table-foot">Los gastos en pesos se pasan a USD con el tipo de cambio de cada gasto. Un gasto mensual se repite desde su fecha hasta su fecha de fin
        (o hasta el mes actual). «Compartido según comisión»: Dystopia paga el % de comisión vigente en cada mes y el cliente el resto.</div>
      ${bajas.length ? `<div class="card-titulo">Dados de baja</div><div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th>Fecha</th><th>Entidad</th><th>Descripción</th><th class="num clave">Monto</th><th></th></tr></thead><tbody>
        ${bajas.map(g => `<tr><td>${esc(fmtFecha(g.fecha))}</td><td>${esc(nombreEntidad(g.entidad))}</td><td class="ajusta">${esc(g.descripcion)}</td>
          <td class="num">${g.moneda} ${Number(g.monto).toLocaleString('es-AR')}</td>
          <td>${puede ? `<button type="button" class="btn btn-sm" data-reactivar="${g.id}">Reactivar</button>` : ''}</td></tr>`).join('')}</tbody></table></div>` : ''}`;

    etiquetarTablas(el);
    el.querySelector('#f-mes').onchange = e => { estado.mes = e.target.value; pintar(); };
    el.querySelector('#f-ent').onchange = e => { estado.entidad = e.target.value; pintar(); };
    el.querySelector('#f-cat').onchange = e => { estado.cat = e.target.value; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => recargar();
    el.querySelector('#btn-cats').onclick = () => abrirCategorias(cats, r => recargar(r === true));
    const nuevo = el.querySelector('#btn-nuevo');
    if (nuevo) nuevo.onclick = () => abrirFormGasto(null, cats, recargar);
    for (const b of el.querySelectorAll('[data-editar]')) b.onclick = () => abrirFormGasto(porId.get(Number(b.dataset.editar)), cats, recargar);
    for (const b of el.querySelectorAll('[data-baja]')) b.onclick = async () => {
      const g = porId.get(Number(b.dataset.baja));
      if (!await confirmar({ titulo: 'Dar de baja el gasto', texto: `«${g.descripcion}» deja de contarse en todos los meses. Se puede reactivar.`, ok: 'Dar de baja' })) return;
      try { await gastoBaja(g.id, false); toast('Gasto dado de baja'); recargar(); } catch (e) { toast(`No se pudo: ${e.message}`, 'error'); }
    };
    for (const b of el.querySelectorAll('[data-reactivar]')) b.onclick = async () => {
      try { await gastoBaja(Number(b.dataset.reactivar), true); toast('Gasto reactivado'); recargar(); } catch (e) { toast(`No se pudo: ${e.message}`, 'error'); }
    };
  };
  pintar();
}
