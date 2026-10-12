// carga-liam.mjs - foto del CRM de ventas de liam -> migraciones/078_liam_carga_datos.sql
//
// Uso (desde la carpeta dystopia-finanzas, Node 18+, sin instalar nada):
//   node scripts/carga-liam.mjs "C:\ruta\CRM VENTAS - BPF.xlsx"
//   node scripts/carga-liam.mjs "C:\ruta\CRM VENTAS - BPF.xlsx" --hoja "DATA"
//   (tambien acepta un .csv exportado de la hoja Data)
//
// Que hace: lee la hoja con el MISMO parser que la sync (parsers/data.js),
// normaliza estados / programa / show up y escribe:
//   migraciones/078_liam_carga_datos.sql   <- esto se corre en el SQL Editor
//   scripts/salida/078_liam_reporte.txt    <- LEER ANTES de correr el SQL
// No toca la base: solo genera archivos. La 078 reemplaza las filas de liam
// que vienen del Sheet y exige que la 077 (corte) ya este corrida.
// El SQL generado es un unico bloque DO (atomico, sin tablas temporales) mas
// un diagnostico de solo lectura al principio.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { leerXlsx, leerCsv } from './lector-xlsx.mjs';
import { parseData } from '../supabase/functions/_shared/parsers/data.js';
import { normalizar, esVacio, parseFecha, parseFechaTexto } from '../supabase/functions/_shared/parsers/comun.js';

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

// ------------------------------------------------- alias (mismos que 014/058/060)
// Encabezado real: "Encargado de la llamada" (closer) y "Fecha" (fecha de la llamada).
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

// Fechas escritas a mano ("Saturday, July 4, 2026 a la tarde", "Tuesday, July 7
// 2016, 6 PM", sin anio): el parser compartido (sync) no las lee. Aca se
// reescriben a ISO SOLO en esta carga, y SOLO si el dia de la semana escrito
// confirma el anio (2025-2027). Cada una queda en el reporte para revisarla.
const MESES = ['january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september', 'october', 'november', 'december'];
const DIAS = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
const fechasCorregidas = [];
{
  const kF = encabezado.findIndex((h) => normalizar(h) === 'fecha');
  for (let i = hdr + 1; i < hoja.matriz.length; i++) {
    const fila = hoja.matriz[i];
    const v = fila && fila[kF];
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
    fechasCorregidas.push(`fila ${i + 1}: [${v.trim()}] -> ${iso}${m[4] && Number(m[4]) !== anios[0] ? ` (el anio escrito era ${m[4]}; el dia de la semana indica ${anios[0]})` : ''}`);
    fila[kF] = iso;
  }
}

const res = parseData(hoja.matriz, { alias, fila_encabezado: hdr + 1 });
if (res.error) { console.error('El parser no pudo leer la hoja:', res.error); console.error('Encabezado:', encabezado.map((h, k) => `${k + 1}:${h}`).join(' | ')); process.exit(1); }

// ------------------------------------------------------ normalizacion (Nacho)
const ESTADOS = new Set(['NO CIERRE', 'EN SEGUIMIENTO', 'NO SHOW', 'NO CALIFICADO', 'ADENTRO EN LLAMADA',
  'ADENTRO EN SEGUIMIENTO', 'FEE', 'GHOSTEADO']);
const ESTADO_MAPA = {
  'ADENTRO EN CHAT': 'ADENTRO EN SEGUIMIENTO',
  // 084: "Seguimiento cuotas" es seguimiento (abierto), NO venta cerrada.
  'SEGUIMIENTO CUOTAS': 'EN SEGUIMIENTO',
  'ADENTRO LLAMADA': 'ADENTRO EN LLAMADA',
  'NO CALIFICA': 'NO CALIFICADO',
  'CONTEXTO': null,
};
const cuenta = (m, k) => m.set(k, (m.get(k) || 0) + 1);
const rep = { estadoCrudo: new Map(), estadoFuera: new Map(), programaCrudo: new Map(), programaFuera: new Map(),
  closer: new Map(), fuente: new Map(), showUp: new Map(), telefonoError: 0 };

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
  return {
    fila: f.fila_planilla, fecha: f.fecha_llamada, hora: f.hora_llamada, closer: f.closer, nombre: f.nombre,
    show_up: f.show_up, calificacion: f.calificacion, estado: estado(f.estado_llamada),
    fuente: f.tipo_booking, programa: programa(f.programa),
    cc_dia1: f.cc_dia1, cc_cerrado: f.cc_cerrado, cc_seguimiento: f.cc_seguimiento, monto_restante: f.monto_restante,
    telefono: tel, instagram: f.instagram, email: f.email, contexto_setter: f.contexto_setter,
    contexto_closer: f.contexto_closer, formulario: f.formulario || {},
  };
});

