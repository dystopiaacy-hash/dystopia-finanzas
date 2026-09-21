-- 005_sync_escribir.sql — Dystopia Finanzas: reemplazo atomico por fuente.
--
-- Por que hace falta: la Edge Function habla con la base por PostgREST, y
-- PostgREST no puede agrupar un DELETE y varios INSERT en una transaccion.
-- Sin esto, una caida a mitad de camino deja una fuente con la mitad de los
-- datos. fin_sync_escribir hace TODO el reemplazo de una fuente en una sola
-- llamada = una sola transaccion: si algo falla, no queda nada a medias y se
-- conservan los datos anteriores.
--
-- Solo la ejecuta service_role (la Edge Function). security invoker: corre
-- con los grants de service_role sobre las 12 tablas fin_* (001, bloque 4).
-- NO es security definer a proposito.
-- Idempotente (create or replace). Requiere 001.

begin;

create or replace function public.fin_sync_escribir(
  p_corrida     bigint,
  p_estado      text,
  p_mensaje     text,
  p_hash        text,
  p_controles   jsonb,
  p_leidas      int,
  p_descartadas int,
  p_datos       jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_corrida public.fin_sync_corridas%rowtype;
  v_fuente  public.fin_fuentes%rowtype;
  n_pagos   int := 0;
  n_pnl     int := 0;
  n_saldos  int := 0;
  n_reparto int := 0;
  n_cuotas  int := 0;
  n_rech    int := 0;
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

  -- Dos corridas de la misma fuente a la vez (cron + boton manual) se hacen en fila.
  perform pg_advisory_xact_lock(hashtext('fin_sync_escribir'), v_fuente.id::int);

  -- Reemplazo completo: se borra todo lo de la fuente y se inserta lo nuevo.
  delete from public.fin_pagos      where fuente_id = v_fuente.id;
  delete from public.fin_pnl        where fuente_id = v_fuente.id;
  delete from public.fin_pnl_saldos where fuente_id = v_fuente.id;
  delete from public.fin_reparto    where fuente_id = v_fuente.id;
  delete from public.fin_cuotas     where fuente_id = v_fuente.id;

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

  insert into public.fin_filas_rechazadas (corrida_id, fila_planilla, motivo, valor_crudo, comprobante, metodo_pago, contenido_crudo)
  select p_corrida, x.fila_planilla, x.motivo, x.valor_crudo, x.comprobante, x.metodo_pago, coalesce(x.contenido_crudo, '[]'::jsonb)
  from jsonb_to_recordset(coalesce(p_datos -> 'rechazadas', '[]'::jsonb)) as x(
    fila_planilla int, motivo text, valor_crudo text, comprobante text, metodo_pago text, contenido_crudo jsonb);
  get diagnostics n_rech = row_count;

  update public.fin_sync_corridas set
    fin               = now(),
    estado            = p_estado,
    filas_leidas      = p_leidas,
    filas_cargadas    = n_pagos + n_pnl + n_cuotas,
    filas_rechazadas  = n_rech,
    filas_descartadas = p_descartadas,
    mensaje           = p_mensaje,
    hash_encabezado   = p_hash,
    controles         = coalesce(p_controles, '[]'::jsonb)
  where id = p_corrida;

  return jsonb_build_object('pagos', n_pagos, 'pnl', n_pnl, 'saldos', n_saldos, 'reparto', n_reparto,
                            'cuotas', n_cuotas, 'rechazadas', n_rech);
end $$;

revoke all on function public.fin_sync_escribir(bigint, text, text, text, jsonb, int, int, jsonb) from public, anon, authenticated;
grant execute on function public.fin_sync_escribir(bigint, text, text, text, jsonb, int, int, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Prueba de humo (se autorrevierte): dos corridas seguidas de la misma
-- fuente. La segunda reemplaza a la primera (no suma). Un estado 'error' no
-- escribe. Un fallo a mitad (fila invalida) no deja nada a medias.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fuente bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_c3     bigint;
  v_n      int;
  v_estado text;
  v_pago   jsonb := '{"fila_planilla":2,"fecha":"2026-02-10","alumno":"Smoke","monto_usd":900,"monto_origen":900,"moneda_origen":"USD"}';
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('liam', 'SMOKE_005', 1, 'Smoke', 'pagos', 10000) returning id into v_fuente;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c1;
    perform public.fin_sync_escribir(v_c1, 'ok', null, 'h1', '[]', 3, 0,
      jsonb_build_object('pagos', jsonb_build_array(v_pago, v_pago || '{"fila_planilla":3}'),
                         'rechazadas', '[{"fila_planilla":4,"motivo":"falta monto","contenido_crudo":["x"]}]'::jsonb));
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fuente;
    if v_n <> 2 then raise exception 'smoke 005: primera corrida dejo % pagos, se esperaban 2', v_n; end if;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c2;
    perform public.fin_sync_escribir(v_c2, 'revisar', null, 'h1', '[]', 1, 0,
      jsonb_build_object('pagos', jsonb_build_array(v_pago)));
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fuente;
    if v_n <> 1 then raise exception 'smoke 005: la segunda corrida no reemplazo (quedan % pagos)', v_n; end if;
    select estado into v_estado from public.fin_sync_corridas where id = v_c2;
    if v_estado <> 'revisar' then raise exception 'smoke 005: la corrida quedo en %', v_estado; end if;

    -- Estado error: no escribe.
    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c3;
    begin
      perform public.fin_sync_escribir(v_c3, 'error', null, null, '[]', 0, 0, '{}');
      raise exception 'smoke 005: estado error escribio datos';
    exception when raise_exception then
      if sqlerrm like 'smoke 005:%' then raise; end if;
    end;
    -- Fila invalida (sin alumno, viola not null): nada a medias, siguen los datos de c2.
    begin
      perform public.fin_sync_escribir(v_c3, 'ok', null, 'h1', '[]', 2, 0,
        jsonb_build_object('pagos', jsonb_build_array(v_pago, v_pago - 'alumno')));
      raise exception 'smoke 005: una fila invalida no hizo fallar la escritura';
    exception when not_null_violation then null;
    end;
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fuente and sync_id = v_c2;
    if v_n <> 1 then raise exception 'smoke 005: un fallo a mitad borro los datos anteriores'; end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 005: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control: security_definer = false, service_role ejecuta,
-- anon y authenticated NO.
-- ---------------------------------------------------------------------------
select p.proname                                              as funcion,
       p.prosecdef                                            as security_definer,
       has_function_privilege('service_role', p.oid, 'execute')  as service_role_ejecuta,
       has_function_privilege('anon', p.oid, 'execute')          as anon_ejecuta,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_ejecuta
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fin_sync_escribir';

commit;
