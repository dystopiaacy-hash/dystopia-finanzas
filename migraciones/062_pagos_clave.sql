-- =====================================================================
-- 062_pagos_clave.sql
-- FINANZAS, fase 1: identidad estable de cada pago.
--
-- Problema: la sync borra e inserta fin_pagos cada 15 minutos, asi que
-- fin_pagos.id cambia en cada corrida. La liquidacion de lucas 2026-06
-- (cerrada, 62 lineas) ya apunta a 62 ids que no existen.
--
-- Solucion (decision V1, FASE0-FINANZAS.md):
-- 1. fin_pago_huella(): md5 de cliente + fecha + alumno + monto + concepto,
--    normalizados (minusculas, espacios colapsados, monto a 2 decimales).
--    NO incluye fila_planilla: insertar una fila arriba no cambia nada.
-- 2. fin_pagos.clave = huella + '#' + ocurrencia. La ocurrencia desempata
--    dos pagos identicos legitimos (hoy no hay ninguno: control 10.5).
--    La pone un trigger al insertar; un UPDATE nunca la cambia.
-- 3. fin_liquidacion_items.pago_clave: la liquidacion guarda la clave y
--    se reconectan las lineas ya cerradas por fecha + alumno + monto.
-- 4. fin_cerrar_periodo (copia exacta de la 012) ahora guarda la clave.
-- 5. fin_v_comisiones_fuera_de_cierre: pagos con comision en un periodo
--    ya cerrado que no estan en la liquidacion (cargados tarde o
--    editados despues del cierre). Se pagan como ajuste.
--
-- Limite conocido: si alguien corrige alumno, fecha, monto o concepto en
-- la planilla, ese pago cambia de clave (es otro contenido). Es el
-- puente hasta el corte: desde ahi la clave la da la app y no cambia.
--
-- No toca fin_sync_escribir ni la Edge Function: el trigger completa las
-- columnas nuevas en cada insert de la sync.
-- Idempotente. Probada dos veces contra Postgres local con el esquema
-- real (001 a 061) y los pagos reales del export del 2026-10-02.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Guarda: fin_cerrar_periodo en produccion tiene que ser la de la 012.
-- ---------------------------------------------------------------------
do $$
declare v text;
begin
  v := pg_get_functiondef('public.fin_cerrar_periodo(text,text,text,boolean,text)'::regprocedure);
  if v not like '%Las lineas de calculo se reemplazan%'
     or v not like '%from fin_v_comisiones c%'
     or v not like '%c.estado     = ''calculado''%' then
    raise exception 'GUARDA 062: fin_cerrar_periodo no es la version de la 012. No se aplica nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Huella de contenido
