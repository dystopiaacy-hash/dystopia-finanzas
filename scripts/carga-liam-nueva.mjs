// carga-liam-nueva.mjs - CRM de ventas de liam (hoja Data del 28/10) -> migraciones/237_liam_data_nueva_carga.sql
//
// Uso (desde la carpeta dystopia-finanzas, Node 18+, sin instalar nada):
//   node scripts/carga-liam-nueva.mjs "C:\ruta\CRM VENTAS - BPF.xlsx"
//   node scripts/carga-liam-nueva.mjs "C:\ruta\Data.csv"        (CSV de la hoja Data)
//   (opcional) --hoja "Data"
//
// DIFERENCIA CON carga-liam.mjs (078): aquella REEMPLAZA la foto de liam. Esta
// SOLO AGREGA: inserta las llamadas de la hoja que la app todavia no tiene y
// no toca, no pisa y no borra ninguna fila existente. Como ya no hay
// reemplazo no hace falta tabla de respaldo (la vuelta atras borra solo lo
// insertado, que queda identificado en fin_llamadas_carga_237).
//
// Una llamada de la hoja "ya existe" si hay una fila de liam con la misma
// fecha Y (el mismo nombre normalizado, o el mismo mail, o los mismos ultimos
// 8 digitos del telefono). Eso cubre las que entraron por el webhook de GHL
// con otro formato de nombre.
//
// Genera:
//   migraciones/237_liam_data_nueva_carga.sql   <- esto se corre en el SQL Editor
//   scripts/salida/237_liam_reporte.txt         <- LEER ANTES de correr el SQL
// No toca la base: solo escribe archivos.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { leerXlsx, leerCsv } from './lector-xlsx.mjs';
import { parseData } from '../supabase/functions/_shared/parsers/data.js';
import { normalizar, esVacio, parseFecha, parseFechaTexto } from '../supabase/functions/_shared/parsers/comun.js';

const NUM = '237';
const aqui = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const ruta = args.find((a) => !a.startsWith('--'));
const iHoja = args.indexOf('--hoja');
const hojaPedida = iHoja >= 0 ? args[iHoja + 1] : null;
if (!ruta) { console.error('Falta la ruta del archivo. Ver el encabezado de este script.'); process.exit(1); }

// ---------------------------------------------------------------- lectura
const hojas = /\.csv$/i.test(ruta) ? leerCsv(ruta) : leerXlsx(ruta);
const tieneEncabezado = (m) => {
  for (let i = 0; i < Math.min(15, m.length); i++) {
    const n = (m[i] || []).map(normalizar);
    if (n.includes('nombre') && n.includes('encargado de la llamada')) return i;
  }
  return -1;
};
let hoja = hojaPedida ? hojas.find((h) => normalizar(h.nombre) === normalizar(hojaPedida)) : null;
if (!hoja && !hojaPedida) hoja = hojas.find((h) => tieneEncabezado(h.matriz) >= 0);
if (!hoja) {
  console.error('No encontre la hoja Data. Hojas del archivo:');
  hojas.forEach((h) => console.error(`  - "${h.nombre}" (${h.matriz.length} filas)`));
  console.error('Usar --hoja "nombre".');
  process.exit(1);
}
const hdr = tieneEncabezado(hoja.matriz);
if (hdr < 0) { console.error(`La hoja "${hoja.nombre}" no tiene encabezado con "Nombre" y "Encargado de la llamada" en las primeras 15 filas.`); process.exit(1); }
const encabezado = hoja.matriz[hdr].map((v) => (esVacio(v) ? '' : String(v).trim()));

