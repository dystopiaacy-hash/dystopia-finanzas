/* Mapa: marcos de Finanzas, Dystopia y Dirección, tarjeta «Empieza aquí», estructura del marco y flechas del recorrido. */
import { esc } from './ui.js';
import { nombreCliente, ABRIR } from './mapa.js';
import { marcosA } from './mapa-marcos.js';
import { SIN, ent, pct, money, count, uc, fecha, chip, delta, kpi, kpis, vh, card, aviso, grid, vacio, tabla, hbars, strip, linea, acumulado } from './mapa-ui.js';

const sub = (D, tx) => `${tx} · ${D.mesTxt} · ${D.cliTxt}`;
const sinLectura = area => aviso(`No se pudo leer ${area}: el resto del mapa sigue funcionando.`, 'bad');
const CATS = { ads: 'Ads', zoom: 'Zoom', landings: 'Landings', comisiones: 'Comisiones', otros: 'Otros' };
const nomConc = c => String(c || 'sin clasificar').replace(/_/g, ' ');

/* ---------------- Finanzas ---------------- */
function finanzas(D) {
  const p = D.d.plata, g = D.d.pagos, prev = D.d.prev;
  if (!p) return [{ id: 'caja', label: 'Flujo de caja', base: () => vh('Flujo de caja', sub(D, 'Finanzas')) + sinLectura('Finanzas'), pool: [] }];
  const gastosBajos = p.cash > 0 && p.gastos < p.cash * 0.01;
  const cats = Object.entries(p.categorias).filter(([, v]) => v != null && v > 0).map(([k, v]) => [CATS[k] || k, v, uc(v)]);
  const caja = () => vh('Flujo de caja', sub(D, 'Cobrado, gastado y ganancia del cliente')) +
    kpis([kpi('Cobrado', money(p.cash), delta(p.cash, prev && prev.cash), true), kpi('Gastos del cliente', money(p.gastos), delta(p.gastos, prev && prev.gastos, { invertir: true })),
      kpi('Ganancia del cliente', money(p.ganancia), delta(p.ganancia, prev && prev.ganancia)), kpi('Pagos cargados', count(g && g.cantidad), g ? `suman ${uc(g.total)}` : 'sin dato')]) +
    (gastosBajos ? aviso('Gastos del mes sin cargar: la ganancia está sobreestimada.') : '') +
    grid('1.45fr 1fr', card('Cobrado acumulado por día', g ? `${ent(g.cantidad)} pagos` : '', g ? linea(acumulado(g.porDia), { fmt: v => uc(v) }) : aviso('Pagos: sin dato', 'warn')),
      card('En qué se gasta', uc(p.gastos), hbars(cats, { vacioTxt: 'Sin gastos cargados' })));
  const pool = [
    () => strip([['Ads', money(p.categorias.ads)], ['Zoom', money(p.categorias.zoom)], ['Landings', money(p.categorias.landings)], ['Comisiones', money(p.categorias.comisiones)]]),
    () => card('Cobrado por concepto', uc(p.cash), hbars(p.porConcepto.slice(0, 5).map(([k, v]) => [nomConc(k), v, uc(v)]), { vacioTxt: 'Sin conceptos este mes' })),
    () => card('De dónde sale', '', `<p class="mtxt">Cobrado y gastos son los de Comparar y Cierre${p.cerrado ? ' (mes cerrado: foto del cierre)' : ' (mes abierto: en vivo)'}. La línea de arriba suma los pagos cargados en la app, que pueden diferir levemente.</p>`)
  ];
  const pagos = () => vh('Pagos', sub(D, 'Últimos pagos cargados')) + grid('1.5fr 1fr',
    card('Últimos pagos', g ? `${ent(g.cantidad)} en el mes` : '', g ? tabla([{ h: 'Fecha' }, { h: 'Alumno' }, { h: 'Concepto' }, { h: 'Monto', num: 1 }],
      g.ultimos.slice(0, 8).map(x => [fecha(x.fecha), x.alumno || '—', x.concepto || '—', money(Number(x.monto_usd) || 0)])) : aviso('Pagos: sin dato', 'warn'), { flush: true }),
    card('Cobrado por concepto', uc(p.cash), hbars(p.porConcepto.slice(0, 6).map(([k, v]) => [nomConc(k), v, uc(v)]), { vacioTxt: 'Sin conceptos este mes' })));
  return [{ id: 'caja', label: 'Flujo de caja', base: caja, pool }, { id: 'pagos', label: 'Pagos', base: pagos, pool: [pool[0], pool[2]] }];
}

