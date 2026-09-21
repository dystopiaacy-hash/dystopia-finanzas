-- 006_corridas_cortes.sql — Dystopia Finanzas: que una funcion que muere no
-- quede invisible. Ver CONTRATO.md seccion 4.2.
--
-- 1. fin_sync_corridas: estados 'pendiente' (abierta al arrancar la
--    invocacion, todavia sin tocar) y 'omitida' (la invocacion murio antes
--    de llegar: NO fallo, no arranco). Columnas nuevas:
--      invocacion     agrupa las corridas de una misma llamada.
--      payload_bytes  tamanio de la respuesta de Google para ESA hoja; se
--                     escribe antes de parsear, asi queda aunque muera ahi.
--      corte          por que murio: motivo del runtime ('memory', 'cpu',
--                     'wall_clock', ...) o 'sin_cierre' si la encontro la
--                     invocacion siguiente. NULL = no murio.
-- 2. fin_v_salud_sync: la ultima corrida que se INTENTO (ignora pendiente y
--    omitida) + cortes y omitidas de las ultimas 24 h + payload_bytes.
--
-- Compatible hacia atras: la funcion deployada hoy (v8) sigue andando con
-- esta migracion corrida. La funcion NUEVA necesita esta migracion (inserta
-- 'pendiente'): correr esto PRIMERO y despues redeployar.
-- Idempotente. Requiere 001 y 003.

begin;

-- ---------------------------------------------------------------------------
-- 1. fin_sync_corridas
-- ---------------------------------------------------------------------------
alter table public.fin_sync_corridas
  add column if not exists invocacion    uuid,
  add column if not exists payload_bytes bigint,
  add column if not exists corte         text;

-- El check de estado de 001 no tiene nombre propio: se busca por su definicion.
do $$
declare v_nombre text;
begin
  for v_nombre in
    select conname from pg_constraint
    where conrelid = 'public.fin_sync_corridas'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%en_curso%'
  loop
    execute format('alter table public.fin_sync_corridas drop constraint %I', v_nombre);
  end loop;
end $$;

alter table public.fin_sync_corridas
  add constraint fin_sync_corridas_estado_ck
  check (estado in ('pendiente', 'en_curso', 'ok', 'revisar', 'error', 'parcial', 'omitida'));

alter table public.fin_sync_corridas drop constraint if exists fin_sync_corridas_corte_ck;
alter table public.fin_sync_corridas
  add constraint fin_sync_corridas_corte_ck
  check (corte is null or estado in ('error', 'omitida'));

alter table public.fin_sync_corridas drop constraint if exists fin_sync_corridas_payload_ck;
alter table public.fin_sync_corridas
  add constraint fin_sync_corridas_payload_ck
  check (payload_bytes is null or payload_bytes >= 0);

comment on column public.fin_sync_corridas.estado is
  'pendiente = abierta al arrancar la invocacion, sin tocar. en_curso = se esta leyendo/escribiendo esta fuente. '
  'ok | revisar | parcial | error = termino (error = no se toco ningun dato). '
  'omitida = la funcion murio antes de llegar a esta fuente: no fallo, no arranco.';
comment on column public.fin_sync_corridas.invocacion is 'Una llamada a la Edge Function abre una corrida por fuente, todas con el mismo uuid.';
comment on column public.fin_sync_corridas.payload_bytes is
  'Bytes de la respuesta de Google para esta hoja (grid filtrado). Se escribe ANTES de parsear. Por encima de FIN_PAYLOAD_UMBRAL_BYTES la corrida queda en revisar con motivo ''payload grande''.';
comment on column public.fin_sync_corridas.corte is
  'Por que murio la funcion en esta corrida: motivo del runtime (memory, cpu, wall_clock, early_drop, termination) o sin_cierre (la encontro abierta la invocacion siguiente). NULL = no murio.';

-- ---------------------------------------------------------------------------
-- 2. fin_v_salud_sync (mismas columnas de 003 y en el mismo orden; las nuevas al final)
-- ---------------------------------------------------------------------------
create or replace view public.fin_v_salud_sync
with (security_invoker = true) as
select f.id as fuente_id,
       f.cliente_id,
       f.tipo,
       f.nombre_hoja_esperado,
       f.activo,
       c.id as corrida_id,
       c.inicio,
       c.fin,
       c.estado,
       c.filas_leidas,
       c.filas_cargadas,
       c.filas_rechazadas,
       c.filas_descartadas,
       c.mensaje,
       c.controles,
       (c.estado = 'revisar')        as requiere_revision,
       now() - c.inicio as antiguedad,
       c.payload_bytes,
       c.corte,
       coalesce(k.cortes_24h, 0)   as cortes_24h,
       k.ultimo_corte,
       k.ultimo_corte_motivo,
       coalesce(k.omitidas_24h, 0) as omitidas_24h
