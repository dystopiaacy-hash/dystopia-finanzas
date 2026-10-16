-- =====================================================================
-- 148_finanzas_ia_lectura_mensual.sql
-- IA en Finanzas: lectura mensual de numeros (P&L, pagos, cobranzas, comisiones)
-- por cliente, con historial. Numero asignado por el jefe.
--
-- Que crea (todo nuevo, no toca nada existente):
--   * tabla fin_lecturas_mes: una fila por lectura generada (cliente, periodo 'YYYY-MM',
--     texto, datos usados, costo, origen cron/manual, quien). Con historial: regenerar
--     agrega una fila, no pisa; la app muestra la ultima de cada mes y permite ver las anteriores.
--     RLS: solo fundador y finanzas asignado al cliente. Escribe solo la Edge Function (service_role).
--   * fin_lectura_puede_ver(cliente): fundador, o rol finanzas con el cliente en crm_asignaciones.
--   * fin_lectura_clientes(): clientes de liam/agus/teo que el usuario puede ver (para la app).
--   * fin_lectura_numeros(cliente, periodo): arma el resumen compacto en jsonb (solo service_role).
--   * fin_lectura_guardar(...): inserta la lectura (solo service_role).
--   * cron ia_lectura_mensual: dia 1 de cada mes, 11:31 UTC = 8:31 ART (Argentina no tiene horario
--     de verano), net.http_post a la Edge Function ia-lectura-mensual con la URL en Vault
--     (ia_lectura_mensual_url) y fin_sync_service_key, igual que ventas_ia_*.
--
-- Todo es idempotente (create if not exists / create or replace / drop policy if exists):
-- se puede volver a correr. No hace falta begin/commit ni lock (no toca tablas existentes).
--
-- ORDEN: BLOQUE 1 (esquema y funciones) > BLOQUE 2 (humo) > desplegar la funcion
--   (supabase functions deploy ia-lectura-mensual --no-verify-jwt) > BLOQUE 3 (cron y Vault)
--   > controles de a uno. Correr fuera de :00/:15/:30/:45 y de las 9:00 (corre la sync).
--   La Edge Function usa el secreto ANTHROPIC_API_KEY, que ya esta cargado.
-- Depende de: 137 (ia_uso), 003/011 (vistas de cobranzas y comisiones), 075 (fin_asignado), 142 (cron/Vault).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas, tabla, permisos y funciones
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.ia_uso') is null then v_falta := v_falta || ' ia_uso(137)'; end if;
  if to_regclass('public.fin_pagos') is null then v_falta := v_falta || ' fin_pagos'; end if;
  if to_regclass('public.fin_pnl') is null then v_falta := v_falta || ' fin_pnl'; end if;
  if to_regclass('public.fin_pnl_saldos') is null then v_falta := v_falta || ' fin_pnl_saldos'; end if;
  if to_regclass('public.fin_v_cobranzas') is null then v_falta := v_falta || ' fin_v_cobranzas'; end if;
  if to_regclass('public.fin_v_comisiones') is null then v_falta := v_falta || ' fin_v_comisiones'; end if;
  if to_regclass('public.fin_v_comisiones_mensual') is null then v_falta := v_falta || ' fin_v_comisiones_mensual'; end if;
  if to_regclass('public.crm_clients') is null then v_falta := v_falta || ' crm_clients'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if to_regprocedure('public.rol_actual()') is null then v_falta := v_falta || ' rol_actual()'; end if;
  if to_regprocedure('public.fin_asignado(text)') is null then v_falta := v_falta || ' fin_asignado(text)(075)'; end if;
  if to_regprocedure('public.cs_hoy()') is null then v_falta := v_falta || ' cs_hoy()'; end if;
  if v_falta <> '' then
    raise exception 'GUARDA 148: faltan:%', v_falta;
  end if;
  -- columnas que lee fin_lectura_numeros
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'fin_v_comisiones'
         and column_name in ('cliente_id', 'periodo', 'estado')) <> 3 then
    raise exception 'GUARDA 148: fin_v_comisiones no tiene cliente_id, periodo y estado';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'fin_v_comisiones_mensual'
         and column_name in ('cliente_id', 'periodo', 'rol', 'vendedor', 'base_usd', 'comision_usd', 'pagos')) <> 7 then
    raise exception 'GUARDA 148: fin_v_comisiones_mensual no tiene las columnas esperadas';
  end if;
  raise notice 'GUARDA 148 OK';