/* ---------------- Dystopia ---------------- */
function dystopia(D) {
  const p = D.d.plata, prev = D.d.prev;
  if (!p) return [{ id: 'res', label: 'Resultado', base: () => vh('Resultado', sub(D, 'Dystopia')) + sinLectura('Dystopia'), pool: [] }];
  const filas = p.porCliente.map(c => [nombreCliente(c.cliente), money(c.fact), money(c.gastos), money(c.ganancia), c.pct != null ? pct(c.pct) : '—', money(c.dys)]);
  const res = () => vh('Resultado de la agencia', sub(D, 'Ganancia de Dystopia')) +
    kpis([kpi('Ganancia de Dystopia', money(p.gananciaDys), delta(p.gananciaDys, prev && prev.gananciaDys), true), kpi('% sobre la ganancia', { t: pct(p.pct) }, 'porcentaje vigente'),
      kpi('Ganancia de los clientes', money(p.ganancia), delta(p.ganancia, prev && prev.ganancia)), kpi('Facturación', money(p.cash), delta(p.cash, prev && prev.cash))]) +
    card('Por cliente', 'ganancia × porcentaje', tabla([{ h: 'Cliente' }, { h: 'Facturación', num: 1 }, { h: 'Gastos', num: 1 }, { h: 'Ganancia', num: 1 }, { h: '%', num: 1 }, { h: 'Dystopia', num: 1 }], filas,
      { foot: filas.length > 1 ? ['Total', money(p.cash), money(p.gastos), money(p.ganancia), pct(p.pct), money(p.gananciaDys)] : null, vacioTxt: 'Sin clientes este mes' }), { flush: true });
  const pool = [
    () => card('Ganancia de Dystopia por cliente', uc(p.gananciaDys), hbars(p.porCliente.map(c => [nombreCliente(c.cliente), Math.max(0, c.dys), uc(c.dys)]))),
    () => strip([['Transferencias del mes', count(p.trans.length)], ['Hechas', count(p.transHechas)], ['Total a transferir', money(p.transTotal)], ['Mes', { t: p.cerrado ? 'Cerrado' : 'Abierto' }]]),
    () => card('Cómo se calcula', '', '<p class="mtxt">Ganancia del cliente = facturación − gastos. Ganancia de Dystopia = esa ganancia × el porcentaje vigente de cada cliente. Es la misma cuenta de Dystopia y de Comparar.</p>')
  ];
  const estado = e => (e === 'hecha' ? chip('ok', 'Hecha') : chip('warn', 'Pendiente'));
  const trans = () => vh('Transferencias', sub(D, 'Del cierre de mes · solo lectura')) +
    kpis([kpi('A transferir', money(p.transTotal), `${ent(p.trans.length)} transferencias`, true), kpi('Hechas', count(p.transHechas), 'marcadas como hechas'), kpi('Pendientes', count(p.trans.length - p.transHechas), 'por hacer')]) +
    card('Transferencias del mes', p.cerrado ? 'mes cerrado' : 'mes abierto', tabla([{ h: 'Destinatario' }, { h: 'Concepto' }, { h: 'Cliente' }, { h: 'Monto', num: 1 }, { h: 'Estado' }],
      p.trans.slice(0, 8).map(t => [t.destinatario, t.concepto, t.cliente ? nombreCliente(t.cliente) : '—', money(t.monto), { html: estado(t.estado), t: t.estado }]), { vacioTxt: 'Sin transferencias calculadas este mes' }), { flush: true });
  return [{ id: 'res', label: 'Resultado', base: res, pool }, { id: 'trans', label: 'Transferencias', base: trans, pool: [pool[2]] }];
}

