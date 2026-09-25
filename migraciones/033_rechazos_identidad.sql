-- ============================================================================
-- Migración 033: identidad estable para fin_filas_rechazadas
-- Proyecto: Dystopia Finanzas
-- Fecha: 2026-09-25
--
-- PROBLEMA
--   La tabla se identifica por corrida_id. Cada corrida genera un id nuevo,
--   asi que el mismo rechazo se reinserta en cada pasada del sync.
--   Estado al 2026-09-25: 52.960 filas que son 162 rechazos reales,
--   repartidos en 3.886 corridas. Crece ~15.600 filas por dia.
--   Cada fila lleva contenido_crudo, que es la fila entera de la planilla,
--   con nombre y telefono del alumno. Es dato personal duplicado cientos
--   de veces sin ningun motivo.
--
-- SOLUCION
--   Darle a cada rechazo una identidad estable y que cada corrida haga
--   upsert en lugar de insert, y despues borre lo que ya no aparece.
--   Identidad: (fuente_id, fila_planilla, motivo, huella)
--   huella = md5 del contenido crudo. Es una columna generada, la calcula
--   Postgres, asi la Edge Function no tiene que reproducir el hash.
--
-- ESTA MIGRACION NO BORRA NADA.
--   Solo agrega columnas, el indice y la funcion de escritura.
--   Es compatible con la Edge Function actual: las filas viejas quedan con
--   fuente_id NULL y no chocan con el indice unico.
--   La limpieza va en la 034, DESPUES de que la funcion nueva este deployada
--   y haya corrido al menos una vez. Si limpiamos antes, la proxima corrida
--   vuelve a llenar la tabla.
--
-- ORDEN DE LOS 4 PASOS
--   1. Esta migracion.
--   2. Claude Code cambia la Edge Function para llamar a fin_rechazos_escribir().
--   3. Esperar una corrida y verificar.
--   4. Migracion 034: borra las filas viejas (fuente_id IS NULL).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas. Todas nullable o con default, para no romper la
--    Edge Function que hoy esta en produccion.
-- ---------------------------------------------------------------------------
alter table public.fin_filas_rechazadas
  add column if not exists fuente_id   bigint      null references public.fin_fuentes(id) on delete cascade,
  add column if not exists primera_vez timestamptz not null default now(),
  add column if not exists ultima_vez  timestamptz not null default now(),
  add column if not exists veces       integer     not null default 1;

-- huella: la calcula Postgres. jsonb::text es determinista (ordena las claves),
-- asi que no depende de como serialice el JSON quien inserta.
alter table public.fin_filas_rechazadas
  add column if not exists huella text
  generated always as (md5(contenido_crudo::text)) stored;

comment on column public.fin_filas_rechazadas.fuente_id is
  'Fuente a la que pertenece el rechazo. NULL = fila vieja, anterior a la 033.';
comment on column public.fin_filas_rechazadas.huella is
  'md5 del contenido crudo. Generada por Postgres. Parte de la identidad del rechazo.';
comment on column public.fin_filas_rechazadas.veces is
  'Cuantas corridas vieron este mismo rechazo. Alto = error cronico en la planilla.';
comment on column public.fin_filas_rechazadas.primera_vez is
  'Cuando se vio por primera vez. Sirve para distinguir un error nuevo de uno viejo.';

-- ---------------------------------------------------------------------------
-- 2. Identidad. Las filas viejas tienen fuente_id NULL y en Postgres los NULL
--    no chocan entre si, asi que conviven sin conflicto hasta la 034.
-- ---------------------------------------------------------------------------
create unique index if not exists fin_filas_rechazadas_identidad_uq
  on public.fin_filas_rechazadas (fuente_id, fila_planilla, motivo, huella);

create index if not exists fin_filas_rechazadas_fuente_idx
  on public.fin_filas_rechazadas (fuente_id, ultima_vez);

-- ---------------------------------------------------------------------------
-- 3. Funcion de escritura.
--    Va por RPC y no por PostgREST directo, por la misma razon que la 005:
--    el upsert y el borrado de lo que ya no aparece tienen que pasar en
--    la misma transaccion. Si se corta en el medio, la fuente queda sin
--    rechazos y la pantalla de errores miente diciendo que esta todo bien.
--
--    p_rechazos: array de objetos con
--      fila_planilla int, motivo text, valor_crudo text,
--      comprobante text, metodo_pago text, contenido_crudo jsonb
-- ---------------------------------------------------------------------------
create or replace function public.fin_rechazos_escribir(
  p_fuente_id  bigint,
  p_corrida_id bigint,
  p_rechazos   jsonb
)
returns table (insertados int, actualizados int, borrados int)
language plpgsql
security invoker
as $fn$
declare
  v_ahora     timestamptz := clock_timestamp();
  v_antes     bigint;
  v_afectados bigint;
  v_borrados  bigint;