end
$g$;

-- Permiso de lectura: fundador, o finanzas asignado al cliente. Cliente, closer, setter y ventas no.
create or replace function public.fin_lectura_puede_ver(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $f$
  select auth.uid() is not null
     and (coalesce(public.es_fundador(), false)
          or (public.rol_actual() = 'finanzas' and public.fin_asignado(p_cliente)));
$f$;

create table if not exists public.fin_lecturas_mes (
  id            bigint generated always as identity primary key,
  cliente_id    text        not null references public.crm_clients(id),
  periodo       text        not null,
  texto         text        not null,
  datos         jsonb,
  modelo        text,
  origen        text        not null default 'manual',
  generado_por  uuid        references auth.users(id) on delete set null,   -- null = cron
  costo_usd     numeric,
  generado_en   timestamptz not null default now(),
  constraint fin_lecturas_mes_periodo_ck check (periodo ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  constraint fin_lecturas_mes_origen_ck check (origen in ('cron', 'manual')),
  constraint fin_lecturas_mes_texto_ck check (btrim(texto) <> '')
);
create index if not exists fin_lecturas_mes_idx on public.fin_lecturas_mes (cliente_id, periodo, generado_en desc);

comment on table public.fin_lecturas_mes is
  'Lectura mensual de numeros hecha por IA (148). Historial: cada regeneracion es una fila nueva. Escribe solo la Edge Function ia-lectura-mensual.';

alter table public.fin_lecturas_mes enable row level security;
drop policy if exists fin_lecturas_mes_lectura on public.fin_lecturas_mes;
create policy fin_lecturas_mes_lectura on public.fin_lecturas_mes
  for select to authenticated using (public.fin_lectura_puede_ver(cliente_id));

revoke all on public.fin_lecturas_mes from anon, public, authenticated;
grant select on public.fin_lecturas_mes to authenticated;
grant all on public.fin_lecturas_mes to service_role;

-- Clientes que la app ofrece en "Lectura del mes".
create or replace function public.fin_lectura_clientes()
returns table (cliente_id text, nombre text)
language sql stable security definer set search_path = ''
as $f$
  select c.id, c.nombre
    from public.crm_clients c
   where c.id in ('liam', 'agus', 'teo')
     and public.fin_lectura_puede_ver(c.id)
   order by array_position(array['liam', 'agus', 'teo'], c.id);
$f$;

-- Numeros de UN mes de UN cliente (interna). Todo en USD.
create or replace function public.fin_lectura_mes_base(p_cliente text, p_ini date)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_fin     date := (p_ini + interval '1 month')::date;
  v_periodo text := to_char(p_ini, 'YYYY-MM');
  v_ingreso numeric; v_gastos numeric; v_revenue numeric;
  v_pnl jsonb; v_pagos jsonb; v_com jsonb; v_saldos jsonb;
begin
  select coalesce(round(sum(monto_usd), 2), 0) into v_ingreso
    from public.fin_pagos where cliente_id = p_cliente and fecha >= p_ini and fecha < v_fin;

  select jsonb_build_object(
           'revenue_declarado_opps', coalesce(round(sum(monto_usd) filter (where categoria = 'revenue'), 2), 0),
           'staff', coalesce(round(sum(monto_usd) filter (where categoria = 'staff'), 2), 0),
           'softwares', coalesce(round(sum(monto_usd) filter (where categoria = 'softwares'), 2), 0),
           'others', coalesce(round(sum(monto_usd) filter (where categoria = 'others'), 2), 0),
           'sin_categoria', coalesce(round(sum(monto_usd) filter (where categoria = 'sin_categoria'), 2), 0),
           'gastos_total', coalesce(round(sum(monto_usd) filter (where categoria <> 'revenue'), 2), 0)),
         coalesce(sum(monto_usd) filter (where categoria <> 'revenue'), 0),
         coalesce(sum(monto_usd) filter (where categoria = 'revenue'), 0)
    into v_pnl, v_gastos, v_revenue
    from public.fin_pnl
   where cliente_id = p_cliente and anio = extract(year from p_ini)::int and mes = extract(month from p_ini)::int;

  select jsonb_build_object(
           'cobrado_neto', v_ingreso,
           'cantidad', count(*),
           'devoluciones_usd', coalesce(round(sum(monto_usd) filter (where monto_usd < 0), 2), 0),
           'cantidad_devoluciones', count(*) filter (where monto_usd < 0),
           'por_concepto', coalesce((
             select jsonb_agg(x order by x.usd desc) from (
               select coalesce(nullif(btrim(concepto), ''), '(sin concepto)') as concepto,
                      round(sum(monto_usd), 2) as usd, count(*) as pagos
                 from public.fin_pagos
                where cliente_id = p_cliente and fecha >= p_ini and fecha < v_fin
                group by 1 order by 2 desc limit 8) x), '[]'::jsonb),
           'por_programa', coalesce((
             select jsonb_agg(x order by x.usd desc) from (
               select coalesce(nullif(btrim(programa), ''), '(sin programa)') as programa,
                      round(sum(monto_usd), 2) as usd, count(*) as pagos
                 from public.fin_pagos
                where cliente_id = p_cliente and fecha >= p_ini and fecha < v_fin
                group by 1 order by 2 desc limit 6) x), '[]'::jsonb))
    into v_pagos
    from public.fin_pagos where cliente_id = p_cliente and fecha >= p_ini and fecha < v_fin;

  select jsonb_build_object('apertura', opening_balance, 'cierre', closing_balance, 'dividendos', dividends_released)
    into v_saldos
    from public.fin_pnl_saldos
   where cliente_id = p_cliente and anio = extract(year from p_ini)::int and mes = extract(month from p_ini)::int;

  select jsonb_build_object(
           'total_usd', coalesce(round(sum(comision_usd), 2), 0),
           'base_usd', coalesce(round(sum(base_usd), 2), 0),
           'por_rol', coalesce((
             select jsonb_object_agg(rol, usd) from (
               select rol, round(sum(comision_usd), 2) as usd
                 from public.fin_v_comisiones_mensual
                where cliente_id = p_cliente and periodo = v_periodo group by rol) r), '{}'::jsonb),
           'principales', coalesce((
             select jsonb_agg(x order by x.usd desc) from (
               select vendedor, rol, round(sum(comision_usd), 2) as usd
                 from public.fin_v_comisiones_mensual
                where cliente_id = p_cliente and periodo = v_periodo
                group by vendedor, rol order by 3 desc limit 5) x), '[]'::jsonb),
           'pagos_sin_calcular', (select count(*) from public.fin_v_comisiones
                                   where cliente_id = p_cliente and periodo = v_periodo and estado in ('sin_asignar', 'sin_monto_usd')))
    into v_com
    from public.fin_v_comisiones_mensual
   where cliente_id = p_cliente and periodo = v_periodo;

  return jsonb_build_object(
    'periodo', v_periodo,
    'ingreso_real_pagos', v_ingreso,
    'gastos', v_gastos,
    'net_cash_flow_pagos_menos_gastos', round(v_ingreso - v_gastos, 2),
    'diferencia_opps_menos_pagos', round(v_revenue - v_ingreso, 2),
    'pnl_opps', v_pnl,
    'pagos', v_pagos,
    'saldos', v_saldos,
    'comisiones', v_com);
end
$f$;

-- Resumen compacto para la IA: el mes, el mes previo y la foto de cobranzas al momento de generar.
create or replace function public.fin_lectura_numeros(p_cliente text, p_periodo text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_ini date; v_cob jsonb;
begin
  if p_periodo is null or p_periodo !~ '^\d{4}-(0[1-9]|1[0-2])$' then
    raise exception 'periodo invalido (esperado YYYY-MM)';
  end if;
  if not exists (select 1 from public.crm_clients where id = p_cliente) then
    raise exception 'cliente inexistente';
  end if;
  v_ini := to_date(p_periodo || '-01', 'YYYY-MM-DD');

  select jsonb_build_object(
           'fecha_foto', public.cs_hoy(),
           'cuotas_pendientes', count(*),
           'saldo_pendiente_usd', coalesce(round(sum(greatest(coalesce(monto, 0) - coalesce(monto_cobrado, 0), 0)), 2), 0),
           'vencidas', count(*) filter (where vencida),
           'saldo_vencido_usd', coalesce(round(sum(greatest(coalesce(monto, 0) - coalesce(monto_cobrado, 0), 0)) filter (where vencida), 2), 0),
           'vencidas_mas_de_14_dias', count(*) filter (where vencida and dias_al_vencimiento < -14),
           'vencen_en_7_dias', count(*) filter (where not vencida and dias_al_vencimiento between 0 and 7),
           'del_mes_aun_sin_cobrar', count(*) filter (where fecha_pago >= v_ini and fecha_pago < (v_ini + interval '1 month')::date))
    into v_cob
    from public.fin_v_cobranzas where cliente_id = p_cliente;

  return jsonb_build_object(
    'cliente', p_cliente,
    'periodo', p_periodo,
    'moneda', 'USD',
    'mes', public.fin_lectura_mes_base(p_cliente, v_ini),
    'mes_previo', public.fin_lectura_mes_base(p_cliente, (v_ini - interval '1 month')::date),
    'cobranzas_hoy', v_cob);
end
$f$;

-- Guarda una lectura (la llama la Edge Function con service_role).
create or replace function public.fin_lectura_guardar(
  p_cliente text, p_periodo text, p_texto text, p_datos jsonb, p_modelo text,
  p_origen text, p_user uuid, p_costo numeric)
returns table (id bigint, generado_en timestamptz)
language plpgsql security definer set search_path = ''
as $f$
begin
  return query
    insert into public.fin_lecturas_mes (cliente_id, periodo, texto, datos, modelo, origen, generado_por, costo_usd)
    values (p_cliente, p_periodo, p_texto, p_datos, p_modelo, p_origen, p_user, p_costo)
    returning fin_lecturas_mes.id, fin_lecturas_mes.generado_en;
end
$f$;

revoke all on function public.fin_lectura_puede_ver(text) from public, anon;
revoke all on function public.fin_lectura_clientes() from public, anon;
revoke all on function public.fin_lectura_mes_base(text, date) from public, anon, authenticated;
revoke all on function public.fin_lectura_numeros(text, text) from public, anon, authenticated;
revoke all on function public.fin_lectura_guardar(text, text, text, jsonb, text, text, uuid, numeric) from public, anon, authenticated;
grant execute on function public.fin_lectura_puede_ver(text) to authenticated, service_role;
grant execute on function public.fin_lectura_clientes() to authenticated, service_role;
grant execute on function public.fin_lectura_mes_base(text, date) to service_role;
grant execute on function public.fin_lectura_numeros(text, text) to service_role;
grant execute on function public.fin_lectura_guardar(text, text, text, jsonb, text, text, uuid, numeric) to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Prueba de humo (corre como postgres, no deja nada: termina en ERROR a proposito)
-- Resultado esperado: ERROR "HUMO 148 OK: ...". Cualquier "HUMO 148 FALLO" = avisar.
-- ---------------------------------------------------------------------
do $h$
declare
  v_cli text; v_num jsonb; v_id bigint; v_leido text; v_puede boolean;
begin
  select id into v_cli from public.crm_clients where id in ('liam', 'agus', 'teo') order by id limit 1;
  if v_cli is null then raise exception 'HUMO 148 FALLO: no hay ningun cliente liam/agus/teo'; end if;

  v_num := public.fin_lectura_numeros(v_cli, to_char(current_date - interval '1 month', 'YYYY-MM'));
  if v_num is null or not (v_num ? 'mes') or not (v_num ? 'mes_previo') or not (v_num ? 'cobranzas_hoy') then
    raise exception 'HUMO 148 FALLO: fin_lectura_numeros no devolvio mes, mes_previo y cobranzas_hoy';
  end if;
  if (v_num -> 'mes' -> 'pagos' ->> 'cantidad') is null or (v_num -> 'mes' -> 'comisiones' ->> 'total_usd') is null then
    raise exception 'HUMO 148 FALLO: faltan campos de pagos o comisiones';
  end if;

  begin
    perform public.fin_lectura_numeros(v_cli, '2026-13');
    raise exception 'HUMO 148 FALLO: acepto un periodo invalido';
  exception when others then
    if sqlerrm like 'HUMO 148%' then raise; end if;
  end;

  select id into v_id from public.fin_lectura_guardar(v_cli, '2000-01', '- prueba', v_num, 'humo', 'manual', null, null);
  select texto into v_leido from public.fin_lecturas_mes where id = v_id;
  if v_leido is distinct from '- prueba' then raise exception 'HUMO 148 FALLO: no se guardo la lectura'; end if;

  -- sin sesion (auth.uid() null) nadie ve nada
  v_puede := public.fin_lectura_puede_ver(v_cli);
  if v_puede is not false then raise exception 'HUMO 148 FALLO: sin sesion puede ver = %', v_puede; end if;

  raise exception 'HUMO 148 OK: numeros de % armados (% bytes), lectura guardada y leida, sin sesion no ve. Se revierte.',
    v_cli, length(v_num::text);
end
$h$;

-- ---------------------------------------------------------------------
-- BLOQUE 3. Cron. Correr DESPUES de desplegar ia-lectura-mensual (--no-verify-jwt).
--   ia_lectura_mensual: dia 1 de cada mes, 11:31 UTC = 8:31 ART. Genera la lectura del mes anterior
--   para liam, agus y teo (si ya hay una del cron para ese mes, no la repite).
--   Secretos de Vault: fin_sync_service_key (ya existe) e ia_lectura_mensual_url (se crea aca si falta).
-- ---------------------------------------------------------------------
do $v$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'fin_sync_service_key') then
    raise exception '148: falta el secreto fin_sync_service_key en Vault (ver 004_cron.sql, paso 0)';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'ia_lectura_mensual_url') then
    perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ia-lectura-mensual', 'ia_lectura_mensual_url');
  end if;
end
$v$;

select cron.unschedule(jobid) from cron.job where jobname = 'ia_lectura_mensual';

select cron.schedule('ia_lectura_mensual', '31 11 1 * *',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'ia_lectura_mensual_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_service_key')),
      body    := '{"accion":"mensual"}'::jsonb,
      timeout_milliseconds := 150000
    );
  $cron$);

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno; el editor muestra solo el ultimo resultado)
-- =====================================================================

