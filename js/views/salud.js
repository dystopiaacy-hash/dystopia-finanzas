/* Salud de sincronización (solo fundador). Última corrida de cada fuente.
   requiere_revision de fin_v_salud_sync solo marca 'revisar'; acá error,
   parcial, colgada y nunca corrió se muestran con el MISMO peso que revisar
   (tarjeta grande arriba, mismo tamaño) y error va primero: una fuente caída
   no puede verse menos urgente que un total que no cuadra. */
import { esc, fmtFechaHora, toast, confirmar, abrirModal } from '../ui.js';
import { salud, corridas, rechazadas, fuentes, sincronizarAhora, numCelda, usd, MESES } from '../datos.js';
import { vacio, clienteChip, badgeEstado, estadoFuente, requiereAccion, ESTADOS, botonRecargar } from './comunes.js';

const TIPOS = { pagos: 'Pagos', opps: 'Opps (P&L)', cuotas: 'Cuotas' };
const num = v => (v == null ? '—' : String(v));

export async function vistaSalud(el, vigente) {
  const [filas, mapaFuentes] = await Promise.all([salud(), fuentes()]);
  if (!vigente()) return;
  if (!filas.length) { el.innerHTML = vacio('No hay fuentes configuradas'); return; }
  const conEstado = filas.map(f => ({ ...f, clave: estadoFuente(f) }))
    .sort((a, b) => (ESTADOS[a.clave].orden - ESTADOS[b.clave].orden) || a.cliente_id.localeCompare(b.cliente_id));
  const urgentes = conEstado.filter(f => requiereAccion(f.clave));
  const resto = conEstado.filter(f => !requiereAccion(f.clave));
  const cuenta = clave => conEstado.filter(f => f.clave === clave).length;

  el.innerHTML = `
    <div class="filter-row">
      <button type="button" class="btn btn-accent" id="btn-sync">Sincronizar todo ahora</button>
      <button type="button" class="btn" id="btn-dry">Probar sin escribir</button>
      <span class="grow"></span>${botonRecargar()}
    </div>
    <div class="salud-banner ${urgentes.length ? 'hay' : 'nada'}">
      ${urgentes.length
        ? `<strong>${urgentes.length} ${urgentes.length === 1 ? 'fuente requiere' : 'fuentes requieren'} acción</strong>
           ${['error', 'colgada', 'parcial', 'sin_corridas', 'revisar', 'desactualizada'].filter(cuenta)
             .map(c => `${badgeEstado(c)} ${cuenta(c)}`).join(' ')}`
        : '<strong>Todas las fuentes activas sincronizaron bien.</strong>'}
    </div>
    <div class="salud-grid">${urgentes.map(f => tarjeta(f, mapaFuentes)).join('')}</div>
    ${resto.length ? `
      <div class="section-title">Sin problemas<span class="line"></span></div>
      <div class="card table-card">
        <table class="data-table">
          <thead><tr><th>Cliente</th><th>Hoja</th><th>Estado</th><th>Última corrida</th>
            <th class="num">Leídas</th><th class="num">Cargadas</th><th class="num">Rechazadas</th><th></th></tr></thead>
          <tbody>${resto.map(f => `<tr>
            <td>${clienteChip(f.cliente_id)}</td><td>${esc(TIPOS[f.tipo] || f.tipo)} · ${esc(f.nombre_hoja_esperado)}</td>
            <td>${badgeEstado(f.clave)}</td><td>${fmtFechaHora(f.inicio)}</td>
            <td class="num">${num(f.filas_leidas)}</td><td class="num">${num(f.filas_cargadas)}</td><td class="num">${num(f.filas_rechazadas)}</td>
            <td>${f.corrida_id ? `<button type="button" class="btn btn-sm" data-hist="${f.fuente_id}">Historial</button>` : ''}</td>
          </tr>`).join('')}</tbody>
        </table>
      </div>` : ''}`;

  el.querySelector('#btn-recargar').onclick = () => vistaSalud(el, vigente);
  el.querySelector('#btn-sync').onclick = e => correr(e.target, {}, el, vigente);
  el.querySelector('#btn-dry').onclick = e => correr(e.target, { dry_run: true }, el, vigente);
  for (const b of el.querySelectorAll('[data-reintentar]')) {
    b.onclick = () => correr(b, { fuente_id: Number(b.dataset.reintentar) }, el, vigente);
  }
  for (const b of el.querySelectorAll('[data-aceptar]')) {
    b.onclick = async () => {
      const ok = await confirmar({
        titulo: 'Aceptar el encabezado nuevo',
        texto: 'La próxima lectura va a tomar la estructura actual de la hoja como buena y va a reemplazar los datos de esta fuente.',
        detalle: 'Hacelo solo si revisaste la hoja y el cambio de columnas es correcto.',
        ok: 'Aceptar y sincronizar', peligro: false
      });
      if (ok) correr(b, { fuente_id: Number(b.dataset.aceptar), aceptar_encabezado: true }, el, vigente);
    };
  }
  for (const b of el.querySelectorAll('[data-rech]')) b.onclick = () => verRechazadas(Number(b.dataset.rech), mapaFuentes.get(Number(b.dataset.fuente)));
  for (const b of el.querySelectorAll('[data-hist]')) b.onclick = () => verHistorial(Number(b.dataset.hist));
}