begin
  if p_fuente_id is null then
    raise exception 'fin_rechazos_escribir: p_fuente_id no puede ser NULL';
  end if;

  if p_rechazos is null then
    p_rechazos := '[]'::jsonb;
  end if;

  if jsonb_typeof(p_rechazos) <> 'array' then
    raise exception 'fin_rechazos_escribir: p_rechazos tiene que ser un array, llego %',
      jsonb_typeof(p_rechazos);
  end if;

  select count(*) into v_antes
  from public.fin_filas_rechazadas
  where fuente_id = p_fuente_id;

  insert into public.fin_filas_rechazadas (
    corrida_id, fuente_id, fila_planilla, motivo,
    valor_crudo, comprobante, metodo_pago, contenido_crudo,
    primera_vez, ultima_vez, veces
  )
  select
    p_corrida_id,
    p_fuente_id,
    r.fila_planilla,
    r.motivo,
    r.valor_crudo,
    r.comprobante,
    r.metodo_pago,
    r.contenido_crudo,
    v_ahora,
    v_ahora,
    1
  from jsonb_to_recordset(p_rechazos) as r(
    fila_planilla   int,
    motivo          text,
    valor_crudo     text,
    comprobante     text,
    metodo_pago     text,
    contenido_crudo jsonb
  )
  on conflict (fuente_id, fila_planilla, motivo, huella) do update
    set corrida_id  = excluded.corrida_id,
        valor_crudo = excluded.valor_crudo,
        comprobante = excluded.comprobante,
        metodo_pago = excluded.metodo_pago,
        ultima_vez  = v_ahora,
        veces       = public.fin_filas_rechazadas.veces + 1;

  get diagnostics v_afectados = row_count;

  -- Lo que no se vio en esta corrida ya no esta en la planilla: alguien lo
  -- arreglo. Se borra. Solo toca esta fuente y nunca las filas viejas
  -- (fuente_id NULL), que se limpian en la 034.
  delete from public.fin_filas_rechazadas
  where fuente_id = p_fuente_id
    and ultima_vez < v_ahora;

  get diagnostics v_borrados = row_count;

  return query
  select
    greatest((select count(*)::int from public.fin_filas_rechazadas where fuente_id = p_fuente_id)
             - v_antes::int + v_borrados::int, 0),
    (v_afectados - greatest(
       (select count(*) from public.fin_filas_rechazadas where fuente_id = p_fuente_id)
       - v_antes + v_borrados, 0))::int,
    v_borrados::int;
end
$fn$;

comment on function public.fin_rechazos_escribir(bigint, bigint, jsonb) is
  'Reemplaza los rechazos de una fuente en una transaccion: upsert por identidad y borrado de los que ya no aparecen. La llama la Edge Function sincronizar.';