// ------------------------------------------------- alias (mismos que 014/058/060/078)
// Encabezado del 28/10: "Encargado de la llamada" (col 1), "Fecha" (col 2); MES, semana y "False" no se leen.
const posDe = (nombre) => encabezado.findIndex((h) => normalizar(h) === nombre);
const kCloser = posDe('encargado de la llamada');
const kFecha = posDe('fecha');
if (kCloser < 0 || kFecha < 0) {
  console.error('Se esperaban las columnas "Encargado de la llamada" (closer) y "Fecha". Encabezado leido:');
  console.error(encabezado.map((h, k) => `${k + 1}:${h}`).join(' | '));
  process.exit(1);
}
const A = (campo, alias, extra = {}) => ({ campo, alias, obligatorio: false, posicion: null, clave: null, ...extra });
const alias = [
  A('closer', 'Encargado de la llamada', { obligatorio: true, posicion: kCloser + 1 }),
  A('fecha_llamada', 'Fecha', { obligatorio: true, posicion: kFecha + 1 }),
  A('nombre', 'Nombre', { obligatorio: true }),
  A('calificacion', 'Calificacion'),
  A('show_up', 'Show up'),
  A('estado_llamada', 'Estado de la llamada'), A('estado_llamada', 'Estado'), A('estado_llamada', 'Contexto'),
  A('contexto_closer', 'Contexto Closer'),
  A('contexto_setter', 'Contexto setter'),
  A('cc_dia1', 'CC DIA 1'),
  A('cc_seguimiento', 'CC Seguimiento'),
  A('cc_cerrado', 'CC TRATO CERRADO'),
  A('monto_restante', 'Monto restante a pagar'),
  A('telefono', 'Telefono'),
  A('tipo_booking', 'tipo de booking'),
  A('email', 'Email'),
  A('programa', 'Programa'),
  A('instagram', 'Instagram'), A('instagram', 'Cuenta de IG'),
  ...[['Edad', 'edad'], ['Profesion', 'profesion'], ['Contexto + IG', 'contexto_ig'],
    ['Situacion actual de inversiones', 'situacion_inversiones'],
    ['Objetivo de la consultoria', 'objetivo_consultoria'], ['Ingreso mensual actual', 'ingreso_mensual'],
    ['Capital inicial para invertir', 'capital_inicial'], ['Objetivo al invertir', 'objetivo_invertir'],
    ['Inversion mensual', 'inversion_mensual']].map(([a, c]) => A('formulario', a, { clave: c })),
];

// Fechas escritas a mano ("Saturday, July 4, 2026 a la tarde"): el parser de la sync no las lee.
// Igual que la 078: se reescriben a ISO SOLO si el dia de la semana confirma el anio (2025-2027).
const MESES = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const DIAS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
const fechasCorregidas = [];
for (let i = hdr + 1; i < hoja.matriz.length; i++) {
  const fila = hoja.matriz[i];
  const v = fila && fila[kFecha];
  if (typeof v !== 'string' || parseFecha(v) !== null || parseFechaTexto(v) !== null) continue;
  const m = v.trim().match(/^([A-Za-z]+),?\s+([A-Za-z]+)\.?,?\s+(\d{1,2})(?:\s*,?\s*(\d{4}))?/);
  if (!m) continue;
  const dow = DIAS.indexOf(m[1].toLowerCase());
  const mes = MESES.indexOf(m[2].toLowerCase());
  const dia = Number(m[3]);
  if (dow < 0 || mes < 0 || dia < 1 || dia > 31) continue;
  const anios = [2025, 2026, 2027].filter((a) => {
    const d = new Date(Date.UTC(a, mes, dia));
    return d.getUTCMonth() === mes && d.getUTCDay() === dow;
  });
  if (anios.length !== 1) continue;
  const iso = `${anios[0]}-${String(mes + 1).padStart(2, '0')}-${String(dia).padStart(2, '0')}`;
  fechasCorregidas.push(`fila ${i + 1}: [${v.trim()}] -> ${iso}`);
  fila[kFecha] = iso;
}

const res = parseData(hoja.matriz, { alias, fila_encabezado: hdr + 1 });
if (res.error) { console.error('El parser no pudo leer la hoja:', res.error); console.error('Encabezado:', encabezado.map((h, k) => `${k + 1}:${h}`).join(' | ')); process.exit(1); }

// ------------------------------------------------------ normalizacion (decisiones de Nacho, igual que la 078)
const ESTADOS = new Set(['NO CIERRE', 'EN SEGUIMIENTO', 'NO SHOW', 'NO CALIFICADO', 'ADENTRO EN LLAMADA',
  'ADENTRO EN SEGUIMIENTO', 'FEE', 'GHOSTEADO']);
