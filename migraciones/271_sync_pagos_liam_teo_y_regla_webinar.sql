-- =====================================================================
-- 271_sync_pagos_liam_teo_y_regla_webinar.sql
-- (1) Sync de pagos de Liam (BluePrint): se reactiva sin duplicar lo que ya entro por importacion de la app.
-- (2) Sync de pagos de Teo (North Ecom): el arreglo es de codigo (Edge Function) + aceptar el encabezado; aca solo controles.
-- (3) Regla de fuente "Webinar" nueva: vista aparte, NO reescribe fin_pagos ni el Sheet.
-- Numero asignado por el jefe (2/11/2026). SIN CORRER, SQL NO PROBADO contra Postgres.
--
-- ORDEN (importante):
--   a) Desplegar la Edge Function `sincronizar` (hash de encabezado de Pagos sin orden + monto 1254,11 de Teo).
--   b) BLOQUE 1 (sync sin duplicar) > BLOQUE 3 (vistas) > BLOQUE 4 y 5 (humo) > BLOQUE 2 (reactivar Liam, SOLO si se decide).
--   c) En la app: Salud > "Aceptar encabezado" en Pagos de Teo y en Pagos de Liam (una vez cada uno), esperar 15 minutos.
--   d) Controles C1.. de a uno.
--   Correr cada bloque por separado. No correr a las :00/:15/:30/:45 ni a las 9:00 (corre la sync).
--
-- (1) LIAM
--   La fuente `pagos` de Liam esta cortada desde la 076 (cortada_en + activo=false): sus pagos viven en la app (origen
--   'app'). Desde el 12/10 la hoja tiene el primer encabezado "-" en vez de FECHA DE CARGA; el alias '-' ya lo puso la 236
--   (este archivo lo vuelve a asegurar, idempotente). Faltan 5 pagos de la hoja del 28 al 31/10 (filas 303 a 307).
--   BLOQUE 1: fin_sync_escribir = copia exacta de la 209 + un unico cambio: NO inserta un pago de la hoja si ya hay uno
--     cargado por la app (origen distinto de 'sheet') con la misma huella de contenido (cliente + fecha + alumno + monto
--     + concepto, la clave de pago de la 062; si la huella se repite se cuenta por cantidad) o con la misma fila de
--     planilla + fecha + monto. Asi los 57 pagos importados no se duplican y entran solo los 5 que faltan. Vale para los
--     3 clientes: hoy Agus y Teo no tienen filas 'app' que coincidan, no cambia nada para ellos.
--   BLOQUE 2: reactivar la fuente (cortada_en = null, activo = true). CONSECUENCIA A DECIDIR: fin_carga_habilitada(cliente)
--     (066) es "la fuente de pagos esta cortada". Con la fuente activa, Cargar pago de Liam queda deshabilitado en la app
--     y los pagos se vuelven a cargar en la hoja. Se puede dejar sin correr y volver a cortar con la vuelta atras.
--   Sin la planilla encabezado aceptado la corrida da "cambio el encabezado": hay que aceptarlo UNA vez (ver ORDEN c).
--
-- (2) TEO
--   La sync de Teo mapea por NOMBRE de columna (alias), pero comparaba el encabezado por POSICION con la ultima corrida
--   buena; al poner PAGO antes de CONCEPTO (20/10) se frenaron las 902 corridas. Codigo: el hash de Pagos ya no depende
--   del orden (procesar.js). Aun asi el hash guardado es de un encabezado distinto: aceptar el encabezado una vez.
--   La fila 178 de julio (1254,11) se lee ahora como monto (grid.js): entra con la proxima corrida.
--
-- (3) REGLA DE FUENTE WEBINAR (criterio)
--   Un pago cuenta como Webinar solo si:
--     a) la planilla lo marca explicitamente (fuente_lead con webinar / replay, o fuente_ingreso = 'Webinar'), o
--     b) el cliente es nuevo: su PRIMER pago (el de menor fecha del alumno, monto mayor a 0) cae entre la fecha de un
--        webinar de ese cliente (fin_webinars, activo) y el fin de su ventana (ventana_hasta, o fecha + ventana_dias).
--   Cuotas, fees y completas de un alumno HEREDAN la fuente de su primer pago (la del cierre), no la del webinar que
--   este corriendo cuando pagan. Lo que la planilla trae marcado explicitamente no se pisa. NO es explicito lo que la
--   regla vieja (1/11) escribio en la hoja: pagos con "Fuente inferida" en la nota y fuente webinar; esos se vuelven a
--   decidir con la regla nueva (otras fuentes inferidas, ej. instagram antes del 20/09, se respetan).
--   Alumno = nombre normalizado (sin tildes ni signos, minusculas). Un pago sin primer pago identificable decide solo
--   por su fecha. Si no hay ninguna fuente, queda sin fuente (NO se inventa una).
--   Donde vive: fin_pago_fuente_calc (interna) y fin_v_pago_fuente (publica, con permiso). Se calcula al leer: no hay
--   nada guardado que se desactualice cuando la sync reinserta los pagos de la hoja. fin_pagos y el Sheet no se tocan.
--   fin_v_webinar_resultado pasa a contar ingresos con esta regla (mismas columnas que la 267).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. fin_sync_escribir sin duplicar pagos de la app
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';
lock table public.fin_pagos, public.fin_alias_columnas, public.fin_fuentes in access exclusive mode;

