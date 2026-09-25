-- ============================================================================
-- Migración 031: catálogo de conceptos de pago (fin_conceptos)
-- Proyecto: Dystopia Finanzas
-- Fecha: 2026-09-25
-- Depende de: 001 (esquema fin), funciones compartidas es_fundador() / rol_actual()
--
-- Qué hace:
--   1. Función de normalización fin_normalizar_concepto(text)
--   2. Tabla catálogo fin_conceptos (cliente_id NULLABLE = regla global)
--   3. Función de resolución fin_categoria_concepto(cliente_id, concepto)
--   4. Seed de los 30 conceptos relevados el 2026-09-25 (1.621 pagos)
--   5. RLS + revoke anon
--   6. Smoke test que se auto-revierte
--
-- Qué NO hace (a propósito):
--   - No crea la vista de desglose para la torta. Esa va en la 032, después
--     de que corras el CONTROL 1 y me pases los nombres reales de columnas
--     de fin_pagos (monto / fecha). No quiero adivinarlos y romperte una vista.
--   - No toca fin_alertas. El aviso por concepto nuevo va en la 033, después
--     de leer el cuerpo actual de esa función.
--
-- Clasificación aprobada (tiene que dar 1.621 pagos exactos):
--   venta_nueva   1.471 pagos   763.396 USD   90,6%
--   cuota            34 pagos    18.215 USD    2,2%
--   producto        102 pagos    56.883 USD    6,8%
--   sin_clasificar   14 pagos     4.199 USD    0,5%
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Normalización
--    upper + trim + colapso de espacios internos. Vacío o NULL -> (SIN CONCEPTO)
-- ---------------------------------------------------------------------------
create or replace function public.fin_normalizar_concepto(p_concepto text)
returns text
language sql
immutable
parallel safe
as $$
  select coalesce(
    nullif(upper(btrim(regexp_replace(coalesce(p_concepto, ''), '\s+', ' ', 'g'))), ''),
    '(SIN CONCEPTO)'
  );
$$;

comment on function public.fin_normalizar_concepto(text) is
  'Normaliza el concepto de un pago para matchear contra fin_conceptos. Vacío o NULL -> (SIN CONCEPTO).';

-- ---------------------------------------------------------------------------
-- 2. Catálogo
--    cliente_id NULL  = regla global (aplica a todos los clientes)
--    cliente_id != NULL = override para ese cliente, gana sobre la global
-- ---------------------------------------------------------------------------
create table if not exists public.fin_conceptos (
  id            bigint generated always as identity primary key,
  concepto_norm text        not null,
  cliente_id    text        null references public.crm_clients(id) on delete cascade,
  categoria     text        not null
                check (categoria in ('venta_nueva', 'cuota', 'producto', 'sin_clasificar')),
  nota          text,
  creado_en     timestamptz not null default now(),
  constraint fin_conceptos_norm_chk
    check (concepto_norm = public.fin_normalizar_concepto(concepto_norm))
);

comment on table public.fin_conceptos is
  'Catálogo de conceptos de pago. Sin fila -> sin_clasificar (no hay catch-all a venta_nueva).';
comment on column public.fin_conceptos.cliente_id is
  'NULL = regla global. Con valor = override de ese cliente, tiene prioridad sobre la global.';

-- Unicidad con NULL: dos índices parciales, porque en Postgres NULL != NULL
create unique index if not exists fin_conceptos_global_uq
  on public.fin_conceptos (concepto_norm)
  where cliente_id is null;

create unique index if not exists fin_conceptos_cliente_uq
  on public.fin_conceptos (concepto_norm, cliente_id)
  where cliente_id is not null;

create index if not exists fin_conceptos_categoria_idx
  on public.fin_conceptos (categoria);

-- ---------------------------------------------------------------------------
-- 3. Resolución: override de cliente -> regla global -> sin_clasificar
-- ---------------------------------------------------------------------------
create or replace function public.fin_categoria_concepto(
  p_cliente_id text,
  p_concepto   text
)
returns text
language sql
stable
parallel safe
as $$
  select coalesce(
    (
      select c.categoria
      from public.fin_conceptos c
      where c.concepto_norm = public.fin_normalizar_concepto(p_concepto)
        and (c.cliente_id = p_cliente_id or c.cliente_id is null)
      order by (c.cliente_id is null)   -- false (override) ordena antes que true (global)
      limit 1
    ),
    'sin_clasificar'
  );
$$;

comment on function public.fin_categoria_concepto(text, text) is
  'Devuelve la categoría de un pago. Override por cliente gana sobre regla global. Desconocido -> sin_clasificar.';

