// Genera migraciones/076_liam_pagos_al_dia.sql desde el xlsx de Finanzas de Liam.
//   npm run liam:generar            (usa la ruta por defecto de abajo)
//   npm run liam:generar -- "<ruta.xlsx>"
// Usa el MISMO parser que la sync (parsePagos), asi los pagos quedan como los
// habria dejado la sync, mas las reglas de Nacho (respuestas-nacho.md):
//   - pago sin fecha: se imputa al mes (fecha del pago anterior de la planilla)
//   - closer "BPF" = sin closer
//   - la columna de fuente (L) se guarda como columna "Fuente" de Pagos
//   - reembolso sin pago original en la planilla: queda pendiente, no se inventa
//   - filas de "segundo comprobante": el link va a la nota del pago anterior
// El SQL generado es UNA sola sentencia (do $liam076$ ... $liam076$): no usa
// begin/commit ni tablas temporales, porque el SQL Editor del dashboard pasa
// por un pooler y no garantiza una sola transaccion/conexion por archivo.
import fs from 'node:fs';
import { leerXlsx } from './xlsx-leer.mjs';
import { parsePagos } from '../supabase/functions/_shared/parsers/pagos.js';
import { CONFIG } from './config.mjs';

const XLSX = process.argv[2] || 'C:/Users/Admin/Downloads/jefe/insumos/liam-septiembre/BluePrint - Finanzas 2026.xlsx';
const SALIDA = new URL('../migraciones/076_liam_pagos_al_dia.sql', import.meta.url);

const libro = leerXlsx(XLSX);
const hoja = libro.Pagos;
if (!hoja) throw new Error('El xlsx no tiene la hoja "Pagos"');

// Matriz densa, con las fechas como numero de serie.
const ANCHO = 14;
const M = hoja.map(r => Array.from({ length: ANCHO }, (_, c) => {
  const v = (r || [])[c];
  if (v === undefined) return null;
  return v && typeof v === 'object' && v.fecha !== undefined ? v.fecha : v;
}));
// La planilla rotula la fecha con "-". El alias de la sync es FECHA DE CARGA.
M[0][0] = 'FECHA DE CARGA';

const COL = { fecha: 0, programa: 1, alumno: 2, telefono: 3, concepto: 4, monto: 5, closer: 6, setter: 7, comprobante: 8, recibe: 9, metodo: 10, fuente: 11 };
const esNum = v => typeof v === 'number' && Number.isFinite(v);
const vacia = r => r.every(v => v === null || (typeof v === 'string' && v.trim() === ''));
const imputadas = [];      // pagos sin fecha
const continuaciones = []; // filas de segundo comprobante
const notaExtra = new Map(); // fila (1-based) -> texto

// 1. Continuaciones ("... segundo comprobante"): sin concepto ni monto.
let ultimaConDatos = -1;
for (let i = 1; i < M.length; i++) {
  const r = M[i];
  if (vacia(r)) continue;
  const alumno = String(r[COL.alumno] ?? '');
  if (/segundo\s+comp/i.test(alumno) && !esNum(r[COL.monto]) && ultimaConDatos > 0) {
    const link = typeof r[COL.comprobante] === 'string' && /^https?:\/\//.test(r[COL.comprobante]) ? r[COL.comprobante] : null;
    continuaciones.push({ fila: i + 1, alumno, link, aFila: ultimaConDatos + 1 });
    if (link) notaExtra.set(ultimaConDatos + 1, `Segundo comprobante: ${link}`);
    M[i] = Array.from({ length: ANCHO }, () => null);
    continue;
  }
  ultimaConDatos = i;
}

// 2. Pagos sin fecha: se imputan al mes (fecha de la ultima fila con fecha).
let ultimaFecha = null;
for (let i = 1; i < M.length; i++) {
  const r = M[i];
  if (vacia(r)) continue;
  if (esNum(r[COL.fecha])) { ultimaFecha = r[COL.fecha]; continue; }
  const sinFecha = r[COL.fecha] === null || (typeof r[COL.fecha] === 'string' && r[COL.fecha].trim() === '');
  if (sinFecha && String(r[COL.alumno] ?? '').trim() && esNum(r[COL.monto]) && ultimaFecha !== null) {
    imputadas.push({ fila: i + 1, alumno: r[COL.alumno], monto: r[COL.monto], desdeSerial: ultimaFecha });
    r[COL.fecha] = ultimaFecha;
  }
}

