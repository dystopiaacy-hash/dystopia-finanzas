/* Mapa: contenido de los marcos de Marketing, Setting, Ventas, Seguimiento y Soporte.
   Cada pestaña = { id, label, base(): html, pool: [() => html] } (el motor rellena con el pool hasta el borde del marco).
   Sin dato -> «sin dato» en el número y un aviso, nunca un marco roto. */
import { nombreCliente } from './mapa.js';
import { SIN, ent, pct, money, count, fecha, chip, delta, kpi, kpis, vh, card, aviso, grid, vacio, tabla, hbars, strip, linea, acumulado } from './mapa-ui.js';

const sub = (D, tx) => `${tx} · ${D.mesTxt} · ${D.cliTxt}`;
const sinLectura = area => aviso(`No se pudo leer ${area}: el resto del mapa sigue funcionando.`, 'bad');
const porCli = lista => lista.map(([c, v]) => [nombreCliente(c), v]);

/* ---------------- Marketing ---------------- */
function marketing(D) {
  const m = D.d.marketing, prev = D.d.prev;
  if (!m) return [{ id: 'res', label: 'Resultados', base: () => vh('Resultados', sub(D, 'Marketing')) + sinLectura('Marketing'), pool: [] }];
  const dias = Object.keys(m.porDia).length;
  const res = () => vh('Resultados', sub(D, 'Piezas publicadas')) +
    kpis([
      kpi('Piezas publicadas', count(m.piezas), delta(m.piezas, prev && prev.piezas), true),
      kpi('Plataformas', count(m.porPlataforma.length), 'con al menos una pieza'),
      kpi('Clientes con piezas', count(m.porCliente.length), 'de los elegidos'),
      kpi('Días con publicación', count(dias), `de ${D.diasMes} del mes`)
    ]) +
    grid('1fr 1fr',
      card('Por plataforma', `Total ${ent(m.piezas)}`, hbars(m.porPlataforma.slice(0, 6))),
      card('Por cliente', `Total ${ent(m.piezas)}`, hbars(porCli(m.porCliente)))) +
    card('Últimas piezas', 'estado PUBLICADO', tabla([{ h: 'Fecha' }, { h: 'Cliente' }, { h: 'Plataforma' }, { h: 'Pieza' }],
      m.ultimas.slice(0, 5).map(u => [fecha(u.fecha), nombreCliente(u.cliente), u.plataforma, u.titulo || '—'])), { flush: true });
  const pool = [
    () => card('Piezas publicadas, acumulado del mes', `${ent(m.piezas)} en total`, linea(acumulado(m.porDia))),
    () => strip([['Promedio por día con piezas', count(dias ? Math.round((m.piezas / dias) * 10) / 10 : 0)], ['Plataforma que más publica', { t: (m.porPlataforma[0] || ['—'])[0] }], ['Mes anterior', count(prev && prev.piezas)], ['Cliente que más publica', { t: nombreCliente((m.porCliente[0] || ['—'])[0]) }]]),
    () => card('Qué mide esta pantalla', '', '<p class="mtxt">Cuenta las piezas con estado PUBLICADO por fecha de publicación, igual que el dashboard de Marketing. Las vistas, guardados y mensajes de cada pieza viven en la app de Marketing.</p>')
  ];
  const piezas = () => vh('Piezas', sub(D, 'Últimas publicadas')) + card('Últimas piezas publicadas', `${ent(m.ultimas.length)} de ${ent(m.piezas)}`,
    tabla([{ h: 'Fecha' }, { h: 'Cliente' }, { h: 'Plataforma' }, { h: 'Pieza' }], m.ultimas.map(u => [fecha(u.fecha), nombreCliente(u.cliente), u.plataforma, u.titulo || '—'])), { flush: true });
  return [{ id: 'res', label: 'Resultados', base: res, pool }, { id: 'piezas', label: 'Piezas', base: piezas, pool: [pool[0]] }];
}