do $g$
declare v text;
begin
  v := pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure);
  if v not like '%209: nota, email, fuente_email%' or v not like '%esta cortada desde%'
     or v not like '%065: no toca pagos cargados en la app%' or v not like '%196: comprobantes_extra%' then
    raise exception 'GUARDA 271: fin_sync_escribir no es la de la 209 (o perdio una de sus marcas). No se toca nada.';
  end if;
  if to_regprocedure('public.fin_pago_huella(text,date,text,numeric,text)') is null then
    raise exception 'GUARDA 271: falta fin_pago_huella (062).';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'huella')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'origen') then
    raise exception 'GUARDA 271: fin_pagos no tiene huella (062) u origen (065).';
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 15, 30, 45) then
    raise exception 'GUARDA 271: no correr en los minutos 00, 15, 30 y 45 (corre la sync). Reintentar.';
  end if;
end
$g$;

-- Alias de Liam y Teo (ya los puso la 236; por si no corrio, o corrio a medias).
insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, posicion)
select f.id, a.campo, a.alias, a.obligatorio, a.posicion
from public.fin_fuentes f
join (values
  ('liam', 'fecha',       '-',      true,  null::int),
  ('liam', 'fecha',       'FECHA DE CARGA', true, null::int),
  ('liam', 'email',       'MAIL',   false, null::int),
  ('liam', 'fuente_lead', 'FUENTE', false, null::int),
  ('liam', 'nota',        'NOTAS',  false, null::int),
  ('teo',  'email',       'MAIL',   false, null::int),
  ('teo',  'fuente_lead', 'FUENTE', false, null::int)
) as a(cliente, campo, alias, obligatorio, posicion) on a.cliente = f.cliente_id
where f.tipo = 'pagos'
on conflict (fuente_id, campo_canonico, alias) do nothing;

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
  n_en_app   int := 0;
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
  -- 271: no duplica pagos que ya estan cargados por la app (origen distinto de 'sheet'); ver el encabezado de la 271.
  insert into public.fin_pagos (cliente_id, fuente_id, sync_id, fila_planilla, fecha, programa, alumno, telefono,
    concepto, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente, moneda_cobro, closer, setter,
    comprobante, quien_recibe, metodo_pago, monto_restante, estado, comprobantes_extra,  -- 196: comprobantes_extra
    nota, email, fuente_email, fuente_lead)  -- 209: nota, email, fuente_email (planilla de Agus)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha, x.programa, x.alumno, x.telefono,
         x.concepto, x.monto_usd, x.monto_origen, x.moneda_origen, x.tc_usado, x.tc_fuente, x.moneda_cobro, x.closer, x.setter,
         x.comprobante, x.quien_recibe, x.metodo_pago, x.monto_restante, x.estado,
         case when jsonb_typeof(x.comprobantes_extra) = 'array' then x.comprobantes_extra else '[]'::jsonb end,  -- 196
         x.nota, x.email, x.fuente_email, x.fuente_lead  -- 209
  from (
    select y.*,
           row_number() over (partition by y.h271 order by y.fila_planilla) as o271
    from (
      select r.*, public.fin_pago_huella(v_fuente.cliente_id, r.fecha, r.alumno, r.monto_usd, r.concepto) as h271
      from jsonb_to_recordset(coalesce(p_datos -> 'pagos', '[]'::jsonb)) as r(
        fila_planilla int, fecha date, programa text, alumno text, telefono text, concepto text, monto_usd numeric,
        monto_origen numeric, moneda_origen text, tc_usado numeric, tc_fuente text, moneda_cobro text, closer text,
        setter text, comprobante text, quien_recibe text, metodo_pago text, monto_restante numeric, estado text,
        comprobantes_extra jsonb, nota text, email text, fuente_email text, fuente_lead text)
    ) y
  ) x
  where x.o271 > (select count(*) from public.fin_pagos a                              -- 271: misma huella ya cargada en la app
                   where a.cliente_id = v_fuente.cliente_id and coalesce(a.origen, 'sheet') <> 'sheet' and a.huella = x.h271)
    and not exists (select 1 from public.fin_pagos a                                    -- 271: misma fila + fecha + monto ya cargada en la app
                     where a.cliente_id = v_fuente.cliente_id and coalesce(a.origen, 'sheet') <> 'sheet'
                       and a.fila_planilla = x.fila_planilla and a.fecha = x.fecha and a.monto_usd = x.monto_usd);
  get diagnostics n_pagos = row_count;
  n_en_app := coalesce(jsonb_array_length(p_datos -> 'pagos'), 0) - n_pagos;

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
                            'cuotas', n_cuotas, 'llamadas', n_llamadas, 'rechazadas', n_rech,
                            'pagos_ya_en_app', n_en_app);  -- 271