/* ---------------- Dirección ---------------- */
function direccion(D) {
  const { marketing: m, ventas: v, plata: p, prev } = D.d;
  const pz = m ? m.piezas : null, ag = v ? v.agendadas : null, ci = v ? v.cerradas : null, cash = p ? p.cash : null, gd = p ? p.gananciaDys : null;
  const kp = (l, val, act, pv, primary) => kpi(l, val, delta(act, pv), primary);
  const filas = [['Piezas publicadas', pz, prev && prev.piezas, ent], ['Llamadas agendadas', ag, prev && prev.agendadas, ent], ['Cierres', ci, prev && prev.cerradas, ent],
    ['Cobrado', cash, prev && prev.cash, uc], ['Ganancia de Dystopia', gd, prev && prev.gananciaDys, uc]].map(([k, a, b, f]) => {
    const pv = a != null && b ? ((a - b) / Math.abs(b)) * 100 : null;
    return [k, a == null ? SIN : { t: f(a), title: String(a) }, b == null ? SIN : f(b), pv == null ? '—' : { html: `<span class="kd ${pv >= 0 ? 'up' : 'dn'}">${pv >= 0 ? '▲' : '▼'} ${pct(Math.abs(pv))}</span>`, t: '' }];
  });
  const areas = [
    ['Marketing', m ? `${ent(m.piezas)} piezas publicadas` : 'sin dato', m ? chip('ok', 'Con datos') : chip('n', 'Sin dato')],
    ['Setting', 'sin datos todavía', chip('n', 'Pendiente')],
    ['Ventas', v ? `${ent(v.agendadas ?? 0)} agendas · ${ent(v.cerradas)} cierres` : 'sin dato', v ? (v.agendadas > 0 && v.presentadas === 0 ? chip('warn', 'Mirar') : chip('ok', 'Bien')) : chip('n', 'Sin dato')],
    ['Seguimiento', D.d.seguimiento ? `${ent(D.d.seguimiento.activos)} alumnos en seguimiento` : 'sin dato', D.d.seguimiento ? chip('ok', 'Con datos') : chip('n', 'Sin dato')],
    ['Finanzas', p ? `${uc(p.cash)} cobrado · ${uc(p.gastos)} de gastos` : 'sin dato', p ? (p.cash > 0 && p.gastos < p.cash * 0.01 ? chip('warn', 'Mirar') : chip('ok', 'Bien')) : chip('n', 'Sin dato')]
  ];
  const cadena = () => vh('Resumen', sub(D, 'La agencia en una pantalla')) +
    kpis([kp('Piezas', count(pz), pz, prev && prev.piezas, true), kp('Agendas', count(ag), ag, prev && prev.agendadas), kp('Cierres', count(ci), ci, prev && prev.cerradas), kp('Cobrado', money(cash), cash, prev && prev.cash), kp('Ganancia Dystopia', money(gd), gd, prev && prev.gananciaDys)]) +
    grid('1.35fr 1fr', card('La cadena del mes contra el anterior', 'piezas → agendas → cierres → cobrado → Dystopia', tabla([{ h: 'Eslabón' }, { h: 'Este mes', num: 1 }, { h: 'Mes anterior', num: 1 }, { h: 'Variación', num: 1 }], filas), { flush: true }),
      card('Cada área en una línea', '', `<ul class="mlist">${areas.map(([k, t, c]) => `<li><span class="li-t"><b>${esc(k)}</b> · ${esc(t)}</span><span class="li-d">${c}</span></li>`).join('')}</ul>`));
  const pool = [
    () => strip([['Cobrado por cierre', money(ci ? (cash || 0) / ci : null)], ['Show up sin marcar', count(v && v.sinShowUp)], ['Alumnos en seguimiento', count(D.d.seguimiento && D.d.seguimiento.activos)], ['% Dystopia', { t: p ? pct(p.pct) : SIN }]]),
    () => card('Cómo leer el tablero', '', '<p class="mtxt">Cada número sale del marco de su área, con el mismo cliente y mes que elegiste arriba. «Mes anterior» es el mismo cliente un mes antes. Las metas todavía no están definidas.</p>')
  ];
  const metas = () => vh('Metas', sub(D, 'Objetivos del mes')) + `<div class="grow">${card('Metas a definir', '', vacio('Metas a definir',
    'Todavía no hay metas cargadas. Cuando se definan, acá se compara cada eslabón de la cadena contra su meta.', ['Meta de piezas por mes', 'Meta de agendas y de cierres', 'Meta de cobrado y de ganancia de Dystopia']), { cls: 'fill' })}</div>`;
  return [{ id: 'res', label: 'Resumen', base: cadena, pool }, { id: 'metas', label: 'Metas', base: metas, pool: [] }];
}