// Foto compacta: claves cortas y sin los valores vacios (jsonb_to_recordset
// deja en null lo que falta). Baja el archivo a menos de la mitad.
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
// Todo el trabajo va en UN solo bloque DO: una sentencia es atomica aunque el
// editor reparta el archivo entre conexiones. Sin tablas temporales y sin
// depender de begin/commit.
const DIAGNOSTICO = `select
  (select count(*) from public.fin_fuentes
    where cliente_id = 'liam' and tipo = 'data' and cortada_en is not null) as fuente_cortada_077,
  count(*) filter (where origen = 'sheet') as filas_sheet,
  count(*) filter (where origen = 'app' and fila_planilla is not null) as filas_de_la_foto,
  count(*) filter (where origen = 'app' and fila_planilla is null) as filas_a_mano,
  count(*) filter (where origen = 'app' and fila_planilla is not null and actualizado_por is not null) as foto_editadas_por_el_equipo,
  ${filas.length} as filas_esperadas,
  case
    when (select count(*) from public.fin_fuentes
           where cliente_id = 'liam' and tipo = 'data' and cortada_en is not null) = 0
      then 'FALTA LA 077: la fuente Data de liam no esta cortada; correr la 077 antes'
    when count(*) filter (where origen = 'app' and fila_planilla is not null) = ${filas.length}
         and count(*) filter (where origen = 'sheet') = 0
      then 'COMPLETO: la foto ya esta cargada; correr la 078 de nuevo deja lo mismo'
    when count(*) filter (where origen = 'app' and fila_planilla is not null) = 0
      then 'NADA APLICADO: listo para correr la 078'
    else 'A MEDIAS: correr la 078 completa (borra y vuelve a cargar la foto)'
  end as estado
from public.fin_llamadas
where cliente_id = 'liam';`;

