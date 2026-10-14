/* Alertas de cobros a Discord (solo fundador). Por cliente: activa o no, hora, último envío y
   "Vista previa" (arma el texto de hoy SIN enviarlo). El webhook vive en Vault, no se ve ni se edita acá. */
import { esc, fmtFechaHora, toast, abrirModal } from '../ui.js';
import { alertasCobrosEstado, alertasCobrosGuardar, alertasCobrosVistaPrevia } from '../datos.js';
import { vacio, clienteChip, botonRecargar } from './comunes.js';

const HORAS = Array.from({ length: 17 }, (_, i) => i + 6);

/* Opciones de hora (HH:05, el cron corre al :05). opcional = suma "Sin 2.º aviso" (null). */
function opcionesHora(actual, opcional) {
  const sel = actual == null ? null : Number(actual);
  return (opcional ? `<option value=""${sel === null ? ' selected' : ''}>Sin 2.º aviso</option>` : '')
    + HORAS.map(h => `<option value="${h}"${h === sel ? ' selected' : ''}>${String(h).padStart(2, '0')}:05</option>`).join('');
}

/* Dos renglones (1.º y 2.º aviso); sin segundo horario muestra solo el primero. */
function turnos(v1, v2, hora2, fmt) {
  const t = v => (v ? fmt(v) : '—');
  return hora2 == null && !v2 ? t(v1) : `1.º ${t(v1)}<br>2.º ${t(v2)}`;
}

export async function vistaAlertas(el, vigente) {
  const filas = await alertasCobrosEstado();
  if (!vigente()) return;
  if (!filas.length) {
    el.innerHTML = vacio('No hay clientes con alerta de cobros', 'Se crean al correr la migración 103 para los clientes con hoja de cuotas.');
    return;
  }
  el.innerHTML = `
    <div class="filter-row"><span class="grow"></span>${botonRecargar()}</div>
    <div class="card table-card">
      <table class="data-table">
        <thead><tr><th>Cliente</th><th>Activa</th><th>1.er aviso</th><th>2.º aviso</th><th>Montos</th><th>Webhook</th>
          <th>Último envío</th><th>Resultado</th><th></th></tr></thead>
        <tbody>${filas.map(f => `<tr data-cliente="${esc(f.cliente_id)}">
          <td>${clienteChip(f.cliente_id)}</td>
          <td><input type="checkbox" data-campo="activo"${f.activo ? ' checked' : ''} aria-label="Alerta activa"></td>
          <td><select data-campo="hora" aria-label="Hora del primer aviso">${opcionesHora(f.hora_envio, false)}</select></td>
          <td><select data-campo="hora2" aria-label="Hora del segundo aviso">${opcionesHora(f.hora_envio_2, true)}</select></td>
          <td><input type="checkbox" data-campo="montos"${f.mostrar_montos ? ' checked' : ''} aria-label="Mostrar montos"></td>
          <td>${f.tiene_webhook ? 'Cargado' : '<span class="txt-rojo">Falta en Vault</span>'}</td>
          <td>${turnos(f.ultimo_envio, f.ultimo_envio_2, f.hora_envio_2, x => fmtFechaHora(x))}</td>
          <td>${turnos(f.ultimo_resultado, f.ultimo_resultado_2, f.hora_envio_2, x => esc(x))}</td>
          <td><button type="button" class="btn btn-sm" data-previa>Vista previa</button></td>
        </tr>`).join('')}</tbody>
      </table>
    </div>
    <div class="table-foot">Se manda todos los días a las horas elegidas (hora de Argentina); el 2.º aviso es opcional. Cada aviso se controla
      aparte: si el de la mañana ya salió, el de la noche sale igual. Si a la hora del 2.º todavía no había salido el 1.º, se manda uno solo.
      Los lunes incluye los cobros de los próximos 7 días.
      Sin montos ni teléfonos salvo que se active "Montos". Si no hay nada para avisar no se manda nada.
      El webhook se carga en Vault: fin_discord_webhook_cobros_&lt;cliente&gt; (o fin_discord_webhook_cobros para un canal general).</div>`;

  el.querySelector('#btn-recargar').onclick = () => vistaAlertas(el, vigente);

  for (const tr of el.querySelectorAll('tr[data-cliente]')) {
    const cliente = tr.dataset.cliente;
    const guardar = async () => {
      const activo = tr.querySelector('[data-campo=activo]').checked;
      const hora = Number(tr.querySelector('[data-campo=hora]').value);
      const v2 = tr.querySelector('[data-campo=hora2]').value;
      const hora2 = v2 === '' ? null : Number(v2);
      const montos = tr.querySelector('[data-campo=montos]').checked;
      if (hora2 === hora) {
        toast('Los dos avisos no pueden tener la misma hora', 'error');
        if (vigente()) vistaAlertas(el, vigente);
        return;
      }
      try {
        await alertasCobrosGuardar(cliente, activo, hora, montos, hora2);
        toast('Alerta guardada');
      } catch (e) {
        toast(`No se pudo guardar: ${e.message}`, 'error');
        if (vigente()) vistaAlertas(el, vigente);
      }
    };
    for (const c of tr.querySelectorAll('[data-campo]')) c.onchange = guardar;
    tr.querySelector('[data-previa]').onclick = e => vistaPrevia(cliente, e.target);
  }
}

async function vistaPrevia(cliente, boton) {
  boton.disabled = true;
  try {
    const hoy = await alertasCobrosVistaPrevia(cliente);
    const c = hoy.cuentas || {};
    const mensajes = hoy.mensajes || [];
    abrirModal({
      titulo: `Vista previa · ${cliente}`, ancho: true,
      cuerpo: `<p class="aviso-texto">Es lo que se mandaría hoy (${esc(hoy.fecha)}). No se envía nada.
          ${hoy.incluye_semana ? 'Incluye los próximos 7 días (es lunes).' : 'Hoy no es lunes: no incluye los próximos 7 días.'}</p>
        <p class="aviso-texto">Hoy: <strong>${c.hoy ?? 0}</strong> · Atrasadas: <strong>${c.atrasadas ?? 0}</strong>
          (de más de 14 días: ${c.atrasadas_altas ?? 0}) · Próximos 7 días: <strong>${c.proximos ?? 0}</strong></p>
        ${mensajes.length
          ? mensajes.map(m => `<pre style="white-space:pre-wrap;margin:0 0 12px">${esc(m)}</pre>`).join('')
          : '<p class="aviso-texto"><strong>Hoy no se mandaría nada</strong> (no hay cobros para avisar).</p>'}`
    });
  } catch (e) {
    toast(`No se pudo armar la vista previa: ${e.message}`, 'error');
  } finally {
    boton.disabled = false;
  }
}
