-- =====================================================================
-- 228_pagos_fuente_ingreso_y_fuentes_liam.sql
-- Parte A: fin_pagos.fuente_ingreso (Webinar / Lead magnet funnel / Llamada / venta / Otro), opcional,
--          para Liam, Agus y Teo, cargable desde "Cargar pago".
-- Parte B: 6 fuentes de agenda nuevas de Liam (YT, YT VENTAS, LINKEDIN, WEBINAR, POST WEBINAR, WEBINAR REPLAY)
--          en fin_catalogos (dimension 'fuente') y fin_fuentes_mapa.
-- SIN CORRER, NO PROBADA contra Postgres. Solo aditiva: no borra ni pisa datos.
--
-- Decisiones:
--  * fuente_ingreso es una columna NUEVA y distinta de fuente_lead (209, texto libre de Agus: origen del lead
--    segun su planilla). No se toca fuente_lead. Una es "de donde vino el lead" (libre, Sheet); la otra es "por
--    que canal entro este ingreso" (lista cerrada, carga a mano). Las filas viejas y las del Sheet quedan en null.
--  * La sync no se toca: fin_sync_escribir no nombra la columna, asi que las filas 'sheet' quedan en null.
--  * fin_pago_cargar = copia EXACTA de la 211 + fuente_ingreso (valida contra la lista; sin la clave, igual que antes).
--  * fin_columnas_sistema('pagos') = la de la 209 + 'fuente_ingreso' al final (sin esto el panel Columnas rechaza
--    la clave). fin_columnas_ocultas_por_defecto no cambia: la columna queda visible en la grilla y en Cargar pago.
--  * Parte B: ventas-agenda, fin_agendas_entrantes y fin_procesar_agenda NO tienen lista fija de wf ni de fuente
--    (wf = texto libre; la fuente va tal cual a fin_llamadas.tipo_booking), no hace falta tocarlos. El mapa se
--    siembra con atribucion NULL (sin definir, igual que WEBINAR/YOUTUBE en la 025): decide la agencia.
--    Catalogos de Agus y Teo: no se tocan.
--
-- Depende de la 209 y de la 211 (guardas). Orden: 209 -> 211 -> 228 -> publicar el front.
-- No correr a las :00/:15/:30/:45 ni a las 9:00. Re-ejecutable.
-- Controles C1 a C6 y vuelta atras al final (de a uno).
-- =====================================================================

begin;
set local lock_timeout = '10s';
lock table public.fin_pagos in share row exclusive mode;

-- ---------------------------------------------------------------------
-- Guardas
-- ---------------------------------------------------------------------
do $g$
declare v text; n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'fin_pagos' and column_name in ('email', 'fuente_email', 'fuente_lead');
  if n <> 3 then
    raise exception 'GUARDA 228: faltan columnas en fin_pagos (hay % de 3): falta correr la 209. No se toca nada.', n;
  end if;

  v := pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure);
  if v not like '%-- 211: mail y fuentes%' and v not like '%-- 228: fuente de ingreso%' then
    raise exception 'GUARDA 228: fin_pago_cargar no es la de la 211 (falta correr la 211, o la cambio algo despues). No se toca nada.';
  end if;

  if public.fin_columnas_sistema('pagos') is distinct from array['fecha', 'alumno', 'telefono', 'programa', 'concepto', 'monto_usd',
       'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante', 'nota', 'origen', 'fila_planilla',
       'email', 'fuente_email', 'fuente_lead']
     and public.fin_columnas_sistema('pagos') is distinct from array['fecha', 'alumno', 'telefono', 'programa', 'concepto', 'monto_usd',
       'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante', 'nota', 'origen', 'fila_planilla',
       'email', 'fuente_email', 'fuente_lead', 'fuente_ingreso'] then
    raise exception 'GUARDA 228: fin_columnas_sistema(''pagos'') no es la de la 209 (17 claves). No se toca nada.';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- 1. Columna nueva (null en todo lo existente)
-- ---------------------------------------------------------------------
alter table public.fin_pagos add column if not exists fuente_ingreso text;

