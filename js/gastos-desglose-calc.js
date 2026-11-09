/* Desglose de gastos y ROAS (solo cuentas, sin DOM ni Supabase: se prueba en Node). Todo se arma desde lo que ya
   existe en otras pantallas; no se copia ningún monto:
     - Opps: fin_pnl (gastos que el cliente declara en su planilla)
     - Gastos cargados + IA automática: fin_v_gastos_mes (174)
     - Webinars: fin_webinar_gastos (267); los marcados en_opps ya están en Opps y NO suman de nuevo
     - Comisiones: salen del Cierre (fin_v_dys_ganancia_mes: gastos_comision_usd + comision_opps_vigente_usd)
   El total del Cierre (gastos_cliente_usd) se muestra al lado para ver si cierra. */

export const CLIENTES = [['liam', 'Liam'], ['agus', 'Agus'], ['teo', 'Teo']];
export const nombreCli = id => (CLIENTES.find(c => c[0] === id) || [id, id])[1];
export const BUCKETS = [['ads', 'Ads'], ['manychat', 'ManyChat'], ['bunny', 'Bunny'], ['ia', 'IA'], ['herramientas', 'Otras herramientas'],
  ['zoom', 'Zoom'], ['landing', 'Landings'], ['comisiones', 'Comisiones'], ['otros', 'Otros']];
export const nombreBucket = b => (BUCKETS.find(x => x[0] === b) || [b, b])[1];
/* Gasto imputable al ROAS: ads + herramientas (ManyChat, Bunny, IA, otras, Zoom, landings). No entran comisiones ni «Otros». */
export const IMPUTABLES = new Set(['ads', 'manychat', 'bunny', 'ia', 'herramientas', 'zoom', 'landing']);
export const CONCEPTO_A_BUCKET = {
  ads_webinar: 'ads', ads_replay: 'ads', zoom: 'zoom', landing: 'landing', ghl: 'herramientas', manychat: 'manychat',
  whatsapp: 'herramientas', addevent: 'herramientas', comision_closer: 'comisiones', otros: 'otros'
};

const n = v => Number(v) || 0;
const r2 = v => Math.round(v * 100) / 100;
const mm = v => String(v).padStart(2, '0');
export const ymDe = (anio, mes) => `${anio}-${mm(mes)}`;

/* Clasifica un texto libre (item de Opps, categoría + descripción de un gasto). Mismo espíritu que fin_comparar_patrones (280). */
export function bucketTexto(texto) {
  const t = String(texto || '').toLowerCase();
  if (/closer|setter/.test(t)) return 'comisiones';
  if (/manychat/.test(t)) return 'manychat';
  if (/bunny/.test(t)) return 'bunny';
  if (/zoom/.test(t)) return 'zoom';
  if (/landing|funnel|clickfunnels/.test(t)) return 'landing';
  if (/\bads\b|adset|publicidad|anuncio|facebook|\bmeta\b|tiktok|youtube|google/.test(t)) return 'ads';
  if (/ghl|gohighlevel|software|suscrip|herramienta|whatsapp|addevent|zapier|notion|canva|\bia\b|claude|gemini|openai/.test(t)) return 'herramientas';
  return 'otros';
}

