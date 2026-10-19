-- =====================================================================
-- 196_pagos_comprobantes_extra.sql
-- Pagos: varios comprobantes por pago. Numero 196 asignado por el jefe. SIN CORRER, NO PROBADA contra Postgres.
--
-- Contexto: en la planilla de pagos hay filas sin monto que son "segundo comprobante", "x2", "x3" o solo un
-- link: otro comprobante del pago anterior. El parser (supabase/functions/_shared/parsers/pagos.js) ya no las
-- rechaza: las adjunta al pago y manda el pago con `comprobantes_extra` (lista de links).
--
-- Que hace:
--   1. fin_pagos.comprobantes_extra jsonb not null default '[]' (array de textos). `comprobante` queda como el
--      link 1; los extras son el 2, 3... Las filas existentes y las cargadas en la app quedan con '[]'.
--   2. fin_sync_escribir: copia EXACTA de la 065 con un cambio: el insert de pagos copia comprobantes_extra
--      (coalesce a '[]'). La sync borra y reinserta los pagos 'sheet' en cada corrida, asi que los extras
--      se recalculan de la hoja: no se acumulan ni se duplican (idempotente).
-- No toca la sync de Liam (fuente cortada: fin_sync_escribir sigue levantando la excepcion de cortada_en).
-- Orden: correr ANTES del redeploy de `sincronizar` y de publicar el front (con la funcion vieja el campo
-- se ignora sin error; con el front viejo la columna no molesta).
-- No correr a las :00/:15/:30/:45 ni a las 9:00 (corre la sync). Re-ejecutable.
-- Controles C1 a C5 y vuelta atras al final (de a uno).
-- =====================================================================

begin;
set local lock_timeout = '10s';
lock table public.fin_pagos in access exclusive mode;

-- Guarda: la funcion vigente tiene que ser la de la 065 (o esta misma, si se corre dos veces).
do $g$
declare v text;
begin
  v := pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure);
  if v not like '%065: no toca pagos cargados en la app%'
     or v not like '%esta cortada desde%'
     or v not like '%060: no toca filas de ghl ni de la app%' then
    raise exception 'GUARDA 196: fin_sync_escribir no es la de la 065 (algo la cambio despues). No se toca nada.';
  end if;
end
$g$;

alter table public.fin_pagos
  add column if not exists comprobantes_extra jsonb not null default '[]'::jsonb;

alter table public.fin_pagos drop constraint if exists fin_pagos_comp_extra_ck;
alter table public.fin_pagos add constraint fin_pagos_comp_extra_ck
  check (jsonb_typeof(comprobantes_extra) = 'array');

comment on column public.fin_pagos.comprobantes_extra is
  '196: links de comprobantes adicionales del pago (el 2, 3...). El 1 es `comprobante`. La sync los toma de las filas "segundo comprobante"/"x2"/solo link de la planilla.';

