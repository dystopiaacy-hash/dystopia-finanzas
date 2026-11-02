/* Cierre de mes: lista de transferencias del mes y su formulario (migración 269). Los renglones automáticos
   (sueldo, comisiones, socios, cliente → Dystopia) no dejan editar el monto: sale de las cuentas; lo demás se edita acá. */
import { esc, abrirModal, toast, fmtFecha, hoyAR, urlSegura, confirmar } from '../ui.js';
import { usd } from '../datos.js';
import { ENTIDADES, nombreEntidad } from '../gastos.js';
import { PAGADORES, TIPOS, TIPOS_MANUALES, transferenciaGuardar } from '../cierre.js';

const u = n => usd(n, { centavos: true });
const nombrePagador = t => (t.pagador_tipo === 'otro' ? (t.pagador_texto || 'Otro') : (PAGADORES.find(p => p[0] === t.pagador_tipo) || [0, t.pagador_tipo])[1]);
const fila = (id, label, control, hint = '') =>
  `<div class="form-row"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${esc(hint)}</div>` : ''}</div>`;

export function tablaTransferencias(lista, cerrado) {
  const activas = lista.filter(t => t.activo);
  const total = activas.reduce((a, t) => a + Number(t.monto_usd), 0);
  const pend = activas.filter(t => t.estado === 'pendiente').reduce((a, t) => a + Number(t.monto_usd), 0);
  const filas = activas.map(t => {
    const link = t.comprobante ? urlSegura(t.comprobante) : '';
    const dif = t.estado === 'hecha' && t.monto_calc != null && Number(t.monto_calc) !== Number(t.monto_usd);
    return `<tr>
      <td class="ajusta">${esc(t.destinatario)}${t.tipo === 'comision' && t.auto ? ` <button class="btn btn-sm" data-ventas="${esc(t.clave_auto)}">Ver ventas</button>` : ''}</td>
      <td class="ajusta">${esc(TIPOS[t.tipo] || t.tipo)}: ${esc(t.concepto)}</td>
      <td>${t.cliente_id ? esc(nombreEntidad(t.cliente_id)) : '—'}</td>
      <td class="num">${u(t.monto_usd)}${dif ? ` <span class="badge" title="El sistema calcula ${esc(u(t.monto_calc))} ahora">⚠ dif.</span>` : ''}</td>
      <td>${esc(nombrePagador(t))}</td>
      <td>${t.estado === 'hecha' ? '<span class="badge">Hecha</span>' : '<span class="badge badge-outline">Pendiente</span>'}</td>
      <td>${t.fecha_pago ? fmtFecha(t.fecha_pago) : '—'}</td>
      <td>${link ? `<a href="${esc(link)}" target="_blank" rel="noopener">abrir ↗</a>` : '—'}</td>
      <td class="acciones">${cerrado ? '' : `${t.estado === 'pendiente' && t.monto_usd > 0 ? `<button class="btn btn-sm btn-accent" data-hecha="${t.id}">Marcar hecha</button> ` : ''}
        <button class="btn btn-sm" data-transf="${t.id}">Editar</button>`}</td></tr>`;
  }).join('');
  return `
    <div class="card-titulo">Transferencias del mes
      ${cerrado ? '' : '<button type="button" class="btn btn-sm" id="transf-nueva">+ Editor / equipo / otra</button>'}</div>
    <div class="card table-card"><table class="data-table tabla-tarjetas">
      <thead><tr><th class="titulo">Destinatario</th><th class="largo">Concepto</th><th>Cliente</th><th class="num clave">Monto</th>
        <th>Quién pagó</th><th>Estado</th><th>Fecha de pago</th><th>Comprobante</th><th class="acciones"></th></tr></thead>
      <tbody>${filas || '<tr><td colspan="9">Todavía no hay transferencias. Calculalas con «Calcular transferencias».</td></tr>'}
        ${filas ? `<tr class="pnl-fuerte"><td>Total</td><td></td><td></td><td class="num">${u(total)}</td><td colspan="5">Pendiente: ${u(pend)}</td></tr>` : ''}</tbody>
    </table></div>
    <div class="table-foot">«Quién pagó» no cambia el monto: indica de qué bolsillo sale. Las comisiones salen de las ventas del mes (con su % editable);
      el reparto de socios sale de la ganancia neta de Dystopia.</div>`;
}

/* t = transferencia existente (o null = alta manual). hecha = abrirla ya en estado «hecha». */
export function abrirTransferencia(t, ym, alGuardar, { hecha = false } = {}) {
  const v = t || { tipo: 'editor', pagador_tipo: 'dystopia', estado: 'pendiente', monto_usd: '' };
  const auto = !!(t && t.auto);
  const estado = hecha ? 'hecha' : v.estado;
  const clientes = ENTIDADES.filter(e => e[0] !== 'dystopia');
  const m = abrirModal({
    titulo: !t ? 'Nueva transferencia' : hecha ? 'Marcar transferencia hecha' : 'Editar transferencia', ancho: true,
    cuerpo: `<form class="form-grid2" novalidate onsubmit="return false">
      ${fila('t-tipo', 'Tipo', auto ? `<input type="text" id="t-tipo" disabled value="${esc(TIPOS[v.tipo] || v.tipo)}">`
        : `<select id="t-tipo">${TIPOS_MANUALES.map(([k, n]) => `<option value="${k}"${k === v.tipo ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select>`)}
      ${fila('t-dest', 'Destinatario', `<input type="text" id="t-dest" maxlength="120" autocomplete="off" value="${esc(v.destinatario || '')}"${auto ? ' disabled' : ''}>`)}
      <div class="campo-ancho">${fila('t-con', 'Concepto', `<input type="text" id="t-con" maxlength="200" value="${esc(v.concepto || '')}"${auto ? ' disabled' : ''}>`)}</div>
      ${fila('t-monto', 'Monto (USD)', `<input type="number" id="t-monto" min="0" step="0.01" value="${v.monto_usd ?? ''}"${auto ? ' disabled' : ''}>`,
        auto ? 'Sale de las cuentas del mes; se corrige en los porcentajes, gastos o pagos.' : '')}
      ${fila('t-cli', 'Cliente asociado (opcional)', `<select id="t-cli"${auto ? ' disabled' : ''}><option value="">—</option>${clientes.map(([k, n]) => `<option value="${k}"${k === v.cliente_id ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select>`)}
      ${fila('t-pag', 'Quién pagó', `<select id="t-pag">${PAGADORES.map(([k, n]) => `<option value="${k}"${k === v.pagador_tipo ? ' selected' : ''}>${esc(n)}</option>`).join('')}</select>`)}
      ${fila('t-pagtxt', 'Si es «Otro»: quién', `<input type="text" id="t-pagtxt" maxlength="120" value="${esc(v.pagador_texto || '')}">`)}
      ${fila('t-est', 'Estado', `<select id="t-est"><option value="pendiente"${estado === 'pendiente' ? ' selected' : ''}>Pendiente</option><option value="hecha"${estado === 'hecha' ? ' selected' : ''}>Hecha</option></select>`)}
      ${fila('t-fecha', 'Fecha de pago', `<input type="date" id="t-fecha" value="${esc(v.fecha_pago || (hecha ? hoyAR() : ''))}">`, 'Obligatoria si está hecha.')}
      <div class="campo-ancho">${fila('t-comp', 'Comprobante (link)', `<input type="url" id="t-comp" maxlength="500" placeholder="https://…" value="${esc(v.comprobante || '')}">`)}</div>
      <div class="campo-ancho">${fila('t-nota', 'Nota', `<input type="text" id="t-nota" maxlength="300" value="${esc(v.nota || '')}">`)}</div>
      <div class="campo-ancho"><span class="form-error" id="t-error" role="alert"></span></div></form>`,
    pie: `${t && !auto ? '<button type="button" class="btn btn-danger" id="t-baja">Dar de baja</button>' : ''}
      <button type="button" class="btn" id="t-cancelar">Cancelar</button><button type="button" class="btn btn-accent" id="t-guardar">Guardar</button>`
  });
  const q = id => m.el.querySelector('#' + id);
  q('t-cancelar').onclick = () => m.cerrar();
  const ejecutar = async (campos, aviso) => {
    q('t-guardar').disabled = true;
    try { await transferenciaGuardar(t ? t.id : null, campos); m.cerrar(); toast(aviso); alGuardar(); } catch (e) {
      q('t-error').textContent = `No se pudo guardar: ${e.message}`; q('t-guardar').disabled = false;
    }
  };
  if (q('t-baja')) q('t-baja').onclick = async () => {
    if (!await confirmar({ titulo: 'Dar de baja', texto: `¿Dar de baja la transferencia a ${v.destinatario}? Queda registrada pero no cuenta.`, ok: 'Dar de baja' })) return;
    ejecutar({ activo: false, baja_manual: true }, 'Transferencia dada de baja');
  };
  q('t-guardar').onclick = () => {
    const dest = q('t-dest').value.trim(), con = q('t-con').value.trim(), monto = Number(q('t-monto').value);
    const pag = q('t-pag').value, pagtxt = q('t-pagtxt').value.trim(), est = q('t-est').value, fecha = q('t-fecha').value;
    const comp = q('t-comp').value.trim();
    if (!dest) return void (q('t-error').textContent = 'Falta el destinatario.');
    if (!con) return void (q('t-error').textContent = 'Falta el concepto.');
    if (q('t-monto').value === '' || !(monto >= 0)) return void (q('t-error').textContent = 'El monto no puede ser negativo.');
    if (pag === 'otro' && !pagtxt) return void (q('t-error').textContent = 'Si pagó «Otro», escribí quién.');
    if (est === 'hecha' && !fecha) return void (q('t-error').textContent = 'Una transferencia hecha necesita la fecha de pago.');
    if (comp && !urlSegura(comp)) return void (q('t-error').textContent = 'El comprobante tiene que ser un link http(s).');
    const base = { pagador_tipo: pag, pagador_texto: pag === 'otro' ? pagtxt : null, estado: est, fecha_pago: fecha || null,
      comprobante: comp || null, nota: q('t-nota').value.trim() || null };
    ejecutar(auto ? base : { ...base, tipo: q('t-tipo').value, destinatario: dest, concepto: con, monto_usd: monto,
      cliente_id: q('t-cli').value || null, ...(t ? {} : { mes: `${ym}-01`, auto: false }) }, 'Transferencia guardada');
  };
}