-- C1. Tabla con RLS y su politica: 1 fila, rls = true, politicas = 1.
-- select c.relname, c.relrowsecurity as rls,
--        (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname) as politicas
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public' and c.relname = 'fin_lecturas_mes';

-- C2. Funciones y permisos: authenticated true solo en las 2 de la app; service_role true en las 5. 5 filas.
-- select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('fin_lectura_puede_ver','fin_lectura_clientes','fin_lectura_mes_base','fin_lectura_numeros','fin_lectura_guardar')
--  order by 1;

-- C3. Como fundador (poner el uuid de un fundador): ve liam, agus y teo. 3 filas.
-- select set_config('request.jwt.claim.sub', '<uuid fundador>', true);
-- select * from public.fin_lectura_clientes();

-- C4. El resumen que lee la IA para el mes anterior (revisar a ojo que los numeros cierren con el P&L de la app):
-- select jsonb_pretty(public.fin_lectura_numeros('liam', to_char(current_date - interval '1 month', 'YYYY-MM')));

-- C5. Cron y Vault: 1 fila activa con '31 11 1 * *' y 1 fila de secreto.
-- select jobname, schedule, active from cron.job where jobname = 'ia_lectura_mensual';
-- select name from vault.decrypted_secrets where name = 'ia_lectura_mensual_url';