CREATE OR REPLACE FUNCTION public.fin_sync_escribir(p_corrida bigint, p_estado text, p_mensaje text, p_hash text, p_controles jsonb, p_leidas integer, p_descartadas integer, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_corrida  public.fin_sync_corridas%rowtype;
  v_fuente   public.fin_fuentes%rowtype;
  n_pagos    int := 0;
  n_pnl      int := 0;
  n_saldos   int := 0;
  n_reparto  int := 0;
  n_cuotas   int := 0;
  n_llamadas int := 0;
  n_rech     int := 0;
begin
  if p_estado is null or p_estado not in ('ok', 'revisar', 'parcial') then
    raise exception 'fin_sync_escribir: el estado % no escribe datos', p_estado;
  end if;

  select * into v_corrida from public.fin_sync_corridas where id = p_corrida for update;
  if not found then raise exception 'fin_sync_escribir: no existe la corrida %', p_corrida; end if;
  if v_corrida.estado <> 'en_curso' then
    raise exception 'fin_sync_escribir: la corrida % ya esta cerrada (%)', p_corrida, v_corrida.estado;
  end if;
  select * into v_fuente from public.fin_fuentes where id = v_corrida.fuente_id;

  -- 060: una fuente cortada ya no se escribe nunca (la carga es en la app).
  if v_fuente.cortada_en is not null then
    raise exception 'fin_sync_escribir: la fuente % esta cortada desde %', v_fuente.id, v_fuente.cortada_en;
  end if;

  -- Dos corridas de la misma fuente a la vez (cron + boton manual) se hacen en fila.
  perform pg_advisory_xact_lock(hashtext('fin_sync_escribir'), v_fuente.id::int);

  -- Reemplazo completo: se borra todo lo de la fuente y se inserta lo nuevo.
  delete from public.fin_pagos      where fuente_id = v_fuente.id and origen = 'sheet';  -- 065: no toca pagos cargados en la app
  delete from public.fin_pnl        where fuente_id = v_fuente.id;
  delete from public.fin_pnl_saldos where fuente_id = v_fuente.id;
  delete from public.fin_reparto    where fuente_id = v_fuente.id;
  delete from public.fin_cuotas     where fuente_id = v_fuente.id;
  delete from public.fin_llamadas   where fuente_id = v_fuente.id and origen = 'sheet';  -- 060: no toca filas de ghl ni de la app

  -- cliente_id, fuente_id y sync_id salen de la fuente y la corrida, nunca del payload.
  insert into public.fin_pagos (cliente_id, fuente_id, sync_id, fila_planilla, fecha, programa, alumno, telefono,
    concepto, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente, moneda_cobro, closer, setter,
    comprobante, quien_recibe, metodo_pago, monto_restante, estado, comprobantes_extra)  -- 196: comprobantes_extra
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha, x.programa, x.alumno, x.telefono,
         x.concepto, x.monto_usd, x.monto_origen, x.moneda_origen, x.tc_usado, x.tc_fuente, x.moneda_cobro, x.closer, x.setter,
         x.comprobante, x.quien_recibe, x.metodo_pago, x.monto_restante, x.estado,
         case when jsonb_typeof(x.comprobantes_extra) = 'array' then x.comprobantes_extra else '[]'::jsonb end  -- 196
  from jsonb_to_recordset(coalesce(p_datos -> 'pagos', '[]'::jsonb)) as x(
    fila_planilla int, fecha date, programa text, alumno text, telefono text, concepto text, monto_usd numeric,
    monto_origen numeric, moneda_origen text, tc_usado numeric, tc_fuente text, moneda_cobro text, closer text,
    setter text, comprobante text, quien_recibe text, metodo_pago text, monto_restante numeric, estado text,
    comprobantes_extra jsonb);
  get diagnostics n_pagos = row_count;

  insert into public.fin_pnl (cliente_id, fuente_id, sync_id, anio, mes, categoria, item, monto_usd, fila_planilla, columna_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.categoria, x.item, x.monto_usd, x.fila_planilla, x.columna_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'pnl', '[]'::jsonb)) as x(
    anio int, mes int, categoria text, item text, monto_usd numeric, fila_planilla int, columna_planilla int);
  get diagnostics n_pnl = row_count;

  insert into public.fin_pnl_saldos (cliente_id, fuente_id, sync_id, anio, mes, opening_balance, closing_balance, dividends_released)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.opening_balance, x.closing_balance, x.dividends_released
  from jsonb_to_recordset(coalesce(p_datos -> 'saldos', '[]'::jsonb)) as x(
    anio int, mes int, opening_balance numeric, closing_balance numeric, dividends_released numeric);
  get diagnostics n_saldos = row_count;

  insert into public.fin_reparto (cliente_id, fuente_id, sync_id, anio, mes, beneficiario, monto, fila_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.beneficiario, x.monto, x.fila_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'reparto', '[]'::jsonb)) as x(
    anio int, mes int, beneficiario text, monto numeric, fila_planilla int);
  get diagnostics n_reparto = row_count;

  insert into public.fin_cuotas (cliente_id, fuente_id, sync_id, alumno, telefono, programa, numero_cuota, tipo_cuota,
    monto, monto_cobrado, fecha_pago, estado, closer, contexto, fila_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.alumno, x.telefono, x.programa, x.numero_cuota, x.tipo_cuota,
         x.monto, x.monto_cobrado, x.fecha_pago, x.estado, x.closer, x.contexto, x.fila_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'cuotas', '[]'::jsonb)) as x(
    alumno text, telefono text, programa text, numero_cuota int, tipo_cuota text, monto numeric, monto_cobrado numeric,
    fecha_pago date, estado text, closer text, contexto text, fila_planilla int);
  get diagnostics n_cuotas = row_count;

  insert into public.fin_llamadas (cliente_id, fuente_id, sync_id, fila_planilla, fecha_llamada, closer, nombre,
    show_up, calificacion, estado_llamada, tipo_booking, programa, cc_dia1, cc_cerrado, cc_seguimiento,
    monto_restante, telefono, instagram, contexto_closer, contexto_setter,
    email, hora_llamada, formulario, origen)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha_llamada, x.closer, x.nombre,
         x.show_up, x.calificacion, x.estado_llamada, x.tipo_booking, x.programa, x.cc_dia1, x.cc_cerrado, x.cc_seguimiento,
         x.monto_restante, x.telefono, x.instagram, x.contexto_closer, x.contexto_setter,
         x.email, x.hora_llamada, coalesce(x.formulario, '{}'::jsonb), 'sheet'
  from jsonb_to_recordset(coalesce(p_datos -> 'llamadas', '[]'::jsonb)) as x(
    fila_planilla int, fecha_llamada date, closer text, nombre text, show_up text, calificacion text,
    estado_llamada text, tipo_booking text, programa text, cc_dia1 numeric, cc_cerrado numeric,
    cc_seguimiento numeric, monto_restante numeric, telefono text, instagram text, contexto_closer text,
    contexto_setter text, email text, hora_llamada time, formulario jsonb);
  get diagnostics n_llamadas = row_count;

  insert into public.fin_filas_rechazadas (corrida_id, fila_planilla, motivo, valor_crudo, comprobante, metodo_pago, contenido_crudo)
  select p_corrida, x.fila_planilla, x.motivo, x.valor_crudo, x.comprobante, x.metodo_pago, coalesce(x.contenido_crudo, '[]'::jsonb)
  from jsonb_to_recordset(coalesce(p_datos -> 'rechazadas', '[]'::jsonb)) as x(
    fila_planilla int, motivo text, valor_crudo text, comprobante text, metodo_pago text, contenido_crudo jsonb);
  get diagnostics n_rech = row_count;

  update public.fin_sync_corridas set
    fin               = now(),
    estado            = p_estado,
    filas_leidas      = p_leidas,
    filas_cargadas    = n_pagos + n_pnl + n_cuotas + n_llamadas,
    filas_rechazadas  = n_rech,
    filas_descartadas = p_descartadas,
    mensaje           = p_mensaje,
    hash_encabezado   = p_hash,
    controles         = coalesce(p_controles, '[]'::jsonb)
  where id = p_corrida;

  return jsonb_build_object('pagos', n_pagos, 'pnl', n_pnl, 'saldos', n_saldos, 'reparto', n_reparto,
                            'cuotas', n_cuotas, 'llamadas', n_llamadas, 'rechazadas', n_rech);
