-- ============================================================================
-- Migración 034: limpieza de fin_filas_rechazadas
-- Proyecto: Dystopia Finanzas
-- Fecha: 2026-09-25
-- Depende de: 033 + Edge Function sincronizar v11 (ya deployada)
--
-- VERIFICADO ANTES DE ESCRIBIR ESTA MIGRACION
--   Corrida 19:45 UTC (primera con el codigo nuevo): 142 rechazos, veces = 1
--   Corrida 20:00 UTC (segunda):                     142 rechazos, veces = 2
--   Duplicados por (fuente_id, fila_planilla, motivo): 0
--   Filas viejas (fuente_id NULL): 53.102, clavadas, dejaron de crecer
--   => el upsert matchea, el borrado funciona y el INSERT viejo esta muerto.
--
-- QUE HACE
--   1. Borra las 53.102 filas viejas. Son duplicados de los mismos 142
--      rechazos, cada una con contenido_crudo: la fila entera de la planilla
--      con nombre y telefono del alumno.
--   2. Pone fuente_id en NOT NULL, para que el problema no pueda volver.
--
-- CONSECUENCIA DEL NOT NULL, LEELA ANTES DE CORRER
--   fin_sync_escribir (migracion 013) todavia tiene el INSERT viejo. Hoy
--   inserta 0 filas porque la Edge Function dejo de mandar p_datos.rechazadas.
--   Con el NOT NULL, si alguien revierte la Edge Function ese INSERT falla y
--   se cae la escritura entera de esa fuente. El sync se rompe fuerte y a la
--   vista, en vez de volver a llenar la tabla en silencio.
--   Es a proposito: preferimos que se rompa a que mienta.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Guarda de seguridad.
--    Si la Edge Function nueva no esta funcionando, no limpiamos nada.
--    Exige al menos 1 rechazo con fuente_id y que alguno tenga veces >= 2,
--    que es la prueba de que el upsert esta matcheando entre corridas.
-- ---------------------------------------------------------------------------
do $guarda$
declare
  v_nuevas    bigint;
  v_con_veces bigint;
  v_reciente  timestamptz;
begin
  select count(*) into v_nuevas
  from public.fin_filas_rechazadas where fuente_id is not null;

  select count(*) into v_con_veces
  from public.fin_filas_rechazadas where fuente_id is not null and veces >= 2;

  select max(ultima_vez) into v_reciente
  from public.fin_filas_rechazadas where fuente_id is not null;

  if v_nuevas = 0 then
    raise exception 'GUARDA: no hay ningun rechazo con fuente_id. La Edge Function nueva no corrio. No se limpia nada.';
  end if;

  if v_con_veces = 0 then
    raise exception 'GUARDA: ningun rechazo tiene veces >= 2. El upsert no esta matcheando entre corridas. No se limpia nada.';
  end if;

  if v_reciente < now() - interval '2 hours' then
    raise exception 'GUARDA: el rechazo mas reciente es de % y ya pasaron mas de 2 horas. El sync puede estar caido. No se limpia nada.', v_reciente;
  end if;

  raise notice 'GUARDA OK: % rechazos con fuente_id, % con veces>=2, ultimo %',
    v_nuevas, v_con_veces, v_reciente;
end
$guarda$;

-- ---------------------------------------------------------------------------
-- 2. La limpieza.
-- ---------------------------------------------------------------------------
do $limpieza$
declare
  v_borradas bigint;
begin
  delete from public.fin_filas_rechazadas where fuente_id is null;
  get diagnostics v_borradas = row_count;
  raise notice 'LIMPIEZA: % filas viejas borradas', v_borradas;
end
$limpieza$;

-- ---------------------------------------------------------------------------
-- 3. Que no pueda volver a pasar.
-- ---------------------------------------------------------------------------
alter table public.fin_filas_rechazadas
  alter column fuente_id set not null;

comment on column public.fin_filas_rechazadas.fuente_id is
  'Fuente del rechazo. NOT NULL desde la 034: toda fila tiene que entrar por fin_rechazos_escribir().';

commit;

-- ============================================================================
-- DESPUES DEL COMMIT, CORRE ESTO APARTE
-- No puede ir adentro de la transaccion. Devuelve al disco el espacio de las
-- 53.102 filas borradas. Sin esto el espacio queda reservado para la tabla.
-- ============================================================================
-- vacuum (analyze) public.fin_filas_rechazadas;


-- ============================================================================
-- CONTROLES. De a uno, en orden.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- CONTROL 1
-- Como quedo la tabla. Esperado: total ~142, viejas 0.
-- ----------------------------------------------------------------------------
-- select count(*) as total,
--        count(*) filter (where fuente_id is null) as viejas,
--        count(distinct fuente_id) as fuentes,
--        min(veces) as veces_min,
--        max(veces) as veces_max,
--        max(ultima_vez) as ultima_actualizacion
-- from public.fin_filas_rechazadas;


-- ----------------------------------------------------------------------------
-- CONTROL 2
-- Los 142 rechazos reales por motivo. Esta es la lista que la agencia
-- tiene que arreglar en las planillas.
-- ----------------------------------------------------------------------------
-- select motivo, count(*) as rechazos, max(veces) as corridas_seguidas
-- from public.fin_filas_rechazadas
-- group by motivo
-- order by 2 desc;


-- ----------------------------------------------------------------------------
-- CONTROL 3
-- fuente_id quedo NOT NULL. Esperado: is_nullable = NO
-- ----------------------------------------------------------------------------
-- select column_name, is_nullable
-- from information_schema.columns
-- where table_schema = 'public'
--   and table_name = 'fin_filas_rechazadas'
--   and column_name = 'fuente_id';


-- ----------------------------------------------------------------------------
-- CONTROL 4  (correlo DESPUES de la proxima corrida, no ahora)
-- Que el sync siga sano despues del NOT NULL.
-- Esperado: ninguna corrida en error, y el total de rechazos sin moverse.
-- ----------------------------------------------------------------------------
-- select estado, count(*) as corridas
-- from public.fin_sync_corridas
-- where inicio > now() - interval '20 minutes'
-- group by estado
-- order by 2 desc;
