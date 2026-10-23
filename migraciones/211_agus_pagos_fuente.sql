-- =====================================================================
-- 211_agus_pagos_fuente.sql
-- Cargar pago de la app: Mail, Fuente del mail y Fuente (origen del lead), los tres opcionales.
-- SIN CORRER, NO PROBADA contra Postgres.
--
-- Que hace: fin_pago_cargar(jsonb) = copia EXACTA de la 066 (la unica definicion vigente) con un cambio:
-- lee p.email, p.fuente_email y p.fuente_lead y los guarda en las columnas fin_pagos.email, fuente_email
-- y fuente_lead (las crea la 209). Sin esas claves en el jsonb se comporta igual que antes, asi que Liam, Teo
-- y cualquier otro cliente cargan como siempre. No toca datos, tablas, permisos ni la sync.
--   - email: opcional; si viene, tiene que parecer un mail (algo@algo). Se guarda en minusculas y sin espacios.
--   - fuente_email y fuente_lead: opcionales, texto libre, hasta 200 caracteres.
-- Los 3 campos se muestran en el formulario solo donde la columna esta visible en la config de Pagos
-- (la 209 la deja visible para Agus), por eso los demas clientes no ven cambios en la pantalla.
-- Pagos editados despues (fin_pago_editar): estas 3 columnas quedan de solo lectura; no se toca esa funcion.
--
-- Depende de la 209 (columnas nuevas; guarda). Orden: 209 -> 211 -> publicar el front.
-- No correr a las :00/:15/:30/:45 ni a las 9:00. Re-ejecutable (create or replace).
-- Controles C1 a C4 y vuelta atras al final (de a uno).
-- =====================================================================

begin;
set local lock_timeout = '10s';

-- ---------------------------------------------------------------------
-- Guardas
-- ---------------------------------------------------------------------
do $g$
declare v text; n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'fin_pagos' and column_name in ('email', 'fuente_email', 'fuente_lead');
  if n <> 3 then
    raise exception 'GUARDA 211: faltan columnas en fin_pagos (hay % de 3): falta correr la 209. No se toca nada.', n;
  end if;

  v := pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure);
  if v not like '%Las devoluciones se cargan con "Devolver" sobre el pago original%'
     or v not like '%Ese closer no esta asignado a % o no tiene alias%'
     or v not like '%El comprobante tiene que ser un link%'
     or (v not like '%nota, creado_por, creado_en)%' and v not like '%-- 211: mail y fuentes%') then
    raise exception 'GUARDA 211: fin_pago_cargar no es la de la 066 (o la cambio algo despues). No se toca nada.';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- fin_pago_cargar = 066 + email, fuente_email, fuente_lead