const ESTADO_MAPA = {
  'ADENTRO EN CHAT': 'ADENTRO EN SEGUIMIENTO',
  'SEGUIMIENTO CUOTAS': 'EN SEGUIMIENTO',
  'ADENTRO LLAMADA': 'ADENTRO EN LLAMADA',
  'NO CALIFICA': 'NO CALIFICADO',
  'CONTEXTO': null,
};
const cuenta = (m, k) => m.set(k, (m.get(k) || 0) + 1);
const rep = { estadoCrudo: new Map(), estadoFuera: new Map(), programaCrudo: new Map(), programaFuera: new Map(),
  closer: new Map(), fuente: new Map(), showUp: new Map(), mes: new Map(), telefonoError: 0 };

function estado(v) {
  if (esVacio(v)) return null;
  const k = normalizar(v).toUpperCase();
  cuenta(rep.estadoCrudo, k);
  const e = k in ESTADO_MAPA ? ESTADO_MAPA[k] : k;
  if (e && !ESTADOS.has(e)) cuenta(rep.estadoFuera, e);
  return e;
}
function programa(v) {
  if (esVacio(v)) return null;
  const k = normalizar(v).toUpperCase();
  cuenta(rep.programaCrudo, k);
  if (/\b1\s*A\s*1\b|\b1A1\b/.test(k)) return '1 a 1 Blueprint Financiero';
  if (k.includes('GESTION')) return 'GESTION DE CAPITAL';
  if (k.includes('BLUEPRINT') || k === 'BPF') return 'BLUEPRINT';
  cuenta(rep.programaFuera, k);
  return null;
}

const filas = res.filas.map((f) => {
  const tel = f.telefono && /^#(DIV\/0!|N\/A|REF!|VALUE!|NAME\?|NUM!|NULL!|ERROR!)$/i.test(f.telefono) ? null : f.telefono;
  if (f.telefono && !tel) rep.telefonoError++;
  cuenta(rep.closer, f.closer);
  cuenta(rep.fuente, f.tipo_booking || '(vacio)');
  cuenta(rep.showUp, f.show_up || '(vacio)');
  cuenta(rep.mes, f.fecha_llamada.slice(0, 7));
  return {
    fila: f.fila_planilla, fecha: f.fecha_llamada, hora: f.hora_llamada, closer: f.closer, nombre: f.nombre,
    show_up: f.show_up, calificacion: f.calificacion, estado: estado(f.estado_llamada),
    fuente: f.tipo_booking, programa: programa(f.programa),
    cc_dia1: f.cc_dia1, cc_cerrado: f.cc_cerrado, cc_seguimiento: f.cc_seguimiento, monto_restante: f.monto_restante,
    telefono: tel, instagram: f.instagram, email: f.email, contexto_setter: f.contexto_setter,
    contexto_closer: f.contexto_closer, formulario: f.formulario || {},
  };
});

// Foto compacta (mismas claves cortas que la 078).
const CLAVES = { fila: 'f', fecha: 'd', hora: 'h', closer: 'c', nombre: 'n', show_up: 'u', calificacion: 'q', estado: 'e',
  fuente: 'z', programa: 'p', cc_dia1: 'a', cc_cerrado: 'b', cc_seguimiento: 'g', monto_restante: 'm', telefono: 't',
  instagram: 'i', email: 'x', contexto_setter: 's', contexto_closer: 'k', formulario: 'o' };
const compacta = filas.map((f) => {
  const o = {};
  for (const [campo, clave] of Object.entries(CLAVES)) {
    let v = f[campo];
    if (v === null || v === undefined || v === '') continue;
    if (campo === 'formulario') {
      v = Object.fromEntries(Object.entries(v).filter(([, x]) => x !== null && x !== undefined && x !== ''));
      if (!Object.keys(v).length) continue;
    }
    o[clave] = v;
  }
  return o;
});
const json = JSON.stringify(compacta);
for (const marca of ['$snap$', '$liam$']) {
  if (json.includes(marca)) { console.error(`El JSON contiene la marca ${marca}: cambiar la marca del script.`); process.exit(1); }
}