-- ---------------------------------------------------------------------------
-- 4. Seed: 30 conceptos distintos relevados el 2026-09-25 sobre fin_pagos
--    Todos globales (cliente_id null). Los overrides por cliente se cargan
--    después, a mano, si algún cliente usa una palabra distinto al resto.
-- ---------------------------------------------------------------------------
insert into public.fin_conceptos (concepto_norm, cliente_id, categoria, nota) values
  -- VENTA NUEVA -- 1.471 pagos / 763.396 USD
  ('FEE',                                 null, 'venta_nueva', '610 pagos al 2026-09-25'),
  ('PIF',                                 null, 'venta_nueva', '387 pagos al 2026-09-25'),
  ('COMPLETA PIF',                        null, 'venta_nueva', '217 pagos. Completa la venta original, no es cobro de cuota'),
  ('1RA CUOTA',                           null, 'venta_nueva', '135 pagos. Primera cuota = entrada de la venta nueva'),
  ('REFUERZA FEE',                        null, 'venta_nueva', '95 pagos'),
  ('COMPLETA FEE',                        null, 'venta_nueva', '13 pagos'),
  ('FEE DE PIF',                          null, 'venta_nueva', '5 pagos'),
  ('COMPLETA 1RA CUOTA',                  null, 'venta_nueva', '3 pagos'),
  ('COMPLETA PAGO',                       null, 'venta_nueva', '3 pagos'),
  ('COMPLETO FEE (ACCESO AL PROGRAMA)',   null, 'venta_nueva', '2 pagos'),
  ('REFUERZO FEE',                        null, 'venta_nueva', '1 pago. Variante de escritura de REFUERZA FEE'),

  -- CUOTA -- 34 pagos / 18.215 USD
  ('2DA CUOTA',                           null, 'cuota',       '34 pagos'),

  -- PRODUCTO (resell / upsell / renovación / comunidad) -- 102 pagos / 56.883 USD
  ('RESELL / UPSELL',                     null, 'producto',    '29 pagos'),
  ('CUOTA RENOVACION',                    null, 'producto',    '20 pagos'),
  ('COMUNIDAD',                           null, 'producto',    '15 pagos'),
  ('UPSELL',                              null, 'producto',    '13 pagos'),
  ('RESELL',                              null, 'producto',    '10 pagos'),
  ('UPSELL / RESELL',                     null, 'producto',    '3 pagos'),
  ('CUOTA RESELL',                        null, 'producto',    '2 pagos'),
  ('PARTE UPSELL',                        null, 'producto',    '1 pago'),
  ('PIF UPSELL',                          null, 'producto',    '1 pago'),
  ('COMPLETA UPSELL / RESELL',            null, 'producto',    '1 pago'),
  ('REFUERZO FEE RESELL',                 null, 'producto',    '1 pago'),
  ('COMPLETA UPSELL',                     null, 'producto',    '1 pago'),
  ('COMPLETA CUOTA 1 RESELL',             null, 'producto',    '1 pago'),
  ('3RA CUOTA RENEWAL',                   null, 'producto',    '1 pago'),
  ('CUOTA UPSELL',                        null, 'producto',    '1 pago'),
  ('2DA CUOTA RESELL',                    null, 'producto',    '1 pago'),
  ('FEE RESELL',                          null, 'producto',    '1 pago'),

  -- SIN CLASIFICAR -- 14 pagos / 4.199 USD
  ('(SIN CONCEPTO)',                      null, 'sin_clasificar',
     '14 pagos de liam y teo, marzo a agosto, con la celda de concepto vacía en la planilla')
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 5. RLS + permisos
--    El catálogo no tiene datos de clientes (son etiquetas), así que lo puede
--    leer cualquier usuario autenticado. Escribir, solo fundador.
-- ---------------------------------------------------------------------------
alter table public.fin_conceptos enable row level security;

drop policy if exists fin_conceptos_select on public.fin_conceptos;
create policy fin_conceptos_select
  on public.fin_conceptos
  for select
  to authenticated
  using (true);

drop policy if exists fin_conceptos_escritura on public.fin_conceptos;
create policy fin_conceptos_escritura
  on public.fin_conceptos
  for all
  to authenticated
  using (public.es_fundador())
  with check (public.es_fundador());

revoke all on table public.fin_conceptos from anon;
grant select on table public.fin_conceptos to authenticated;
grant all    on table public.fin_conceptos to service_role;