// 3. Parser de la sync.
const res = parsePagos(M, CONFIG.liam.pagos);
if (res.error) throw new Error('parsePagos: ' + res.error);

const pendientes = res.rechazadas.map(x => ({
  fila: x.fila_planilla, motivo: x.motivo, valor: x.valor_crudo,
  contenido: (x.contenido_crudo || []).slice(0, 11).map(v => (v === null ? '' : String(v))).join(' | ')
}));

// 4. Filas finales.
const fuenteDe = fila => {
  const v = M[fila - 1][COL.fuente];
  if (typeof v !== 'string') return null;
  const t = v.trim();
  if (!t || t.startsWith('(')) return null; // "(Entra en vigencia ...)" es un comentario, no una fuente
  return t;
};
const filas = res.filas.map(f => {
  const closer = f.closer && f.closer.trim().toUpperCase() === 'BPF' ? null : f.closer;
  const imp = imputadas.find(x => x.fila === f.fila_planilla);
  const notas = [];
  if (imp) notas.push('Sin fecha en la planilla: imputado al mes');
  if (notaExtra.has(f.fila_planilla)) notas.push(notaExtra.get(f.fila_planilla));
  return {
    fila: f.fila_planilla, fecha: f.fecha, programa: f.programa, alumno: f.alumno, telefono: f.telefono,
    concepto: f.concepto, monto: f.monto_usd, closer, setter: f.setter, comprobante: f.comprobante,
    recibe: f.quien_recibe, metodo: f.metodo_pago, moneda_cobro: f.moneda_cobro,
    nota: notas.length ? notas.join(' · ') : null, fuente: fuenteDe(f.fila_planilla)
  };
});

// 5. SQL.
const q = v => (v === null || v === undefined || String(v).trim() === '' ? 'null' : `'${String(v).replace(/'/g, "''")}'`);
const n = v => (v === null || v === undefined ? 'null' : String(v));
const valores = filas.map(f =>
  `    (${f.fila}, date '${f.fecha}', ${q(f.programa)}, ${q(f.alumno)}, ${q(f.telefono)}, ${q(f.concepto)}, ${n(f.monto)}, ` +
  `${q(f.closer)}, ${q(f.setter)}, ${q(f.comprobante)}, ${q(f.recibe)}, ${q(f.metodo)}, ${q(f.moneda_cobro)}, ${q(f.nota)}, ${q(f.fuente)})`
).join(',\n');

const porMes = {};
for (const f of filas) { const k = f.fecha.slice(0, 7); porMes[k] = Math.round(((porMes[k] || 0) + f.monto) * 100) / 100; }
const total = Math.round(filas.reduce((a, f) => a + f.monto, 0) * 100) / 100;
const comentarioPend = pendientes.map(p => `--   fila ${p.fila}: ${p.motivo}${p.valor ? ` (${p.valor})` : ''} :: ${p.contenido}`).join('\n');
const comentarioImp = imputadas.map(x => `--   fila ${x.fila}: ${x.alumno} ${x.monto}`).join('\n');
const comentarioMes = Object.entries(porMes).sort().map(([k, v]) => `--   ${k}: ${v}`).join('\n');
const ahora = new Date().toISOString().slice(0, 10);