end $function$;

commit;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo)
-- =====================================================================

-- C1. Columna creada, tipo jsonb, no nula. Esperado: 1 fila, jsonb, NO, '[]'::jsonb.
-- select column_name, data_type, is_nullable, column_default from information_schema.columns
--  where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'comprobantes_extra';

-- C2. La funcion nueva quedo arriba y conserva lo anterior. Esperado: las 4 en true.
-- select pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%196: comprobantes_extra%' as copia_extras,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%065: no toca pagos cargados en la app%' as solo_sheet,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%esta cortada desde%' as respeta_corte,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%060: no toca filas de ghl ni de la app%' as llamadas_igual;

-- C3. Ningun pago existente quedo con extras ni con tipo raro. Esperado: con_extras 0 (hasta la proxima sync de Agus), no_array 0.
-- select count(*) filter (where jsonb_array_length(comprobantes_extra) > 0) as con_extras,
--        count(*) filter (where jsonb_typeof(comprobantes_extra) <> 'array') as no_array,
--        count(*) as total
--   from public.fin_pagos;

-- C4. LUEGO de la proxima sincronizacion de Agus (redeploy de `sincronizar` hecho): pagos con extras.
--     Esperado: hasta 13 filas rechazadas menos (las que tenian pago anterior) pasan a extras en sus pagos.
-- select p.fila_planilla, p.alumno, p.comprobante, p.comprobantes_extra
--   from public.fin_pagos p join public.crm_clients c on c.id = p.cliente_id
--  where c.slug = 'agus' and jsonb_array_length(p.comprobantes_extra) > 0
--  order by p.fila_planilla;   -- si crm_clients no tiene `slug`, filtrar por el cliente_id de Agus

-- C5. LUEGO de la proxima sincronizacion: idempotencia. Correr C4 y, 15 minutos despues, otra vez:
--     la cantidad total de links tiene que ser la misma (no crece).
-- select sum(jsonb_array_length(comprobantes_extra)) as links_extra from public.fin_pagos;

-- =====================================================================
-- VUELTA ATRAS (no correr salvo marcha atras)
-- =====================================================================
-- 1) Redeploy de `sincronizar` con el parser anterior (git) y volver a correr el bloque 3 de la 065
--    (create or replace de fin_sync_escribir, sin comprobantes_extra).
-- 2) alter table public.fin_pagos drop constraint if exists fin_pagos_comp_extra_ck;
--    alter table public.fin_pagos drop column if exists comprobantes_extra;
