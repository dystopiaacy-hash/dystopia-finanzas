-- =====================================================================
-- 060_sync_formulario_email_hora.sql
-- Ventas, fase 2 (cierre). Requiere sincronizar v13 deployada (ya esta).
--
-- 1. fin_sync_escribir (copia exacta de produccion) con tres cambios:
--    a. escribe email, hora_llamada y formulario, y marca origen 'sheet';
--    b. solo borra filas de llamadas con origen 'sheet': nunca toca las
--       que lleguen por GHL o se carguen en la app;
--    c. se niega a escribir en una fuente cortada.
-- 2. Alias del email y de las preguntas del formulario.
--
-- Idempotente. Sin begin/commit. Controles abajo, de a uno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. fin_sync_escribir
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
  delete from public.fin_pagos      where fuente_id = v_fuente.id;
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
-- 2. Alias de email y formulario (liam, lucas, teo; mauro no)
--    El parser compara sin tildes, en minuscula y con espacios colapsados.
-- ---------------------------------------------------------------------
insert into fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, clave)
select f.id, s.campo, s.alias, false, s.clave
from (values
  ('liam', 'email',      'Email',                            null::text),
  ('liam', 'formulario', 'Edad',                             'edad'),
  ('liam', 'formulario', 'Profesión',                        'profesion'),
  ('liam', 'formulario', 'Contexto + IG',                    'contexto_ig'),
  ('liam', 'formulario', 'Situación actual de inversiones',  'situacion_inversiones'),
  ('liam', 'formulario', 'Objetivo de la consultoria',       'objetivo_consultoria'),
  ('liam', 'formulario', 'Ingreso mensual actual',           'ingreso_mensual'),
  ('liam', 'formulario', 'Capital inicial para invertir',    'capital_inicial'),
  ('liam', 'formulario', 'Objetivo al invertir',             'objetivo_invertir'),
  ('liam', 'formulario', 'Inversión mensual',                'inversion_mensual'),
  ('lucas','formulario', 'Ocupacion Actual',                 'ocupacion'),
  ('lucas','formulario', 'Bloqueo Principal',                'bloqueo'),
  ('lucas','formulario', 'Inversion Disponible',             'inversion_disponible'),
  ('teo',  'formulario', 'En qué punto estas en E-Commerce', 'punto_ecommerce'),
  ('teo',  'formulario', 'Ingreso mensual actual',           'ingreso_mensual'),
  ('teo',  'formulario', 'Qué objetivo tenés con tu E-Commerce? Por ejemplo en los próximos 4 meses.', 'objetivo'),
  ('teo',  'formulario', 'bloqueo principal',                'bloqueo'),
  ('teo',  'formulario', 'Inversión disponible',             'inversion_disponible')
) s(cliente, campo, alias, clave)
join fin_fuentes f on f.cliente_id = s.cliente and f.tipo = 'data'
on conflict (fuente_id, campo_canonico, alias) do nothing;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. La funcion nueva quedo arriba: las 3 en true.
-- select pg_get_functiondef('fin_sync_escribir'::regproc) like '%hora_llamada time, formulario jsonb%' as columnas,
--        pg_get_functiondef('fin_sync_escribir'::regproc) like '%and origen = ''sheet''%' as borra_solo_sheet,
--        pg_get_functiondef('fin_sync_escribir'::regproc) like '%esta cortada desde%' as guard_corte;

-- C2. Alias cargados: liam 1 email + 9 formulario, lucas 3, teo 5.
-- select f.cliente_id, a.campo_canonico, count(*)
--   from fin_alias_columnas a join fin_fuentes f on f.id = a.fuente_id
--  where a.campo_canonico in ('email','formulario')
--  group by 1, 2 order by 1, 2;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================

-- C3. Corridas en ok (mauro sigue en revisar) y mismas filas que antes:
--     liam 518, lucas 541, teo 363, mauro 984.
-- select f.cliente_id, c.estado, c.filas_cargadas, c.inicio
--   from fin_sync_corridas c join fin_fuentes f on f.id = c.fuente_id
--  where f.tipo = 'data' order by c.id desc limit 4;

-- C4. Formulario, email y hora llenos.
--     liam: ~490 con formulario, ~500 con email, ~350 con hora.
--     lucas: ~80 con formulario. teo: ~310 con formulario, ~210 con hora.
-- select cliente_id, count(*) as filas,
--        count(*) filter (where formulario <> '{}'::jsonb) as con_formulario,
--        count(*) filter (where email is not null) as con_email,
--        count(*) filter (where hora_llamada is not null) as con_hora
--   from fin_llamadas group by 1 order by 1;

-- C5. Una muestra para ver que las claves quedaron bien.
-- select cliente_id, nombre, hora_llamada, formulario
--   from fin_llamadas where formulario <> '{}'::jsonb
--  order by fecha_llamada desc limit 6;
