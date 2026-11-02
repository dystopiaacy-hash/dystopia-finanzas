/* Formularios (modales) del apartado Webinars: el webinar, un gasto por concepto y un ajuste de ingreso.
   La base valida de nuevo todo (checks de las tablas fin_webinar_*, migración 267). */
import { esc, abrirModal, toast, hoyAR } from '../ui.js';
import { ENTIDADES } from '../gastos.js';
import { CONCEPTOS, TIPOS_AJUSTE, webinarGuardar, gastoWebinarGuardar, ajusteGuardar } from '../webinars.js';

const fila = (id, label, control, hint = '') =>
  `<div class="form-row"><label for="${id}">${esc(label)}</label>${control}${hint ? `<div class="hint">${esc(hint)}</div>` : ''}</div>`;
const opt = (arr, sel) => arr.map(([k, n]) => `<option value="${esc(k)}"${k === sel ? ' selected' : ''}>${esc(n)}</option>`).join('');
const entero = v => (v === '' || v == null ? null : Math.round(Number(v)));

/* Arma el modal, valida con `leer()` (devuelve campos o un string con el error) y guarda con `guardar(campos)`. */
function formulario({ titulo, cuerpo, textoGuardar, leer, guardar, alGuardar, aviso }) {
  const m = abrirModal({
    titulo, ancho: true,
    cuerpo: `<form class="form-grid2" novalidate onsubmit="return false">${cuerpo}<div class="campo-ancho"><span class="form-error" id="w-error" role="alert"></span></div></form>`,
    pie: `<button type="button" class="btn" id="w-cancelar">Cancelar</button><button type="button" class="btn btn-accent" id="w-guardar">${esc(textoGuardar)}</button>`
  });
  const q = id => m.el.querySelector('#' + id);
  q('w-cancelar').onclick = () => m.cerrar();
  q('w-guardar').onclick = async () => {
    const r = leer(q);
    if (typeof r === 'string') { q('w-error').textContent = r; return; }
    q('w-error').textContent = '';
    q('w-guardar').disabled = true;
    try { await guardar(r); m.cerrar(); toast(aviso); alGuardar(); } catch (e) {
      q('w-error').textContent = `No se pudo guardar: ${e.message}`;
      q('w-guardar').disabled = false;
    }
  };
}

/* w = fila de fin_v_webinar_resultado (o null para uno nuevo). */
export function abrirFormWebinar(w, alGuardar) {
  const v = w || { cliente_id: 'agus', ventana_dias: 14, fecha: hoyAR() };
  const clientes = ENTIDADES.filter(e => e[0] !== 'dystopia');
  /* La vista devuelve la ventana ya resuelta: solo se precarga lo que difiere del valor por defecto. */
  const vd0 = w && w.ventana_desde !== w.fecha ? w.ventana_desde : '';
  const vh0 = w && w.ventana_hasta !== sumar(w.fecha, w.ventana_dias) ? w.ventana_hasta : '';
  formulario({
    titulo: w ? 'Editar webinar' : 'Nuevo webinar', textoGuardar: w ? 'Guardar cambios' : 'Crear webinar', alGuardar,
    aviso: w ? 'Cambios guardados' : 'Webinar creado',
    cuerpo: `
      ${fila('w-cli', 'Cliente', `<select id="w-cli"${w ? ' disabled' : ''}>${opt(clientes, v.cliente_id)}</select>`)}
      ${fila('w-nombre', 'Nombre', `<input type="text" id="w-nombre" maxlength="80" autocomplete="off" value="${esc(v.nombre || '')}">`, 'Ej.: AF 15/11')}
      ${fila('w-fecha', 'Fecha del webinar', `<input type="date" id="w-fecha" value="${esc(v.fecha || '')}">`)}
      ${fila('w-replay', 'Fecha del replay (opcional)', `<input type="date" id="w-replay" value="${esc(v.fecha_replay || '')}">`)}
      ${fila('w-dias', 'Ventana de ingresos (días después del webinar)', `<input type="number" id="w-dias" min="0" max="120" step="1" value="${v.ventana_dias ?? 14}">`,
        'Se cuentan los pagos con fuente webinar o replay desde el día del webinar hasta ese día.')}
      <div class="form-row"><label>&nbsp;</label><div class="hint">Para fijar la ventana a mano, completá las dos fechas de abajo (pisan los días).</div></div>
      ${fila('w-vd', 'Ventana desde (opcional)', `<input type="date" id="w-vd" value="${esc(vd0)}">`)}
      ${fila('w-vh', 'Ventana hasta (opcional)', `<input type="date" id="w-vh" value="${esc(vh0)}">`)}
      ${fila('w-reg', 'Registrados', `<input type="number" id="w-reg" min="0" step="1" value="${v.registrados ?? ''}">`)}
      ${fila('w-asi', 'Asistentes', `<input type="number" id="w-asi" min="0" step="1" value="${v.asistentes ?? ''}">`)}
      ${fila('w-com', 'Compradores', `<input type="number" id="w-com" min="0" step="1" value="${v.compradores ?? ''}">`)}
      ${fila('w-ll', 'Llamadas', `<input type="number" id="w-ll" min="0" step="1" value="${v.llamadas ?? ''}">`)}
      ${fila('w-cash', 'Cash informado por las métricas (referencia)', `<input type="number" id="w-cash" step="0.01" value="${v.cash_informado ?? ''}">`, 'Solo para comparar con lo que calcula la app; no se suma.')}
      <div class="campo-ancho">${fila('w-nota', 'Nota', `<textarea id="w-nota" rows="2">${esc(v.nota || '')}</textarea>`)}</div>`,
    leer: q => {
      if (!q('w-nombre').value.trim()) return 'Falta el nombre.';
      if (!q('w-fecha').value) return 'Falta la fecha del webinar.';
      const vd = q('w-vd').value, vh = q('w-vh').value;
      if (vd && vh && vh < vd) return 'La ventana termina antes de empezar.';
      const c = { nombre: q('w-nombre').value.trim(), fecha: q('w-fecha').value, fecha_replay: q('w-replay').value || null,
        ventana_dias: entero(q('w-dias').value) ?? 14, ventana_desde: vd || null, ventana_hasta: vh || null,
        registrados: entero(q('w-reg').value), asistentes: entero(q('w-asi').value), compradores: entero(q('w-com').value),
        llamadas: entero(q('w-ll').value), cash_informado: q('w-cash').value === '' ? null : Number(q('w-cash').value),
        nota: q('w-nota').value.trim() || null };
      if (!w) c.cliente_id = q('w-cli').value;
      return c;
    },
    guardar: c => webinarGuardar(w ? w.webinar_id : null, c)
  });
}