/* Todas las líneas de gasto, cada una con su origen. suma=false: se muestra pero no entra en el total (ya está en otro lado). */
export function armarLineas({ opps = [], gastos = [], webGastos = [], webs = [], ganancia = [] }) {
  const L = [];
  const esCli = id => CLIENTES.some(c => c[0] === id);
  for (const o of opps) {
    if (!esCli(o.cliente_id) || o.categoria === 'revenue') continue;
    const b = bucketTexto(o.item);
    const com = b === 'comisiones';
    L.push({ cli: o.cliente_id, ym: ymDe(o.anio, o.mes), origen: 'Opps', bucket: b, concepto: o.item, monto: n(o.monto_usd), suma: !com,
      nota: com ? 'Las comisiones de closer/setter salen del Cierre (línea «Cierre»)' : '' });
  }
  for (const g of gastos) {
    if (!esCli(g.entidad)) continue;
    const ia = g.origen === 'ia_auto' || g.categoria_clave === 'ia';
    const b = ia ? 'ia' : bucketTexto(`${g.categoria || ''} ${g.descripcion || ''}`);
    const propio = g.reparto === 'dystopia';
    L.push({ cli: g.entidad, ym: String(g.mes).slice(0, 7), origen: ia ? 'IA automática' : 'Gastos', bucket: b, concepto: g.descripcion || g.categoria || '',
      monto: n(g.monto_usd), suma: !propio, nota: propio ? '100% Dystopia: no entra en los gastos del cliente' : '', reparto: g.reparto, gastoId: g.gasto_id });
  }
  const web = new Map(webs.map(w => [w.webinar_id, w]));
  for (const g of webGastos) {
    const w = web.get(g.webinar_id);
    if (!w || !esCli(w.cliente_id)) continue;
    L.push({ cli: w.cliente_id, ym: String(g.fecha).slice(0, 7), origen: 'Webinar', bucket: CONCEPTO_A_BUCKET[g.concepto] || 'otros',
      concepto: `${w.nombre}: ${g.concepto}`, monto: n(g.monto_usd), suma: !g.en_opps,
      nota: g.en_opps ? 'Ya está en Opps de ese mes: no se suma de nuevo' : '', webinarId: g.webinar_id, enOpps: !!g.en_opps, conceptoWeb: g.concepto });
  }
  for (const f of ganancia) {
    if (!esCli(f.entidad)) continue;
    const c = n(f.gastos_comision_usd) + n(f.comision_opps_vigente_usd);
    if (c) L.push({ cli: f.entidad, ym: String(f.mes).slice(0, 7), origen: 'Cierre', bucket: 'comisiones', concepto: 'Comisiones de closers/setters', monto: c, suma: true,
      nota: f.comision_modo === 'opps' ? 'Mes sin comisiones calculadas: vienen de las líneas de Opps' : 'Calculadas en el Cierre de mes' });
  }
  return L;
}

/* Una fila por cliente y mes: gasto por bucket, total, imputable, total del Cierre, ingresos y ROAS. */
export function resumenPorMes(lineas, ganancia) {
  const m = new Map();
  const fila = (cli, ym) => {
    const k = `${cli}|${ym}`;
    if (!m.has(k)) m.set(k, { cli, ym, b: Object.fromEntries(BUCKETS.map(x => [x[0], 0])), total: 0, imputable: 0, cierre: null, ingresos: null, fuenteIngresos: '', op: 0, ca: 0, wb: 0, cm: 0 });
    return m.get(k);
  };
  for (const l of lineas) {
    if (!l.suma) continue;
    const f = fila(l.cli, l.ym);
    f.b[l.bucket] = r2(f.b[l.bucket] + l.monto);
    f.total = r2(f.total + l.monto);
    if (IMPUTABLES.has(l.bucket)) f.imputable = r2(f.imputable + l.monto);
    if (l.origen === 'Opps') f.op = r2(f.op + l.monto);
    else if (l.origen === 'Gastos' || l.origen === 'IA automática') f.ca = r2(f.ca + l.monto);
    else if (l.origen === 'Webinar') f.wb = r2(f.wb + l.monto);
    else if (l.origen === 'Cierre') f.cm = r2(f.cm + l.monto);
  }
  for (const g of ganancia) {
    if (!CLIENTES.some(c => c[0] === g.entidad)) continue;
    const f = fila(g.entidad, String(g.mes).slice(0, 7));
    f.cierre = n(g.gastos_cliente_usd); f.ingresos = n(g.facturacion_usd); f.fuenteIngresos = g.fuente_facturacion || '';
  }
  for (const f of m.values()) f.roas = f.ingresos != null && f.imputable > 0 ? r2(f.ingresos / f.imputable) : null;
  return [...m.values()].sort((a, b) => (a.ym < b.ym ? 1 : a.ym > b.ym ? -1 : a.cli.localeCompare(b.cli)));
}

/* ROAS por webinar: cash (pagos con fuente webinar en la ventana + ajustes) / gasto imputable (ads + herramientas, incluidos
   los que ya están en Opps; sin comisión del closer ni «otros»). roasAds = el de la pantalla Webinars (solo ads). */