const sql = `-- =====================================================================
-- 078_liam_carga_datos.sql  -  VENTAS: ultima foto del CRM de liam
-- =====================================================================
-- GENERADO por scripts/carga-liam.mjs el ${new Date().toISOString().slice(0, 10)} desde "${path.basename(ruta)}"
-- (hoja "${hoja.nombre}", ${filas.length} llamadas). NO editar a mano: regenerar.
-- Correr DESPUES de la 077 y ANTES de que el equipo empiece a editar.
-- Evitar :00, :15, :30 y :45.
-- Copiar al portapapeles con: Get-Content archivo.sql -Raw -Encoding UTF8 | Set-Clipboard
--
-- COMO CORRERLA (SQL Editor del dashboard):
--   1) PASO 0: seleccionar solo el bloque de diagnostico y Run. No modifica
--      nada; devuelve una fila con el estado de la base.
--   2) PASO 1: pegar/seleccionar el bloque DO y Run. Es UNA sola sentencia:
--      o se aplica entera o no se aplica nada. No usa tablas temporales.
--   Se puede correr mas de una vez: borra la foto anterior y la vuelve a
--   cargar, con el mismo resultado final (sin duplicar filas).
--
-- Que hace: reemplaza las llamadas de liam que vinieron del Sheet por esta
-- foto (origen 'app', con su fila de planilla como referencia). No toca las
-- llamadas agregadas a mano (fila_planilla null), ni otros clientes, ni
-- pagos. Conserva los valores de columnas nuevas (campos_extra) cuando la
-- llamada se reconoce por fecha + nombre.
-- Se niega a correr si el equipo ya edito filas de esta carga.
-- Closer: se unifica al alias canonico de la persona (fin_personas).
-- Fuente: se unifica a la fuente canonica de su grupo (fin_fuentes_mapa).
-- Programa: si Finanzas (fin_pagos) tiene un unico programa para ese
-- alumno, manda Finanzas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PASO 0 - DIAGNOSTICO (solo lectura). Resultado esperado en la columna estado:
--   NADA APLICADO -> correr el PASO 1.
--   A MEDIAS      -> correr el PASO 1 igual (lo deja completo).
--   COMPLETO      -> no hace falta correr nada; ir a los controles.
--   FALTA LA 077  -> correr la 077 primero.
-- ---------------------------------------------------------------------
${DIAGNOSTICO}

-- ---------------------------------------------------------------------
-- PASO 1 - CARGA (una sola sentencia, atomica)
-- ---------------------------------------------------------------------
do $liam$
declare
  v_snap   jsonb := $snap$${json}$snap$::jsonb;
  v_extras jsonb;
  v_n      int;
begin
  perform set_config('lock_timeout', '8s', true);
  lock table public.fin_llamadas in access exclusive mode;

  if not exists (select 1 from public.fin_fuentes
                 where cliente_id = 'liam' and tipo = 'data' and cortada_en is not null) then
    raise exception '078: correr primero la 077 (la fuente Data de liam tiene que estar cortada)';
  end if;
  if exists (select 1 from public.fin_llamadas
             where cliente_id = 'liam' and origen = 'app' and fila_planilla is not null
               and actualizado_por is not null) then
    raise exception '078: el equipo ya edito filas de una carga anterior; no se pisa. Hablar con Joaquin.';
  end if;

  select count(*) into v_n from jsonb_array_elements(v_snap);
  if v_n <> ${filas.length} then
    raise exception '078: la foto trae % filas y se esperaban ${filas.length} (archivo truncado?)', v_n;
  end if;

  -- Valores de columnas nuevas ya cargados (se re-aplican al final).
  select coalesce(jsonb_agg(jsonb_build_object(
           'd', fecha_llamada, 'n', public.fin_normalizar_nombre(nombre), 'x', campos_extra)), '[]'::jsonb)
    into v_extras
  from public.fin_llamadas
  where cliente_id = 'liam' and campos_extra <> '{}'::jsonb;

  delete from public.fin_llamadas
   where cliente_id = 'liam'
     and (origen = 'sheet' or (origen = 'app' and fila_planilla is not null));

  with s as (
    select * from jsonb_to_recordset(v_snap) as t(
      f int, d date, h text, c text, n text, u text, q text, e text, z text, p text,
      a numeric, b numeric, g numeric, m numeric, t text, i text, x text, s text, k text, o jsonb)
  ), a as (
    -- Closer: alias canonico de la persona; sin alias conocido queda como vino.
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
    -- Fuente: la mas usada de su grupo.
    select upper(btrim(fuente_cruda)) as cruda, fuente
    from public.fin_fuentes_mapa where cliente_id = 'liam'
  ), cnt as (
    select upper(btrim(z)) as cruda, count(*) as n from s where z is not null group by 1
  ), canon as (
    select distinct on (fm.fuente) fm.fuente, fm.cruda
    from fm left join cnt on cnt.cruda = fm.cruda
    order by fm.fuente, coalesce(cnt.n, 0) desc, fm.cruda
  ), fu as (
    select s.f, coalesce(canon.cruda, upper(btrim(s.z))) as tipo_booking
    from s
    left join fm on fm.cruda = upper(btrim(s.z))
    left join canon on canon.fuente = fm.fuente
  )
  insert into public.fin_llamadas
    (cliente_id, fuente_id, fila_planilla, fecha_llamada, hora_llamada, closer, nombre, show_up,
     calificacion, estado_llamada, tipo_booking, programa, cc_dia1, cc_cerrado, cc_seguimiento,
     monto_restante, telefono, instagram, email, contexto_setter, contexto_closer, formulario, origen)
  select 'liam',
         (select id from public.fin_fuentes
           where cliente_id = 'liam' and tipo = 'data' and cortada_en is not null order by id limit 1),
         s.f, s.d, nullif(s.h, '')::time, cl.closer, s.n, s.u,
         s.q, s.e, fu.tipo_booking, s.p, s.a, s.b, s.g,
         s.m, s.t, s.i, s.x, s.s, s.k,
         coalesce(s.o, '{}'::jsonb), 'app'
  from s
  join cl on cl.f = s.f
  join fu on fu.f = s.f
  order by s.f;

  update public.fin_llamadas l set campos_extra = e.x
  from (select r.d, r.n, (array_agg(r.x))[1] as x
          from jsonb_to_recordset(v_extras) as r(d date, n text, x jsonb)
         group by 1, 2 having count(*) = 1) e
  where l.cliente_id = 'liam' and l.origen = 'app' and l.fila_planilla is not null
    and l.fecha_llamada = e.d
    and public.fin_normalizar_nombre(l.nombre) = e.n
    and l.campos_extra = '{}'::jsonb;

  -- Programa: manda Finanzas cuando el alumno tiene un solo programa.
  with pg as (
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
  )
  update public.fin_llamadas l set programa = u.prog
  from uno u
  where l.cliente_id = 'liam' and l.origen = 'app' and l.fila_planilla is not null
    and public.fin_normalizar_nombre(l.nombre) = u.n
    and l.programa is distinct from u.prog;

  -- Fuentes canonicas como opciones del desplegable de Fuente.
  insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
  select 'liam', 'fuente', t.tipo_booking, (row_number() over (order by t.n desc, t.tipo_booking))::int
  from (select l.tipo_booking, count(*) as n from public.fin_llamadas l
         where l.cliente_id = 'liam' and l.origen = 'app' and l.fila_planilla is not null
           and l.tipo_booking is not null and btrim(l.tipo_booking) <> '' group by 1) t
  on conflict (cliente_id, dimension, valor) do update set activo = true, updated_at = now();
end
$liam$;


-- =====================================================================
-- CONTROLES (sueltos: seleccionar uno y Run; no dependen de nada del bloque)
-- =====================================================================
-- C0. Estado general (el mismo diagnostico del PASO 0): tiene que decir COMPLETO.
${DIAGNOSTICO.split('\n').map((l) => '-- ' + l).join('\n')}

-- C1. Cantidad: ${filas.length} llamadas de la foto + las agregadas a mano.
-- select origen, count(*), count(*) filter (where fila_planilla is not null) as de_la_foto
--   from public.fin_llamadas where cliente_id = 'liam' group by 1;

-- C2. Estados (solo los 8 del catalogo; cero de SEGUIMIENTO CUOTAS / CHAT; las cuotas quedan en EN SEGUIMIENTO).
-- select estado_llamada, count(*) from public.fin_llamadas
--  where cliente_id = 'liam' group by 1 order by 2 desc;

-- C3. Closers que NO se unificaron a una persona conocida (revisar uno a uno:
--     agregar el alias en fin_personas y volver a generar).
-- select l.closer, count(*) from public.fin_llamadas l
--  where l.cliente_id = 'liam'
--    and not exists (select 1 from public.fin_personas p
--                     where p.cliente_id = 'liam' and lower(btrim(p.alias)) = lower(btrim(l.closer)))
--  group by 1 order by 2 desc;

-- C4. Fuentes sin grupo en fin_fuentes_mapa (quedan como vinieron).
-- select l.tipo_booking, count(*) from public.fin_llamadas l
--  where l.cliente_id = 'liam' and l.tipo_booking is not null
--    and not exists (select 1 from public.fin_fuentes_mapa m
--                     where m.cliente_id = 'liam' and upper(btrim(m.fuente_cruda)) = upper(btrim(l.tipo_booking)))
--  group by 1 order by 2 desc;

-- C5. Programa de la foto.
-- select programa, count(*) from public.fin_llamadas where cliente_id = 'liam' group by 1 order by 2 desc;

-- C6. CRM vs Finanzas (informativo; manda Finanzas): cobrado por alumno en
--     la grilla contra lo cargado en Pagos. Diferencias grandes = revisar.
-- select l.nombre, sum(coalesce(l.cc_dia1,0) + coalesce(l.cc_seguimiento,0)) as crm,
--        (select sum(p.monto_usd) from public.fin_pagos p
--          where p.cliente_id = 'liam'
--            and public.fin_normalizar_nombre(p.alumno) = public.fin_normalizar_nombre(l.nombre)) as finanzas
--   from public.fin_llamadas l where l.cliente_id = 'liam'
--  group by l.nombre
-- having sum(coalesce(l.cc_dia1,0) + coalesce(l.cc_seguimiento,0)) > 0
--  order by abs(sum(coalesce(l.cc_dia1,0) + coalesce(l.cc_seguimiento,0))
--               - coalesce((select sum(p.monto_usd) from public.fin_pagos p
--                            where p.cliente_id = 'liam'
--                              and public.fin_normalizar_nombre(p.alumno) = public.fin_normalizar_nombre(l.nombre)), 0)) desc
--  limit 40;

-- C7. La sync de liam sigue apagada y las otras siguen vivas.
-- select cliente_id, activo, cortada_en from public.fin_fuentes where tipo = 'data' order by 1;
`;