/* ---------------- Definición de los 8 marcos en orden de recorrido ---------------- */
export const AREAS = [
  { id: 'marketing', nombre: 'Marketing', sub: 'Piezas publicadas', regla: 'Cada pieza publicada tiene que traer gente nueva a la agenda.', f: marcosA.marketing },
  { id: 'setting', nombre: 'Setting', sub: 'Conversaciones que se vuelven agendas', regla: 'Una conversación sin calificar no cuenta como agenda.', f: marcosA.setting },
  { id: 'ventas', nombre: 'Ventas', sub: 'Llamadas, cierres y cobros', regla: 'Toda llamada agendada se atiende y toda venta queda cargada el mismo día.', f: marcosA.ventas },
  { id: 'seguimiento', nombre: 'Seguimiento', sub: 'Servicio al cliente', regla: 'Ningún alumno pasa más de una semana sin que alguien lo contacte.', f: marcosA.seguimiento },
  { id: 'soporte', nombre: 'Soporte', sub: 'Pedidos y dudas de los alumnos', regla: 'Todo pedido de un alumno tiene una respuesta y un plazo.', f: marcosA.soporte },
  { id: 'finanzas', nombre: 'Finanzas', sub: 'Cobrado, gastos y ganancia', regla: 'Lo cobrado y lo gastado del mes se cierra con números reales, no estimados.', f: finanzas },
  { id: 'dystopia', nombre: 'Dystopia', sub: 'El resultado de la agencia', regla: 'La ganancia de la agencia es su porcentaje de lo que gana cada cliente.', f: dystopia },
  { id: 'direccion', nombre: 'Dirección', sub: 'La agencia en una pantalla', regla: 'Cada número del tablero se puede seguir hasta el área de donde sale.', f: direccion }
];

const FW = 1240, FH = 800, GX = 300, GY = 420;
/* Serpiente: fila 1 a la derecha (Marketing, Setting, Ventas, Seguimiento); fila 2 vuelve (Soporte, Finanzas, Dystopia, Dirección). */
const CELDAS = [[0, 0], [1, 0], [2, 0], [3, 0], [3, 1], [2, 1], [1, 1], [0, 1]];
export const posicion = i => ({ x: CELDAS[i][0] * (FW + GX), y: CELDAS[i][1] * (FH + GY), w: FW, h: FH });
export const INTRO = { x: -1300, y: 0, w: 1000, h: 2 * FH + GY };
export const BOUNDS = (() => { const x0 = INTRO.x, x1 = 3 * (FW + GX) + FW, y1 = 2 * FH + GY; return { x: x0 - 150, y: -100, w: x1 - x0 + 300, h: y1 + 350 }; })();

/* Rótulos de las flechas con los números reales encadenados. */
export function enlaces(D) {
  const { marketing: m, ventas: v, plata: p, seguimiento: s } = D.d;
  /* Un rótulo por tramo, con lo que SALE del área de origen hacia la siguiente. */
  const T = [m ? `${ent(m.piezas)} piezas` : 'piezas: sin dato', v && v.agendadas != null ? `${ent(v.agendadas)} agendas` : 'agendas: sin dato', v ? `${ent(v.cerradas)} cierres` : 'cierres: sin dato',
    s ? `${ent(s.activos)} alumnos` : 'alumnos: sin dato', p ? `${uc(p.cash)} cobrado` : 'cobrado: sin dato', p ? `${uc(p.ganancia)} ganancia del cliente` : 'ganancia: sin dato', p ? `${uc(p.gananciaDys)} Dystopia` : 'Dystopia: sin dato'];
  const L = [['r', 'l'], ['r', 'l'], ['r', 'l'], ['b', 't'], ['l', 'r'], ['l', 'r'], ['l', 'r']];
  return L.map(([a, b], i) => ({ de: i, a: i + 1, ladoDe: a, ladoA: b, txt: T[i] }));
}

const ICO = ['M4 6h16M4 12h16M4 18h10', 'M12 3v18M3 12h18', 'M4 20V10M10 20V4M16 20v-7M22 20H2', 'M3 12h4l3-8 4 16 3-8h4'];
const logo = '<span class="logo">D</span>';