alter table public.fin_pagos drop constraint if exists fin_pagos_fuente_ingreso_ck;
alter table public.fin_pagos add constraint fin_pagos_fuente_ingreso_ck
  check (fuente_ingreso is null or fuente_ingreso in ('Webinar', 'Lead magnet funnel', 'Llamada / venta', 'Otro'));

comment on column public.fin_pagos.fuente_ingreso is
  '228: canal por el que entro el ingreso (Webinar, Lead magnet funnel, Llamada / venta, Otro). Opcional, se carga a mano desde Cargar pago; null en pagos viejos y del Sheet. Distinta de fuente_lead (209, texto libre del Sheet de Agus).';

-- ---------------------------------------------------------------------
-- 2. fin_columnas_sistema('pagos') = 209 + fuente_ingreso al final
-- ---------------------------------------------------------------------
create or replace function public.fin_columnas_sistema(p_vista text)
returns text[]
language sql immutable set search_path = public
as $$
  select case p_vista
    when 'pagos' then array['fecha', 'alumno', 'telefono', 'programa', 'concepto', 'monto_usd',
                            'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante',
                            'nota', 'origen', 'fila_planilla', 'email', 'fuente_email', 'fuente_lead',
                            'fuente_ingreso']
    when 'pnl' then array['revenue_declarado', 'ingreso_real', 'staff', 'softwares', 'others',
                          'sin_categoria', 'gastos_total', 'net_cash_flow', 'dividends_released',
                          'opening_balance', 'closing_balance']
    when 'resumen' then array['ingreso_real', 'revenue_declarado', 'diferencia', 'gastos_total',
                              'net_cash_flow', 'cantidad_pagos', 'sincronizacion']
    when 'conciliacion' then array['mes', 'revenue_opps', 'revenue_pagos', 'cantidad_pagos',
                                   'diferencia', 'diferencia_pct']
  end;
$$;

-- ---------------------------------------------------------------------
-- 3. fin_pago_cargar = 211 + fuente_ingreso
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
  v_fing    text    := nullif(btrim(p ->> 'fuente_ingreso'), '');          -- 228
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

  -- 228: fuente de ingreso (opcional, lista cerrada)
  if v_fing is not null and v_fing not in ('Webinar', 'Lead magnet funnel', 'Llamada / venta', 'Otro') then
    raise exception 'Fuente de ingreso invalida: %', v_fing;
  end if;

  insert into public.fin_pagos (
    cliente_id, fuente_id, origen, fila_planilla, fecha, programa, programa_id, alumno, telefono,
    concepto, concepto_id, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente,
    metodo_pago, metodo_pago_id, quien_recibe, quien_recibe_id, closer, setter, comprobante,
    nota, creado_por, creado_en,
    email, fuente_email, fuente_lead,  -- 211
    fuente_ingreso)  -- 228
  values (
    v_cli, v_fuente.id, 'app', null, v_fecha, v_prog, (p ->> 'programa_id')::bigint, v_alumno,
    nullif(btrim(p ->> 'telefono'), ''),
    v_conc, (p ->> 'concepto_id')::bigint, v_monto, v_monto, 'USD', 1, 'app',
    v_met, (p ->> 'metodo_pago_id')::bigint, v_rec, nullif(p ->> 'quien_recibe_id', '')::bigint,
    v_closer, v_setter, v_comp, nullif(btrim(p ->> 'nota'), ''), auth.uid(), now(),
    v_email, v_fmail, v_flead,  -- 211
    v_fing)  -- 228
  returning * into v_fila;

  return jsonb_build_object('ok', true, 'id', v_fila.id, 'clave', v_fila.clave);
end $$;

-- ---------------------------------------------------------------------
-- 4. Liam: 6 fuentes de agenda nuevas (solo si no estaban; no se pisa nada)
-- ---------------------------------------------------------------------
-- Mapa crudo -> canonica -> atribucion. Atribucion NULL = sin definir (como WEBINAR/YOUTUBE en la 025);
-- cambiarla despues es un update de una fila.
insert into public.fin_fuentes_mapa (cliente_id, fuente_cruda, fuente, atribucion)
select 'liam', v.n, v.n, null
from (values ('YT'), ('YT VENTAS'), ('LINKEDIN'), ('WEBINAR'), ('POST WEBINAR'), ('WEBINAR REPLAY')) as v(n)
where not exists (select 1 from public.fin_fuentes_mapa m
                   where m.cliente_id = 'liam' and upper(btrim(m.fuente_cruda)) = v.n);