revoke all on function public.fin_rechazos_escribir(bigint, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.fin_rechazos_escribir(bigint, bigint, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Smoke test. Se auto-revierte.
--    OJO: NO llama a fin_rechazos_escribir() con una fuente real, porque la
--    funcion borra los rechazos de esa fuente y en este momento la Edge
--    Function vieja todavia no los sabe reescribir.
--    La prueba de punta a punta va en el paso 3, con una corrida real.
--    corrida_id tiene FK a fin_sync_corridas: el smoke reusa la ultima corrida
--    existente y no crea ninguna.
-- ---------------------------------------------------------------------------
do $smoke$
declare
  v_huella_a  text;
  v_huella_b  text;
  v_fuente    bigint;
  v_corrida   bigint;
  v_choco     boolean := false;
begin
  -- corrida_id tiene FK a fin_sync_corridas, asi que el smoke usa una corrida
  -- real que ya existe. No crea ni modifica corridas.
  select id into v_corrida from public.fin_sync_corridas order by id desc limit 1;

  if v_corrida is null then
    raise notice 'SMOKE 033 OMITIDO: no hay ninguna corrida en fin_sync_corridas';
    return;
  end if;

  -- 4.a la huella se genera sola y es estable ante el orden de las claves
  insert into public.fin_filas_rechazadas
    (corrida_id, fila_planilla, motivo, contenido_crudo)
  values
    (v_corrida, -999, 'SMOKE 033', '{"a":1,"b":2}'::jsonb)
  returning huella into v_huella_a;

  insert into public.fin_filas_rechazadas
    (corrida_id, fila_planilla, motivo, contenido_crudo)
  values
    (v_corrida, -998, 'SMOKE 033', '{"b":2,"a":1}'::jsonb)
  returning huella into v_huella_b;

  if v_huella_a is null or v_huella_a <> v_huella_b then
    delete from public.fin_filas_rechazadas where motivo = 'SMOKE 033';
    raise exception 'SMOKE 4.a FALLA: la huella no es estable ante el orden de claves (% vs %)',
      v_huella_a, v_huella_b;
  end if;

  -- 4.b dos filas viejas identicas con fuente_id NULL NO chocan entre si
  insert into public.fin_filas_rechazadas
    (corrida_id, fila_planilla, motivo, contenido_crudo)
  values (v_corrida, -999, 'SMOKE 033', '{"a":1,"b":2}'::jsonb);

  -- 4.c con fuente_id, la misma identidad SI choca
  select id into v_fuente from public.fin_fuentes order by id limit 1;

  if v_fuente is not null then
    begin
      insert into public.fin_filas_rechazadas
        (corrida_id, fuente_id, fila_planilla, motivo, contenido_crudo)
      values (v_corrida, v_fuente, -999, 'SMOKE 033', '{"a":1,"b":2}'::jsonb);

      insert into public.fin_filas_rechazadas
        (corrida_id, fuente_id, fila_planilla, motivo, contenido_crudo)
      values (v_corrida, v_fuente, -999, 'SMOKE 033', '{"a":1,"b":2}'::jsonb);
    exception when unique_violation then
      v_choco := true;
    end;

    if not v_choco then
      delete from public.fin_filas_rechazadas where motivo = 'SMOKE 033';
      raise exception 'SMOKE 4.c FALLA: el indice unico no impidio el duplicado';
    end if;
  end if;

  delete from public.fin_filas_rechazadas where motivo = 'SMOKE 033';

  if exists (select 1 from public.fin_filas_rechazadas where motivo = 'SMOKE 033') then
    raise exception 'SMOKE 4.d FALLA: quedaron filas del smoke test';
  end if;

  raise notice 'SMOKE 033 OK: huella estable, NULL conviven, identidad unica con fuente_id';
end
$smoke$;

commit;

-- ============================================================================
-- CONTROLES. De a uno, en orden.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONTROL 1
-- Las columnas nuevas existen. Esperado: 5 filas
-- (fuente_id, huella, primera_vez, ultima_vez, veces)
-- ----------------------------------------------------------------------------
-- select column_name, data_type, is_generated
-- from information_schema.columns
-- where table_schema = 'public'
--   and table_name = 'fin_filas_rechazadas'
--   and column_name in ('fuente_id','huella','primera_vez','ultima_vez','veces')
-- order by column_name;


-- ----------------------------------------------------------------------------
-- CONTROL 2
-- Foto de como esta la tabla ANTES del cambio en la Edge Function.
-- Guardá este numero: es contra el que vamos a comparar despues.
-- Esperado hoy: viejas ~52.960, nuevas 0
-- ----------------------------------------------------------------------------
-- select count(*) filter (where fuente_id is null) as viejas,
--        count(*) filter (where fuente_id is not null) as nuevas,
--        count(*) as total
-- from public.fin_filas_rechazadas;


-- ----------------------------------------------------------------------------
-- CONTROL 3
-- La funcion existe y solo la puede ejecutar service_role.
-- Esperado: 1 fila, ejecuta_service_role = true, ejecuta_anon = false,
--           ejecuta_authenticated = false
-- ----------------------------------------------------------------------------
-- select p.proname,
--        pg_get_function_identity_arguments(p.oid) as args,
--        has_function_privilege('service_role',  p.oid, 'execute') as ejecuta_service_role,
--        has_function_privilege('anon',          p.oid, 'execute') as ejecuta_anon,
--        has_function_privilege('authenticated', p.oid, 'execute') as ejecuta_authenticated
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public' and p.proname = 'fin_rechazos_escribir';


-- ----------------------------------------------------------------------------
-- CONTROL 4
-- El indice unico esta. Esperado: 1 fila.
-- ----------------------------------------------------------------------------
-- select indexname, indexdef
-- from pg_indexes
-- where schemaname = 'public'
--   and tablename = 'fin_filas_rechazadas'
--   and indexname = 'fin_filas_rechazadas_identidad_uq';