export function roasWebinars(webs, webGastos) {
  return webs.map(w => {
    const gs = webGastos.filter(g => g.webinar_id === w.webinar_id);
    const imputable = r2(gs.filter(g => IMPUTABLES.has(CONCEPTO_A_BUCKET[g.concepto] || 'otros')).reduce((a, g) => a + n(g.monto_usd), 0));
    const cash = n(w.cash_usd);
    return { webinarId: w.webinar_id, cli: w.cliente_id, nombre: w.nombre, fecha: w.fecha, cash, imputable, ads: n(w.ads_usd), probable: n(w.ingreso_probable_usd),
      roas: imputable > 0 && (cash > 0 || gs.length) ? r2(cash / imputable) : null, roasAds: w.roas != null ? n(w.roas) : null, sinGastos: gs.length === 0 };
  });
}

/* ROAS por funnel. Ingresos: pagos por fuente final (fin_v_pago_fuente). Gasto: solo el que se puede atribuir con los datos:
   webinar = gastos imputables de sus webinars; landing = landings que no son de un webinar. Los demás canales no tienen
   gasto atribuible (Opps no separa ads por canal) -> ROAS «sin dato». cli / ym vacíos = todos. */
export function roasFunnels(pagos, lineas, webs, cli = '', ym = '') {
  const okP = p => (!cli || p.cliente_id === cli) && (!ym || String(p.fecha).slice(0, 7) === ym);
  const okL = l => (!cli || l.cli === cli) && (!ym || l.ym === ym);
  const grupo = p => {
    const f = String(p.fuente_final || '').trim().toLowerCase();
    if (p.es_webinar) return 'webinar';
    if (!f) return 'sin fuente';
    if (/landing/.test(f)) return 'landing';
    if (/vsl/.test(f)) return 'vsl';
    return f;
  };
  const ing = new Map();
  for (const p of pagos.filter(okP)) {
    const g = grupo(p); const a = ing.get(g) || { usd: 0, n: 0 };
    a.usd = r2(a.usd + n(p.monto_usd)); a.n += 1; ing.set(g, a);
  }
  const L = lineas.filter(okL).filter(l => l.suma || l.enOpps);
  const gasto = {
    webinar: r2(L.filter(l => l.origen === 'Webinar' && IMPUTABLES.has(l.bucket)).reduce((a, l) => a + l.monto, 0)),
    landing: r2(L.filter(l => l.origen !== 'Webinar' && l.suma && l.bucket === 'landing').reduce((a, l) => a + l.monto, 0))
  };
  const claves = ['webinar', 'landing', 'vsl', ...[...ing.keys()].filter(k => !['webinar', 'landing', 'vsl', 'sin fuente'].includes(k)).sort(), 'sin fuente'];
  const out = claves.map(k => {
    const i = ing.get(k); const g = gasto[k];
    const ingresos = i ? i.usd : null;
    const motivo = !i ? (k === 'vsl' || k === 'landing' ? 'Ningún pago trae esta fuente: no hay forma de atribuir ingresos' : 'Sin pagos')
      : g == null ? 'No hay gasto atribuible a este canal (Opps no separa ads por canal)' : (g <= 0 ? 'Sin gasto cargado' : '');
    return { funnel: k, ingresos, pagos: i ? i.n : 0, gasto: g == null ? null : g, roas: i && g > 0 ? r2(i.usd / g) : null, motivo };
  });
  return out;
}

/* Control: ManyChat cargado como gasto mensual Y como gasto de webinar en el mismo cliente y mes (se contaría dos veces). */
export function avisosDuplicados(lineas) {
  const k = new Map();
  for (const l of lineas) {
    if (l.bucket !== 'manychat' || !l.suma) continue;
    const a = k.get(`${l.cli}|${l.ym}`) || { cli: l.cli, ym: l.ym, web: 0, otros: 0 };
    if (l.origen === 'Webinar') a.web += 1; else a.otros += 1;
    k.set(`${l.cli}|${l.ym}`, a);
  }
  return [...k.values()].filter(a => a.web && a.otros);
}