function tarjeta(f, mapaFuentes) {
  const e = ESTADOS[f.clave];
  const fuente = mapaFuentes.get(f.fuente_id);
  const controles = Array.isArray(f.controles) ? f.controles : [];
  const encabezado = f.clave === 'error' && /encabezado/i.test(f.mensaje || '');
  return `
    <div class="card salud-card sem-${e.nivel}">
      <div class="salud-head">
        ${badgeEstado(f.clave)}${clienteChip(f.cliente_id)}
        <span class="salud-hoja">${esc(TIPOS[f.tipo] || f.tipo)} · ${esc(f.nombre_hoja_esperado)}</span>
      </div>
      <div class="salud-msg">${esc(mensajeDe(f))}</div>
      ${f.corrida_id ? `<div class="salud-nums">
        <span>Última: <strong>${fmtFechaHora(f.inicio)}</strong></span>
        <span>Leídas <strong>${num(f.filas_leidas)}</strong></span>
        <span>Cargadas <strong>${num(f.filas_cargadas)}</strong></span>
        <span>Rechazadas <strong>${num(f.filas_rechazadas)}</strong></span>
        <span>Descartadas <strong>${num(f.filas_descartadas)}</strong></span>
      </div>` : ''}
      ${controles.length ? `<ul class="salud-controles">${controles.slice(0, 12).map(c => `<li>${control(c, fuente)}</li>`).join('')}
        ${controles.length > 12 ? `<li class="txt-gris">y ${controles.length - 12} más…</li>` : ''}</ul>` : ''}
      <div class="salud-acciones">
        <button type="button" class="btn btn-sm btn-accent" data-reintentar="${f.fuente_id}">Reintentar</button>
        ${encabezado ? `<button type="button" class="btn btn-sm" data-aceptar="${f.fuente_id}">Aceptar encabezado nuevo</button>` : ''}
        ${f.filas_rechazadas ? `<button type="button" class="btn btn-sm" data-rech="${f.corrida_id}" data-fuente="${f.fuente_id}">Ver rechazadas</button>` : ''}
        ${f.corrida_id ? `<button type="button" class="btn btn-sm" data-hist="${f.fuente_id}">Historial</button>` : ''}
        ${fuente ? `<a class="btn btn-sm btn-ghost" href="${esc(`https://docs.google.com/spreadsheets/d/${encodeURIComponent(fuente.spreadsheet_id)}/edit#gid=${fuente.gid}`)}" target="_blank" rel="noopener">Abrir hoja ↗</a>` : ''}
      </div>
    </div>`;
}

function mensajeDe(f) {
  if (f.clave === 'sin_corridas') return 'Nunca se sincronizó. ¿Está deployada la Edge Function y corrida la 005?';
  if (f.clave === 'colgada') return `La corrida empezó ${fmtFechaHora(f.inicio)} y nunca terminó (la función se cortó). Los datos anteriores siguen intactos.`;
  if (f.clave === 'desactualizada') return `La última corrida buena es de ${fmtFechaHora(f.inicio)}. ¿Está activo el cron (004)?`;
  if (f.clave === 'error') {
    const m = f.mensaje || 'Error sin detalle.';
    return /ning[uú]n dato/i.test(m) ? m : `${m} — no se tocó ningún dato: se muestra lo de la última corrida buena.`;
  }
  if (f.clave === 'parcial') return `${f.mensaje || ''} — se cargó lo válido; revisar las filas rechazadas.`;
  return f.mensaje || 'La corrida cargó los datos, pero hay controles que no cuadran.';
}