end $function$;

commit;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Reactivar la fuente de Pagos de Liam (SOLO si se decide volver a la hoja; ver el encabezado)
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';
lock table public.fin_fuentes in access exclusive mode;

do $g$
begin
  if pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) not like '%271: no duplica pagos%' then
    raise exception 'GUARDA 271: correr antes el BLOQUE 1 (sin el, la sync duplicaria los pagos de la app). No se toca nada.';
  end if;
  if (select count(*) from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos') <> 1 then
    raise exception 'GUARDA 271: se esperaba 1 fuente de pagos de liam.';
  end if;
  if not exists (select 1 from public.fin_alias_columnas a join public.fin_fuentes f on f.id = a.fuente_id
                  where f.cliente_id = 'liam' and f.tipo = 'pagos' and a.campo_canonico = 'fecha' and a.alias = '-') then
    raise exception 'GUARDA 271: falta el alias de fecha "-" en la fuente de Pagos de Liam (correr el BLOQUE 1).';
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 15, 30, 45) then
    raise exception 'GUARDA 271: no correr en los minutos 00, 15, 30 y 45 (corre la sync). Reintentar.';
  end if;
end
$g$;

create table if not exists public.fin_fuentes_respaldo_271 (
  fuente_id  bigint primary key,
  cortada_en timestamptz,
  activo     boolean,
  hecho_en   timestamptz not null default now()
);
alter table public.fin_fuentes_respaldo_271 enable row level security;
revoke all on public.fin_fuentes_respaldo_271 from anon, authenticated;
grant all on public.fin_fuentes_respaldo_271 to service_role;

insert into public.fin_fuentes_respaldo_271 (fuente_id, cortada_en, activo)
select id, cortada_en, activo from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos'
on conflict (fuente_id) do nothing;

update public.fin_fuentes set cortada_en = null, activo = true
 where cliente_id = 'liam' and tipo = 'pagos';

commit;

-- ---------------------------------------------------------------------
-- BLOQUE 3. Regla de fuente Webinar: vistas (no tocan fin_pagos)
-- ---------------------------------------------------------------------
do $g$
declare v text;
begin
  if to_regclass('public.fin_webinars') is null or to_regclass('public.fin_v_webinar_resultado') is null then
    raise exception 'GUARDA 271: falta la 267 (fin_webinars, fin_v_webinar_resultado).';
  end if;
  v := pg_get_viewdef('public.fin_v_webinar_resultado'::regclass);
  if v not like '%fin_webinar_ajustes%' or v not like '%cash_informado%' then
    raise exception 'GUARDA 271: fin_v_webinar_resultado no es la de la 267 (ni la de la 271). No se toca nada.';
  end if;
  if to_regprocedure('public.fin_dys_puede_ver()') is null or to_regprocedure('public.fin_gastos_puede_ver()') is null then
    raise exception 'GUARDA 271: faltan fin_dys_puede_ver / fin_gastos_puede_ver (174).';
  end if;
end
$g$;