/* ---------------- Setting (sin datos todavía) ---------------- */
function setting(D) {
  const base = () => vh('Conversaciones', sub(D, 'Del mensaje a la agenda')) +
    kpis([kpi('Conversaciones', { t: SIN }, 'ManyChat', true), kpi('Respuestas', { t: SIN }, 'ManyChat'), kpi('Calificadas', { t: SIN }, 'ManyChat'), kpi('Agendas generadas', { t: SIN }, 'ManyChat')]) +
    `<div class="grow">${card('Sin datos todavía', 'estado del área', vacio('Sin datos todavía',
      'Falta conectar los eventos de ManyChat del CRM de Agus para contar conversaciones, respuestas y agendas por setter.',
      ['Eventos de ManyChat del CRM de Agus', 'Quién setea cada agenda', 'Cuándo se considera «calificada» una conversación']), { cls: 'fill' })}</div>`;
  return [{ id: 'conv', label: 'Conversaciones', base, pool: [] }];
}

/* ---------------- Ventas ---------------- */
function ventas(D) {
  const v = D.d.ventas, prev = D.d.prev;
  if (!v) return [{ id: 'perf', label: 'Performance', base: () => vh('Performance', sub(D, 'Ventas')) + aviso('Ventas: sin dato para este mes y cliente.', 'warn'), pool: [] }];
  const tasa = v.presentadas ? (v.cerradas / v.presentadas) * 100 : null;
  const showUp = v.presentadas != null && v.agendadas ? (v.presentadas / v.agendadas) * 100 : null;
  const faltan = v.agendadas > 0 && v.presentadas === 0;
  const filasC = v.closers.slice(0, 7).map(c => [c.closer, c.agendadas, c.presentadas, c.cerradas, c.presentadas ? pct((c.cerradas / c.presentadas) * 100) : '—']);
  const colsC = [{ h: 'Closer' }, { h: 'Agendadas', num: 1 }, { h: 'Presentadas', num: 1 }, { h: 'Cierres', num: 1 }, { h: '% cierre', num: 1 }];
  const tot = v.closers.reduce((a, c) => ({ a: a.a + c.agendadas, p: a.p + c.presentadas, c: a.c + c.cerradas }), { a: 0, p: 0, c: 0 });
  const perf = () => vh('Performance', sub(D, 'Llamadas, cierres y cobros')) +
    kpis([
      kpi('Llamadas agendadas', count(v.agendadas), v.futuras ? `${ent(v.futuras)} todavía por venir` : delta(v.agendadas, prev && prev.agendadas), true),
      kpi('Presentadas', count(v.presentadas), showUp != null ? `Show up ${pct(showUp)} de las agendadas` : 'sin llamadas cargadas'),
      kpi('Cierres', count(v.cerradas), delta(v.cerradas, prev && prev.cerradas)),
      kpi('Tasa de cierre', { t: pct(tasa) }, 'cierres sobre presentadas'),
      kpi('Show up sin marcar', count(v.sinShowUp), 'se completa días después')
    ]) +
    (faltan ? aviso(`Show up sin marcar: hay ${ent(v.agendadas)} agendadas pero ninguna figura como presentada. Se completa días después de la llamada.`) : '') +
    card('Por closer', 'meta de cierre a definir', tabla(colsC, filasC, { foot: filasC.length ? ['Total', tot.a, tot.p, tot.c, tot.p ? pct((tot.c / tot.p) * 100) : '—'] : null, vacioTxt: 'Sin closers cargados este mes' }), { flush: true });
  const pool = [
    () => card('Cierres por cliente', `Total ${ent(v.cerradas)}`, hbars(v.porCliente.map(c => [nombreCliente(c.cliente), c.cerradas]))),
    () => strip([['Llamadas hoy y futuras', count(v.futuras)], ['No show', count(v.noShow)], ['Show up sin marcar', count(v.sinShowUp)], ['Cierres', count(v.cerradas)]]),
    () => card('De dónde sale', '', '<p class="mtxt">Agendadas incluye las futuras. Presentadas = columna Show up marcada «sí». Para los clientes sin planilla de llamadas (hoy Agus) los cierres salen de su hoja de cierres y las llamadas quedan en «sin dato».</p>')
  ];
  const cli = () => vh('Por cliente', sub(D, 'Ventas')) + card('Embudo por cliente', 'agendadas → presentadas → cierres', tabla(
    [{ h: 'Cliente' }, { h: 'Agendadas', num: 1 }, { h: 'Presentadas', num: 1 }, { h: 'Cierres', num: 1 }],
    v.porCliente.map(c => [nombreCliente(c.cliente), c.agendadas ?? SIN, c.presentadas ?? SIN, c.cerradas])), { flush: true });
  return [{ id: 'perf', label: 'Performance', base: perf, pool }, { id: 'cli', label: 'Por cliente', base: cli, pool: [pool[0], pool[2]] }];
}