// ------------------------------------------------------------------- SQL
const sql = `-- =====================================================================
-- ${NUM}_liam_data_nueva_carga.sql  -  VENTAS: llamadas nuevas del CRM de liam (hoja Data del 28/10)
-- =====================================================================
-- GENERADO por scripts/carga-liam-nueva.mjs el ${new Date().toISOString().slice(0, 10)} desde "${path.basename(ruta)}"
-- (hoja "${hoja.nombre}", ${filas.length} llamadas). NO editar a mano: regenerar.
-- Evitar :00, :15, :30 y :45.
-- Copiar al portapapeles con: Get-Content archivo.sql -Raw -Encoding UTF8 | Set-Clipboard
--
-- QUE HACE: SOLO AGREGA. Inserta en fin_llamadas (origen 'app', fila_planilla null,
-- como las agregadas a mano) las llamadas de la hoja que la app todavia no
-- tiene. NO actualiza, NO pisa y NO borra ninguna fila existente, de liam ni
-- de nadie: por eso no hay tabla de respaldo. Una llamada "ya existe" si hay
-- una de liam con la misma fecha Y (mismo nombre normalizado, o mismo mail, o
-- mismos ultimos 8 digitos del telefono).
-- Deja el detalle de cada fila de la hoja en public.fin_llamadas_carga_237
-- (accion: insertada | ya_existia | ya_existia_con_diferencias). Las
-- "con diferencias" NO se tocan: se revisan a mano (control C3).
-- Closer: se unifica al alias canonico de la persona (fin_personas).
-- Fuente: se unifica a la fuente canonica de su grupo (fin_fuentes_mapa).
-- Programa: si Finanzas (fin_pagos) tiene un unico programa para ese alumno, manda Finanzas.
-- Se corre UNA vez (si la tabla de detalle ya tiene filas, se niega).
--
-- COMO CORRERLA (SQL Editor): PASO 1 (crear tabla de detalle) y PASO 2 (bloque DO,
-- una sola sentencia atomica). Despues los controles, de a uno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PASO 1 - tabla de detalle de la carga (solo la ve quien corre SQL / service_role)
-- ---------------------------------------------------------------------
create table if not exists public.fin_llamadas_carga_237 (
  n          int primary key,          -- fila de la hoja Data
  fecha      date not null,
  nombre     text not null,
  accion     text not null check (accion in ('insertada', 'ya_existia', 'ya_existia_con_diferencias')),
  llamada_id text,                     -- id de fin_llamadas (la insertada o la que ya estaba)
  detalle    jsonb not null default '{}'::jsonb,
  creado_en  timestamptz not null default now()
);
alter table public.fin_llamadas_carga_237 enable row level security;
revoke all on table public.fin_llamadas_carga_237 from anon, authenticated;

-- ---------------------------------------------------------------------
-- PASO 2 - CARGA (una sola sentencia, atomica)
-- ---------------------------------------------------------------------
do $liam$
declare
  v_snap jsonb := $snap$${json}$snap$::jsonb;
  v_n    int;
begin
  perform set_config('lock_timeout', '8s', true);
  lock table public.fin_llamadas in share row exclusive mode;

  if not exists (select 1 from public.fin_fuentes
                 where cliente_id = 'liam' and tipo = 'data' and cortada_en is not null) then
    raise exception '${NUM}: la fuente Data de liam no esta cortada (077); esta carga es para la app, no para la sync';
  end if;
  if exists (select 1 from public.fin_llamadas_carga_237) then
    raise exception '${NUM}: ya se corrio (fin_llamadas_carga_237 tiene filas). Ver los controles; no se repite.';
  end if;
  select count(*) into v_n from jsonb_array_elements(v_snap);
  if v_n <> ${filas.length} then
    raise exception '${NUM}: la foto trae % filas y se esperaban ${filas.length} (archivo truncado?)', v_n;
  end if;

  -- 1) Clasificar cada fila de la hoja contra lo que ya hay.
  insert into public.fin_llamadas_carga_237 (n, fecha, nombre, accion, llamada_id, detalle)
  select s.f, s.d, s.n,
         case when ex.id is null then 'insertada'
              when coalesce(ex.estado_llamada, '') is distinct from coalesce(s.e, '')
                or abs(coalesce(ex.cc_dia1, 0) + coalesce(ex.cc_cerrado, 0) + coalesce(ex.cc_seguimiento, 0)
                       - (coalesce(s.a, 0) + coalesce(s.b, 0) + coalesce(s.g, 0))) > 0.5
                then 'ya_existia_con_diferencias'
              else 'ya_existia' end,
         ex.id::text,
         case when ex.id is null then '{}'::jsonb
              else jsonb_build_object(
                'app_estado', ex.estado_llamada, 'hoja_estado', s.e,
                'app_cash', coalesce(ex.cc_dia1, 0) + coalesce(ex.cc_cerrado, 0) + coalesce(ex.cc_seguimiento, 0),
                'hoja_cash', coalesce(s.a, 0) + coalesce(s.b, 0) + coalesce(s.g, 0),
                'app_origen', ex.origen) end
  from jsonb_to_recordset(v_snap) as s(
      f int, d date, h text, c text, n text, u text, q text, e text, z text, p text,
      a numeric, b numeric, g numeric, m numeric, t text, i text, x text, s text, k text, o jsonb)
  left join lateral (
    select l.*
    from public.fin_llamadas l
    where l.cliente_id = 'liam' and l.fecha_llamada = s.d
      and (public.fin_normalizar_nombre(l.nombre) = public.fin_normalizar_nombre(s.n)
           or (s.x is not null and btrim(s.x) <> '' and lower(btrim(l.email)) = lower(btrim(s.x)))
           or (length(regexp_replace(coalesce(s.t, ''), '\\D', '', 'g')) >= 8
               and right(regexp_replace(coalesce(l.telefono, ''), '\\D', '', 'g'), 8)
                 = right(regexp_replace(s.t, '\\D', '', 'g'), 8)))
    order by (public.fin_normalizar_nombre(l.nombre) = public.fin_normalizar_nombre(s.n)) desc, l.id
    limit 1
  ) ex on true;

  -- 2) Insertar solo las que no estaban (misma logica de closer / fuente / programa que la 078).
  with s as (
    select * from jsonb_to_recordset(v_snap) as t(
      f int, d date, h text, c text, n text, u text, q text, e text, z text, p text,
      a numeric, b numeric, g numeric, m numeric, t text, i text, x text, s text, k text, o jsonb)
    where f in (select n from public.fin_llamadas_carga_237 where accion = 'insertada')
  ), a as (
    select p.id, p.vendedor_id, btrim(p.alias) as alias, v.nombre_norm
    from public.fin_personas p
    left join public.fin_vendedores v on v.id = p.vendedor_id
    where p.cliente_id = 'liam' and (p.campo is null or p.campo in ('closer', 'ambos'))
  ), pref as (
    select distinct on (vendedor_id) vendedor_id, alias
    from a where vendedor_id is not null
    order by vendedor_id, (public.fin_normalizar_nombre(alias) = nombre_norm) desc, char_length(alias) desc, id
  ), m as (
    select distinct on (s.f) s.f, a.vendedor_id, a.alias as alias_hallado
    from s
    join a on public.fin_normalizar_nombre(a.alias) = public.fin_normalizar_nombre(s.c)
    order by s.f, (lower(a.alias) = lower(btrim(s.c))) desc, a.id
  ), cl as (
    select s.f, coalesce(pref.alias, m.alias_hallado, btrim(s.c)) as closer
    from s
    left join m on m.f = s.f
    left join pref on pref.vendedor_id = m.vendedor_id
  ), fm as (
    select upper(btrim(fuente_cruda)) as cruda, fuente
    from public.fin_fuentes_mapa where cliente_id = 'liam'
  ), cnt as (
    select upper(btrim(l.tipo_booking)) as cruda, count(*) as n
    from public.fin_llamadas l where l.cliente_id = 'liam' and l.tipo_booking is not null group by 1
  ), canon as (
    select distinct on (fm.fuente) fm.fuente, fm.cruda
    from fm left join cnt on cnt.cruda = fm.cruda
    order by fm.fuente, coalesce(cnt.n, 0) desc, fm.cruda
  ), fu as (
    select s.f, coalesce(canon.cruda, upper(btrim(s.z))) as tipo_booking
    from s
    left join fm on fm.cruda = upper(btrim(s.z))
    left join canon on canon.fuente = fm.fuente
  ), pg as (
    select public.fin_normalizar_nombre(alumno) as n,
           case when upper(programa) ~ '(^|[^0-9])1\\s*A\\s*1([^0-9]|$)' or upper(programa) ~ '1A1'
                  then '1 a 1 Blueprint Financiero'
                when upper(programa) like '%GESTI%' then 'GESTION DE CAPITAL'
                when upper(programa) like '%BLUEPRINT%' or upper(programa) like '%BPF%' then 'BLUEPRINT'
           end as prog
    from public.fin_pagos
    where cliente_id = 'liam' and programa is not null and btrim(programa) <> ''
  ), uno as (
    select n, min(prog) as prog from pg where prog is not null group by n having count(distinct prog) = 1
  ), ins as (
    insert into public.fin_llamadas
      (cliente_id, fuente_id, fila_planilla, fecha_llamada, hora_llamada, closer, nombre, show_up,
       calificacion, estado_llamada, tipo_booking, programa, cc_dia1, cc_cerrado, cc_seguimiento,
       monto_restante, telefono, instagram, email, contexto_setter, contexto_closer, formulario, origen)
    select 'liam',
           (select f2.id from public.fin_fuentes f2
             where f2.cliente_id = 'liam' and f2.tipo = 'data' and f2.cortada_en is not null order by f2.id limit 1),
           null, s.d, nullif(s.h, '')::time, cl.closer, s.n, s.u,
           s.q, s.e, fu.tipo_booking, coalesce(uno.prog, s.p), s.a, s.b, s.g,
           s.m, s.t, s.i, s.x, s.s, s.k,
           coalesce(s.o, '{}'::jsonb), 'app'
    from s
    join cl on cl.f = s.f
    join fu on fu.f = s.f
    left join uno on uno.n = public.fin_normalizar_nombre(s.n)
    returning id, fecha_llamada, public.fin_normalizar_nombre(nombre) as nn
  )
  update public.fin_llamadas_carga_237 c set llamada_id = ins.id::text
  from ins
  where c.accion = 'insertada' and c.fecha = ins.fecha_llamada
    and public.fin_normalizar_nombre(c.nombre) = ins.nn
    and c.llamada_id is null;
end
$liam$;


-- =====================================================================
-- CONTROLES (sueltos: seleccionar uno y Run)
-- =====================================================================
-- C1. Resultado de la carga: filas de la hoja por accion. Suma = ${filas.length}.
-- select accion, count(*) from public.fin_llamadas_carga_237 group by 1 order by 2 desc;

-- C2. Las insertadas tienen que tener llamada_id y existir en fin_llamadas (esperado: 0 sin id).
-- select count(*) filter (where c.llamada_id is null) as sin_id,
--        count(*) filter (where l.id is null) as no_existen
--   from public.fin_llamadas_carga_237 c
--   left join public.fin_llamadas l on l.id::text = c.llamada_id
--  where c.accion = 'insertada';

-- C3. Las que ya existian pero con estado o cash distinto (NO se tocaron; revisar con el equipo).
-- select n as fila_hoja, fecha, nombre, detalle
--   from public.fin_llamadas_carga_237 where accion = 'ya_existia_con_diferencias' order by fecha, n;

-- C4. Insertadas por mes (liam, solo las de esta carga).
-- select to_char(fecha, 'YYYY-MM') as mes, count(*) from public.fin_llamadas_carga_237
--  where accion = 'insertada' group by 1 order by 1;

-- C5. Closers que NO se unificaron a una persona conocida (agregar el alias en fin_personas).
-- select l.closer, count(*) from public.fin_llamadas l
--  join public.fin_llamadas_carga_237 c on c.llamada_id = l.id::text and c.accion = 'insertada'
--  where not exists (select 1 from public.fin_personas p
--                     where p.cliente_id = 'liam' and lower(btrim(p.alias)) = lower(btrim(l.closer)))
--  group by 1 order by 2 desc;

-- C6. No quedaron duplicadas de GHL: misma fecha y mismo mail entre insertadas y existentes (esperado: 0 filas).
-- select l.fecha_llamada, lower(btrim(l.email)) as mail, count(*)
--   from public.fin_llamadas l
--  where l.cliente_id = 'liam' and l.email is not null and btrim(l.email) <> ''
--  group by 1, 2 having count(*) > 1 order by 1 desc limit 40;

-- C7. Ninguna fila ajena cambio: liam no tiene filas de origen sheet y el total subio solo por las insertadas.
-- select origen, count(*) from public.fin_llamadas where cliente_id = 'liam' group by 1;

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (borra SOLO lo insertado por esta carga; no toca nada mas)
-- ---------------------------------------------------------------------
-- begin;
--   delete from public.fin_llamadas l using public.fin_llamadas_carga_237 c
--    where c.accion = 'insertada' and c.llamada_id = l.id::text and l.cliente_id = 'liam' and l.actualizado_por is null;
--   -- (si el equipo ya edito alguna insertada, queda: revisar a mano con C2)
--   drop table public.fin_llamadas_carga_237;
-- commit;
`;

