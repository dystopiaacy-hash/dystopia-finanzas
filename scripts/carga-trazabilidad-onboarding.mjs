// carga-trazabilidad-onboarding.mjs - genera migraciones/248_ventas_trazabilidad_onboarding_datos.sql
//
// Uso (desde dystopia-finanzas, Node 18+, sin instalar nada):
//   node scripts/carga-trazabilidad-onboarding.mjs [carpeta-sheets] [carpeta-formulas]
// Por defecto lee los CSV de ..\dystopia-ventas\insumos\sheets-2026-10-28 y ...\formulas-2026-10-28:
//   CRM_VENTAS_-_BPF/Trazabilidad_-_Data.csv        -> fin_trazabilidad (liam)
//   CRM_VENTAS_-_BPF/Dashoboard_-_Onboarding.csv    -> fin_hoja_resumen hoja 'onboarding' (liam, foto "Septiembre n=44")
//   formulas/Dashboard_Trazabilidad__formulas.csv   -> fin_hoja_resumen hoja 'trazabilidad' (liam, secciones 6 y 7)
//   CRM_Ventas_NEC/DATA_ONBOARDING.csv              -> fin_onboarding_respuestas (teo)
// Escribe: migraciones/248_...sql (se corre en el SQL Editor, DESPUES de la 247) y
//          scripts/salida/248_reporte.txt (leer antes de correr). No toca la base.
// El SQL sale en ASCII puro (los acentos como U&'\00E1') para que no se rompa al copiarlo.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const ventas = path.resolve(aqui, '..', '..', 'dystopia-ventas', 'insumos');
const dirSheets = process.argv[2] || path.join(ventas, 'sheets-2026-10-28');
const dirForm = process.argv[3] || path.join(ventas, 'formulas-2026-10-28');