// Diagnostico de solo lectura (va al principio y al final). No usa temporales ni
// nombra columnas/tablas que podrian no existir: lo condicional va por query_to_xml.
const cnt = sql => `(xpath('/row/c/text()', query_to_xml('${sql.replace(/'/g, "''")}', false, true, '')))[1]::text::int`;
const DIAG = `with s as (
  select
    to_regclass('public.fin_clientes_areas') is not null as t_areas,
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'importado_en') as c_importado,
    to_regclass('public.fin_import_liam_076') is not null as t_foto,
    coalesce((select bool_or(cortada_en is not null and not activo)
                from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos'), false) as corte,
    exists (select 1 from public.fin_columnas
             where cliente_id = 'liam' and vista = 'pagos' and clave = 'x_fuente_bpf') as col_fuente,
    (select count(*) from public.fin_pagos where cliente_id = 'liam' and origen = 'sheet')::int as pagos_sheet,
    (select count(*) from public.fin_pagos where cliente_id = 'liam' and origen = 'app')::int as pagos_app,
    (select count(*) from public.fin_pagos where cliente_id = 'liam'
        and fila_planilla between 182 and 190
        and alumno ~* '^\\s*(gabriel|alfredo|joaqu[ií]n\\s+fern[aá]ndez)')::int as filas_prueba
), d as (
  select s.*,
    case when c_importado then ${cnt("select count(*) as c from public.fin_pagos where cliente_id = 'liam' and importado_en is not null")} end as importados,
    case when t_foto then ${cnt('select count(*) as c from public.fin_import_liam_076')} end as foto_filas,
    case when t_foto then ${cnt("select count(*) as c from (select public.fin_pago_huella('liam', fecha, alumno, monto, concepto) as h, row_number() over (partition by public.fin_pago_huella('liam', fecha, alumno, monto, concepto) order by fila) as o from public.fin_import_liam_076) d left join (select huella as h, count(*)::int as n from public.fin_pagos where cliente_id = 'liam' group by huella) b using (h) where d.o > coalesce(b.n, 0)")} end as foto_sin_pago
  from s
)
select
  case
    when not (t_areas and c_importado) then 'FALTA LA 075: correrla antes (la 076 no se aplica)'
    when corte and pagos_sheet = 0 and col_fuente and coalesce(importados, 0) > 0 and coalesce(foto_sin_pago, 0) = 0
      then 'COMPLETO: la 076 ya esta aplicada (si se vuelve a correr, no cambia nada)'
    when not corte and coalesce(importados, 0) = 0 and not col_fuente
      then 'NADA APLICADO: correr la 076 entera'
    else 'A MEDIAS: correr la 076 entera (es re-ejecutable y lo termina)'
  end as estado,
  corte as fuente_pagos_cortada,
  t_foto as existe_foto,
  foto_filas,
  foto_sin_pago as foto_sin_pago_en_base,
  pagos_sheet as pagos_liam_sheet,
  pagos_app as pagos_liam_app,
  coalesce(importados, 0) as pagos_importados,
  col_fuente as columna_fuente,
  filas_prueba as filas_de_prueba
from d;`;