function control(c, fuente) {
  const partes = [];
  if (c.mes) partes.push(`<strong>${esc(MESES[c.mes - 1])}</strong>`);
  partes.push(esc(c.motivo || 'control'));
  if (c.control) partes.push(`${esc(c.control)}: items ${usd(c.items, { centavos: true })} vs planilla ${usd(c.planilla, { centavos: true })} (dif ${usd(c.diferencia, { centavos: true })})`);
  if (c.item) partes.push(`“${esc(c.item)}”`);
  if (c.fila_planilla) partes.push(numCelda(`fila ${c.fila_planilla}${c.valor != null ? ` = ${c.valor}` : ''}`, fuente, c.fila_planilla));
  return partes.join(' · ');
}

async function correr(boton, cuerpo, el, vigente) {
  const texto = boton.textContent;
  boton.disabled = true;
  boton.textContent = cuerpo.dry_run ? 'Leyendo…' : 'Sincronizando…';
  try {
    const r = await sincronizarAhora(cuerpo);
    const s = r.resumen || {};
    if (cuerpo.dry_run) {
      abrirModal({
        titulo: 'Prueba sin escribir', ancho: true,
        cuerpo: `<p class="aviso-texto">Se leyeron las planillas y se parsearon; no se escribió nada. ${r.segundos} s.</p>
          <table class="data-table data-table-dense"><thead><tr><th>Cliente</th><th>Tipo</th><th>Estado</th><th>Detalle</th></tr></thead>
          <tbody>${(r.resultados || []).map(x => `<tr><td>${clienteChip(x.cliente_id)}</td><td>${esc(x.tipo)}</td>
            <td>${badgeEstado(ESTADOS[x.estado] ? x.estado : 'error')}</td>
            <td title="${esc(x.mensaje || '')}">${esc(x.escrito ? `cargaría ${x.escrito.cargadas}, rechazaría ${x.escrito.rechazadas}` : '')} ${esc(x.mensaje || '')}</td></tr>`).join('')}</tbody></table>`
      });
    } else {
      toast(`Listo: ${s.ok || 0} ok · ${s.revisar || 0} revisar · ${s.parcial || 0} parcial · ${s.error || 0} error`, s.error ? 'error' : '');
      if (vigente()) vistaSalud(el, vigente);
    }
  } catch (e) {
    toast(`No se pudo sincronizar: ${e.message}`, 'error');
  } finally {
    boton.disabled = false;
    boton.textContent = texto;
  }
}

async function verRechazadas(corridaId, fuente) {
  const m = abrirModal({ titulo: 'Filas rechazadas', ancho: true, cuerpo: '<div class="loading-inline">Cargando…</div>' });
  try {
    const filas = await rechazadas(corridaId);
    m.el.querySelector('.modal-body').innerHTML = `
      <table class="data-table data-table-dense"><thead><tr><th>Fila</th><th>Motivo</th><th>Valor</th><th>Comprobante</th></tr></thead>
      <tbody>${filas.map(r => `<tr><td>${numCelda(`fila ${r.fila_planilla}`, fuente, r.fila_planilla)}</td><td>${esc(r.motivo)}</td>
        <td title="${esc(r.valor_crudo || '')}">${esc(r.valor_crudo || '—')}</td><td>${esc(r.comprobante || '—')}</td></tr>`).join('')}</tbody></table>
      ${filas.length === 500 ? '<div class="table-foot">Se muestran las primeras 500.</div>' : ''}`;
  } catch (e) {
    m.el.querySelector('.modal-body').innerHTML = `<p class="aviso-texto">${esc(e.message)}</p>`;
  }
}

async function verHistorial(fuenteId) {
  const m = abrirModal({ titulo: 'Últimas 10 corridas', ancho: true, cuerpo: '<div class="loading-inline">Cargando…</div>' });
  try {
    const filas = await corridas(fuenteId);
    m.el.querySelector('.modal-body').innerHTML = `
      <table class="data-table data-table-dense"><thead><tr><th>Inicio</th><th>Estado</th><th class="num">Leídas</th>
        <th class="num">Cargadas</th><th class="num">Rechazadas</th><th>Mensaje</th></tr></thead>
      <tbody>${filas.map(c => `<tr><td>${fmtFechaHora(c.inicio)}</td><td>${badgeEstado(ESTADOS[c.estado] ? c.estado : 'error')}</td>
        <td class="num">${num(c.filas_leidas)}</td><td class="num">${num(c.filas_cargadas)}</td><td class="num">${num(c.filas_rechazadas)}</td>
        <td title="${esc(c.mensaje || '')}">${esc(c.mensaje || '')}</td></tr>`).join('')}</tbody></table>`;
  } catch (e) {
    m.el.querySelector('.modal-body').innerHTML = `<p class="aviso-texto">${esc(e.message)}</p>`;
  }
}