revoke all on function public.fin_normalizar_concepto(text) from anon;
revoke all on function public.fin_categoria_concepto(text, text) from anon;
grant execute on function public.fin_normalizar_concepto(text)      to authenticated, service_role;
grant execute on function public.fin_categoria_concepto(text, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Smoke test (se auto-revierte, no deja nada en la tabla)
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_res text;
begin
  -- 6.a normalización
  if public.fin_normalizar_concepto('  completa   pif ') <> 'COMPLETA PIF' then
    raise exception 'SMOKE 6.a FALLA: normalización no colapsa espacios ni pasa a mayúscula';
  end if;
  if public.fin_normalizar_concepto(null) <> '(SIN CONCEPTO)' then
    raise exception 'SMOKE 6.a FALLA: NULL no cae en (SIN CONCEPTO)';
  end if;
  if public.fin_normalizar_concepto('   ') <> '(SIN CONCEPTO)' then
    raise exception 'SMOKE 6.a FALLA: vacío no cae en (SIN CONCEPTO)';
  end if;

  -- 6.b regla global resuelve
  if public.fin_categoria_concepto('liam', 'completa pif') <> 'venta_nueva' then
    raise exception 'SMOKE 6.b FALLA: COMPLETA PIF no resuelve a venta_nueva';
  end if;

  -- 6.c desconocido cae en sin_clasificar, NO en venta_nueva
  if public.fin_categoria_concepto('liam', 'ZZZ CONCEPTO INVENTADO') <> 'sin_clasificar' then
    raise exception 'SMOKE 6.c FALLA: un concepto desconocido no cayó en sin_clasificar';
  end if;

  -- 6.d el override por cliente le gana a la regla global
  insert into public.fin_conceptos (concepto_norm, cliente_id, categoria, nota)
  values ('COMPLETA PIF', 'teo', 'producto', 'SMOKE TEST - se borra al final');

  select public.fin_categoria_concepto('teo', 'completa pif') into v_res;
  if v_res <> 'producto' then
    delete from public.fin_conceptos where nota = 'SMOKE TEST - se borra al final';
    raise exception 'SMOKE 6.d FALLA: el override de teo no ganó, devolvió %', v_res;
  end if;

  select public.fin_categoria_concepto('liam', 'completa pif') into v_res;
  if v_res <> 'venta_nueva' then
    delete from public.fin_conceptos where nota = 'SMOKE TEST - se borra al final';
    raise exception 'SMOKE 6.d FALLA: el override de teo contaminó a liam, devolvió %', v_res;
  end if;

  delete from public.fin_conceptos where nota = 'SMOKE TEST - se borra al final';

  -- 6.e el smoke no dejó basura
  if exists (select 1 from public.fin_conceptos where nota like 'SMOKE TEST%') then
    raise exception 'SMOKE 6.e FALLA: quedaron filas del smoke test en fin_conceptos';
  end if;

  raise notice 'SMOKE 031 OK: normalización, resolución, sin_clasificar y override verificados';
end
$smoke$;

commit;

-- ============================================================================
-- CONTROLES. Corrélos DE A UNO, en orden. El editor solo muestra el último.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONTROL 1  (este es el que necesito para escribir la 032)
-- Nombres y tipos reales de las columnas de fin_pagos.
-- Pasámelo entero.
-- ----------------------------------------------------------------------------
-- select column_name, data_type, is_nullable
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'fin_pagos'
-- order by ordinal_position;


-- ----------------------------------------------------------------------------
-- CONTROL 2
-- El catálogo quedó con 30 filas globales y ninguna huérfana.
-- Esperado: total = 30, venta_nueva = 11, cuota = 1, producto = 17, sin_clasificar = 1
-- ----------------------------------------------------------------------------
-- select categoria, count(*) as filas
-- from public.fin_conceptos
-- where cliente_id is null
-- group by categoria
-- union all
-- select 'TOTAL', count(*) from public.fin_conceptos
-- order by 1;


-- ----------------------------------------------------------------------------
-- CONTROL 3  (el importante)
-- Cada pago de fin_pagos cae en una categoría, y los números cierran contra
-- el relevamiento. Esperado EXACTO:
--   venta_nueva     1471
--   cuota             34
--   producto         102
--   sin_clasificar    14
--   TOTAL           1621
-- Si sin_clasificar da más de 14, entraron conceptos nuevos desde el sync de
-- hoy: el CONTROL 4 te dice cuáles.
-- ----------------------------------------------------------------------------
-- select public.fin_categoria_concepto(p.cliente_id, p.concepto) as categoria,
--        count(*) as pagos
-- from public.fin_pagos p
-- group by 1
-- order by 2 desc;


-- ----------------------------------------------------------------------------
-- CONTROL 4
-- Conceptos que están en fin_pagos y NO en el catálogo. Tiene que dar 0 filas.
-- Si devuelve algo, son conceptos nuevos que hay que clasificar a mano.
-- ----------------------------------------------------------------------------
-- select public.fin_normalizar_concepto(p.concepto) as concepto_norm,
--        count(*) as pagos,
--        min(p.cliente_id) as un_cliente
-- from public.fin_pagos p
-- where public.fin_categoria_concepto(p.cliente_id, p.concepto) = 'sin_clasificar'
--   and not exists (
--     select 1 from public.fin_conceptos c
--     where c.concepto_norm = public.fin_normalizar_concepto(p.concepto)
--   )
-- group by 1
-- order by 2 desc;


-- ----------------------------------------------------------------------------
-- CONTROL 5
-- anon no puede leer el catálogo. Tiene que dar 0 filas.
-- ----------------------------------------------------------------------------
-- select grantee, privilege_type
-- from information_schema.role_table_grants
-- where table_schema = 'public'
--   and table_name = 'fin_conceptos'
--   and grantee = 'anon';