-- Interna (sin permisos para la app): una fila por pago con su fuente final y el criterio.
create or replace view public.fin_pago_fuente_calc as
with base as (
  select p.id, p.cliente_id, p.clave, p.fecha, p.alumno, p.monto_usd, p.concepto, p.fila_planilla,
         nullif(btrim(p.fuente_lead), '') as lead_crudo,
         nullif(btrim(p.fuente_ingreso), '') as ingreso,
         (coalesce(p.nota, '') ilike '%fuente inferida%') as nota_inferida,
         btrim(regexp_replace(lower(translate(coalesce(p.alumno, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g')) as k
    from public.fin_pagos p
), ex as (
  select b.*,
         -- Webinar escrito por la regla vieja (nota "Fuente inferida"): no cuenta como marca explicita.
         case when b.lead_crudo is not null and b.nota_inferida
                   and (b.lead_crudo ilike '%webinar%' or b.lead_crudo ilike '%replay%') then null
              else b.lead_crudo end as lead_valido
    from base b
), prop as (
  select e.*,
         case when e.ingreso = 'Webinar' then 'Webinar' else coalesce(e.lead_valido, e.ingreso) end as fuente_explicita,
         exists (select 1 from public.fin_webinars w
                  where w.activo and w.cliente_id = e.cliente_id
                    and e.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)) as en_ventana
    from ex e
), prop2 as (
  select q.*, coalesce(q.fuente_explicita, case when q.en_ventana then 'Webinar' end) as fuente_propia
    from prop q
), primero as (
  select distinct on (cliente_id, k) cliente_id, k, id as primero_id
    from prop2
   where monto_usd > 0 and k <> ''
   order by cliente_id, k, fecha, fila_planilla nulls last, id
)
select q.id as pago_id, q.cliente_id, q.clave as pago_clave, q.fecha, q.alumno, q.monto_usd, q.concepto,
       q.lead_crudo as fuente_planilla,
       q.nota_inferida as fuente_inferida_vieja,
       q.fuente_explicita,
       f.clave as primer_pago_clave, f.fecha as primer_pago_fecha,
       case when q.fuente_explicita is not null then q.fuente_explicita
            when f.id is null or f.id = q.id then case when q.en_ventana then 'Webinar' end
            else f.fuente_propia end as fuente_final,
       case when q.fuente_explicita is not null then 'explicita en la planilla'
            when f.id is null then case when q.en_ventana then 'sin primer pago identificable: cae en ventana de webinar' else 'sin dato' end
            when f.id = q.id then case when q.en_ventana then 'primer pago dentro de la ventana de un webinar' else 'primer pago fuera de toda ventana: sin dato' end
            when f.fuente_propia is not null then 'hereda la fuente del primer pago'
            else 'hereda del primer pago, que no tiene fuente' end as criterio,
       (coalesce(case when q.fuente_explicita is not null then q.fuente_explicita
                      when f.id is null or f.id = q.id then case when q.en_ventana then 'Webinar' end
                      else f.fuente_propia end, '') ilike '%webinar%'
        or coalesce(case when q.fuente_explicita is not null then q.fuente_explicita
                         when f.id is null or f.id = q.id then case when q.en_ventana then 'Webinar' end
                         else f.fuente_propia end, '') ilike '%replay%') as es_webinar
  from prop2 q
  left join primero pr on pr.cliente_id = q.cliente_id and pr.k = q.k
  left join prop2 f on f.id = pr.primero_id;

comment on view public.fin_pago_fuente_calc is
  '271: fuente de cada pago con la regla nueva (explicita en la planilla, o primer pago dentro de la ventana de un webinar, o heredada del primer pago). Interna, sin permisos para la app. No toca fin_pagos.';

-- Publica: la ve quien ve Dystopia o Gastos (como fin_v_webinar_resultado).
create or replace view public.fin_v_pago_fuente as
select * from public.fin_pago_fuente_calc
 where public.fin_dys_puede_ver() or public.fin_gastos_puede_ver();

comment on view public.fin_v_pago_fuente is
  '271: igual a fin_pago_fuente_calc pero solo para quien ve Dystopia o Gastos.';

revoke all on public.fin_pago_fuente_calc, public.fin_v_pago_fuente from public, anon, authenticated;
grant select on public.fin_v_pago_fuente to authenticated;
grant select on public.fin_pago_fuente_calc, public.fin_v_pago_fuente to service_role;

-- fin_v_webinar_resultado = la de la 267 (mismas columnas) con los ingresos por la regla nueva.
create or replace view public.fin_v_webinar_resultado as
select w.id as webinar_id, w.cliente_id, w.nombre, w.fecha, w.fecha_replay, w.ventana_dias,
       coalesce(w.ventana_desde, w.fecha) as ventana_desde,
       coalesce(w.ventana_hasta, w.fecha + w.ventana_dias) as ventana_hasta,
       w.registrados, w.asistentes, w.compradores, w.llamadas, w.cash_informado, w.nota,
       coalesce(pg.usd, 0) as ingreso_pagos_usd, coalesce(pg.n, 0) as pagos_n,
       coalesce(aj.cash, 0) as ingreso_ajustes_usd,
       coalesce(aj.probable, 0) as ingreso_probable_usd,
       coalesce(pg.usd, 0) + coalesce(aj.cash, 0) as cash_usd,
       coalesce(gs.total, 0) as gastos_usd,
       coalesce(gs.ads, 0) as ads_usd,
       coalesce(gs.en_opps, 0) as gastos_en_opps_usd,
       coalesce(pg.usd, 0) + coalesce(aj.cash, 0) - coalesce(gs.total, 0) as ganancia_usd,
       coalesce(pg.usd, 0) + coalesce(aj.cash, 0) + coalesce(aj.probable, 0) - coalesce(gs.total, 0) as ganancia_con_probables_usd,
       round((coalesce(pg.usd, 0) + coalesce(aj.cash, 0)) / nullif(coalesce(gs.ads, 0), 0), 2) as roas,
       case when w.cash_informado is null then null
            else coalesce(pg.usd, 0) + coalesce(aj.cash, 0) - w.cash_informado end as cash_vs_informado_usd
  from public.fin_webinars w
  left join lateral (
    -- 271: pagos de la ventana cuya fuente FINAL (regla nueva) es Webinar / Replay
    select sum(v.monto_usd) as usd, count(*) as n
      from public.fin_pago_fuente_calc v
     where v.cliente_id = w.cliente_id
       and v.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)
       and v.es_webinar
  ) pg on true
  left join lateral (
    select sum(coalesce(p.monto_usd, a.monto_usd)) filter (where a.tipo <> 'venta_probable') as cash,
           sum(coalesce(p.monto_usd, a.monto_usd)) filter (where a.tipo = 'venta_probable') as probable
      from public.fin_webinar_ajustes a
      left join public.fin_pagos p on p.cliente_id = w.cliente_id and p.clave = a.pago_clave
     where a.webinar_id = w.id and a.activo
       -- un pago asignado a mano que ya entra por su fuente dentro de la ventana no se cuenta dos veces
       and not (p.id is not null
                and p.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)
                and exists (select 1 from public.fin_pago_fuente_calc v where v.pago_id = p.id and v.es_webinar))
  ) aj on true
  left join lateral (
    select sum(g.monto_usd) as total,
           sum(g.monto_usd) filter (where g.concepto in ('ads_webinar', 'ads_replay')) as ads,
           sum(g.monto_usd) filter (where g.en_opps) as en_opps
      from public.fin_webinar_gastos g
     where g.webinar_id = w.id and g.activo
  ) gs on true
 where w.activo and (public.fin_dys_puede_ver() or public.fin_gastos_puede_ver());

-- ---------------------------------------------------------------------
-- BLOQUE 4. Humo de la regla (se revierte solo: termina SIEMPRE en ERROR "HUMO 271 REGLA OK")
-- ---------------------------------------------------------------------
do $h$
declare
  v_f bigint; v_web bigint; r record; v_n int; v_usd numeric;
begin
  select id into v_f from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' order by id limit 1;
  if v_f is null then raise exception 'HUMO 271: liam no tiene fuente de pagos'; end if;

  insert into public.fin_webinars (cliente_id, nombre, fecha) values ('liam', 'HUMO 271', date '2030-01-01') returning id into v_web;

  insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, concepto, monto_usd, monto_origen, moneda_origen,
                                tc_usado, tc_fuente, nota, fuente_lead, origen, importado_en)
  values
    ('liam', v_f, 990001, date '2030-01-02', 'Humo Nuevo',  'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990002, date '2030-03-01', 'Humo Nuevo',  'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990003, date '2029-12-01', 'Humo Viejo',  'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990004, date '2030-01-03', 'Humo Viejo',  'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990005, date '2029-12-02', 'Humo Inf',    'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990006, date '2030-01-05', 'Humo Inf',    'FEE',  50,  50, 'USD', 1, 'planilla', 'Fuente inferida 01/11: webinar por regla', 'webinar', 'app', now()),
    ('liam', v_f, 990007, date '2029-12-03', 'Humo Marc',   'PIF', 100, 100, 'USD', 1, 'planilla', null, null, 'app', now()),
    ('liam', v_f, 990008, date '2030-01-06', 'Humo Marc',   'FEE',  50,  50, 'USD', 1, 'planilla', null, 'webinar', 'app', now()),
    ('liam', v_f, 990009, date '2029-12-04', 'Humo Insta',  'PIF', 100, 100, 'USD', 1, 'planilla', null, 'instagram', 'app', now()),
    ('liam', v_f, 990010, date '2030-01-07', 'Humo Insta',  'FEE',  50,  50, 'USD', 1, 'planilla', null, null, 'app', now());

  -- Esperado por fila: es_webinar. 1 y 2 si (primer pago en ventana y su cuota), 8 si (marca explicita), el resto no.
  for r in
    select p.fila_planilla, c.es_webinar, c.fuente_final
      from public.fin_pago_fuente_calc c
      join public.fin_pagos p on p.id = c.pago_id
     where p.fila_planilla between 990001 and 990010 and p.cliente_id = 'liam'
  loop
    if r.es_webinar is distinct from (r.fila_planilla in (990001, 990002, 990008)) then
      raise exception 'HUMO 271: la fila % dio es_webinar % y no era lo esperado', r.fila_planilla, r.es_webinar;
    end if;
    if r.fila_planilla = 990010 and r.fuente_final is distinct from 'instagram' then
      raise exception 'HUMO 271: la cuota de Humo Insta tenia que heredar instagram y dio %', coalesce(r.fuente_final, 'nada');
    end if;
  end loop;

  select count(*), coalesce(sum(c.monto_usd), 0) into v_n, v_usd
    from public.fin_pago_fuente_calc c
   where c.cliente_id = 'liam' and c.es_webinar and c.fecha between date '2030-01-01' and date '2030-01-15';
  if v_n <> 2 or v_usd <> 150 then
    raise exception 'HUMO 271: la ventana tenia que sumar 2 pagos y 150, dio % pagos y %', v_n, v_usd;
  end if;

  raise exception 'HUMO 271 REGLA OK';
end
$h$;

-- ---------------------------------------------------------------------
-- BLOQUE 5. Humo de la sync sin duplicar (se revierte solo: termina SIEMPRE en ERROR "HUMO 271 SYNC OK")
-- ---------------------------------------------------------------------
do $h$
declare
  v_f bigint; v_c bigint; v_res jsonb; v_n int;
begin
  select id into v_f from public.fin_fuentes where cliente_id = 'liam' and tipo = 'pagos' order by id limit 1;
  if v_f is null then raise exception 'HUMO 271: liam no tiene fuente de pagos'; end if;
  if pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) not like '%271: no duplica pagos%' then
    raise exception 'HUMO 271: falta el BLOQUE 1';
  end if;

  -- (dentro de la prueba la fuente se activa; si ya lo estaba no cambia nada, y todo se revierte)
  update public.fin_fuentes set cortada_en = null, activo = true where id = v_f;

  -- Un pago ya cargado por la app, y la hoja trae ese mismo (misma fila) mas uno nuevo.
  insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, concepto, monto_usd, monto_origen, moneda_origen,
                                tc_usado, tc_fuente, origen, importado_en)
  values ('liam', v_f, 990101, date '2030-02-01', 'Humo Sync', 'FEE', 123.45, 123.45, 'USD', 1, 'planilla', 'app', now());

  insert into public.fin_sync_corridas (fuente_id, estado, invocacion) values (v_f, 'en_curso', gen_random_uuid()) returning id into v_c;

  v_res := public.fin_sync_escribir(v_c, 'ok', 'humo', 'humo', '[]'::jsonb, 2, 0, jsonb_build_object('pagos', jsonb_build_array(
    jsonb_build_object('fila_planilla', 990101, 'fecha', '2030-02-01', 'alumno', 'humo  sync', 'concepto', 'fee', 'monto_usd', 123.45,
                       'monto_origen', 123.45, 'moneda_origen', 'USD', 'tc_usado', 1, 'tc_fuente', 'planilla'),
    jsonb_build_object('fila_planilla', 990102, 'fecha', '2030-02-02', 'alumno', 'Humo Sync Nuevo', 'concepto', 'FEE', 'monto_usd', 10,
                       'monto_origen', 10, 'moneda_origen', 'USD', 'tc_usado', 1, 'tc_fuente', 'planilla'))));

  if (v_res ->> 'pagos')::int <> 1 or (v_res ->> 'pagos_ya_en_app')::int <> 1 then
    raise exception 'HUMO 271: la sync tenia que insertar 1 y omitir 1 y devolvio %', v_res::text;
  end if;
  select count(*) into v_n from public.fin_pagos where cliente_id = 'liam' and alumno ilike 'humo sync%';
  if v_n <> 2 then raise exception 'HUMO 271: tenia que haber 2 pagos de prueba y hay %', v_n; end if;
  select count(*) into v_n from public.fin_pagos where cliente_id = 'liam' and alumno = 'Humo Sync Nuevo' and origen = 'sheet';
  if v_n <> 1 then raise exception 'HUMO 271: el pago nuevo de la hoja no entro como origen sheet'; end if;

  raise exception 'HUMO 271 SYNC OK';
