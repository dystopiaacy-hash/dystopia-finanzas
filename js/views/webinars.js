/* Webinars (fundador, o quien figure en fin_dys_acceso). Un registro por webinar con sus ingresos (pagos con fuente
   webinar / replay en la ventana + ajustes), sus gastos por concepto y el resultado (ganancia, ROAS, costo).
   Los gastos que no están ya en Opps suman también a los gastos del cliente del mes (ver Dystopia). Migración 267. */
import { esc, fmtFecha, fmtNum, confirmar, toast } from '../ui.js';
import { usd } from '../datos.js';
import { nombreEntidad, editaGastos, sumar } from '../gastos.js';
import { webinarsResultado, webinarGastos, webinarAjustes, webinarReglas, pagosSinFuente, nombreConcepto, nombreTipo,
  gastoWebinarBaja, ajusteBaja, ajusteGuardar, webinarBaja, cargarReglas } from '../webinars.js';
import { statCard, vacio, botonRecargar, etiquetarTablas } from './comunes.js';
import { abrirFormWebinar, abrirFormGastoWebinar, abrirFormAjuste } from './webinars-form.js';

const u = n => usd(n, { centavos: true });
const gan = n => `<span class="${n < 0 ? 'txt-rojo' : ''}">${u(n)}</span>`;
const roas = r => (r == null ? '—' : `${String(Number(r).toFixed(1)).replace('.', ',')}x`);
const num = n => (n == null ? '—' : fmtNum(n));

