-- =====================================================================
-- 065_pagos_origen.sql
-- FINANZAS, fase 4: proteccion del corte. Ver ESQUEMA-FINANZAS.md, seccion 2.
--
-- Mismo patron que la 059/060 para las llamadas de Ventas:
-- 1. fin_pagos.origen: 'sheet' (copiado de la planilla por la sync) o
--    'app' (cargado en la app, a partir de la 066). Todo lo existente
--    queda 'sheet'.
-- 2. fila_planilla deja de ser obligatoria, pero solo para filas 'app'
--    (una fila 'sheet' sin numero de fila sigue siendo un error).
-- 3. fin_sync_escribir (copia exacta de produccion = 060) con UN cambio:
--    al reemplazar los pagos de una fuente borra solo las filas 'sheet'.
--    Lo cargado en la app no lo toca nunca.
-- 4. fin_v_pagos_doble_carga: el mismo pago (misma huella) cargado en la
--    app Y en la planilla. Mientras un cliente no este cortado, si alguien
--    carga en los dos lados se contaria dos veces; esta vista lo muestra.
-- 2b. El trigger de clave de la 062 numera cada origen por separado:
--    las filas 'app' quedan con clave huella#a1, huella#a2...
--
-- No da permisos de escritura (eso es la 066): hoy nadie puede crear
-- filas 'app' salvo desde el SQL Editor.
-- Idempotente. Probada dos veces contra Postgres local con el esquema
-- real y los pagos del 2026-10-02.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Guarda: fin_sync_escribir en produccion tiene que ser la de la 060
--    (o esta misma, si se corre dos veces).
-- ---------------------------------------------------------------------
do $$
declare v text;
begin
  v := pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure);
  if v not like '%060: no toca filas de ghl ni de la app%'
     or v not like '%esta cortada desde%'
     or (v not like '%delete from public.fin_pagos      where fuente_id = v_fuente.id;%'
         and v not like '%065: no toca pagos cargados en la app%') then
    raise exception 'GUARDA 065: fin_sync_escribir no es la version de la 060. No se aplica nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1 y 2. origen y fila_planilla
-- ---------------------------------------------------------------------
alter table public.fin_pagos
  add column if not exists origen text not null default 'sheet';

alter table public.fin_pagos drop constraint if exists fin_pagos_origen_ck;
alter table public.fin_pagos add constraint fin_pagos_origen_ck
  check (origen in ('sheet', 'app'));

alter table public.fin_pagos alter column fila_planilla drop not null;
alter table public.fin_pagos drop constraint if exists fin_pagos_fila_ck;
alter table public.fin_pagos add constraint fin_pagos_fila_ck
  check (origen = 'app' or fila_planilla is not null);

comment on column public.fin_pagos.origen is
  '065: sheet = lo escribe la sync (se reemplaza cada 15 min); app = cargado en la app, la sync no lo toca.';

create index if not exists fin_pagos_fuente_origen_idx
  on public.fin_pagos (fuente_id, origen);

-- ---------------------------------------------------------------------
-- 2b. Clave por origen (ajuste del trigger de la 062)
--     Las filas 'sheet' se numeran solo entre filas 'sheet' (#1, #2...)
--     y las 'app' solo entre filas 'app' (#a1, #a2...). Asi cargar un pago
--     en la app nunca le cambia la clave a una fila de la planilla, aunque
--     sea el mismo pago cargado dos veces. Las claves existentes no cambian.
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
  select coalesce(max(p.ocurrencia), 0) + 1
    into new.ocurrencia
    from public.fin_pagos p
   where p.cliente_id = new.cliente_id
     and p.huella     = new.huella
     and p.origen     = coalesce(new.origen, 'sheet');
  new.clave := new.huella
            || case when coalesce(new.origen, 'sheet') = 'app' then '#a' else '#' end
            || new.ocurrencia;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 3. fin_sync_escribir: copia exacta de la 060 + borrar solo 'sheet'
-- ---------------------------------------------------------------------
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
    comprobante, quien_recibe, metodo_pago, monto_restante, estado)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha, x.programa, x.alumno, x.telefono,
         x.concepto, x.monto_usd, x.monto_origen, x.moneda_origen, x.tc_usado, x.tc_fuente, x.moneda_cobro, x.closer, x.setter,
         x.comprobante, x.quien_recibe, x.metodo_pago, x.monto_restante, x.estado
  from jsonb_to_recordset(coalesce(p_datos -> 'pagos', '[]'::jsonb)) as x(
    fila_planilla int, fecha date, programa text, alumno text, telefono text, concepto text, monto_usd numeric,
    monto_origen numeric, moneda_origen text, tc_usado numeric, tc_fuente text, moneda_cobro text, closer text,
    setter text, comprobante text, quien_recibe text, metodo_pago text, monto_restante numeric, estado text);
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


-- ---------------------------------------------------------------------
-- 4. Doble carga: mismo pago en la app y en la planilla
-- ---------------------------------------------------------------------
create or replace view public.fin_v_pagos_doble_carga
with (security_invoker = true) as
select a.cliente_id, a.fecha, a.alumno, a.monto_usd, a.concepto,
       a.clave as clave_app, s.clave as clave_sheet, s.fila_planilla
from public.fin_pagos a
join public.fin_pagos s
  on s.cliente_id = a.cliente_id
 and s.huella     = a.huella
 and s.origen     = 'sheet'
where a.origen = 'app';

comment on view public.fin_v_pagos_doble_carga is
  '065: pagos cargados en la app que tambien estan en la planilla (misma huella). Hasta el corte del cliente, uno de los dos sobra.';

revoke all on public.fin_v_pagos_doble_carga from anon;
grant select on public.fin_v_pagos_doble_carga to authenticated;
grant all on public.fin_v_pagos_doble_carga to service_role;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Todo lo existente quedo 'sheet'. Esperado: una sola fila,
--     origen sheet, con el total de pagos (~1.621).
-- select origen, count(*) from public.fin_pagos group by 1;

-- C2. La funcion nueva quedo arriba: las 3 en true.
-- select pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure)
--          like '%fuente_id = v_fuente.id and origen = ''sheet'';  -- 065%' as pagos_solo_sheet,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure)
--          like '%060: no toca filas de ghl%' as llamadas_igual,
--        to_regclass('public.fin_v_pagos_doble_carga') is not null as vista_ok;

-- C3. Doble carga. Esperado: 0 filas (todavia no hay filas 'app').
-- select * from public.fin_v_pagos_doble_carga;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================

-- C4. La sync sigue andando: corridas de pagos en ok/revisar como antes
--     (liam y mauro ok; agus, teo y lucas revisar) y mismas filas.
-- select f.cliente_id, c.estado, c.filas_cargadas, c.inicio
--   from public.fin_sync_corridas c join public.fin_fuentes f on f.id = c.fuente_id
--  where f.tipo = 'pagos' order by c.id desc limit 5;