from public.fin_fuentes f
left join lateral (
  -- La ultima corrida que se intento: una pendiente u omitida no dice nada
  -- sobre la fuente (no se llego a leer), se ve la anterior.
  select * from public.fin_sync_corridas sc
  where sc.fuente_id = f.id and sc.estado not in ('pendiente', 'omitida')
  order by sc.inicio desc
  limit 1
) c on true
left join lateral (
  select count(*) filter (where sc.estado = 'error' and sc.corte is not null)   as cortes_24h,
         max(coalesce(sc.fin, sc.inicio)) filter (where sc.estado = 'error' and sc.corte is not null) as ultimo_corte,
         (array_agg(sc.corte order by sc.inicio desc) filter (where sc.estado = 'error' and sc.corte is not null))[1] as ultimo_corte_motivo,
         count(*) filter (where sc.estado = 'omitida')                             as omitidas_24h
  from public.fin_sync_corridas sc
  where sc.fuente_id = f.id and sc.inicio > now() - interval '24 hours'
) k on true;

-- create or replace conserva los grants de 003 (authenticated SELECT, la RLS filtra); se reafirman.
revoke all on public.fin_v_salud_sync from anon, public;
revoke all on public.fin_v_salud_sync from authenticated;
grant select on public.fin_v_salud_sync to authenticated;

-- ---------------------------------------------------------------------------
-- Prueba de humo (se autorrevierte). Una fuente con: ok hace 2 h, un corte
-- por memoria hace 1 h, ok hace 30 min, una omitida hace 5 min y una
-- pendiente recien abierta. La vista tiene que mostrar el ok de hace 30 min
-- (no la omitida ni la pendiente), 1 corte (memory) y 1 omitida.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fuente bigint;
  v_ok     bigint;
  v        record;
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('liam', 'SMOKE_006', 1, 'Smoke', 'pagos', 10000) returning id into v_fuente;

    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado)
    values (v_fuente, now() - interval '2 hours', now() - interval '2 hours', 'ok');
    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado, corte, payload_bytes)
    values (v_fuente, now() - interval '1 hour', now() - interval '1 hour', 'error', 'memory', 2500000);
    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado, payload_bytes)
    values (v_fuente, now() - interval '30 minutes', now() - interval '30 minutes', 'ok', 2400000) returning id into v_ok;
    insert into public.fin_sync_corridas (fuente_id, inicio, fin, estado, corte)
    values (v_fuente, now() - interval '5 minutes', now() - interval '5 minutes', 'omitida', 'sin_cierre');
    insert into public.fin_sync_corridas (fuente_id, estado) values (v_fuente, 'pendiente');

    select * into v from public.fin_v_salud_sync where fuente_id = v_fuente;
    if not found then raise exception 'smoke 006: fin_v_salud_sync no devuelve la fuente'; end if;
    if v.corrida_id <> v_ok then raise exception 'smoke 006: la vista muestra la corrida % (%), se esperaba el ok %', v.corrida_id, v.estado, v_ok; end if;
    if v.payload_bytes <> 2400000 then raise exception 'smoke 006: payload_bytes = %', v.payload_bytes; end if;
    if v.cortes_24h <> 1 or v.ultimo_corte_motivo is distinct from 'memory' then
      raise exception 'smoke 006: cortes_24h = %, motivo = %', v.cortes_24h, v.ultimo_corte_motivo;
    end if;
    if v.omitidas_24h <> 1 then raise exception 'smoke 006: omitidas_24h = %', v.omitidas_24h; end if;

    -- Los checks: corte solo en error/omitida; un estado inventado no entra.
    begin
      insert into public.fin_sync_corridas (fuente_id, estado, corte) values (v_fuente, 'ok', 'memory');
      raise exception 'smoke 006: se acepto corte en una corrida ok';
    exception when check_violation then null;
    end;
    begin
      insert into public.fin_sync_corridas (fuente_id, estado) values (v_fuente, 'cualquiera');
      raise exception 'smoke 006: se acepto un estado inventado';
    exception when check_violation then null;
    end;

    -- fin_sync_escribir (005) sigue exigiendo en_curso: una pendiente no escribe.
    begin
      perform public.fin_sync_escribir(
        (select id from public.fin_sync_corridas where fuente_id = v_fuente and estado = 'pendiente'),
        'ok', null, 'h', '[]', 0, 0, '{}');
      raise exception 'smoke 006: fin_sync_escribir escribio sobre una corrida pendiente';
    exception when raise_exception then
      if sqlerrm like 'smoke 006:%' then raise; end if;
    end;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 006: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control: los 3 checks nuevos, las 3 columnas y que la vista
-- expone las columnas nuevas. Nada de corridas reales se modifica.
-- ---------------------------------------------------------------------------
select conname as constraint_, pg_get_constraintdef(oid) as definicion
from pg_constraint
where conrelid = 'public.fin_sync_corridas'::regclass and contype = 'c'
order by conname;

select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'fin_v_salud_sync'
  and column_name in ('payload_bytes', 'corte', 'cortes_24h', 'ultimo_corte', 'ultimo_corte_motivo', 'omitidas_24h')
order by column_name;

commit;