-- Catalogo de Fuente de Liam (desplegable de Ventas): al final de la lista actual.
insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
select 'liam', 'fuente', v.n,
       coalesce((select max(c.orden) from public.fin_catalogos c where c.cliente_id = 'liam' and c.dimension = 'fuente'), 0) + v.o
from (values ('YT', 1), ('YT VENTAS', 2), ('LINKEDIN', 3), ('WEBINAR', 4), ('POST WEBINAR', 5), ('WEBINAR REPLAY', 6)) as v(n, o)
where not exists (select 1 from public.fin_catalogos c
                   where c.cliente_id = 'liam' and c.dimension = 'fuente' and upper(btrim(c.valor)) = v.n);

-- ---------------------------------------------------------------------
-- Verificacion dentro de la transaccion
-- ---------------------------------------------------------------------
do $v$
declare v text; n int;
begin
  v := pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure);
  if v not like '%fuente_ingreso)  -- 228%' or v not like '%-- 211: mail y fuentes%'
     or v not like '%Las devoluciones se cargan con "Devolver"%' then
    raise exception 'VERIFICACION 228: fin_pago_cargar no quedo actualizada';
  end if;
  if not has_function_privilege('authenticated', 'public.fin_pago_cargar(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.fin_pago_cargar(jsonb)', 'execute') then
    raise exception 'VERIFICACION 228: permisos de fin_pago_cargar alterados';
  end if;
  if not ('fuente_ingreso' = any (public.fin_columnas_sistema('pagos'))) then
    raise exception 'VERIFICACION 228: fin_columnas_sistema no suma fuente_ingreso';
  end if;
  select count(*) into n from public.fin_catalogos c
   where c.cliente_id = 'liam' and c.dimension = 'fuente'
     and upper(btrim(c.valor)) in ('YT', 'YT VENTAS', 'LINKEDIN', 'WEBINAR', 'POST WEBINAR', 'WEBINAR REPLAY');
  if n <> 6 then raise exception 'VERIFICACION 228: el catalogo de Liam tiene % de las 6 fuentes nuevas', n; end if;
end
$v$;

commit;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo)
-- =====================================================================

-- C1. Columna nueva, sin datos en pagos viejos. Esperado: 1 fila text, nullable; con_fuente_ingreso = 0 (hasta que alguien cargue uno).
-- select c.data_type, c.is_nullable,
--        (select count(*) from public.fin_pagos where fuente_ingreso is not null) as con_fuente_ingreso,
--        (select count(*) from public.fin_pagos) as pagos_total
--   from information_schema.columns c
--  where c.table_schema = 'public' and c.table_name = 'fin_pagos' and c.column_name = 'fuente_ingreso';

-- C2. Las 6 fuentes de Liam en el catalogo. Esperado: 6 filas activas.
-- select valor, orden, activo from public.fin_catalogos
--  where cliente_id = 'liam' and dimension = 'fuente'
--    and upper(btrim(valor)) in ('YT', 'YT VENTAS', 'LINKEDIN', 'WEBINAR', 'POST WEBINAR', 'WEBINAR REPLAY')
--  order by orden;

-- C3. Las 6 en el mapa, con su atribucion. Esperado: 6 filas (las que ya existian conservan su atribucion; las nuevas, null).
-- select fuente_cruda, fuente, atribucion from public.fin_fuentes_mapa
--  where cliente_id = 'liam'
--    and upper(btrim(fuente_cruda)) in ('YT', 'YT VENTAS', 'LINKEDIN', 'WEBINAR', 'POST WEBINAR', 'WEBINAR REPLAY')
--  order by fuente_cruda;