function sumar(iso, n) {
  const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10);
}

/* g = fila de fin_webinar_gastos o null. */
export function abrirFormGastoWebinar(web, g, alGuardar) {
  const v = g || { concepto: 'ads_webinar', fecha: web.fecha, en_opps: false };
  formulario({
    titulo: g ? 'Editar gasto del webinar' : `Gasto de ${web.nombre}`, textoGuardar: g ? 'Guardar cambios' : 'Guardar gasto', alGuardar,
    aviso: g ? 'Cambios guardados' : 'Gasto guardado',
    cuerpo: `
      ${fila('g-con', 'Concepto', `<select id="g-con">${opt(CONCEPTOS, v.concepto)}</select>`)}
      ${fila('g-monto', 'Monto (USD)', `<input type="number" id="g-monto" min="0" step="0.01" value="${v.monto_usd ?? ''}">`)}
      ${fila('g-fecha', 'Fecha (fija el mes del gasto)', `<input type="date" id="g-fecha" value="${esc(v.fecha || '')}">`)}
      ${fila('g-fuente', 'Fuente del dato', `<input type="text" id="g-fuente" maxlength="120" autocomplete="off" placeholder="Meta Ads, GHL, ManyChat, Zoom, WhatsApp…" value="${esc(v.fuente || '')}">`)}
      <div class="campo-ancho">${fila('g-opps', 'Ya está en Opps', `<label class="chk-linea"><input type="checkbox" id="g-opps"${v.en_opps ? ' checked' : ''}> Este gasto ya figura en los gastos de Opps de ese mes</label>`,
        'Cuenta para el resultado del webinar, pero no se suma otra vez a los gastos del cliente (evita duplicarlo).')}</div>
      <div class="campo-ancho">${fila('g-nota', 'Nota', `<textarea id="g-nota" rows="2">${esc(v.nota || '')}</textarea>`)}</div>`,
    leer: q => {
      const monto = Number(q('g-monto').value);
      if (q('g-monto').value === '' || !(monto >= 0)) return 'El monto tiene que ser 0 o más.';
      if (!q('g-fecha').value) return 'Falta la fecha.';
      return { webinar_id: web.webinar_id, concepto: q('g-con').value, monto_usd: monto, fecha: q('g-fecha').value,
        fuente: q('g-fuente').value.trim() || null, nota: q('g-nota').value.trim() || null, en_opps: q('g-opps').checked };
    },
    guardar: c => gastoWebinarGuardar(g ? g.id : null, c)
  });
}

/* a = fila de fin_webinar_ajustes o null. */
export function abrirFormAjuste(web, a, alGuardar) {
  const v = a || { tipo: 'venta_probable' };
  formulario({
    titulo: a ? 'Editar ajuste de ingreso' : `Ajuste de ingreso de ${web.nombre}`, textoGuardar: a ? 'Guardar cambios' : 'Guardar ajuste', alGuardar,
    aviso: a ? 'Cambios guardados' : 'Ajuste guardado',
    cuerpo: `
      ${fila('a-tipo', 'Tipo', `<select id="a-tipo">${opt(TIPOS_AJUSTE, v.tipo)}</select>`, 'Las ventas probables se muestran aparte: no entran al cash ni al ROAS.')}
      ${fila('a-monto', 'Monto (USD)', `<input type="number" id="a-monto" step="0.01" value="${v.monto_usd ?? ''}">`)}
      <div class="campo-ancho">${fila('a-con', 'Concepto', `<input type="text" id="a-con" maxlength="160" autocomplete="off" value="${esc(v.concepto || '')}">`)}</div>
      <div class="campo-ancho">${fila('a-nota', 'Nota', `<textarea id="a-nota" rows="2">${esc(v.nota || '')}</textarea>`)}</div>`,
    leer: q => {
      const monto = Number(q('a-monto').value);
      if (q('a-monto').value === '' || !monto) return 'El monto no puede ser 0.';
      if (!q('a-con').value.trim()) return 'Falta el concepto.';
      return { webinar_id: web.webinar_id, tipo: q('a-tipo').value, concepto: q('a-con').value.trim(), monto_usd: monto, nota: q('a-nota').value.trim() || null };
    },
    guardar: c => ajusteGuardar(a ? a.id : null, c)
  });
}