end
$h$;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- =====================================================================

-- C1. La sync esta instalada. Esperado: true y true.
-- select pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%271: no duplica pagos%' as sync_271,
--        to_regclass('public.fin_pago_fuente_calc') is not null as vista_calc;

-- C2. Pagos por cliente y mes, julio a noviembre, contra lo esperado de la auditoria del 2/11. Esperado: ok = true en todas
--     (Liam octubre 62 / 70.431,36 y Teo octubre 20 / 11.937 salen DESPUES de reactivar Liam, aceptar encabezados y esperar la sync).
-- with real as (
--   select cliente_id, to_char(date_trunc('month', fecha), 'YYYY-MM') as mes, count(*) as n, round(sum(monto_usd), 2) as usd
--     from public.fin_pagos where fecha >= date '2026-07-01' and fecha < date '2026-12-01' group by 1, 2
-- ), esp(cliente_id, mes, n, usd) as (values
--   ('liam','2026-07',33,26562.30), ('liam','2026-08',33,35855.50), ('liam','2026-09',58,61755.90), ('liam','2026-10',62,70431.36),
--   ('agus','2026-07',90,73649.40), ('agus','2026-08',104,96544.70), ('agus','2026-09',108,105443.00), ('agus','2026-10',119,116847.00), ('agus','2026-11',7,6660.00),
--   ('teo','2026-07',34,20814.24), ('teo','2026-08',27,15729.90), ('teo','2026-09',31,23573.50), ('teo','2026-10',20,11937.00)
-- )
-- select coalesce(r.cliente_id, e.cliente_id) as cliente, coalesce(r.mes, e.mes) as mes, r.n as pagos, r.usd, e.n as esperado_n, e.usd as esperado_usd,
--        (r.n is not distinct from e.n and r.usd is not distinct from e.usd) as ok
--   from real r full join esp e on e.cliente_id = r.cliente_id and e.mes = r.mes
--  where r.cliente_id in ('liam','agus','teo') or e.cliente_id is not null order by 1, 2;