-- ---------------------------------------------------------------------
create or replace function public.fin_pago_cargar(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cli     text    := nullif(btrim(p ->> 'cliente_id'), '');
  v_fecha   date;
  v_monto   numeric;
  v_alumno  text    := nullif(btrim(p ->> 'alumno'), '');
  v_comp    text    := nullif(btrim(p ->> 'comprobante'), '');
  v_email   text    := nullif(lower(btrim(p ->> 'email')), '');            -- 211
  v_fmail   text    := nullif(btrim(p ->> 'fuente_email'), '');            -- 211
  v_flead   text    := nullif(btrim(p ->> 'fuente_lead'), '');             -- 211
  v_fuente  public.fin_fuentes%rowtype;
  v_prog    text; v_conc text; v_met text; v_rec text;
  v_closer  text; v_setter text;
  v_hoy     date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_fila    public.fin_pagos%rowtype;
begin
  if v_cli is null then raise exception 'Falta el cliente'; end if;
  if not public.fin_puede_cargar(v_cli) then
    raise exception 'No tenes permiso para cargar pagos de %', v_cli;
  end if;
  if not public.fin_carga_habilitada(v_cli) then
    raise exception 'La carga en la app de % todavia no esta habilitada (la planilla no esta cortada)', v_cli;
  end if;

  select * into v_fuente from public.fin_fuentes
   where cliente_id = v_cli and tipo = 'pagos' and cortada_en is not null
   order by id limit 1;

  begin
    v_fecha := (p ->> 'fecha')::date;
  exception when others then
    raise exception 'Fecha invalida: %', p ->> 'fecha';
  end;
  if v_fecha is null then raise exception 'Falta la fecha'; end if;
  if v_fecha > v_hoy then raise exception 'La fecha % es futura', v_fecha; end if;
  if v_fecha < date '2024-01-01' then raise exception 'La fecha % es demasiado vieja', v_fecha; end if;

  if v_alumno is null then raise exception 'Falta el alumno'; end if;

  begin
    v_monto := round((p ->> 'monto_usd')::numeric, 2);
  exception when others then
    raise exception 'Monto invalido: %', p ->> 'monto_usd';
  end;
  if v_monto is null or v_monto <= 0 then raise exception 'El monto tiene que ser mayor a 0'; end if;
  if v_fuente.tope_monto is not null and v_monto > v_fuente.tope_monto then
    raise exception 'El monto % supera el tope de % USD. Si es correcto, lo carga un fundador desde la base.', v_monto, v_fuente.tope_monto;
  end if;

  select valor into v_prog from public.fin_catalogos
   where id = (p ->> 'programa_id')::bigint and cliente_id = v_cli and dimension = 'programa' and activo;
  if v_prog is null then raise exception 'Programa invalido para %', v_cli; end if;

  select valor into v_conc from public.fin_catalogos
   where id = (p ->> 'concepto_id')::bigint and cliente_id = v_cli and dimension = 'concepto' and activo;
  if v_conc is null then raise exception 'Concepto invalido para %', v_cli; end if;
  if v_conc = 'REFUND' then raise exception 'Las devoluciones se cargan con "Devolver" sobre el pago original'; end if;

  select valor into v_met from public.fin_catalogos
   where id = (p ->> 'metodo_pago_id')::bigint and cliente_id = v_cli and dimension = 'metodo_pago' and activo;
  if v_met is null then raise exception 'Metodo de pago invalido para %', v_cli; end if;

  if nullif(p ->> 'quien_recibe_id', '') is not null then
    select valor into v_rec from public.fin_catalogos
     where id = (p ->> 'quien_recibe_id')::bigint and cliente_id = v_cli and dimension = 'quien_recibe' and activo;
    if v_rec is null then raise exception 'Quien recibe invalido para %', v_cli; end if;
  end if;

  -- Closer y setter: vendedor asignado a este cliente con ese rol. Se guarda
  -- el alias que ya usa fin_v_pago_vendedores, asi la comision sale igual
  -- que con los pagos de la planilla.
  if nullif(p ->> 'closer_id', '') is not null then
    select coalesce(
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id = v_cli order by x.id limit 1),
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id is null order by x.id limit 1))
      into v_closer
      from public.fin_vendedor_asignaciones a
     where a.vendedor_id = (p ->> 'closer_id')::bigint and a.cliente_id = v_cli and a.es_closer
       and (a.hasta is null or a.hasta >= v_fecha)
     limit 1;
    if v_closer is null then raise exception 'Ese closer no esta asignado a % o no tiene alias', v_cli; end if;
  end if;
  if nullif(p ->> 'setter_id', '') is not null then
    select coalesce(
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id = v_cli order by x.id limit 1),
             (select x.alias from public.fin_personas x
               where x.vendedor_id = a.vendedor_id and x.cliente_id is null order by x.id limit 1))
      into v_setter
      from public.fin_vendedor_asignaciones a
     where a.vendedor_id = (p ->> 'setter_id')::bigint and a.cliente_id = v_cli and a.es_setter
       and (a.hasta is null or a.hasta >= v_fecha)
     limit 1;
    if v_setter is null then raise exception 'Ese setter no esta asignado a % o no tiene alias', v_cli; end if;
  end if;

  if v_comp is not null and v_comp !~* '^https?://' then
    raise exception 'El comprobante tiene que ser un link (https://...)';
  end if;

  -- 211: mail y fuentes (opcionales)
  if v_email is not null and (v_email !~ '^[^@[:space:]]+@[^@[:space:]]+$' or length(v_email) > 200) then
    raise exception 'El mail no parece valido';
  end if;
  if length(v_fmail) > 200 then raise exception 'La fuente del mail es demasiado larga (maximo 200 caracteres)'; end if;
  if length(v_flead) > 200 then raise exception 'La fuente es demasiado larga (maximo 200 caracteres)'; end if;

  insert into public.fin_pagos (
    cliente_id, fuente_id, origen, fila_planilla, fecha, programa, programa_id, alumno, telefono,
    concepto, concepto_id, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente,
    metodo_pago, metodo_pago_id, quien_recibe, quien_recibe_id, closer, setter, comprobante,
    nota, creado_por, creado_en,
    email, fuente_email, fuente_lead)  -- 211
  values (
    v_cli, v_fuente.id, 'app', null, v_fecha, v_prog, (p ->> 'programa_id')::bigint, v_alumno,
    nullif(btrim(p ->> 'telefono'), ''),
    v_conc, (p ->> 'concepto_id')::bigint, v_monto, v_monto, 'USD', 1, 'app',
    v_met, (p ->> 'metodo_pago_id')::bigint, v_rec, nullif(p ->> 'quien_recibe_id', '')::bigint,
    v_closer, v_setter, v_comp, nullif(btrim(p ->> 'nota'), ''), auth.uid(), now(),
    v_email, v_fmail, v_flead)  -- 211
  returning * into v_fila;

  return jsonb_build_object('ok', true, 'id', v_fila.id, 'clave', v_fila.clave);
end $$;