export async function vistaWebinars(el, vigente, sel = null) {
  const [webs, reglas] = await Promise.all([webinarsResultado(), webinarReglas().catch(() => [])]);
  if (!vigente()) return;
  const puede = editaGastos();
  const estado = { cliente: '', id: sel };
  const recargar = () => vistaWebinars(el, vigente, estado.id);

  const detalle = async w => {
    const [gastos, ajustes] = await Promise.all([webinarGastos(w.webinar_id), webinarAjustes(w.webinar_id)]);
    const porConcepto = new Map();
    for (const g of gastos.filter(x => x.activo)) porConcepto.set(g.concepto, (porConcepto.get(g.concepto) || 0) + Number(g.monto_usd));
    const filaG = g => `<tr class="${g.activo ? '' : 'fila-baja'}">
      <td class="ajusta">${esc(nombreConcepto(g.concepto))}</td><td class="num">${u(g.monto_usd)}</td><td>${fmtFecha(g.fecha)}</td>
      <td class="ajusta">${esc(g.fuente || '—')}</td>
      <td class="ajusta">${g.en_opps ? '<span class="badge">Ya en Opps</span> ' : ''}${esc(g.nota || '')}${g.activo ? '' : ' (baja)'}</td>
      <td class="acciones">${puede ? (g.activo ? `<button class="btn btn-sm" data-ge="${g.id}">Editar</button> <button class="btn btn-sm" data-gb="${g.id}">Dar de baja</button>`
        : `<button class="btn btn-sm" data-gr="${g.id}">Reactivar</button>`) : ''}</td></tr>`;
    const filaA = a => `<tr class="${a.activo ? '' : 'fila-baja'}">
      <td class="ajusta">${esc(nombreTipo(a.tipo))}</td><td class="ajusta">${esc(a.concepto)}${a.pago_clave ? ' (pago asignado)' : ''}</td>
      <td class="num">${u(a.monto_usd)}</td><td class="ajusta">${esc(a.nota || '')}${a.activo ? '' : ' (no se cuenta)'}</td>
      <td class="acciones">${puede ? (a.activo ? `<button class="btn btn-sm" data-ae="${a.id}">Editar</button> <button class="btn btn-sm" data-ab="${a.id}">Quitar</button>`
        : `<button class="btn btn-sm" data-ar="${a.id}">Activar</button>`) : ''}</td></tr>`;
    return { gastos, ajustes, porConcepto, filaG, filaA };
  };

  const pintar = async () => {
    const lista = webs.filter(w => !estado.cliente || w.cliente_id === estado.cliente);
    const actual = lista.find(w => w.webinar_id === estado.id) || null;
    if (!actual) estado.id = null;
    const tot = k => sumar(lista, k);
    const clientes = [...new Set(webs.map(w => w.cliente_id))];

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Cliente</span>
        <select id="wb-cli"><option value="">Todos</option>${clientes.map(c => `<option value="${c}"${c === estado.cliente ? ' selected' : ''}>${esc(nombreEntidad(c))}</option>`).join('')}</select>
        <span class="grow"></span>
        ${puede ? '<button type="button" class="btn btn-accent btn-sm" id="wb-nuevo">+ Nuevo webinar</button>' : ''}
        ${botonRecargar()}
      </div>
      <div class="grid-3 stat-grid">
        ${statCard(u(tot('cash_usd')), 'Cash de los webinars', { sub: `${lista.length} webinars; ventas probables aparte` })}
        ${statCard(u(tot('gastos_usd')), 'Gastos de los webinars', { sub: 'Incluye lo que ya está en Opps' })}
        ${statCard(u(tot('ganancia_usd')), 'Ganancia', { alerta: tot('ganancia_usd') < 0 })}
      </div>
      ${lista.length ? `<div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th class="titulo">Webinar</th><th>Cliente</th><th>Fecha</th><th>Replay</th><th class="num">Cash</th><th class="num">Probable</th>
          <th class="num">Gastos</th><th class="num clave">Ganancia</th><th class="num">ROAS</th></tr></thead>
        <tbody>${lista.map(w => `<tr data-id="${w.webinar_id}" class="${w.webinar_id === estado.id ? 'fila-activa' : ''}" style="cursor:pointer">
          <td class="ajusta">${esc(w.nombre)}</td><td>${esc(nombreEntidad(w.cliente_id))}</td><td>${fmtFecha(w.fecha)}</td><td>${fmtFecha(w.fecha_replay)}</td>
          <td class="num">${u(w.cash_usd)}</td><td class="num">${w.ingreso_probable_usd > 0 ? u(w.ingreso_probable_usd) : '—'}</td>
          <td class="num">${u(w.gastos_usd)}</td><td class="num">${gan(Number(w.ganancia_usd))}</td><td class="num">${roas(w.roas)}</td></tr>`).join('')}</tbody>
      </table></div>
      <div class="table-foot">Tocá un webinar para ver el detalle. Cash = pagos con fuente webinar o replay dentro de la ventana + ajustes de pagos. ROAS = cash / ads (webinar + replay).
        Costo total = todos los gastos del webinar.</div>` : vacio('No hay webinars', puede ? 'Creá uno con «Nuevo webinar».' : '')}
      <div id="wb-detalle"></div>`;
    etiquetarTablas(el);

    el.querySelector('#wb-cli').onchange = e => { estado.cliente = e.target.value; pintar(); };
    el.querySelector('#btn-recargar').onclick = () => recargar();
    const nuevo = el.querySelector('#wb-nuevo');
    if (nuevo) nuevo.onclick = () => abrirFormWebinar(null, recargar);
    for (const tr of el.querySelectorAll('tr[data-id]')) tr.onclick = () => { estado.id = Number(tr.dataset.id); pintar(); };
    if (actual) await pintarDetalle(actual);
  };

  const pintarDetalle = async w => {
    const d = await detalle(w);
    if (!vigente()) return;
    const caja = el.querySelector('#wb-detalle');
    const diasVentana = `${fmtFecha(w.ventana_desde)} al ${fmtFecha(w.ventana_hasta)}`;
    const dif = w.cash_vs_informado_usd;
    caja.innerHTML = `
      <div class="card-titulo">${esc(w.nombre)} · ${esc(nombreEntidad(w.cliente_id))} · ${fmtFecha(w.fecha)}
        ${puede ? '<button type="button" class="btn btn-sm" id="wb-editar">Editar webinar</button> <button type="button" class="btn btn-sm" id="wb-baja">Dar de baja</button>' : ''}</div>
      <div class="grid-3 stat-grid">
        ${statCard(u(w.cash_usd), 'Ingresos (cash)', { sub: `Pagos ${u(w.ingreso_pagos_usd)} (${w.pagos_n}) + ajustes ${u(w.ingreso_ajustes_usd)}` })}
        ${statCard(u(w.gastos_usd), 'Gastos / costo total', { sub: w.gastos_en_opps_usd > 0 ? `${u(w.gastos_en_opps_usd)} ya están en Opps` : 'Todos suman al cliente' })}
        ${statCard(u(w.ganancia_usd), 'Ganancia', { alerta: w.ganancia_usd < 0, sub: w.ingreso_probable_usd > 0 ? `Con probables: ${u(w.ganancia_con_probables_usd)}` : '' })}
        ${statCard(roas(w.roas), 'ROAS (cash / ads)', { sub: `Ads ${u(w.ads_usd)}` })}
        ${statCard(`${num(w.registrados)} / ${num(w.asistentes)}`, 'Registrados / asistentes', { sub: `Compradores ${num(w.compradores)} · Llamadas ${num(w.llamadas)}` })}
        ${statCard(w.cash_informado == null ? '—' : u(w.cash_informado), 'Cash informado (métricas)', { sub: dif == null ? '' : (Math.abs(dif) < 1 ? 'Coincide con la app' : `La app difiere en ${u(dif)}: ver pagos sin fuente`) })}
      </div>
      <div class="table-foot">Ventana de ingresos: ${esc(diasVentana)}. ${w.nota ? esc(w.nota) : ''}</div>

      <div class="card-titulo">Gastos por concepto
        ${puede ? `<button type="button" class="btn btn-sm" id="wb-gasto">+ Gasto</button> <button type="button" class="btn btn-sm" id="wb-reglas">Cargar Zoom y landing (reglas fijas)</button>` : ''}</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th class="titulo">Concepto</th><th class="num clave">Monto</th><th>Fecha</th><th>Fuente</th><th class="largo">Nota</th><th class="acciones"></th></tr></thead>
        <tbody>${d.gastos.length ? d.gastos.map(d.filaG).join('') : '<tr><td colspan="6">Sin gastos cargados: la ganancia está sobreestimada.</td></tr>'}</tbody></table></div>
      <div class="table-foot">Un gasto se carga una sola vez, acá. «Ya en Opps» = figura en los gastos de Opps del mes: cuenta para este webinar pero no se suma otra vez a los gastos del cliente.</div>

      <div class="card-titulo">Ajustes de ingreso
        ${puede ? `<button type="button" class="btn btn-sm" id="wb-ajuste">+ Ajuste</button> <button type="button" class="btn btn-sm" id="wb-sinfuente">Asignar pagos sin fuente</button>` : ''}</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th class="titulo">Tipo</th><th>Concepto</th><th class="num clave">Monto</th><th class="largo">Nota</th><th class="acciones"></th></tr></thead>
        <tbody>${d.ajustes.length ? d.ajustes.map(d.filaA).join('') : '<tr><td colspan="5">Sin ajustes.</td></tr>'}</tbody></table></div>
      <div id="wb-sf"></div>`;
    etiquetarTablas(caja);

    const q = s => caja.querySelector(s);
    const ge = new Map(d.gastos.map(g => [g.id, g])), ae = new Map(d.ajustes.map(a => [a.id, a]));
    const act = (fn, ok) => async () => { try { await fn(); toast(ok); recargar(); } catch (e) { toast(`No se pudo: ${e.message}`, 'error'); } };
    if (q('#wb-editar')) q('#wb-editar').onclick = () => abrirFormWebinar(w, recargar);
    if (q('#wb-baja')) q('#wb-baja').onclick = async () => {
      if (!await confirmar({ titulo: 'Dar de baja el webinar', texto: `«${w.nombre}» deja de listarse y sus gastos dejan de sumar al cliente.`, ok: 'Dar de baja' })) return;
      act(() => webinarBaja(w.webinar_id), 'Webinar dado de baja')();
    };
    if (q('#wb-gasto')) q('#wb-gasto').onclick = () => abrirFormGastoWebinar(w, null, recargar);
    if (q('#wb-ajuste')) q('#wb-ajuste').onclick = () => abrirFormAjuste(w, null, recargar);
    if (q('#wb-reglas')) q('#wb-reglas').onclick = async () => {
      try { const n = await cargarReglas(w, reglas, d.gastos); toast(n ? `${n} gasto(s) de regla cargados` : 'Ya estaban cargados'); recargar(); } catch (e) { toast(`No se pudo: ${e.message}`, 'error'); }
    };
    for (const b of caja.querySelectorAll('[data-ge]')) b.onclick = () => abrirFormGastoWebinar(w, ge.get(Number(b.dataset.ge)), recargar);
    for (const b of caja.querySelectorAll('[data-gb]')) b.onclick = act(() => gastoWebinarBaja(Number(b.dataset.gb), false), 'Gasto dado de baja');
    for (const b of caja.querySelectorAll('[data-gr]')) b.onclick = act(() => gastoWebinarBaja(Number(b.dataset.gr), true), 'Gasto reactivado');
    for (const b of caja.querySelectorAll('[data-ae]')) b.onclick = () => abrirFormAjuste(w, ae.get(Number(b.dataset.ae)), recargar);
    for (const b of caja.querySelectorAll('[data-ab]')) b.onclick = act(() => ajusteBaja(Number(b.dataset.ab), false), 'Ajuste quitado');
    for (const b of caja.querySelectorAll('[data-ar]')) b.onclick = act(() => ajusteBaja(Number(b.dataset.ar), true), 'Ajuste activado');
    if (q('#wb-sinfuente')) q('#wb-sinfuente').onclick = () => pagosCandidatos(w, d.ajustes, q('#wb-sf'), recargar);
  };

  await pintar();
}

/* Pagos de la ventana sin fuente: se asignan al webinar con un clic (queda un ajuste con la clave del pago; el monto se lee del pago). */
async function pagosCandidatos(w, ajustes, caja, recargar) {
  caja.innerHTML = '<div class="table-foot">Buscando pagos sin fuente…</div>';
  try {
    const ya = new Set(ajustes.filter(a => a.activo && a.pago_clave).map(a => a.pago_clave));
    const pagos = (await pagosSinFuente(w.cliente_id, w.ventana_desde, w.ventana_hasta)).filter(p => !ya.has(p.clave));
    if (!pagos.length) { caja.innerHTML = '<div class="table-foot">No hay pagos sin fuente en la ventana.</div>'; return; }
    caja.innerHTML = `<div class="card-titulo">Pagos sin fuente en la ventana (${pagos.length}, ${u(pagos.reduce((a, p) => a + Number(p.monto_usd), 0))})</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas"><thead><tr><th class="titulo">Alumno</th><th>Fecha</th><th>Concepto</th><th class="num clave">Monto</th><th class="acciones"></th></tr></thead>
      <tbody>${pagos.map((p, i) => `<tr><td class="ajusta">${esc(p.alumno)}</td><td>${fmtFecha(p.fecha)}</td><td>${esc(p.concepto || '—')}</td>
        <td class="num">${u(p.monto_usd)}</td><td class="acciones"><button class="btn btn-sm" data-asig="${i}">Asignar al webinar</button></td></tr>`).join('')}</tbody></table></div>`;
    etiquetarTablas(caja);
    for (const b of caja.querySelectorAll('[data-asig]')) b.onclick = async () => {
      const p = pagos[Number(b.dataset.asig)];
      b.disabled = true;
      try {
        await ajusteGuardar(null, { webinar_id: w.webinar_id, tipo: 'pago_sin_fuente', concepto: `${p.alumno} (${p.concepto || 'pago'})`, monto_usd: p.monto_usd, pago_clave: p.clave, nota: 'Asignado a mano desde la pantalla' });
        toast('Pago asignado'); recargar();
      } catch (e) { b.disabled = false; toast(`No se pudo: ${e.message}`, 'error'); }
    };
  } catch (e) { caja.innerHTML = `<div class="table-foot">No se pudo leer: ${esc(e.message)}</div>`; }
}