function csv(txt) {
  const rows = []; let cur = [], f = '', q = false;
  for (let i = 0; i < txt.length; i++) {
    const c = txt[i];
    if (q) { if (c === '"') { if (txt[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { cur.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && txt[i + 1] === '\n') i++; cur.push(f); rows.push(cur); cur = []; f = ''; }
    else f += c;
  }
  if (f !== '' || cur.length) { cur.push(f); rows.push(cur); }
  return rows;
}
const leer = (...p) => csv(fs.readFileSync(path.join(...p), 'utf8').replace(/^﻿/, ''));
const sinAcentos = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const limpio = v => { const s = String(v ?? '').trim(); return s === '' ? null : s; };
const reporte = [];
const aviso = t => { reporte.push(t); };

// ------------------------------------------------------------ SQL helpers
function lit(s) {
  if (s === null || s === undefined) return 'NULL';
  const t = String(s);
  if (!/[^\x20-\x7E\n\r\t]/.test(t)) return `'${t.replace(/'/g, "''")}'`;
  let out = '';
  for (const ch of t) {
    const cp = ch.codePointAt(0);
    if (ch === "'") out += "''";
    else if (ch === '\\') out += '\\\\';
    else if (cp < 128) out += ch;
    else if (cp <= 0xffff) out += '\\' + cp.toString(16).padStart(4, '0');
    else out += '\\+' + cp.toString(16).padStart(6, '0');
  }
  return `U&'${out}'`;
}
const jsonLit = o => `'${JSON.stringify(o).replace(/[\u0080-￿]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')).replace(/'/g, "''")}'::jsonb`;
const numLit = n => (n === null || n === undefined || Number.isNaN(n) ? 'NULL' : String(n));

// ------------------------------------------------------------ 1. Trazabilidad - Data (liam)
const traz = leer(dirSheets, 'CRM_VENTAS_-_BPF', 'Trazabilidad_-_Data.csv');
const iHdr = traz.findIndex(r => sinAcentos(r[1]) === 'cc' && sinAcentos(r[2]) === 'nombre');
if (iHdr < 0) { console.error('Trazabilidad - Data: no encuentro el encabezado (CC / NOMBRE).'); process.exit(1); }
const esperado = ['', 'cc', 'nombre', 'formato primer contacto', 'angulo primer contacto', 'otros contactos', 'analisis del chat', 'tipo de cliente', 'formato ultimo contacto', 'angulo primer contacto', 'fuente', 'ig', 'manychat'];
esperado.forEach((e, i) => { if (i && !sinAcentos(traz[iHdr][i]).startsWith(e)) { console.error(`Trazabilidad - Data: la columna ${i + 1} es "${traz[iHdr][i]}" y se esperaba "${e}".`); process.exit(1); } });
const montoCc = v => {
  const s = String(v ?? '').replace(/[$\s]/g, '');
  if (!s) return null;
  const n = Number(s.replace(/\./g, '').replace(',', '.'));
  return Number.isFinite(n) ? n : NaN;
};
const trazFilas = [];
traz.slice(iHdr + 1).forEach((r, k) => {
  const fila = iHdr + 2 + k;   // numero de fila en la hoja (1 = primera)
  if (r.every(x => String(x ?? '').trim() === '')) return;
  const nombre = limpio(r[2]);
  if (!nombre) { aviso(`Trazabilidad fila ${fila}: sin nombre, se salta.`); return; }
  const f = limpio(r[0]);
  const fecha = f && /^\d{4}-\d{2}-\d{2}/.test(f) ? f.slice(0, 10) : null;
  if (f && !fecha) aviso(`Trazabilidad fila ${fila} (${nombre}): fecha "${f}" no reconocida, queda vacia.`);
  if (!f) aviso(`Trazabilidad fila ${fila} (${nombre}): sin fecha.`);
  const cc = montoCc(r[1]);
  if (Number.isNaN(cc)) aviso(`Trazabilidad fila ${fila} (${nombre}): CC "${r[1]}" no es un monto, queda vacio.`);
  trazFilas.push({ fila, fecha, cc: Number.isNaN(cc) ? null : cc, nombre,
    f1: limpio(r[3]), a1: limpio(r[4]), otros: limpio(r[5]), chat: limpio(r[6]), tipo: limpio(r[7]),
    f2: limpio(r[8]), a2: limpio(r[9]), fuente: limpio(r[10]), ig: limpio(r[11]), many: limpio(r[12]) });
});

// ------------------------------------------------------------ 2. Dashoboard - Onboarding (liam, foto)
const onb = leer(dirSheets, 'CRM_VENTAS_-_BPF', 'Dashoboard_-_Onboarding.csv');
const tituloOnb = limpio(onb.find(r => limpio(r[0]))?.[0]) || 'Dashoboard - Onboarding';
const nOnb = Number((tituloOnb.match(/n\s*=\s*(\d+)/) || [])[1]) || null;
const resumenOnb = [];  // {orden_seccion, seccion, orden, categoria, cantidad, porcentaje}
{
  let sec = 0, seccion = null, orden = 0, enTabla = false;
  for (const r of onb) {
    const a = limpio(r[0]);
    if (!a) { enTabla = false; continue; }
    if (/^\d+\.\s/.test(a)) { sec += 1; seccion = a.replace(/^\d+\.\s*/, ''); orden = 0; enTabla = false; continue; }
    if (seccion && !enTabla && (sinAcentos(a) === 'categoria' || sinAcentos(a) === 'metrica')) { enTabla = true; continue; }
    if (seccion && enTabla) {
      const cant = limpio(r[1]) === null ? null : Number(String(r[1]).replace(',', '.'));
      const p = limpio(r[2]);
      const pc = p && /%$/.test(p) ? Number(p.replace('%', '').replace(',', '.')) / 100 : null;
      orden += 1;
      resumenOnb.push({ sec, seccion, orden, categoria: a, cantidad: Number.isFinite(cant) ? cant : null, porcentaje: pc });
    } else if (/^lectura/i.test(a)) {
      sec += 1;
      resumenOnb.push({ sec, seccion: 'Lectura', orden: 1, categoria: a, cantidad: null, porcentaje: null });
    }
  }
}

// ------------------------------------------------------------ 3. Dashboard Trazabilidad, secciones 6 y 7 (liam, foto)
const dt = new Map(leer(dirForm, 'Dashboard_Trazabilidad__formulas.csv').map(r => [r[0], r[1]]));
const tituloTraz = limpio(dt.get('A2')) || 'Dashboard Trazabilidad';
const resumenTraz = [];
{
  const filas = [...dt.keys()].filter(k => /^A\d+$/.test(k)).map(k => Number(k.slice(1))).sort((a, b) => a - b);
  let sec = 0, seccion = null, orden = 0;
  for (const n of filas) {
    const a = limpio(dt.get('A' + n));
    if (!a) continue;
    const m = a.match(/^(\d+)\.\s*(.+)$/);
    if (m) { seccion = Number(m[1]) >= 6 ? m[2] : null; if (seccion) { sec = Number(m[1]); orden = 0; } continue; }
    if (seccion) { orden += 1; resumenTraz.push({ sec, seccion, orden, categoria: a, cantidad: null, porcentaje: null }); }
  }
}

// ------------------------------------------------------------ 4. DATA ONBOARDING (teo)
const nec = leer(dirSheets, 'CRM_Ventas_NEC', 'DATA_ONBOARDING.csv');
const SLUGS = [
  ['marca', 'marca temporal'], ['nombre', 'nombre'], ['apellido', 'apellido'], ['telefono', 'numero de telefono'], ['email', 'mail'],
  ['perfil', 'con cual de estos'], ['facturacion', 'cuanto estas facturando'], ['nicho', 'en que nicho'], ['conocio', 'por donde me conociste'],
  ['formato', 'que formato de mi contenido'], ['por_que_formato', 'por que elegiste ese formato'], ['temas', 'que temas te guste'],
  ['dijo_si', 'que te hizo finalmente decir'], ['motivo_accion', 'que te motivo especificamente'], ['expectativas', 'que es lo que esperas'],
  ['tiempo_decidir', 'cuanto tiempo tardaste'], ['mejor_antes', 'que crees que podria haber funcionado'], ['mejora', 'que aspecto del punto'],
  ['problemas', 'cuales eran tus problemas principales'], ['ultimo_convencio', 'que fue lo ultimo que te convencio'], ['impedia', 'que fue lo que impedia'],
  ['mentoria_previa', 'antes de entrar'], ['top3_problemas', 'cuales son tu top 3'], ['objetivo', 'cual es tu principal objetivo']
];
SLUGS.forEach(([s, e], i) => {
  if (!sinAcentos(nec[0][i]).replace(/\s+/g, ' ').includes(e)) { console.error(`DATA ONBOARDING: la columna ${i + 1} es "${String(nec[0][i]).slice(0, 60)}" y se esperaba algo con "${e}" (${s}).`); process.exit(1); }
});
const necFilas = [];
nec.slice(1).forEach((r, k) => {
  const fila = k + 2;
  if (r.every(x => String(x ?? '').trim() === '')) return;
  const marca = limpio(r[0]);
  if (!marca || !/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/.test(marca)) { aviso(`DATA ONBOARDING fila ${fila}: marca temporal "${marca}" no reconocida, se salta.`); return; }
  const resp = {};
  SLUGS.slice(5).forEach(([s], j) => { const v = limpio(r[5 + j]); if (v !== null) resp[s] = v; });
  necFilas.push({ fila, marca: marca.replace(' ', 'T'), nombre: limpio(r[1]), apellido: limpio(r[2]), tel: limpio(r[3]), email: limpio(r[4]), resp });
});

// ------------------------------------------------------------ SQL
const out = [];
out.push(`-- =====================================================================
-- 248_ventas_trazabilidad_onboarding_datos.sql   (GENERADA por scripts/carga-trazabilidad-onboarding.mjs)
-- Ventas. Datos de las tablas de la 247 (correr la 247 ANTES):
--   fin_trazabilidad            liam  ${trazFilas.length} filas  (hoja "Trazabilidad - Data" del CRM de BPF)
--   fin_hoja_resumen            liam  ${resumenOnb.length} filas de onboarding (foto "${tituloOnb.replace(/"/g, '')}")
--                               liam  ${resumenTraz.length} filas de trazabilidad (secciones 6 y 7, snapshot del dashboard)
--   fin_onboarding_respuestas   teo   ${necFilas.length} filas  (hoja "DATA ONBOARDING" del CRM de NEC)
--
-- SOLO AGREGA: si alguna de las tablas ya tiene filas de ese cliente (y hoja) NO carga nada y avisa
-- (no pisa ni borra). La marca temporal de NEC se guarda como hora de Argentina (-03).
-- Un solo bloque; correr fuera de :00/:15/:30/:45. ASCII puro.
-- =====================================================================
`);
out.push(`begin;
set local lock_timeout = '10s';

do $carga$
begin
  if to_regclass('public.fin_trazabilidad') is null or to_regclass('public.fin_onboarding_respuestas') is null
     or to_regclass('public.fin_hoja_resumen') is null then
    raise exception '248: faltan las tablas de la 247 (correrla antes)';
  end if;
  if exists (select 1 from public.fin_trazabilidad where cliente_id = 'liam') then
    raise exception '248: fin_trazabilidad ya tiene filas de liam; no se repite la carga';
  end if;
  if exists (select 1 from public.fin_hoja_resumen where cliente_id = 'liam') then
    raise exception '248: fin_hoja_resumen ya tiene filas de liam; no se repite la carga';
  end if;
  if exists (select 1 from public.fin_onboarding_respuestas where cliente_id = 'teo') then
    raise exception '248: fin_onboarding_respuestas ya tiene filas de teo; no se repite la carga';
  end if;
end
$carga$;
`);
const lote = (cab, filas) => filas.length ? `${cab}\nvalues\n${filas.join(',\n')};\n` : '';
out.push(lote(`insert into public.fin_trazabilidad (cliente_id, fila_planilla, fecha, cc, nombre, formato_primer_contacto, angulo_primer_contacto,
  otros_contactos, analisis_chat, tipo_cliente, formato_ultimo_contacto, angulo_ultimo_contacto, fuente, ig, manychat)`,
trazFilas.map(t => `('liam', ${t.fila}, ${t.fecha ? `date '${t.fecha}'` : 'NULL'}, ${numLit(t.cc)}, ${lit(t.nombre)}, ${lit(t.f1)}, ${lit(t.a1)}, ${lit(t.otros)}, ${lit(t.chat)}, ${lit(t.tipo)}, ${lit(t.f2)}, ${lit(t.a2)}, ${lit(t.fuente)}, ${lit(t.ig)}, ${lit(t.many)})`)));
out.push(lote(`insert into public.fin_hoja_resumen (cliente_id, hoja, titulo, n_respuestas, seccion_orden, seccion, orden, categoria, cantidad, porcentaje)`,
  [...resumenOnb.map(x => `('liam', 'onboarding', ${lit(tituloOnb)}, ${numLit(nOnb)}, ${x.sec}, ${lit(x.seccion)}, ${x.orden}, ${lit(x.categoria)}, ${numLit(x.cantidad)}, ${numLit(x.porcentaje)})`),
   ...resumenTraz.map(x => `('liam', 'trazabilidad', ${lit(tituloTraz)}, NULL, ${x.sec}, ${lit(x.seccion)}, ${x.orden}, ${lit(x.categoria)}, NULL, NULL)`)]));
out.push(lote(`insert into public.fin_onboarding_respuestas (cliente_id, fila_planilla, marca_temporal, nombre, apellido, telefono, email, respuestas)`,
  necFilas.map(x => `('teo', ${x.fila}, timestamptz '${x.marca}-03', ${lit(x.nombre)}, ${lit(x.apellido)}, ${lit(x.tel)}, ${lit(x.email)}, ${jsonLit(x.resp)})`)));
out.push(`commit;

-- =====================================================================
-- CONTROLES (sueltos: seleccionar uno y Run)
-- =====================================================================
-- C1. Filas cargadas (esperado: trazabilidad ${trazFilas.length} | resumen onboarding ${resumenOnb.length} | resumen trazabilidad ${resumenTraz.length} | respuestas teo ${necFilas.length}).
-- select (select count(*) from public.fin_trazabilidad where cliente_id = 'liam') as trazabilidad,
--        (select count(*) from public.fin_hoja_resumen where cliente_id = 'liam' and hoja = 'onboarding') as resumen_onboarding,
--        (select count(*) from public.fin_hoja_resumen where cliente_id = 'liam' and hoja = 'trazabilidad') as resumen_trazabilidad,
--        (select count(*) from public.fin_onboarding_respuestas where cliente_id = 'teo') as respuestas_teo;

-- C2. Trazabilidad: cash total y cierres por mes (comparar con la hoja; el dashboard del 18-09 decia 42 cierres y $61.710 hasta agosto).
-- select to_char(fecha, 'YYYY-MM') as mes, count(*) as cierres, sum(cc) as cc from public.fin_trazabilidad
--  where cliente_id = 'liam' group by 1 order by 1;

-- C3. Onboarding de teo por mes (la hoja DASHBOARD ONBOARDING de NEC decia: 2026-07 = 3, 2026-08 = 5, 2026-09 = 23).
-- select to_char(marca_temporal at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM') as mes, count(*)
--   from public.fin_onboarding_respuestas where cliente_id = 'teo' group by 1 order by 1;

-- C4. Foto de onboarding de liam: titulo y secciones (esperado: 12 secciones de tablas + Lectura).
-- select titulo, n_respuestas, seccion_orden, seccion, count(*) as filas from public.fin_hoja_resumen
--  where cliente_id = 'liam' and hoja = 'onboarding' group by 1, 2, 3, 4 order by 3;

-- C5. Que la sync de Teo (hoja DATA del CRM de NEC) este viva: la fuente 'data' de teo tiene que estar activa y sin corte
--     (esperado: activo = true, cortada_en = null), y las llamadas de teo tienen que llegar hasta octubre.
-- select cliente_id, activo, cortada_en from public.fin_fuentes where tipo = 'data' order by 1;
-- select to_char(fecha_llamada, 'YYYY-MM') as mes, count(*) from public.fin_llamadas where cliente_id = 'teo' group by 1 order by 1;

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (borra SOLO lo cargado por esta migracion)
-- ---------------------------------------------------------------------
-- begin;
--   delete from public.fin_trazabilidad where cliente_id = 'liam';
--   delete from public.fin_hoja_resumen where cliente_id = 'liam';
--   delete from public.fin_onboarding_respuestas where cliente_id = 'teo';
-- commit;
`);

const sqlPath = path.join(aqui, '..', 'migraciones', '248_ventas_trazabilidad_onboarding_datos.sql');
fs.writeFileSync(sqlPath, out.join('\n'), 'utf8');

// ------------------------------------------------------------ reporte
const porMes = new Map();
for (const t of trazFilas) { const k = t.fecha ? t.fecha.slice(0, 7) : '(sin fecha)'; const a = porMes.get(k) || { n: 0, cc: 0 }; a.n += 1; a.cc += t.cc || 0; porMes.set(k, a); }
const rep = [
  'REPORTE 248 - trazabilidad y onboarding',
  `Trazabilidad (liam): ${trazFilas.length} filas, CC total ${trazFilas.reduce((s, t) => s + (t.cc || 0), 0).toFixed(2)}`,
  ...[...porMes].sort().map(([k, v]) => `   ${k}: ${v.n} cierres, CC ${v.cc.toFixed(2)}`),
  `Resumen de onboarding (liam, foto): ${resumenOnb.length} filas, titulo "${tituloOnb}", n=${nOnb}`,
  `Resumen de trazabilidad (liam, secciones 6 y 7): ${resumenTraz.length} filas`,
  `Respuestas de onboarding (teo): ${necFilas.length} filas`,
  '',
  'AVISOS:',
  ...(reporte.length ? reporte.map(x => '  - ' + x) : ['  (ninguno)'])
];
const repPath = path.join(aqui, 'salida', '248_reporte.txt');
fs.mkdirSync(path.dirname(repPath), { recursive: true });
fs.writeFileSync(repPath, rep.join('\n'), 'utf8');
console.log(rep.join('\n'));
console.log(`\nSQL:     ${sqlPath}\nReporte: ${repPath}`);
