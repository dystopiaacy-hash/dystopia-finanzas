/* Vincular alumnos de Finanzas con su ficha en Producto (129). Por cliente: pendientes (con candidatos
   sugeridos y buscador de Producto), vinculados y marcados "no está en Producto". Las RPC verifican el
   permiso (fundador o quien edita pagos del cliente); acá solo se decide qué se ofrece. Sin montos. */
import { esc, fmtFecha, toast, abrirModal } from '../ui.js';
import { clientesVinculables, nombreCliente } from '../sesion.js';
import { vinculosResumen, vinculosLista, vinculosBuscar, vinculosMarcar, vinculosAuto } from '../datos.js';
import { vacio, botonRecargar, etiquetarTablas } from './comunes.js';

const FILTROS = [['pendientes', 'Pendientes'], ['vinculados', 'Vinculados'], ['no_producto', 'No está en Producto']];
const ORIGEN = { auto_pago_clave: 'auto (pago)', auto_telefono: 'auto (teléfono)', auto_nombre: 'auto (nombre)', manual: 'manual' };

/* Cliente y filtro elegidos: se recuerdan al recargar la pantalla. */
const est = { cliente: null, filtro: 'pendientes' };

const tel = ts => (ts && ts.length ? ts.map(t => '…' + esc(t)).join(', ') : '—');

function candidatos(f) {
  const lista = f.candidatos || [];
  const botones = lista.map(c => `<button type="button" class="btn btn-sm" data-vincular="${esc(c.id)}"
      title="${esc([c.telefono, c.estado].filter(Boolean).join(' · '))}">${esc(c.nombre)}
      <span class="muted-empty">(${esc(c.motivo)})</span></button>`).join(' ');
  const aviso = f.resultado === 'ambiguo' ? '<span class="txt-rojo">Ambiguo: elegí uno</span> '
    : (lista.length ? '' : '<span class="muted-empty">Sin candidatos</span> ');
  return aviso + botones;
}

function fila(f, filtro) {
  const cuenta = `${f.n_pagos} pago${f.n_pagos === 1 ? '' : 's'} · ${f.n_cuotas} cuota${f.n_cuotas === 1 ? '' : 's'}`;
  let acciones;
  if (filtro === 'pendientes') {
    acciones = `${candidatos(f)}
      <button type="button" class="btn btn-sm" data-buscar>Buscar en Producto…</button>
      <button type="button" class="btn btn-sm" data-accion="no_producto">No está en Producto</button>`;
  } else if (filtro === 'vinculados') {
    acciones = `<strong>${esc(f.cs_nombre || '(ficha eliminada)')}</strong>
      <span class="badge badge-outline">${esc(ORIGEN[f.origen] || f.origen || '')}</span>
      <button type="button" class="btn btn-sm" data-accion="desvincular">Desvincular</button>`;
  } else {
    acciones = '<button type="button" class="btn btn-sm" data-accion="desvincular">Volver a pendientes</button>';
  }
  return `<tr data-alumno="${esc(f.alumno_norm)}" data-nombre="${esc(f.alumno)}">
    <td>${esc(f.alumno)}</td><td>${tel(f.telefonos)}</td><td>${cuenta}</td>
    <td>${f.ultimo_pago ? esc(fmtFecha(f.ultimo_pago)) : '—'}</td><td>${acciones}</td></tr>`;
}

/* Modal del buscador: la fila lleva un encabezado oculto solo para los rótulos de la tarjeta (celular). */
function filaFicha(c) {
  return `<tr>
    <td>${esc(c.nombre)}</td><td>${esc(c.telefono || '')}</td><td>${esc(c.email || '')}</td>
    <td>${esc(c.estado || '')}${c.vinculos ? ` · ya vinculada a ${c.vinculos} nombre${c.vinculos === 1 ? '' : 's'}` : ''}</td>
    <td><button type="button" class="btn btn-sm btn-accent" data-id="${esc(c.id)}">Vincular</button></td></tr>`;
}