/* HTML de un marco de área (1240x800). El motor activa pestañas y rellena. */
export function htmlMarco(a, i, D) {
  const tabs = a.f(D);
  const ab = ABRIR[a.id];
  const boton = ab ? (ab.url ? `<a class="abrir" href="${esc(ab.url)}" target="_blank" rel="noopener noreferrer">${esc(ab.txt)} ↗</a>` : `<a class="abrir" href="${esc(ab.ruta)}">${esc(ab.txt)} →</a>`)
    : '<span class="abrir off" title="Todavía no hay una app para esta área">Sin app todavía</span>';
  return `<section class="frame" id="f-${a.id}" data-i="${i + 1}" style="left:${posicion(i).x}px;top:${posicion(i).y}px">
    <a class="flabel" href="#${a.id}" data-go="${i + 1}"><span class="fnum">${String(i + 1).padStart(2, '0')}</span><span class="fname">${esc(a.nombre)}</span><span class="fsub"> · ${esc(a.sub)}</span></a>
    <div class="app">
      <div class="app-top">${logo}<b class="at-t">Dystopia</b><span class="at-m">/ <b>${esc(a.nombre)}</b></span>
        <span class="chip ok live"><i></i>Datos reales</span><span class="at-f">${esc(D.mesTxt)} · ${esc(D.cliTxt)}</span>${boton}</div>
      <div class="app-body">
        <nav class="app-nav" aria-label="${esc(a.nombre)}"><div class="grp">${esc(a.nombre)}</div>
          ${tabs.map((t, k) => `<button type="button" class="tab${k ? '' : ' on'}" data-tab="${t.id}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="${ICO[k % ICO.length]}"/></svg>${esc(t.label)}</button>`).join('')}
          <div class="nav-foot"><b>Regla del área</b><p>${esc(a.regla)}</p></div></nav>
        <div class="app-main">${tabs.map((t, k) => `<div class="view" data-view="${t.id}"${k ? ' hidden' : ''}>${t.base()}</div>`).join('')}</div>
      </div></div></section>`;
}
export const poolDe = (a, D) => Object.fromEntries(a.f(D).map(t => [t.id, t.pool]));

/* Tarjeta «Empieza aquí» (marco 0). */
export function htmlIntro(D) {
  const { marketing: m, ventas: v, plata: p } = D.d;
  const cifras = [[String(AREAS.length), 'áreas conectadas'], [m ? ent(m.piezas) : SIN, 'piezas publicadas en el mes'], [v ? ent(v.cerradas) : SIN, 'cierres del mes'], [p ? uc(p.cash) : SIN, 'cobrado en el mes']];
  return `<section class="intro" id="f-inicio" data-i="0" style="left:${INTRO.x}px;top:${INTRO.y}px;width:${INTRO.w}px;height:${INTRO.h}px">
    <div class="eyebrow">MAPA DE SISTEMAS · DYSTOPIA AGENCY</div>
    <h2>Cómo funciona la agencia, de punta a punta</h2>
    <p class="lead">Este mapa junta en una sola pantalla las áreas por las que pasa un alumno: desde la pieza de contenido que lo trae hasta la ganancia que le queda a la agencia. Cada marco es la pantalla real de un área, con los números reales del mes y del cliente que elijas arriba.</p>
    <p>Los números se leen de las mismas fuentes que las demás apps, sin planillas aparte. Desde acá no se edita nada: cada marco tiene su botón para abrir la app donde sí se trabaja.</p>
    <div class="cifras">${cifras.map(([n, t]) => `<div><b>${esc(n)}</b><span>${esc(t)}</span></div>`).join('')}</div>
    <div class="indice">${AREAS.map((a, i) => `<button type="button" data-go="${i + 1}"><span>${String(i + 1).padStart(2, '0')}</span>${esc(a.nombre)}</button>`).join('')}</div>
    <div class="como"><div><b>Moverse</b>Arrastrá el fondo. En el celular, con el dedo.</div><div><b>Acercarse</b>Rueda del mouse, pellizco, doble clic, o las teclas + y −.</div><div><b>Saltar</b>Las teclas 1 a 8 van a cada área, 0 muestra todo y P presenta.</div></div>
    <p class="foot">Las flechas muestran lo que pasa de un área a la siguiente con los números del mes elegido.</p></section>`;
}