-- C4. Fuentes viejas sin cambios. Comparar con lo que habia antes de correr: el conteo de Liam sube como maximo 6 y
--     la atribucion de INSTAGRAM/LANDING/TT sigue igual. Agus y Teo: 0 cambios (esperado: 0 filas nuevas de hoy).
-- select cliente_id, dimension, count(*) as filas from public.fin_catalogos where dimension = 'fuente' group by 1, 2 order by 1;
-- select atribucion, count(*) from public.fin_fuentes_mapa where cliente_id = 'liam' group by 1 order by 1;

-- C5. La funcion conserva lo anterior. Esperado: las 4 en true.
-- select pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%fuente_ingreso)  -- 228%' as con_228,
--        pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%-- 211: mail y fuentes%' as con_211,
--        pg_get_functiondef('public.fin_pago_cargar(jsonb)'::regprocedure) like '%Las devoluciones se cargan con "Devolver"%' as refund_igual,
--        'fuente_ingreso' = any (public.fin_columnas_sistema('pagos')) as columna_en_sistema;

-- C6. Humo (se revierte solo: termina en ERROR a proposito). Reemplazar <UUID_FUNDADOR>. Esperado: el ERROR final dice
--     "HUMO 228 OK: con=Webinar sin=null mala=rechazada".
-- do $h$
-- declare
--   v_cli text; v_prog bigint; v_conc bigint; v_met bigint; v_r jsonb; v_r2 jsonb; v_a text; v_b text;
-- begin
--   perform set_config('request.jwt.claim.sub', '<UUID_FUNDADOR>', true);
--   set local role authenticated;
--   select f.cliente_id into v_cli from public.fin_fuentes f where f.tipo = 'pagos' and f.cortada_en is not null order by f.id limit 1;
--   if v_cli is null then raise exception 'HUMO 228: no hay ningun cliente con la planilla cortada'; end if;
--   select id into v_prog from public.fin_catalogos where cliente_id = v_cli and dimension = 'programa' and activo order by id limit 1;
--   select id into v_conc from public.fin_catalogos where cliente_id = v_cli and dimension = 'concepto' and activo and valor <> 'REFUND' order by id limit 1;
--   select id into v_met  from public.fin_catalogos where cliente_id = v_cli and dimension = 'metodo_pago' and activo order by id limit 1;
--   v_r := public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 228',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met, 'fuente_ingreso', 'Webinar'));
--   v_r2 := public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 228 B',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met));
--   select coalesce(fuente_ingreso, 'null') into v_a from public.fin_pagos where clave = v_r ->> 'clave';
--   select coalesce(fuente_ingreso, 'null') into v_b from public.fin_pagos where clave = v_r2 ->> 'clave';
--   begin
--     perform public.fin_pago_cargar(jsonb_build_object('cliente_id', v_cli, 'fecha', current_date - 1, 'alumno', 'ZZ HUMO 228 C',
--            'monto_usd', 1, 'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met, 'fuente_ingreso', 'Inventada'));
--     raise exception 'HUMO 228 FALLO: acepto una fuente invalida';
--   exception when others then
--     if sqlerrm not like '%Fuente de ingreso invalida%' then raise; end if;
--   end;
--   raise exception 'HUMO 228 OK: con=% sin=% mala=rechazada', v_a, v_b;
-- end
-- $h$;

-- =====================================================================
-- VUELTA ATRAS (no correr salvo marcha atras)
-- =====================================================================
-- 1) Volver a correr el bloque `create or replace function public.fin_pago_cargar` de la 211 (la funcion de esa migracion
--    no nombra fuente_ingreso; el front nuevo manda la clave y la 211 la ignora sin error).
-- 2) Volver a correr el bloque fin_columnas_sistema de la 209 (sin 'fuente_ingreso'). Antes, si el fundador guardo
--    la columna en el panel: delete from public.fin_columnas where vista = 'pagos' and clave = 'fuente_ingreso';
-- 3) alter table public.fin_pagos drop constraint if exists fin_pagos_fuente_ingreso_ck;
--    alter table public.fin_pagos drop column if exists fuente_ingreso;   -- pierde lo cargado a mano
-- 4) Fuentes de Liam (solo las que agrego esta migracion; las que ya existian NO se borran). Ver C2/C3 antes y borrar a mano
--    las filas que no estaban.