-- ---------------------------------------------------------------------
create or replace function public.fin_pago_huella(
  p_cliente text, p_fecha date, p_alumno text, p_monto numeric, p_concepto text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select md5(concat_ws('|',
    p_cliente,
    to_char(p_fecha, 'YYYY-MM-DD'),
    lower(regexp_replace(btrim(coalesce(p_alumno, '')), '\s+', ' ', 'g')),
    round(p_monto, 2)::text,
    upper(regexp_replace(btrim(coalesce(p_concepto, '')), '\s+', ' ', 'g'))
  ));
$$;

comment on function public.fin_pago_huella(text, date, text, numeric, text) is
  '062: md5 del contenido de un pago. Sin fila_planilla a proposito.';

-- ---------------------------------------------------------------------
-- 2. Columnas nuevas en fin_pagos + relleno de lo que ya existe
-- ---------------------------------------------------------------------
alter table public.fin_pagos
  add column if not exists huella     text,
  add column if not exists ocurrencia int,
  add column if not exists clave      text;

update public.fin_pagos p
set huella     = x.h,
    ocurrencia = x.o,
    clave      = x.h || '#' || x.o
from (
  select id, h,
         row_number() over (partition by cliente_id, h order by fuente_id, fila_planilla, id) as o
  from (
    select id, cliente_id, fuente_id, fila_planilla,
           public.fin_pago_huella(cliente_id, fecha, alumno, monto_usd, concepto) as h
    from public.fin_pagos
  ) s
) x
where x.id = p.id
  and p.clave is null;

alter table public.fin_pagos
  alter column huella     set not null,
  alter column ocurrencia set not null,
  alter column clave      set not null;

create unique index if not exists fin_pagos_clave_uq
  on public.fin_pagos (cliente_id, clave);

comment on column public.fin_pagos.clave is
  '062: identidad estable del pago (huella#ocurrencia). Usar esto, no id, para referenciar un pago desde otra tabla.';
comment on column public.fin_pagos.huella is
  '062: huella del contenido al momento de insertar. Un UPDATE no la recalcula.';

-- ---------------------------------------------------------------------
-- 3. Trigger: completa la clave en cada insert; la congela en update
-- ---------------------------------------------------------------------
create or replace function public.fin_pagos_clave()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    new.huella     := old.huella;
    new.ocurrencia := old.ocurrencia;
    new.clave      := old.clave;
    return new;
  end if;

  new.huella := public.fin_pago_huella(new.cliente_id, new.fecha, new.alumno, new.monto_usd, new.concepto);
  -- Las filas ya insertadas en la misma sentencia son visibles aca, asi
  -- que dos pagos identicos de una misma corrida quedan #1 y #2 en orden
  -- de planilla.
  select coalesce(max(p.ocurrencia), 0) + 1
    into new.ocurrencia
    from public.fin_pagos p
   where p.cliente_id = new.cliente_id
     and p.huella     = new.huella;
  new.clave := new.huella || '#' || new.ocurrencia;
  return new;
end $$;

drop trigger if exists fin_pagos_clave_trg on public.fin_pagos;
create trigger fin_pagos_clave_trg
  before insert or update on public.fin_pagos
  for each row execute function public.fin_pagos_clave();

-- ---------------------------------------------------------------------
-- 4. Liquidaciones: guardar la clave y reconectar lo ya cerrado
-- ---------------------------------------------------------------------
alter table public.fin_liquidacion_items
  add column if not exists pago_clave text;

comment on column public.fin_liquidacion_items.pago_clave is
  '062: clave estable del pago (fin_pagos.clave). pago_id queda como dato historico.';

create index if not exists fin_liq_items_pago_clave_idx
  on public.fin_liquidacion_items (pago_clave);

-- Reconexion: solo si hay UN unico pago con esa fecha, alumno y monto.
-- Si hay dos o ninguno, la linea queda sin clave y aparece en el control C4.
update public.fin_liquidacion_items i
set pago_clave = m.clave
from (
  select i2.id as item_id, min(p.clave) as clave, count(distinct p.clave) as n
  from public.fin_liquidacion_items i2
  join public.fin_liquidaciones l on l.id = i2.liquidacion_id
  join public.fin_pagos p
    on p.cliente_id = l.cliente_id
   and p.fecha      = i2.fecha
   and p.alumno is not distinct from i2.alumno
   and p.monto_usd  = i2.base_usd
  where i2.pago_clave is null
    and i2.origen = 'calculo'
  group by i2.id
) m
where m.item_id = i.id
  and m.n = 1;

-- ---------------------------------------------------------------------
-- 5. fin_cerrar_periodo: copia exacta de la 012 + pago_clave
-- ---------------------------------------------------------------------
create or replace function public.fin_cerrar_periodo(
  p_cliente text,
  p_periodo text,
  p_tipo    text default 'pagable',
  p_forzar  boolean default false,
  p_nota    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_liq_id    bigint;
  v_bloqueos  jsonb;
  v_lineas    integer;
  v_total     numeric;
begin
  -- auth.uid() es null cuando corre desde el SQL Editor o con service_role,
  -- que ya tienen acceso total. El guard aplica a usuarios autenticados.
  if auth.uid() is not null and not es_fundador() then
    raise exception 'Solo un fundador puede cerrar un periodo';
  end if;

  if p_periodo !~ '^\d{4}-\d{2}$' then
    raise exception 'Periodo invalido: % (formato esperado YYYY-MM)', p_periodo;
  end if;

  if exists (
    select 1 from fin_liquidaciones
    where cliente_id = p_cliente and periodo = p_periodo and estado = 'cerrada'
  ) then
    raise exception 'El periodo % de % ya esta cerrado. Un periodo cerrado no se recalcula: cargá un ajuste en el periodo abierto.', p_periodo, p_cliente;
  end if;

  v_bloqueos := fin_bloqueos_periodo(p_cliente, p_periodo);

  if jsonb_array_length(v_bloqueos) > 0 and not p_forzar then
    return jsonb_build_object(
      'cerrado',  false,
      'motivo',   'hay bloqueos sin resolver',
      'bloqueos', v_bloqueos
    );
  end if;

  insert into fin_liquidaciones (cliente_id, periodo, estado, tipo, cerrada_en, cerrada_por, bloqueos, nota)
  values (p_cliente, p_periodo, 'cerrada', p_tipo, now(), auth.uid(), v_bloqueos, p_nota)
  on conflict (cliente_id, periodo) do update
    set estado      = 'cerrada',
        tipo        = excluded.tipo,
        cerrada_en  = excluded.cerrada_en,
        cerrada_por = excluded.cerrada_por,
        bloqueos    = excluded.bloqueos,
        nota        = excluded.nota
  returning id into v_liq_id;

  -- Las lineas de calculo se reemplazan; los ajustes cargados a mano se conservan.
  delete from fin_liquidacion_items
  where liquidacion_id = v_liq_id and origen = 'calculo';

  insert into fin_liquidacion_items (
    liquidacion_id, vendedor_id, vendedor_nombre, rol, pago_id, pago_clave,
    fecha, alumno, programa, alias_usado, base_usd, pct, comision_usd, origen
  )
  select
    v_liq_id, c.vendedor_id, v.nombre, c.rol, c.pago_id, p.clave,
    c.fecha, c.alumno, c.programa, c.alias_usado,
    c.monto_usd, c.pct, c.comision_usd, 'calculo'
  from fin_v_comisiones c
  join fin_vendedores v on v.id = c.vendedor_id
  left join fin_pagos p on p.id = c.pago_id   -- 062: identidad estable del pago
  where c.cliente_id = p_cliente
    and c.periodo    = p_periodo
    and c.estado     = 'calculado';

  select count(*), coalesce(sum(comision_usd), 0)
  into v_lineas, v_total
  from fin_liquidacion_items
  where liquidacion_id = v_liq_id;

  return jsonb_build_object(
    'cerrado',      true,
    'liquidacion',  v_liq_id,
    'cliente',      p_cliente,
    'periodo',      p_periodo,
    'tipo',         p_tipo,
    'lineas',       v_lineas,
    'comision_usd', v_total,
    'bloqueos',     v_bloqueos
  );
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Comisiones de periodos cerrados que no entraron en la liquidacion
-- ---------------------------------------------------------------------
create or replace view public.fin_v_comisiones_fuera_de_cierre
with (security_invoker = true) as
select
  c.cliente_id,
  c.periodo,
  l.id        as liquidacion_id,
  p.clave     as pago_clave,
  c.fecha,
  c.alumno,
  c.programa,
  c.monto_usd,
  c.vendedor_id,
  c.rol,
  c.pct,
  c.comision_usd
from public.fin_v_comisiones c
join public.fin_pagos p
  on p.id = c.pago_id
join public.fin_liquidaciones l
  on l.cliente_id = c.cliente_id
 and l.periodo    = c.periodo
 and l.estado     = 'cerrada'
where c.estado = 'calculado'
  and not exists (
    select 1 from public.fin_liquidacion_items i
    where i.liquidacion_id = l.id
      and i.pago_clave     = p.clave
      and i.vendedor_id    = c.vendedor_id
      and i.rol            = c.rol
  );

comment on view public.fin_v_comisiones_fuera_de_cierre is
  '062: pagos que generan comision en un periodo ya cerrado y no estan en su liquidacion. Cargados tarde o editados despues del cierre. Se pagan como ajuste en el periodo abierto.';

revoke all on public.fin_v_comisiones_fuera_de_cierre from anon;
grant select on public.fin_v_comisiones_fuera_de_cierre to authenticated;
grant all on public.fin_v_comisiones_fuera_de_cierre to service_role;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Todos los pagos tienen clave y no hay claves repetidas.
--     Esperado: total = con_clave (aprox. 1.621), repetidas = 0.
-- select count(*) as total,
--        count(clave) as con_clave,
--        count(*) - count(distinct (cliente_id, clave)) as repetidas
--   from public.fin_pagos;

-- C2. Ocurrencias: esperado 1 sola fila, ocurrencia = 1.
--     Si aparece una 2, son dos pagos identicos: mandame cuales.
-- select ocurrencia, count(*) from public.fin_pagos group by 1 order by 1;

-- C3. Trigger y funcion arriba: las 3 en true.
-- select exists (select 1 from pg_trigger where tgname = 'fin_pagos_clave_trg') as trigger_ok,
--        pg_get_functiondef('public.fin_cerrar_periodo(text,text,text,boolean,text)'::regprocedure)
--          like '%p.clave%' as cerrar_guarda_clave,
--        to_regclass('public.fin_v_comisiones_fuera_de_cierre') is not null as vista_ok;

-- C4. Liquidacion de lucas 2026-06 reconectada.
--     Esperado: items 62, con_clave 62, clave_vigente 62.
-- select l.id, l.cliente_id, l.periodo, count(i.id) as items,
--        count(i.pago_clave) as con_clave,
--        count(*) filter (where exists (select 1 from public.fin_pagos p
--          where p.cliente_id = l.cliente_id and p.clave = i.pago_clave)) as clave_vigente
--   from public.fin_liquidaciones l
--   join public.fin_liquidacion_items i on i.liquidacion_id = l.id
--  group by 1, 2, 3 order by 1;

-- C5. Comisiones fuera de cierre. Esperado: 0 filas.
-- select * from public.fin_v_comisiones_fuera_de_cierre;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================

-- C6. La sync sigue andando y las claves no cambian aunque cambien los id.
--     Esperado: corridas de pagos en ok, y C4 sigue dando 62 / 62 / 62.
-- select f.cliente_id, c.estado, c.filas_cargadas, c.inicio
--   from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--  where f.tipo = 'pagos' order by c.id desc limit 5;