-- C3. Sin duplicados entre la app y la hoja (Liam y todos). Esperado: 0 filas.
-- select cliente_id, huella, count(*) filter (where origen = 'sheet') as de_hoja, count(*) filter (where origen <> 'sheet') as de_app
--   from public.fin_pagos group by 1, 2
-- having count(*) filter (where origen = 'sheet') > 0 and count(*) filter (where origen <> 'sheet') > 0;

-- C3b. Posibles duplicados con texto editado: pago de la hoja y pago de la app en la MISMA fila de planilla. Esperado: 0 filas.
--      Si aparece alguno, la hoja cambio el alumno/fecha/monto/concepto despues de la importacion: decidir cual queda (no se borra nada solo).
-- select s.cliente_id, s.fila_planilla, s.fecha as fecha_hoja, s.alumno as alumno_hoja, s.monto_usd as monto_hoja,
--        a.fecha as fecha_app, a.alumno as alumno_app, a.monto_usd as monto_app
--   from public.fin_pagos s join public.fin_pagos a on a.cliente_id = s.cliente_id and a.fila_planilla = s.fila_planilla
--  where s.origen = 'sheet' and a.origen <> 'sheet' order by 1, 2;

-- C4. Estado de las fuentes de Pagos de Liam y Teo y su ultima corrida. Esperado despues de todo: activo true, cortada_en null (Liam), estado ok o revisar.
-- select f.cliente_id, f.id, f.activo, f.cortada_en, c.estado, c.inicio, left(c.mensaje, 160) as mensaje
--   from public.fin_fuentes f
--   left join lateral (select * from public.fin_sync_corridas c where c.fuente_id = f.id order by c.inicio desc limit 1) c on true
--  where f.tipo = 'pagos' and f.cliente_id in ('liam', 'teo') order by f.cliente_id;