-- C6. El humo no dejo nada: 0.
-- select count(*) from public.fin_lecturas_mes where periodo = '2000-01';

-- C7. Despues del primer uso: lecturas, gasto y errores.
-- select cliente_id, periodo, origen, generado_en, costo_usd, left(texto, 80) as inicio
--   from public.fin_lecturas_mes order by generado_en desc limit 10;
-- select funcion, count(*) as llamadas, round(sum(costo_usd), 4) as usd, count(*) filter (where not ok) as con_error
--   from ia_uso where app = 'finanzas' and funcion = 'lectura_mensual' group by 1;
-- select status::text, return_message, start_time from cron.job_run_details
--  where jobid in (select jobid from cron.job where jobname = 'ia_lectura_mensual') order by start_time desc limit 3;

-- =====================================================================
-- VUELTA ATRAS (en este orden; borra el historial de lecturas, no toca nada mas)
-- =====================================================================
-- select cron.unschedule(jobid) from cron.job where jobname = 'ia_lectura_mensual';
-- delete from vault.secrets where name = 'ia_lectura_mensual_url';
-- drop function if exists public.fin_lectura_guardar(text, text, text, jsonb, text, text, uuid, numeric);
-- drop function if exists public.fin_lectura_numeros(text, text);
-- drop function if exists public.fin_lectura_mes_base(text, date);
-- drop function if exists public.fin_lectura_clientes();
-- drop table if exists public.fin_lecturas_mes;
-- drop function if exists public.fin_lectura_puede_ver(text);