const sql = `-- =====================================================================
-- 076_liam_pagos_al_dia.sql
-- FINANZAS: Liam (BPF) al dia + corte de la planilla de PAGOS.
-- Generada ${ahora} por pruebas/liam-generar-076.mjs desde
-- "BluePrint - Finanzas 2026.xlsx" (hoja Pagos). NO editar a mano: se regenera.
--
-- REQUIERE la 075 corrida antes (catalogos, areas, importado_en).
--
-- COMO CORRERLA (SQL Editor del dashboard):
--   1. Seleccionar SOLO el bloque DIAGNOSTICO y Run. No modifica nada. Devuelve una
--      fila con "estado": FALTA LA 075 / NADA APLICADO / A MEDIAS / COMPLETO.
--   2. Si no dice COMPLETO ni FALTA LA 075: correr el archivo entero (o solo el
--      bloque MIGRACION). Es UNA sola sentencia (do $liam076$ ... $liam076$): se
--      aplica completa o no se aplica nada. No usa begin/commit ni temporales.
--   3. Re-ejecutable: sobre una base a medias la termina; si ya esta aplicada
--      (algun pago de liam con importado_en) no hace nada.
--
-- Que hace (solo Liam; el resto de los clientes no se toca):
--   0. Corta la fuente de PAGOS de liam (cortada_en = now(), activo = false):
--      desde aca la sync no la lee ni la pisa. Opps y Cuotas de liam siguen
--      sincronizando (los gastos todavia no se cargan en la app).
--   1. Recrea la foto del xlsx en la tabla normal public.fin_import_liam_076
--      (con huella y ocurrencia; la usan los controles). No es temporal.
--   2. Borra las filas de prueba (fila 182 a 190, gabriel / alfredo / joaquin
--      fernandez) SOLO si no figuran en la foto.
--   3. Inserta los pagos de la foto que todavia no estan (la huella decide;
--      un pago repetido legitimo cuenta por ocurrencia).
--   4. Closer "BPF" = sin closer (salvo pagos ya en una liquidacion cerrada).
--   5. Todos los pagos de liam pasan a origen 'app' con importado_en: desde
--      ahora se editan desde la app (solo fundador). La clave NO cambia.
--   6. Columna "Fuente" de Pagos de liam con lo que decia la columna L.
--   Lo que esta en la base y NO en la foto NO se borra: queda listado en C4
--   para decidir a mano (por si la planilla cambio despues de exportar el xlsx).
--
-- NO correr a las :00/:15/:30/:45 (corre la sync).
--
-- Pagos en la foto: ${filas.length}, total ${total} USD.
-- Total por mes de la foto:
${comentarioMes}
-- Pagos sin fecha en la planilla (imputados al mes, ver nota del pago):
${comentarioImp || '--   (ninguno)'}
-- Filas de la planilla que NO se cargan (pendientes, ver el resumen):
${comentarioPend || '--   (ninguna)'}
-- Filas de "segundo comprobante" (el link va a la nota del pago anterior): ${continuaciones.map(c => c.fila).join(', ') || 'ninguna'}
-- =====================================================================

-- =====================================================================
-- DIAGNOSTICO (solo lectura; correr primero, tambien sirve despues)
-- =====================================================================

${DIAG}

-- =====================================================================
-- MIGRACION (una sola sentencia atomica)
-- =====================================================================

do $liam076$
declare
  v_fuente public.fin_fuentes.id%type;
  v_nuevos int;
  v_solo_db int;
  v_ins int;
begin
  perform set_config('lock_timeout', '10s', true);
  lock table public.fin_pagos, public.fin_fuentes, public.fin_columnas, public.fin_pagos_extra in access exclusive mode;

  if to_regclass('public.fin_clientes_areas') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'importado_en') then
    raise exception 'GUARDA 076: falta correr la 075 antes. No se aplica nada.';
  end if;
  select id into v_fuente from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' order by id limit 1;
  if v_fuente is null then
    raise exception 'GUARDA 076: liam no tiene fuente de pagos. No se aplica nada.';
  end if;

  -- Ya aplicada (la sentencia es atomica: importado_en solo existe si termino): no hace nada.
  if exists (select 1 from public.fin_pagos where cliente_id = 'liam' and importado_en is not null) then
    raise notice '076: ya estaba aplicada (hay pagos de liam con importado_en). No se cambio nada.';
    return;
  end if;

  -- 0. Corte: la sync deja de leer los pagos de liam.
  update public.fin_fuentes
     set cortada_en = coalesce(cortada_en, now()), activo = false
   where cliente_id = 'liam' and tipo = 'pagos';

  -- 1. Foto del xlsx (tabla normal, se recrea; incluye huella y ocurrencia).
  drop table if exists public.fin_import_liam_076;
  create table public.fin_import_liam_076 (
    fila int, fecha date not null, programa text, alumno text not null, telefono text, concepto text,
    monto numeric not null, closer text, setter text, comprobante text, quien_recibe text,
    metodo_pago text, moneda_cobro text, nota text, fuente text,
    huella text, ocu int
  );
  alter table public.fin_import_liam_076 enable row level security;
  revoke all on public.fin_import_liam_076 from anon, authenticated;
  grant all on public.fin_import_liam_076 to service_role;

  insert into public.fin_import_liam_076
    (fila, fecha, programa, alumno, telefono, concepto, monto, closer, setter, comprobante, quien_recibe, metodo_pago, moneda_cobro, nota, fuente)
  values
${valores};

  update public.fin_import_liam_076 f
     set huella = x.h, ocu = x.o
    from (select ctid as c,
                 public.fin_pago_huella('liam', fecha, alumno, monto, concepto) as h,
                 row_number() over (
                   partition by public.fin_pago_huella('liam', fecha, alumno, monto, concepto)
                   order by fila) as o
            from public.fin_import_liam_076) x
   where f.ctid = x.c;

  -- 2. Filas de prueba (solo si no estan en la foto).
  delete from public.fin_pagos p
   where p.cliente_id = 'liam'
     and p.origen = 'sheet'
     and p.fila_planilla between 182 and 190
     and p.alumno ~* '^\\s*(gabriel|alfredo|joaqu[ií]n\\s+fern[aá]ndez)'
     and not exists (select 1 from public.fin_import_liam_076 f where f.huella = p.huella);

  -- Guarda de sentido comun: si la base y el xlsx difieren mucho, algo no es
  -- lo que se espera (sync caida, otro xlsx). La excepcion revierte todo.
  select count(*) into v_nuevos
    from public.fin_import_liam_076 d
    left join (select huella, count(*)::int as n from public.fin_pagos
                where cliente_id = 'liam' group by huella) h using (huella)
   where d.ocu > coalesce(h.n, 0);
  select coalesce(sum(greatest(h.n - coalesce(f.n, 0), 0)), 0) into v_solo_db
    from (select huella, count(*)::int as n from public.fin_pagos
           where cliente_id = 'liam' group by huella) h
    left join (select huella, count(*)::int as n from public.fin_import_liam_076 group by huella) f using (huella);
  raise notice '076: % pagos nuevos desde el xlsx, % pagos de la base que no estan en el xlsx', v_nuevos, v_solo_db;
  if v_nuevos > 40 then
    raise exception 'GUARDA 076: % pagos nuevos (maximo 40). Revisar que el xlsx sea el de liam y la sync este al dia. No se aplica nada.', v_nuevos;
  end if;
  if v_solo_db > 15 then
    raise exception 'GUARDA 076: % pagos de la base no estan en el xlsx (maximo 15). Revisar antes de seguir. No se aplica nada.', v_solo_db;
  end if;

  -- 3. Insertar lo que falta.
  insert into public.fin_pagos (
    cliente_id, fuente_id, fila_planilla, fecha, programa, alumno, telefono, concepto,
    monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente, moneda_cobro,
    closer, setter, comprobante, quien_recibe, metodo_pago, nota, origen)
  select 'liam', v_fuente,
         d.fila, d.fecha, d.programa, d.alumno, d.telefono, d.concepto,
         d.monto, d.monto, 'USD', 1, 'planilla', d.moneda_cobro,
         d.closer, d.setter, d.comprobante, d.quien_recibe, d.metodo_pago, d.nota, 'sheet'
    from public.fin_import_liam_076 d
    left join (select huella, count(*)::int as n from public.fin_pagos
                where cliente_id = 'liam' group by huella) h using (huella)
   where d.ocu > coalesce(h.n, 0)
   order by d.fila;
  get diagnostics v_ins = row_count;

  -- 4. "BPF" como closer = sin closer.
  update public.fin_pagos p
     set closer = null
   where p.cliente_id = 'liam'
     and upper(btrim(p.closer)) = 'BPF'
     and not exists (
       select 1 from public.fin_liquidacion_items i
         join public.fin_liquidaciones l on l.id = i.liquidacion_id
        where l.estado = 'cerrada' and i.pago_clave = p.clave);

  -- 5. Desde ahora los pagos de liam viven en la app.
  update public.fin_pagos
     set origen = 'app', importado_en = now()
   where cliente_id = 'liam' and origen = 'sheet';

  -- 6. Columna "Fuente" (texto) con lo que decia la columna L de la planilla.
  insert into public.fin_columnas (cliente_id, vista, clave, sistema, etiqueta, orden, visible, tipo, opciones)
  select 'liam', 'pagos', 'x_fuente_bpf', false, 'Fuente',
         greatest(coalesce((select max(orden) from public.fin_columnas where cliente_id = 'liam' and vista = 'pagos'), 0), 140) + 10,
         true, 'texto', '[]'::jsonb
   where not exists (select 1 from public.fin_columnas
                      where cliente_id = 'liam' and vista = 'pagos' and clave = 'x_fuente_bpf');

  insert into public.fin_pagos_extra (cliente_id, clave, valores)
  select 'liam', p.clave, jsonb_build_object('x_fuente_bpf', d.fuente)
    from public.fin_import_liam_076 d
    join lateral (
      select x.clave from public.fin_pagos x
       where x.cliente_id = 'liam' and x.huella = d.huella
       order by x.ocurrencia
       limit 1 offset (d.ocu - 1)) p on true
   where d.fuente is not null
  on conflict (cliente_id, clave) do update
    set valores = case when public.fin_pagos_extra.valores ? 'x_fuente_bpf'
                       then public.fin_pagos_extra.valores
                       else public.fin_pagos_extra.valores || excluded.valores end,
        actualizado_en = now();

  raise notice '076: aplicada. % pagos insertados.', v_ins;
end
$liam076$;

-- Resultado: el mismo diagnostico. Esperado: estado = COMPLETO.
${DIAG}

-- =====================================================================
-- CONTROLES (sueltos: seleccionar uno y Run; no dependen de temporales)
-- =====================================================================

-- C1. La sync de pagos de liam esta cortada y el resto sigue igual.
--     Esperado: liam/pagos activo=false con cortada_en; las demas filas como antes.
-- select cliente_id, tipo, activo, cortada_en from public.fin_fuentes order by 1, 2;

-- C2. Todos los pagos de liam son de la app y editables. Esperado: una sola fila origen='app'.
-- select origen, count(*) as pagos, round(sum(monto_usd), 2) as usd
--   from public.fin_pagos where cliente_id = 'liam' group by 1;

-- C3. Total por mes. Esperado = la lista de arriba (puede sobrar lo que muestre C4).
-- select to_char(date_trunc('month', fecha), 'YYYY-MM') as mes, count(*) as pagos, round(sum(monto_usd), 2) as usd
--   from public.fin_pagos where cliente_id = 'liam' group by 1 order by 1;

-- C4. En la base y NO en el xlsx (no se borraron). Esperado: vacio o filas que
--     reconocen como viejas. Si son basura, usar el borrado de abajo.
-- select p.fecha, p.alumno, p.concepto, p.monto_usd, p.clave
--   from public.fin_pagos p
--  where p.cliente_id = 'liam'
--    and not exists (select 1 from public.fin_import_liam_076 f where f.huella = p.huella)
--  order by p.fecha;

-- C5. Las filas de prueba no estan. Esperado: 0.
-- select count(*) from public.fin_pagos
--  where cliente_id = 'liam' and alumno ~* '^\\s*(alfredo|joaqu[ií]n\\s+fern[aá]ndez)';

-- C6. Sin closer "BPF". Esperado: 0 (o los que esten en una liquidacion cerrada).
-- select count(*) from public.fin_pagos where cliente_id = 'liam' and upper(btrim(closer)) = 'BPF';

-- C7. Textos sin catalogo de liam. Esperado: vacio o solo lo que haya que decidir.
-- select * from public.fin_v_alias_pendientes where cliente_id = 'liam' order by pagos desc;

-- C8. Otros clientes intactos. Esperado: agus/teo/lucas/mauro siguen origen='sheet'.
-- select cliente_id, origen, count(*) from public.fin_pagos group by 1, 2 order by 1, 2;

-- =====================================================================
-- LIMPIEZA (preparada, NO corre sola)
-- =====================================================================

-- L1. Borrar de la base lo que listo C4 (despues de revisarlo):
-- delete from public.fin_pagos p
--  where p.cliente_id = 'liam'
--    and not exists (select 1 from public.fin_import_liam_076 f where f.huella = p.huella);

-- L2. Cuando todo este revisado, quitar la tabla de la foto:
-- drop table public.fin_import_liam_076;

-- L3. Donde aparece "Joaquin Fernandez" / usuarios de prueba (solo lectura).
-- select 'crm_members' as donde, user_id::text as id, nombre as texto, rol as detalle
--   from public.crm_members where nombre ilike '%joaqu%fern%' or nombre ilike '%prueba%'
-- union all
-- select 'fin_personas', id::text, alias, campo from public.fin_personas where alias ilike '%joaqu%fern%'
-- union all
-- select 'fin_vendedores', id::text, nombre, null from public.fin_vendedores where nombre ilike '%joaqu%fern%'
-- union all
-- select 'auth.users', id::text, email, null from auth.users where email ilike '%prueba%' or email ilike '%@dystopia.test';

-- L4. Borrado de usuarios de prueba (EDITAR el uuid con el que dio L3; no corre solo):
-- delete from public.fin_personas where user_id = '<uuid>';
-- delete from public.crm_asignaciones where user_id = '<uuid>';
-- delete from public.crm_members where user_id = '<uuid>';
-- (el usuario de Auth se borra a mano en Authentication > Users)
`;

fs.writeFileSync(SALIDA, sql);
console.log(`076 escrita: ${filas.length} pagos, total ${total} USD`);
console.log('por mes:', JSON.stringify(porMes));
console.log('imputadas al mes:', imputadas.map(x => `${x.fila} ${x.alumno}`).join('; ') || '-');
console.log('continuaciones:', continuaciones.map(c => c.fila).join(', ') || '-');
console.log('pendientes (no se cargan):');
for (const p of pendientes) console.log(`  fila ${p.fila}: ${p.motivo} ${p.valor || ''} :: ${p.contenido}`);
console.log('descartadas:', res.stats.descartadas, '| leidas:', res.stats.filas_leidas, '| cargadas:', res.stats.filas_cargadas);