-- ---------------------------------------------------------------------
-- Verificacion dentro de la transaccion
-- ---------------------------------------------------------------------
do $v$
declare v text;
begin
  v := pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure);
  if v not like '%email, fuente_email, fuente_lead)  -- 211%' or v not like '%-- 211: mail y fuentes%' then
    raise exception 'VERIFICACION 211: fin_pago_cargar no quedo actualizada';
  end if;
  if not has_function_privilege('authenticated', 'public.fin_pago_cargar(jsonb)', 'execute') then
    raise exception 'VERIFICACION 211: authenticated perdio el permiso de ejecutar fin_pago_cargar';
  end if;
  if has_function_privilege('anon', 'public.fin_pago_cargar(jsonb)', 'execute') then
    raise exception 'VERIFICACION 211: anon puede ejecutar fin_pago_cargar';
  end if;
end
$v$;

commit;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo)
-- =====================================================================

-- C1. La funcion quedo con lo nuevo y conserva lo de la 066. Esperado: las 4 en true.
-- select pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%-- 211: mail y fuentes%' as con_211,
--        pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%Las devoluciones se cargan con "Devolver"%' as refund_igual,
--        pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%El comprobante tiene que ser un link%' as comprobante_igual,
--        pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%Ese setter no esta asignado a %' as setter_igual;

-- C2. Permisos. Esperado: authenticated = true, anon = false.
-- select has_function_privilege('authenticated', 'public.fin_pago_cargar(jsonb)', 'execute') as authenticated,
--        has_function_privilege('anon', 'public.fin_pago_cargar(jsonb)', 'execute') as anon;

-- C3. Esta migracion no cambio datos. Esperado: 0 filas nuevas con mail/fuentes cargados desde la app
--     hasta que alguien guarde un pago con esos campos.
-- select cliente_id, count(*) filter (where email is not null) as con_mail,
--        count(*) filter (where fuente_email is not null) as con_fuente_mail,
--        count(*) filter (where fuente_lead is not null) as con_fuente
--   from public.fin_pagos where origen = 'app' group by 1 order by 1;

-- C4. Humo (se revierte solo: termina en ERROR a proposito, no deja nada). Reemplazar <UUID_FUNDADOR> por el uuid
--     de un fundador. Usa un cliente con la planilla de pagos cortada (hoy Liam). Esperado: el mensaje del ERROR final
--     dice "HUMO 211 OK: mail=prueba@ejemplo.test fuente_mail=Formulario fuente=instagram sin_campos=ok mail_malo=rechazado".
-- do $h$
-- declare
--   v_cli text; v_prog bigint; v_conc bigint; v_met bigint; v_r jsonb; v_f record; v_r2 jsonb; v_msg text := 'ok';
-- begin
--   perform set_config('request.jwt.claim.sub', '<UUID_FUNDADOR>', true);
--   set local role authenticated;
--   select f.cliente_id into v_cli from public.fin_fuentes f where f.tipo = 'pagos' and f.cortada_en is not null order by f.id limit 1;
--   if v_cli is null then raise exception 'HUMO 211: no hay ningun cliente con la planilla cortada'; end if;
--   select id into v_prog from public.fin_catalogos where cliente_id = v_cli and dimension = 'programa' and activo order by id limit 1;
--   select id into v_conc from public.fin_catalogos where cliente_id = v_cli and dimension = 'concepto' and activo and valor <> 'REFUND' order by id limit 1;
--   select id into v_met  from public.fin_catalogos where cliente_id = v_cli and dimension = 'metodo_pago' and activo order by id limit 1;
--   v_r := public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 211',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met,
--            'email', ' Prueba@Ejemplo.test ', 'fuente_email', 'Formulario', 'fuente_lead', 'instagram'));
--   select email, fuente_email, fuente_lead into v_f from public.fin_pagos where clave = v_r ->> 'clave';
--   v_r2 := public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 211 B',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met));
--   if exists (select 1 from public.fin_pagos where clave = v_r2 ->> 'clave' and (email is not null or fuente_email is not null or fuente_lead is not null)) then
--     raise exception 'HUMO 211 FALLO: sin campos deberia quedar en null';
--   end if;
--   begin
--     perform public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 211 C',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met, 'email', 'no es un mail'));
--     raise exception 'HUMO 211 FALLO: acepto un mail invalido';
--   exception when others then
--     if sqlerrm not like '%no parece valido%' then raise; end if;
--   end;
--   raise exception 'HUMO 211 OK: mail=% fuente_mail=% fuente=% sin_campos=ok mail_malo=rechazado', v_f.email, v_f.fuente_email, v_f.fuente_lead;
-- end
-- $h$;

-- =====================================================================
-- VUELTA ATRAS (no correr salvo marcha atras)
-- =====================================================================
-- Volver a correr el bloque `create or replace function public.fin_pago_cargar` de la migraciones/066_carga_pagos_app.sql
-- (lineas 171 a 289, sin email/fuente_email/fuente_lead). Publicar antes el front anterior: manda esos 3 campos y la
-- funcion de la 066 los ignora sin error (no hay que hacer nada mas).