const dirSql = path.resolve(aqui, '..', 'migraciones');
const dirOut = path.resolve(aqui, 'salida');
fs.mkdirSync(dirOut, { recursive: true });
const archivoSql = path.join(dirSql, `${NUM}_liam_data_nueva_carga.sql`);
fs.writeFileSync(archivoSql, sql, 'utf8');

// --------------------------------------------------------------- reporte
const top = (m, n = 60) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => `  ${String(v).padStart(5)}  ${k}`).join('\n') || '  (ninguno)';
const rech = res.rechazadas.filter((r) => !String(r.motivo).includes('celda rechazada'));
const celdas = res.rechazadas.filter((r) => String(r.motivo).includes('celda rechazada'));
const reporte = `REPORTE ${NUM} - liam (solo agrega)
Archivo: ${ruta}
Hoja: "${hoja.nombre}"  encabezado en fila ${hdr + 1}
Closer = columna ${kCloser + 1}, Fecha = columna ${kFecha + 1}

Filas leidas ${res.stats.filas_leidas} | cargadas en la foto ${res.stats.filas_cargadas} | rechazadas ${res.stats.rechazadas} | descartadas ${res.stats.descartadas} | celdas rechazadas ${res.stats.celdas_rechazadas}
Telefonos con error de formula (quedan vacios): ${rep.telefonoError}

COLUMNAS DEL ENCABEZADO (verificar que no falte ninguna):
${encabezado.map((h, k) => `  ${k + 1}: ${h}`).join('\n')}

FECHAS ESCRITAS A MANO QUE EL SCRIPT CORRIGIO:
${fechasCorregidas.join('\n') || '  (ninguna)'}

FILAS RECHAZADAS (NO entran a la foto; agregarlas a mano con "Anadir llamada"):
${rech.slice(0, 80).map((r) => `  fila ${r.fila_planilla}: ${r.motivo}${r.valor_crudo ? ` [${r.valor_crudo}]` : ''}`).join('\n') || '  (ninguna)'}

CELDAS RECHAZADAS (la fila entra sin ese valor):
${celdas.slice(0, 80).map((r) => `  fila ${r.fila_planilla}: ${r.motivo}${r.valor_crudo ? ` [${r.valor_crudo}]` : ''}`).join('\n') || '  (ninguna)'}

LLAMADAS DE LA FOTO POR MES (cuantas trae la hoja; el SQL inserta solo las que la app no tiene):
${top(rep.mes)}

ESTADOS (crudo):
${top(rep.estadoCrudo)}
Estados fuera del catalogo (quedan igual, revisar):
${top(rep.estadoFuera)}

PROGRAMA en el CRM (crudo; liam no tiene columna Programa en Data, sale de Finanzas):
${top(rep.programaCrudo)}

SHOW UP (ya unificado):
${top(rep.showUp)}

CLOSERS (texto de la planilla; el SQL los unifica por alias, ver control C5):
${top(rep.closer)}

FUENTES (crudo, mayusculas; el SQL las agrupa por fin_fuentes_mapa):
${top(rep.fuente)}
`;
const archivoRep = path.join(dirOut, `${NUM}_liam_reporte.txt`);
fs.writeFileSync(archivoRep, reporte, 'utf8');

console.log(`OK: ${filas.length} llamadas en la foto`);
console.log(`SQL:     ${archivoSql}`);
console.log(`Reporte: ${archivoRep}`);
if (res.stats.rechazadas) console.log(`ATENCION: ${res.stats.rechazadas} filas rechazadas (ver reporte)`);