-- C5. Teo julio: la fila 178 ya no esta rechazada. Esperado: 0 filas en rechazadas de ambiguo y 1 pago de 1254,11.
-- select (select count(*) from public.fin_filas_rechazadas r join public.fin_fuentes f on f.id = r.fuente_id
--          where f.cliente_id = 'teo' and f.tipo = 'pagos' and r.fila_planilla = 178) as rechazadas_f178,
--        (select count(*) from public.fin_pagos where cliente_id = 'teo' and fila_planilla = 178 and monto_usd = 1254.11) as pago_f178;

-- C6. FUENTES DE AGUS EN OCTUBRE, ANTES (fuente_lead tal cual la hoja) Y DESPUES (regla nueva). Esperado antes: webinar 64 / 63.953;
--     despues (calculado sobre la planilla del 2/11): webinar 54 / 52.253 y 10 pagos / 11.700 sin fuente.
-- select coalesce(a.fuente, d.fuente) as fuente, a.n as antes_n, a.usd as antes_usd, d.n as despues_n, d.usd as despues_usd
--   from (select coalesce(lower(btrim(fuente_lead)), '(sin fuente)') as fuente, count(*) as n, sum(monto_usd) as usd
--           from public.fin_pagos where cliente_id = 'agus' and fecha >= date '2026-10-01' and fecha < date '2026-11-01' group by 1) a
--   full join (select case when es_webinar then 'webinar' else coalesce(lower(btrim(fuente_final)), '(sin fuente)') end as fuente, count(*) as n, sum(monto_usd) as usd
--           from public.fin_pago_fuente_calc where cliente_id = 'agus' and fecha >= date '2026-10-01' and fecha < date '2026-11-01' group by 1) d
--     on d.fuente = a.fuente order by coalesce(a.usd, d.usd) desc;