export async function vistaVincular(el, vigente) {
  const clientes = clientesVinculables();
  if (!clientes.length) {
    el.innerHTML = vacio('No tenés clientes para vincular', 'Hace falta poder editar pagos del cliente.');
    return;
  }
  if (!clientes.includes(est.cliente)) est.cliente = clientes[0];
  const [resumen, filas] = await Promise.all([vinculosResumen(est.cliente), vinculosLista(est.cliente, est.filtro)]);
  if (!vigente()) return;

  const r = { ...(resumen || {}) };
  /* El resumen de la base cuenta solo coincidencias exactas (pago, teléfono, nombre); las filas también
     proponen "(parecido)". Con la lista de pendientes a la vista se cuenta igual que las filas. */
  if (est.filtro === 'pendientes') {
    const conCand = filas.filter(f => (f.candidatos || []).length);
    r.ambiguos = filas.filter(f => f.resultado === 'ambiguo').length;
    r.con_parecidos = conCand.filter(f => f.resultado !== 'ambiguo').length;
    r.sin_candidato = filas.length - conCand.length;
  }
  const opcionesCliente = clientes.map(c =>
    `<option value="${esc(c)}"${c === est.cliente ? ' selected' : ''}>${esc(nombreCliente(c))}</option>`).join('');
  el.innerHTML = `
    <div class="filter-row fr-apilar">
      <span class="flabel">Cliente</span><select id="vin-cliente">${opcionesCliente}</select>
      <span class="grow"></span>
      <button type="button" class="btn btn-sm" id="vin-auto">Vincular automáticamente ahora</button>
      ${botonRecargar()}
    </div>
    <p class="aviso-texto">${r.alumnos ?? 0} alumnos en Finanzas · ${r.vinculados ?? 0} vinculados
      (${r.vinculados_auto ?? 0} automáticos, ${r.vinculados_manual ?? 0} a mano) · ${r.pendientes ?? 0} pendientes
      (${r.ambiguos ?? 0} ambiguos${r.con_parecidos !== undefined ? `, ${r.con_parecidos} con candidato parecido` : ''}, ${r.sin_candidato ?? 0} sin candidato) · ${r.no_producto ?? 0} fuera de Producto
      · ${r.fichas_producto ?? 0} fichas en Producto</p>
    <div class="tabs tabs-inline tabs-vin">${FILTROS.map(([k, t]) =>
      `<button type="button" class="tab-btn${k === est.filtro ? ' active' : ''}" data-filtro="${k}">${t}</button>`).join('')}</div>
    ${filas.length ? `<div class="card table-card"><table class="data-table tabla-tarjetas tabla-apilada">
        <thead><tr><th>Alumno en Finanzas</th><th>Teléfono</th><th>Movimientos</th><th>Último pago</th>
          <th class="acciones">${est.filtro === 'pendientes' ? 'Vincular con' : est.filtro === 'vinculados' ? 'Ficha en Producto' : ''}</th></tr></thead>
        <tbody>${filas.map(f => fila(f, est.filtro)).join('')}</tbody></table></div>`
      : vacio(est.filtro === 'pendientes' ? 'No quedan alumnos pendientes' : 'No hay alumnos en esta lista')}
    <div class="table-foot">El vínculo es por cliente y nombre del alumno (sin acentos ni mayúsculas): no se pierde cuando la
      planilla se vuelve a sincronizar. La vinculación automática corre sola cada 15 minutos y solo vincula cuando hay UNA
      ficha posible por pago de origen, teléfono (últimos 8 dígitos) o nombre. Lo que vincules, desvincules o marques a mano
      no lo toca la automática. Esta pantalla no muestra montos.</div>`;

  etiquetarTablas(el);
  const recargar = () => vistaVincular(el, vigente);
  el.querySelector('#btn-recargar').onclick = recargar;
  el.querySelector('#vin-cliente').onchange = e => { est.cliente = e.target.value; recargar(); };
  for (const b of el.querySelectorAll('[data-filtro]')) b.onclick = () => { est.filtro = b.dataset.filtro; recargar(); };

  el.querySelector('#vin-auto').onclick = async e => {
    e.target.disabled = true;
    try {
      const [x] = (await vinculosAuto(est.cliente)) || [];
      toast(x ? `Vinculados ahora: ${x.vinculados} · ambiguos: ${x.ambiguos} · sin candidato: ${x.sin_candidato}`
              : 'Nada para vincular');
      recargar();
    } catch (err) {
      toast(`No se pudo vincular: ${err.message}`, 'error');
      e.target.disabled = false;
    }
  };

  const marcar = async (tr, accion, csId, boton) => {
    boton.disabled = true;
    try {
      await vinculosMarcar(est.cliente, tr.dataset.alumno, accion, csId);
      toast({ vincular: 'Alumno vinculado', desvincular: 'Alumno desvinculado', no_producto: 'Marcado como fuera de Producto' }[accion]);
      recargar();
    } catch (err) {
      toast(`No se pudo guardar: ${err.message}`, 'error');
      boton.disabled = false;
    }
  };
  for (const tr of el.querySelectorAll('tr[data-alumno]')) {
    for (const b of tr.querySelectorAll('[data-vincular]')) b.onclick = () => marcar(tr, 'vincular', b.dataset.vincular, b);
    for (const b of tr.querySelectorAll('[data-accion]')) b.onclick = () => marcar(tr, b.dataset.accion, null, b);
    const bb = tr.querySelector('[data-buscar]');
    if (bb) bb.onclick = () => buscador(tr, id => marcar(tr, 'vincular', id, bb));
  }
}

/* Modal con buscador de fichas de Producto del cliente (nombre, alias, teléfono o email). */
function buscador(tr, alElegir) {
  const m = abrirModal({
    titulo: `Buscar en Producto · ${tr.dataset.nombre}`, ancho: true,
    cuerpo: `<div class="form-row"><label for="vin-q">Nombre, teléfono o email</label>
        <input type="text" id="vin-q" autocomplete="off" maxlength="60" placeholder="Al menos 2 letras"></div>
      <div id="vin-res"><p class="aviso-texto">Escribí para buscar.</p></div>`
  });
  const q = m.el.querySelector('#vin-q');
  const res = m.el.querySelector('#vin-res');
  let t = null, n = 0;
  q.focus();
  q.oninput = () => {
    clearTimeout(t);
    t = setTimeout(async () => {
      const mi = ++n;
      if (q.value.trim().length < 2) { res.innerHTML = '<p class="aviso-texto">Escribí para buscar.</p>'; return; }
      try {
        const lista = await vinculosBuscar(est.cliente, q.value);
        if (mi !== n) return;
        res.innerHTML = lista.length
          ? `<table class="data-table tabla-tarjetas tabla-apilada">
              <thead hidden><tr><th>Nombre</th><th>Teléfono</th><th>Email</th><th>Estado</th><th class="acciones"></th></tr></thead>
              <tbody>${lista.map(filaFicha).join('')}</tbody></table>`
          : '<p class="aviso-texto">Sin resultados en este cliente.</p>';
        etiquetarTablas(res);
        for (const b of res.querySelectorAll('[data-id]')) b.onclick = () => { m.cerrar(); alElegir(b.dataset.id); };
      } catch (err) {
        if (mi === n) res.innerHTML = `<p class="aviso-texto txt-rojo">${esc(err.message)}</p>`;
      }
    }, 250);
  };
}
