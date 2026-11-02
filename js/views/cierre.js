/* Cierre de mes (solo fundador, migración 269): por mes, a quién hay que transferirle y cuánto.
   Clientes (facturación, gastos, ganancia, % y lo que le corresponde a Dystopia), reparto de la ganancia neta entre socios,
   lista de transferencias, avisos de lo que falta y cerrar / reabrir el mes. Un mes cerrado muestra la foto guardada al cerrar. */
import { esc, abrirModal, toast, confirmar, fmtFechaHora, fmtPct, hoyAR } from '../ui.js';
import { yo } from '../sesion.js';
import { usd } from '../datos.js';
import { dysGananciaMes, nombreEntidad, sumar, claveMes, mesesDe, etiquetaMes } from '../gastos.js';
import { estadoMes, logMes, transferencias, ventasMes, avisosMes, socios as cargarSocios, parametros, pctPersonas,
  generar, cerrarMes, reabrirMes, socioGuardar, AVISOS } from '../cierre.js';
import { statCard, botonRecargar, etiquetarTablas } from './comunes.js';
import { tablaTransferencias, abrirTransferencia } from './cierre-transf.js';
import { abrirVentas, abrirPorcentajes } from './cierre-comisiones.js';

const u = n => usd(n, { centavos: true });
const neto = n => `<span class="${n < 0 ? 'txt-rojo' : ''}">${u(n)}</span>`;
const corto = id => (id ? (id === yo.userId ? 'vos' : String(id).slice(0, 8)) : '—');