-- C7. Los pagos de Agus que dejan de ser Webinar y por que. Esperado: 10 filas / 11.700, todas con fuente_inferida_vieja = true.
-- select pago_clave, fecha, alumno, concepto, monto_usd, fuente_planilla, fuente_inferida_vieja, primer_pago_fecha, criterio
--   from public.fin_pago_fuente_calc
--  where cliente_id = 'agus' and fecha >= date '2026-10-01' and fecha < date '2026-11-01'
--    and lower(coalesce(fuente_planilla, '')) like '%webinar%' and not es_webinar order by fecha, alumno;

-- C8. Resultado de los webinars de AF 25/10 y BPF 14/10, ANTES (regla vieja: fuente webinar/replay en la hoja) y DESPUES (vista nueva).
--     Pegar el uuid de un fundador. Esperado AF 25/10 (planilla 2/11): antes 42 pagos / 43.154, despues 47 / 48.214 (suma pagos de noviembre
--     de la ventana que la regla vieja no marcaba); BPF 14/10: antes 17 / 13.699,36, despues 19 / 15.099,36.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select w.nombre, w.fecha, w.ventana_desde, w.ventana_hasta,
--        (select count(*) from public.fin_pagos p where p.cliente_id = w.cliente_id and p.fecha between w.ventana_desde and w.ventana_hasta
--           and (p.fuente_ingreso = 'Webinar' or p.fuente_lead ilike '%webinar%' or p.fuente_lead ilike '%replay%')) as antes_pagos,
--        (select sum(p.monto_usd) from public.fin_pagos p where p.cliente_id = w.cliente_id and p.fecha between w.ventana_desde and w.ventana_hasta
--           and (p.fuente_ingreso = 'Webinar' or p.fuente_lead ilike '%webinar%' or p.fuente_lead ilike '%replay%')) as antes_usd,
--        w.pagos_n as despues_pagos, w.ingreso_pagos_usd as despues_usd, w.cash_usd, w.gastos_usd, w.ganancia_usd, w.roas, w.cash_informado, w.cash_vs_informado_usd
--   from public.fin_v_webinar_resultado w where w.nombre in ('AF 25/10', 'BPF 14/10', 'AF 20/09') order by w.fecha;
-- (misma sesion o ejecucion que el set_config)

-- C9. Primeros pagos que caen en una ventana SIN marca explicita (los que la regla hace Webinar por ser clientes nuevos). Revisar nombres
--     que puedan ser el mismo alumno escrito distinto (la regla identifica al alumno por su nombre normalizado).
-- select cliente_id, fecha, alumno, concepto, monto_usd, primer_pago_fecha from public.fin_pago_fuente_calc
--  where fuente_explicita is null and es_webinar and pago_clave = primer_pago_clave order by cliente_id, fecha, alumno;

-- C10. Seguridad: anon y public sin acceso a las vistas nuevas. Esperado: 0 filas.
-- select grantee, table_name, privilege_type from information_schema.role_table_grants
--  where table_schema = 'public' and grantee in ('anon', 'PUBLIC', 'authenticated') and table_name = 'fin_pago_fuente_calc';

-- =====================================================================
-- VUELTA ATRAS
-- =====================================================================
-- 1) Volver a cortar Liam: update public.fin_fuentes f set cortada_en = r.cortada_en, activo = r.activo
--      from public.fin_fuentes_respaldo_271 r where r.fuente_id = f.id;
-- 2) fin_sync_escribir: volver a correr la seccion 3 de migraciones/209_agus_pagos_mail_nota.sql (la funcion entera).
-- 3) Webinars: volver a correr el create or replace de fin_v_webinar_resultado de la 267, y despues
--      drop view if exists public.fin_v_pago_fuente; drop view if exists public.fin_pago_fuente_calc;
-- 4) drop table if exists public.fin_fuentes_respaldo_271;  (los alias que agrego el BLOQUE 1 ya estaban en la 236: no se borran)