/* ---------------- Seguimiento ---------------- */
function seguimiento(D) {
  const s = D.d.seguimiento;
  if (!s) return [{ id: 'cart', label: 'Cartera', base: () => vh('Cartera', sub(D, 'Seguimiento')) + sinLectura('Seguimiento'), pool: [] }];
  const estado = e => (e === 'onboarding' ? chip('info', 'Onboarding') : e === 'en_renovacion' ? chip('warn', 'En renovación') : chip('ok', 'Activo'));
  const lista = tabla([{ h: 'Alumno' }, { h: 'Cliente' }, { h: 'Estado' }], s.lista.slice(0, 7).map(a => [a.nombre, nombreCliente(a.cliente), { html: estado(a.estado), t: a.estado }]), { vacioTxt: 'Sin alumnos en seguimiento' });
  const cart = () => vh('Cartera', 'Alumnos en seguimiento HOY · no cambia con el mes · ' + D.cliTxt) +
    kpis([kpi('Alumnos en seguimiento', count(s.activos), 'activos, en onboarding o renovación', true), kpi('En onboarding', count(s.onboarding), 'arrancando'), kpi('En renovación', count(s.renovacion), 'por renovar'), kpi('Clientes con alumnos', count(s.porCliente.length), 'de los elegidos')]) +
    grid('1fr 1.4fr', card('Alumnos por cliente', `Total ${ent(s.activos)}`, hbars(porCli(s.porCliente))), card('Últimos alumnos', `${ent(s.lista.length)} de ${ent(s.activos)}`, lista, { flush: true }));
  const pool = [
    () => strip([['Activos', count(s.activos - s.onboarding - s.renovacion)], ['Onboarding', count(s.onboarding)], ['Renovación', count(s.renovacion)], ['Total', count(s.activos)]]),
    () => card('Qué mide esta pantalla', '', '<p class="mtxt">Cuenta los alumnos de Seguimiento (app de Producto) con estado activo, onboarding o en renovación. Es la foto de hoy: cambiar el mes no la modifica.</p>')
  ];
  return [{ id: 'cart', label: 'Cartera', base: cart, pool }];
}

/* ---------------- Soporte (sin datos todavía) ---------------- */
function soporte(D) {
  const base = () => vh('Tickets', sub(D, 'Pedidos y dudas de los alumnos')) +
    kpis([kpi('Abiertos', { t: SIN }, 'sin canal', true), kpi('Primera respuesta', { t: SIN }, 'sin canal'), kpi('Resueltos en plazo', { t: SIN }, 'sin canal'), kpi('Satisfacción', { t: SIN }, 'sin canal')]) +
    `<div class="grow">${card('Sin datos todavía', 'estado del área', vacio('Sin datos todavía',
      'Falta definir por dónde piden ayuda los alumnos (WhatsApp, mail o un formulario) para poder contar tickets y tiempos.',
      ['Canal de soporte por definir', 'Plazos de respuesta por prioridad', 'Quién atiende cada tipo de pedido']), { cls: 'fill' })}</div>`;
  return [{ id: 'tick', label: 'Tickets', base, pool: [] }];
}

export const marcosA = { marketing, setting, ventas, seguimiento, soporte };