/* El mes que se cierra es el anterior al actual. */
function mesAnterior() {
  const d = new Date(`${hoyAR().slice(0, 7)}-01T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 1);
  return d.toISOString().slice(0, 7);
}

export async function vistaCierre(el, vigente) {
  const filas = await dysGananciaMes();
  if (!vigente()) return;
  const meses = mesesDe(filas);
  const prevYm = mesAnterior();
  if (!meses.includes(prevYm)) meses.push(prevYm);
  meses.sort().reverse();
  let ym = prevYm;

  const mostrar = async (reabrir) => {
    el.innerHTML = '<div class="card empty-state"><div class="small">Cargando el cierre…</div></div>';
    let est, log, trans, ventas, avisos, socios, params, pcts;
    try {
      [est, log, trans, ventas, avisos, socios, params, pcts] = await Promise.all([
        estadoMes(ym), logMes(ym), transferencias(ym), ventasMes(ym), avisosMes(ym), cargarSocios(), parametros(), pctPersonas()]);
    } catch (e) {
      el.innerHTML = `<div class="card nota aviso-ambar">No se pudo cargar el cierre: ${esc(e.message)}. ¿Está corrida la migración 269?</div>`;
      return;
    }
    if (!vigente()) return;
    const cerrado = !!est && est.estado === 'cerrado';
    const snap = cerrado ? est.snapshot : null;
    const delMes = filas.filter(f => claveMes(f.mes) === ym);
    const clientes = snap ? snap.clientes : delMes.filter(f => f.entidad !== 'dystopia');
    const propia = delMes.find(f => f.entidad === 'dystopia');
    const bruta = snap ? Number(snap.bruta_usd) : sumar(clientes, 'ganancia_dystopia_usd');
    const gastoPropio = snap ? Number(snap.gasto_propio_usd) : (propia ? Number(propia.gasto_propio_usd) : 0);
    const sueldo = !snap && propia ? Number(propia.sueldo_usd) : 0;
    const netaDys = bruta - gastoPropio;
    const activas = trans.filter(t => t.activo);
    const dysPaga = activas.filter(t => t.pagador_tipo === 'dystopia' && ['editor', 'equipo'].includes(t.tipo)).reduce((a, t) => a + Number(t.monto_usd), 0);
    const sociosMes = socios.filter(s => s.activo && claveMes(s.desde) <= ym && (!s.hasta || claveMes(s.hasta) >= ym));
    const sumaSocios = sociosMes.reduce((a, s) => a + Number(s.porcentaje), 0);
    const personas = [...new Map(ventas.filter(v => v.persona).map(v => [v.persona_norm, { persona: v.persona, persona_norm: v.persona_norm }])).values()];

    const lineasAviso = [];
    if (!cerrado) {
      for (const a of avisos) {
        const cli = a.cliente_id ? ` ${nombreEntidad(a.cliente_id)}` : '';
        if (a.tipo === 'sin_gastos' || a.tipo === 'sin_porcentaje') lineasAviso.push(`${AVISOS[a.tipo]}:${cli}`);
        else if (a.tipo === 'comision_desde_opps') lineasAviso.push(`${AVISOS[a.tipo]}:${cli} (${u(a.monto_usd)})`);
        else if (a.tipo === 'diferencia_con_calculo') lineasAviso.push(`${AVISOS[a.tipo]}${cli} (${a.cantidad}, diferencia ${u(a.monto_usd)})`);
        else lineasAviso.push(`${AVISOS[a.tipo]}${cli}: ${a.cantidad} (${u(a.monto_usd)})`);
      }
      if (!activas.length) lineasAviso.push('Todavía no se calcularon las transferencias del mes');
      if (sociosMes.length && Math.abs(sumaSocios - 100) > 0.001) lineasAviso.push(`Los socios suman ${fmtPct(sumaSocios, 2)} (tienen que sumar 100%)`);
      if (!sociosMes.length) lineasAviso.push('No hay socios activos para repartir la ganancia neta');
    }

    const filaCli = f => `<tr><td class="ajusta">${esc(nombreEntidad(f.entidad))}${f.sin_gastos && !snap ? ' <span class="badge" title="Sin gastos cargados: ganancia sobreestimada">⚠ sin gastos</span>' : ''}${f.comision_modo === 'opps' && Number(f.comision_opps_vigente_usd) && !snap ? ' <span class="badge" title="El mes no tiene comisiones calculadas: las comisiones salen de las líneas de Opps. Calculá las transferencias para usar las del cierre.">comisiones de Opps</span>' : ''}</td>
      <td class="num">${u(f.facturacion_usd)}</td><td class="num">${u(f.gastos_cliente_usd)}</td><td class="num">${neto(Number(f.ganancia_cliente_usd))}</td>
      <td class="num">${f.porcentaje == null ? '—' : fmtPct(f.porcentaje, 1)}</td><td class="num">${u(f.ganancia_dystopia_usd)}</td></tr>`;
    const filaSocio = s => `<tr><td class="ajusta">${esc(s.nombre)}</td><td class="num">${fmtPct(s.porcentaje, 2)}</td>
      <td class="num">${netaDys > 0 ? u(Math.round(netaDys * Number(s.porcentaje)) / 100) : u(0)}</td>
      <td class="acciones"><button class="btn btn-sm" data-socio="${s.id}">Editar</button></td></tr>`;

    el.innerHTML = `
      <div class="filter-row">
        <span class="flabel">Mes</span>
        <select id="ci-mes">${meses.map(m => `<option value="${m}"${m === ym ? ' selected' : ''}>${esc(etiquetaMes(m))}</option>`).join('')}</select>
        ${cerrado ? '<span class="badge">Cerrado</span>' : '<span class="badge badge-outline">Abierto</span>'}
        <span class="grow"></span>
        <button class="btn btn-sm" id="ci-pct">Porcentajes de comisión</button>
        ${cerrado ? '<button class="btn btn-sm" id="ci-reabrir">Reabrir mes</button>'
          : '<button class="btn btn-sm" id="ci-calc">Calcular transferencias</button><button class="btn btn-sm btn-accent" id="ci-cerrar">Cerrar mes</button>'}
        ${botonRecargar()}
      </div>
      ${cerrado ? `<div class="card nota">Mes cerrado el ${esc(fmtFechaHora(est.cerrado_en))} por ${esc(corto(est.cerrado_por))}. Gastos, comisiones y transferencias de ${esc(etiquetaMes(ym))}
        están bloqueados; los números de abajo son la foto guardada al cerrar.${est.reaperturas ? ` Reabierto ${est.reaperturas} ${est.reaperturas === 1 ? 'vez' : 'veces'}.` : ''}</div>` : ''}
      ${lineasAviso.length ? `<div class="card nota aviso-ambar"><strong>Falta para cerrar ${esc(etiquetaMes(ym))}:</strong><ul>${lineasAviso.map(l => `<li>${esc(l)}</li>`).join('')}</ul></div>` : ''}
      <div class="grid-3 stat-grid">
        ${statCard(u(bruta), 'Ganancia bruta de Dystopia', { sub: 'Suma de lo que le toca de cada cliente' })}
        ${statCard(u(gastoPropio), 'Gastos propios de Dystopia', { sub: sueldo ? `Incluye sueldo de Joaquín ${u(sueldo)}` : 'Incluye el sueldo si está cargado' })}
        ${statCard(u(netaDys), 'Ganancia neta a repartir', { alerta: netaDys < 0, sub: dysPaga ? `Aparte, Dystopia paga ${u(dysPaga)} en editor/equipo (no descontado)` : '' })}
      </div>
      <div class="card-titulo">${esc(etiquetaMes(ym))} por cliente</div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th class="titulo">Cliente</th><th class="num">Facturación</th><th class="num">Gastos</th><th class="num">Ganancia</th>
          <th class="num">% Dystopia</th><th class="num clave">Le debe a Dystopia</th></tr></thead>
        <tbody>${clientes.map(filaCli).join('') || '<tr><td colspan="6">Sin datos de clientes este mes</td></tr>'}
          <tr class="pnl-fuerte"><td>Total</td><td class="num">${u(sumar(clientes, 'facturacion_usd'))}</td><td class="num">${u(sumar(clientes, 'gastos_cliente_usd'))}</td>
            <td class="num">${neto(sumar(clientes, 'ganancia_cliente_usd'))}</td><td></td><td class="num">${u(bruta)}</td></tr></tbody></table></div>
      <div class="card-titulo">Reparto de la ganancia neta
        <button type="button" class="btn btn-sm" id="ci-socio-nuevo">+ Socio</button></div>
      <div class="card table-card"><table class="data-table tabla-tarjetas">
        <thead><tr><th class="titulo">Socio</th><th class="num">%</th><th class="num clave">Le corresponde</th><th class="acciones"></th></tr></thead>
        <tbody>${sociosMes.map(filaSocio).join('') || '<tr><td colspan="4">Sin socios activos</td></tr>'}</tbody></table></div>
      <div class="table-foot">Neta = bruta - gastos propios (sueldo incluido) = ${u(netaDys)}. Joaquín no es socio: cobra su sueldo. Si la neta es negativa no se reparte.
        Los socios y sus % se configuran acá (valen para todos los meses desde su fecha).</div>
      ${tablaTransferencias(trans, cerrado)}
      ${log.length ? `<div class="card-titulo">Historial de cierres</div><div class="card table-card"><table class="data-table"><tbody>
        ${log.map(l => `<tr><td>${esc(fmtFechaHora(l.en))}</td><td>${l.accion === 'cerrar' ? 'Cerrado' : 'Reabierto'}</td><td>${esc(corto(l.por))}</td><td>${esc(l.nota || '')}</td></tr>`).join('')}</tbody></table></div>` : ''}`;
    etiquetarTablas(el);

    const q = s => el.querySelector(s);
    const recargar = () => mostrar();
    q('#ci-mes').onchange = e => { ym = e.target.value; mostrar(); };
    q('#btn-recargar').onclick = recargar;
    q('#ci-pct').onclick = () => abrirPorcentajes(params, pcts, personas, recargar);
    const accion = async (fn, aviso) => { try { await fn(); toast(aviso); mostrar(); } catch (e) { toast(`No se pudo: ${e.message}`, 'error'); } };
    if (q('#ci-calc')) q('#ci-calc').onclick = () => accion(() => generar(ym), 'Transferencias calculadas');
    if (q('#ci-cerrar')) q('#ci-cerrar').onclick = async () => {
      const pend = activas.filter(t => t.estado === 'pendiente' && Number(t.monto_usd) > 0).length;
      const ok = await confirmar({ titulo: `Cerrar ${etiquetaMes(ym)}`, peligro: false, ok: 'Cerrar mes',
        texto: 'Se recalculan las transferencias, se guarda una foto de los totales y se bloquean los gastos, comisiones y transferencias del mes.',
        detalle: pend ? `Quedan ${pend} transferencias pendientes: después de cerrar no se pueden marcar como hechas hasta reabrir el mes.` : '' });
      if (ok) accion(() => cerrarMes(ym), 'Mes cerrado');
    };
    if (q('#ci-reabrir')) q('#ci-reabrir').onclick = async () => {
      if (await confirmar({ titulo: `Reabrir ${etiquetaMes(ym)}`, ok: 'Reabrir', texto: 'Se desbloquean gastos, comisiones y transferencias del mes. Queda registrado quién y cuándo.' })) accion(() => reabrirMes(ym), 'Mes reabierto');
    };
    q('#ci-socio-nuevo').onclick = () => abrirSocio(null, recargar);
    for (const b of el.querySelectorAll('[data-socio]')) b.onclick = () => abrirSocio(socios.find(s => s.id === Number(b.dataset.socio)), recargar);
    if (q('#transf-nueva')) q('#transf-nueva').onclick = () => abrirTransferencia(null, ym, recargar);
    for (const b of el.querySelectorAll('[data-transf]')) b.onclick = () => abrirTransferencia(trans.find(t => t.id === Number(b.dataset.transf)), ym, recargar);
    for (const b of el.querySelectorAll('[data-hecha]')) b.onclick = () => abrirTransferencia(trans.find(t => t.id === Number(b.dataset.hecha)), ym, recargar, { hecha: true });
    for (const b of el.querySelectorAll('[data-ventas]')) b.onclick = () => abrirVentas(b.dataset.ventas, ventas, cerrado, c => mostrar(c));
    if (reabrir) abrirVentas(reabrir, ventas, cerrado, c => mostrar(c));
  };
  mostrar();
}

function abrirSocio(s, alGuardar) {
  const v = s || { desde: hoyAR().slice(0, 8) + '01', activo: true };
  const m = abrirModal({
    titulo: s ? 'Editar socio' : 'Nuevo socio', ancho: true,
    cuerpo: `<form class="form-grid2" novalidate onsubmit="return false">
      <div class="form-row"><label for="s-nom">Nombre</label><input type="text" id="s-nom" maxlength="80" value="${esc(v.nombre || '')}"></div>
      <div class="form-row"><label for="s-pct">% de la ganancia neta</label><input type="number" id="s-pct" min="0.01" max="100" step="0.01" value="${v.porcentaje ?? ''}"></div>
      <div class="form-row"><label for="s-desde">Desde</label><input type="date" id="s-desde" value="${esc(v.desde || '')}"></div>
      <div class="form-row"><label for="s-hasta">Hasta (opcional)</label><input type="date" id="s-hasta" value="${esc(v.hasta || '')}"></div>
      <div class="campo-ancho"><label class="chk-linea"><input type="checkbox" id="s-act"${v.activo ? ' checked' : ''}> Activo</label></div>
      <div class="campo-ancho"><span class="form-error" id="s-error" role="alert"></span></div></form>`,
    pie: '<button type="button" class="btn" id="s-cancelar">Cancelar</button><button type="button" class="btn btn-accent" id="s-guardar">Guardar</button>'
  });
  const q = id => m.el.querySelector('#' + id);
  q('s-cancelar').onclick = () => m.cerrar();
  q('s-guardar').onclick = async () => {
    const pct = Number(q('s-pct').value);
    if (!q('s-nom').value.trim()) { q('s-error').textContent = 'Falta el nombre.'; return; }
    if (!(pct > 0 && pct <= 100)) { q('s-error').textContent = 'El porcentaje tiene que estar entre 0 y 100.'; return; }
    if (!q('s-desde').value) { q('s-error').textContent = 'Falta la fecha de inicio.'; return; }
    if (q('s-hasta').value && q('s-hasta').value < q('s-desde').value) { q('s-error').textContent = 'La fecha de fin no puede ser anterior al inicio.'; return; }
    q('s-guardar').disabled = true;
    try {
      await socioGuardar(s ? s.id : null, { nombre: q('s-nom').value.trim(), porcentaje: pct, desde: q('s-desde').value, hasta: q('s-hasta').value || null, activo: q('s-act').checked });
      m.cerrar(); toast('Socio guardado'); alGuardar();
    } catch (e) { q('s-error').textContent = `No se pudo guardar: ${e.message}`; q('s-guardar').disabled = false; }
  };
}