const dirSql = path.resolve(aqui, '..', 'migraciones');
const dirOut = path.resolve(aqui, 'salida');
fs.mkdirSync(dirOut, { recursive: true });
const archivoSql = path.join(dirSql, '078_liam_carga_datos.sql');
fs.writeFileSync(archivoSql, sql, 'utf8');

// --------------------------------------------------------------- reporte
const top = (m, n = 60) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => `  ${String(v).padStart(5)}  ${k}`).join('\n') || '  (ninguno)';
const rech = res.rechazadas.filter((r) => !String(r.motivo).includes('celda rechazada'));
const celdas = res.rechazadas.filter((r) => String(r.motivo).includes('celda rechazada'));
const reporte = `REPORTE 078 - liam
Archivo: ${ruta}
Hoja: "${hoja.nombre}"  encabezado en fila ${hdr + 1}
Closer = columna ${kCloser + 1}, Fecha = columna ${kFecha + 1}

Filas leidas ${res.stats.filas_leidas} | cargadas ${res.stats.filas_cargadas} | rechazadas ${res.stats.rechazadas} | descartadas ${res.stats.descartadas} | celdas rechazadas ${res.stats.celdas_rechazadas}
Telefonos con error de formula (quedan vacios): ${rep.telefonoError}

COLUMNAS DEL ENCABEZADO (verificar que no falte ninguna):
${encabezado.map((h, k) => `  ${k + 1}: ${h}`).join('\n')}

DESCARTADAS por motivo (filas sin datos o encabezado repetido; no son error):
${[...res.descartadas.reduce((m, d) => m.set(d.motivo, (m.get(d.motivo) || 0) + 1), new Map())].map(([k, n]) => `  ${String(n).padStart(5)}  ${k}`).join('\n') || '  (ninguna)'}

FECHAS ESCRITAS A MANO QUE EL SCRIPT CORRIGIO (el dia de la semana confirma el anio; se pierde la hora):
${fechasCorregidas.join('\n') || '  (ninguna)'}

FILAS RECHAZADAS (NO se cargan; agregarlas a mano con "Anadir llamada"):
${rech.slice(0, 80).map((r) => `  fila ${r.fila_planilla}: ${r.motivo}${r.valor_crudo ? ` [${r.valor_crudo}]` : ''}`).join('\n') || '  (ninguna)'}

CELDAS RECHAZADAS (la fila se carga sin ese valor):
${celdas.slice(0, 80).map((r) => `  fila ${r.fila_planilla}: ${r.motivo}${r.valor_crudo ? ` [${r.valor_crudo}]` : ''}`).join('\n') || '  (ninguna)'}

ESTADOS (crudo -> se aplican las decisiones de Nacho):
${top(rep.estadoCrudo)}
Estados fuera del catalogo (quedan igual, revisar):
${top(rep.estadoFuera)}

PROGRAMA en el CRM (crudo):
${top(rep.programaCrudo)}
Programa que no se pudo mapear (queda vacio; Finanzas puede completarlo en la 078):
${top(rep.programaFuera)}

SHOW UP (ya unificado):
${top(rep.showUp)}

CLOSERS (texto de la planilla; la 078 los unifica por alias, ver control C3):
${top(rep.closer)}

FUENTES (crudo, normalizado a mayusculas; la 078 las agrupa por fin_fuentes_mapa):
${top(rep.fuente)}
`;
const archivoRep = path.join(dirOut, '078_liam_reporte.txt');
fs.writeFileSync(archivoRep, reporte, 'utf8');

console.log(`OK: ${filas.length} llamadas`);
console.log(`SQL:     ${archivoSql}`);
console.log(`Reporte: ${archivoRep}`);
if (res.stats.rechazadas) console.log(`ATENCION: ${res.stats.rechazadas} filas rechazadas (ver reporte)`);
