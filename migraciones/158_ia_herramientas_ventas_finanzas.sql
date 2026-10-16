-- =====================================================================
-- 158 · DYSTOPITA EN FINANZAS Y VENTAS: HERRAMIENTAS DE CONSULTA (SOLO LECTURA)
-- Numero asignado por el jefe (16/10). NO corrida. Documentacion para quien las conecta a
-- la Edge Function ia-preguntar: docs/dystopita-herramientas.md
--
-- Que hace
--   Siete funciones "herramienta" que devuelven un resumen CORTO en jsonb (no tablas enteras)
--   para que el chat interno (Dystopita) responda preguntas de Ventas y Finanzas:
--     VENTAS     ia_chat_ventas_resumen  llamadas agendadas / presentadas / cerradas por cliente y mes
--                ia_chat_ventas_equipo   lo mismo por closer o por setter
--                ia_chat_ventas_leads    leads por nivel de la calificacion de IA (147/154)
--     FINANZAS   ia_chat_fin_cobros      lo cobrado (neto de devoluciones) por cliente, mes, concepto, programa y closer
--                ia_chat_fin_resultado   ingresos, gastos y net cash flow por cliente y mes
--                ia_chat_fin_deudas      cuotas pendientes / vencidas (cobranzas)
--                ia_chat_fin_pagos       ultimos pagos (de un alumno, un periodo o un cliente)
--   y tres ayudantes: ia_chat_rol, ia_chat_periodo, ia_chat_cliente (+ ia_chat_clientes_ok, ia_chat_solo_panel).
--
-- DECISION DE DISENO (se aparta de lo pedido, explicada): las funciones son SECURITY INVOKER, no
--   SECURITY DEFINER. Leen las MISMAS tablas y vistas que la app (fin_pagos, fin_pnl, fin_llamadas,
--   fin_v_llamadas_clasificadas, fin_v_cobranzas, fin_v_llamadas_calificadas, todas con RLS o
--   security_invoker), asi que cada rol recibe EXACTAMENTE lo que ya puede ver: no hay una segunda
--   copia de las reglas de permiso que pueda desviarse. Con DEFINER habria que reescribir a mano
--   las politicas de cada tabla (closer por alias, setter, finanzas/ventas por asignacion, cliente
--   por acceso) y cualquier cambio futuro de RLS dejaria la IA viendo de mas. Ademas de la RLS,
--   cada funcion valida el rol (fundador, cliente, closer, setter, finanzas, ventas; si no, 42501)
--   y aplica dos recortes que la app ya hace en el front:
--     - ingresos/gastos (P&L): solo clientes donde fin_ve_plata() es true.
--     - cobros, deudas y pagos: no para un cliente "solo panel" (rol cliente en un cliente por areas
--       que no puede cargar pagos: el front no le muestra Pagos ni Cobranzas). Setter y ventas
--       tampoco ven cobranzas (igual que veCobranzas del front).
--   Nunca escribe, nunca devuelve telefonos ni emails. Montos en USD, como la app.
--
-- Errores: 42501 = sin permiso / sin sesion; 22023 = parametro invalido (mensaje en castellano, seguro de mostrar).
-- Fechas: el periodo es [p_desde, p_hasta] inclusive. Sin fechas = este mes (zona Argentina). Ventas:
--   hasta el fin de mes (cuenta tambien las llamadas ya agendadas para despues de hoy); Finanzas: hasta hoy.
--   Maximo ~26 meses.
--
-- Sin begin/commit (SQL Editor). Idempotente (create or replace). Correr los bloques de a uno, fuera de
-- :00/:15/:30/:45 y de las 9:00 (la sync lee estas tablas). No toca ninguna tabla ni vista existente.
-- Controles al final, de a uno. Vuelta atras al final.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (solo lectura; si algo falta, aborta sin crear nada)
-- ---------------------------------------------------------------------
do $g$
declare f text;
begin
  foreach f in array array['public.fin_pagos', 'public.fin_pnl', 'public.fin_llamadas', 'public.fin_v_llamadas_clasificadas',
                           'public.fin_v_cobranzas', 'public.fin_v_llamadas_calificadas', 'public.crm_clients'] loop
    if to_regclass(f) is null then
      raise exception '158: falta %', f;
    end if;
  end loop;
  foreach f in array array['rol_actual', 'fin_ve_plata', 'fin_puede_cargar', 'fin_cliente_por_areas',
                           'fin_setter_de_llamada', 'fin_nombre_vendedor'] loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = f) then
      raise exception '158: falta la funcion %', f;
    end if;
  end loop;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_llamadas' and column_name = 'estado_agenda') then
    raise exception '158: falta fin_llamadas.estado_agenda (131)';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_v_llamadas_calificadas' and column_name = 'cal_nivel') then
    raise exception '158: falta fin_v_llamadas_calificadas.cal_nivel (147)';
  end if;
  raise notice 'M158 guardas OK';
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Ayudantes y herramientas
-- ---------------------------------------------------------------------

-- Rol del usuario; corta si no hay sesion o el rol no entra a Finanzas/Ventas.
create or replace function public.ia_chat_rol()
returns text
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text;
begin
  if auth.uid() is null then
    raise exception 'ia_chat: sin sesion' using errcode = '42501';
  end if;
  v_rol := public.rol_actual();
  if v_rol is null or v_rol not in ('fundador', 'cliente', 'closer', 'setter', 'finanzas', 'ventas') then
    raise exception 'ia_chat: tu rol no puede usar el chat de Ventas y Finanzas' using errcode = '42501';
  end if;
  return v_rol;
end
$fn$;

-- Periodo [desde, hasta]. Sin fechas: este mes. p_hasta_fin_de_mes: el hasta por defecto es el ultimo dia del mes
-- (Ventas, que cuenta llamadas futuras) en vez de hoy (Finanzas).
create or replace function public.ia_chat_periodo(p_desde date, p_hasta date, p_hasta_fin_de_mes boolean default false)
returns table (desde date, hasta date)
language plpgsql stable
set search_path = public
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_d date;
  v_h date;
begin
  v_d := coalesce(p_desde, date_trunc('month', coalesce(p_hasta, v_hoy)::timestamp)::date);
  v_h := coalesce(p_hasta, case when p_hasta_fin_de_mes
                                then (date_trunc('month', v_d::timestamp) + interval '1 month')::date - 1
                                else v_hoy end);
  if v_d > v_h then
    raise exception 'el periodo es invalido: desde (%) es posterior a hasta (%)', v_d, v_h using errcode = '22023';
  end if;
  if v_h - v_d > 800 then
    raise exception 'el periodo es demasiado largo (maximo unos 26 meses)' using errcode = '22023';
  end if;
  return query select v_d, v_h;
end
$fn$;

-- Cliente por id o nombre (sin importar mayusculas). null = todos los que el usuario ve (la RLS recorta).
create or replace function public.ia_chat_cliente(p_cliente text)
returns text
language plpgsql stable
set search_path = public
as $fn$
declare
  v text := nullif(lower(btrim(coalesce(p_cliente, ''))), '');
  v_id text;
begin
  if v is null then
    return null;
  end if;
  select c.id into v_id from public.crm_clients c where lower(c.id) = v or lower(c.nombre) = v limit 1;
  if v_id is null then
    raise exception 'no encontre el cliente "%" o no tenes acceso', left(v, 40) using errcode = '22023';
  end if;
  return v_id;
end
$fn$;

-- Cliente "solo panel" (mismo criterio que soloPanel() del front, por cliente): rol cliente en un cliente por areas
-- que no puede cargar pagos. Ese usuario no ve Pagos ni Cobranzas en la app.
create or replace function public.ia_chat_solo_panel(p_cliente text)
returns boolean
language sql stable
set search_path = public
as $fn$
  select public.rol_actual() = 'cliente'
     and coalesce(public.fin_cliente_por_areas(p_cliente), false)
     and not coalesce(public.fin_puede_cargar(p_cliente), false)
$fn$;

-- Clientes sobre los que puede consultar segun el modo:
--   'plata' = donde fin_ve_plata (ingresos y gastos); 'pagos' = donde no es "solo panel" (cobros, deudas, pagos).
-- Si queda vacio, corta con 42501.
create or replace function public.ia_chat_clientes_ok(p_cliente text, p_modo text)
returns text[]
language plpgsql stable
set search_path = public
as $fn$
declare
  v_ids text[];
begin
  select coalesce(array_agg(c.id order by c.id), '{}'::text[]) into v_ids
    from public.crm_clients c
   where (p_cliente is null or c.id = p_cliente)
     and case when p_modo = 'plata' then coalesce(public.fin_ve_plata(c.id), false)
              else not public.ia_chat_solo_panel(c.id) end;
  if cardinality(v_ids) = 0 then
    raise exception 'tu rol no ve %', case when p_modo = 'plata' then 'los ingresos y gastos' else 'los pagos ni las cobranzas' end
      || case when p_cliente is null then '' else ' de ese cliente' end
      using errcode = '42501';
  end if;
  return v_ids;
end
$fn$;

-- ---------------------------------------------------------------------
-- VENTAS 1. Llamadas del periodo: agendadas, presentadas, cierres. Total, por cliente y por mes.
--   Mismas definiciones que fin_v_metricas_ventas (excluye duplicadas, 115). agendadas_total = TODAS las llamadas con
--   fecha en el periodo (ya ocurridas + a futuro). show_up_pct = presentadas / (presentadas + no show);
--   cierre_pct = cerradas / presentadas. cash_en_data_usd es lo anotado en Data (atribucion), NO el cash real: ese
--   sale de los pagos (ia_chat_fin_cobros).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_ventas_resumen(
  p_cliente text default null, p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_d date;
  v_h date;
begin
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, true) p;
  return (
    with base as (
      select k.cliente_id, k.periodo, k.es_futura, k.es_agendada, k.es_presentada, k.es_no_show,
             k.es_regenda_o_cancelada, k.es_calificada, k.es_cerrada, k.cc_cobrado,
             (l.estado_agenda = 'cancelada') as cancelada
        from public.fin_v_llamadas_clasificadas k
        join public.fin_llamadas l on l.id = k.id
       where k.fecha_llamada between v_d and v_h
         and (v_cli is null or k.cliente_id = v_cli)
    ), cm as (
      select cliente_id, periodo,
             count(*)                                             as agendadas_total,
             count(*) filter (where es_agendada)                  as ya_ocurridas,
             count(*) filter (where es_futura)                    as a_futuro,
             count(*) filter (where es_presentada)                as presentadas,
             count(*) filter (where es_no_show)                   as no_show,
             count(*) filter (where es_regenda_o_cancelada)       as regendadas_canceladas,
             count(*) filter (where es_agendada and es_calificada) as calificadas,
             count(*) filter (where es_cerrada)                   as cerradas,
             count(*) filter (where cancelada)                    as canceladas_en_agenda,
             coalesce(sum(cc_cobrado) filter (where es_agendada), 0) as cash_en_data_usd
        from base
       group by cliente_id, periodo
    ), g as (
      select cliente_id, periodo, grouping(cliente_id, periodo) as nivel,
             coalesce(sum(agendadas_total), 0)::int       as agendadas_total,
             coalesce(sum(ya_ocurridas), 0)::int          as ya_ocurridas,
             coalesce(sum(a_futuro), 0)::int              as a_futuro,
             coalesce(sum(presentadas), 0)::int           as presentadas,
             coalesce(sum(no_show), 0)::int               as no_show,
             coalesce(sum(regendadas_canceladas), 0)::int as regendadas_canceladas,
             coalesce(sum(calificadas), 0)::int           as calificadas,
             coalesce(sum(cerradas), 0)::int              as cerradas,
             coalesce(sum(canceladas_en_agenda), 0)::int  as canceladas_en_agenda,
             round(coalesce(sum(cash_en_data_usd), 0), 2) as cash_en_data_usd
        from cm
       group by grouping sets ((), (cliente_id), (periodo))
    ), r as (
      select g.*,
             round(100.0 * presentadas / nullif(presentadas + no_show, 0), 1) as show_up_pct,
             round(100.0 * cerradas / nullif(presentadas, 0), 1)              as cierre_pct
        from g
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'cliente', v_cli,
      'total', (select to_jsonb(t) - array['nivel', 'cliente_id', 'periodo'] from r t where t.nivel = 3),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'periodo'] order by t.agendadas_total desc, t.cliente_id)
                                 from r t where t.nivel = 1), '[]'::jsonb),
      'por_mes', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'cliente_id'] order by t.periodo)
                             from r t where t.nivel = 2), '[]'::jsonb),
      'nota', 'agendadas_total cuenta todas las llamadas con fecha en el periodo (ya ocurridas + a futuro); canceladas_en_agenda son las que la agenda marco como canceladas (siguen sumando, igual que en la app).'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- VENTAS 2. Por closer o por setter (p_tipo). p_nombre filtra por nombre parcial. Top 25 por agendadas.
--   Los setters son las llamadas ATRIBUIDAS a un setter (fuente de setter + mes con setter determinado): no es todo
--   su trabajo (igual que fin_v_metricas_setter).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_ventas_equipo(
  p_cliente text default null, p_desde date default null, p_hasta date default null,
  p_tipo text default 'closer', p_nombre text default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol  text := public.ia_chat_rol();
  v_cli  text := public.ia_chat_cliente(p_cliente);
  v_tipo text := lower(btrim(coalesce(p_tipo, 'closer')));
  v_nom  text := nullif(lower(btrim(coalesce(p_nombre, ''))), '');
  v_d date;
  v_h date;
begin
  if v_tipo not in ('closer', 'setter') then
    raise exception 'p_tipo debe ser closer o setter' using errcode = '22023';
  end if;
  if v_nom is not null then
    v_nom := replace(replace(replace(left(v_nom, 60), '\', '\\'), '%', '\%'), '_', '\_');
  end if;
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, true) p;
  return (
    with base as (
      select k.cliente_id, k.es_agendada, k.es_futura, k.es_presentada, k.es_no_show, k.es_cerrada, k.es_calificada,
             case when v_tipo = 'closer'
                  then coalesce(k.vendedor, k.closer_crudo)
                  else public.fin_nombre_vendedor(public.fin_setter_de_llamada(k.cliente_id, k.fecha_llamada, l.tipo_booking))
             end as persona
        from public.fin_v_llamadas_clasificadas k
        join public.fin_llamadas l on l.id = k.id
       where k.fecha_llamada between v_d and v_h
         and (v_cli is null or k.cliente_id = v_cli)
    ), por as (
      select cliente_id, persona,
             count(*)                                            as agendadas_total,
             count(*) filter (where es_agendada)                 as ya_ocurridas,
             count(*) filter (where es_presentada)               as presentadas,
             count(*) filter (where es_no_show)                  as no_show,
             count(*) filter (where es_agendada and es_calificada) as calificadas,
             count(*) filter (where es_cerrada)                  as cerradas
        from base
       where persona is not null and btrim(persona) <> ''
         and (v_nom is null or lower(persona) like '%' || v_nom || '%')
       group by cliente_id, persona
    ), top as (
      select p.*,
             round(100.0 * presentadas / nullif(presentadas + no_show, 0), 1) as show_up_pct,
             round(100.0 * cerradas / nullif(presentadas, 0), 1)              as cierre_pct
        from por p
       order by agendadas_total desc, persona
       limit 25
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'cliente', v_cli,
      'tipo', v_tipo,
      'llamadas_visibles_en_el_periodo', (select count(*) from base),
      'personas', coalesce((select jsonb_agg(to_jsonb(t) order by t.agendadas_total desc, t.persona) from top t), '[]'::jsonb),
      'nota', case when v_tipo = 'setter'
                   then 'Solo cuenta llamadas atribuidas a un setter (fuente de setter con setter determinado); no es todo su trabajo.'
                   else 'Un closer ve solo sus propias llamadas.' end
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- VENTAS 3. Leads y su calificacion de IA (147/154). p_nivel de la lista: caliente (defecto), tibio, frio,
--   sin_calificar o todos. Lista de hasta 10, por puntaje. Sin telefono ni email.
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_ventas_leads(
  p_cliente text default null, p_desde date default null, p_hasta date default null,
  p_nivel text default 'caliente')
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol   text := public.ia_chat_rol();
  v_cli   text := public.ia_chat_cliente(p_cliente);
  v_nivel text := lower(btrim(coalesce(p_nivel, 'caliente')));
  v_d date;
  v_h date;
begin
  if v_nivel not in ('caliente', 'tibio', 'frio', 'sin_calificar', 'todos') then
    raise exception 'p_nivel debe ser caliente, tibio, frio, sin_calificar o todos' using errcode = '22023';
  end if;
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, true) p;
  return (
    with base as (
      select c.cliente_id, c.fecha_llamada, c.nombre, c.closer, c.show_up, c.estado_llamada,
             coalesce(c.cal_nivel, 'sin_calificar') as nivel, c.cal_puntaje as puntaje, c.cal_motivo as motivo
        from public.fin_v_llamadas_calificadas c
        join public.fin_v_llamadas_clasificadas k on k.id = c.id     -- deja afuera las duplicadas (115)
       where c.fecha_llamada between v_d and v_h
         and (v_cli is null or c.cliente_id = v_cli)
         and coalesce(c.estado_agenda, '') <> 'cancelada'
    ), pc as (
      select cliente_id,
             count(*)                                       as leads,
             count(*) filter (where nivel = 'caliente')     as calientes,
             count(*) filter (where nivel = 'tibio')        as tibios,
             count(*) filter (where nivel = 'frio')         as frios,
             count(*) filter (where nivel = 'sin_calificar') as sin_calificar
        from base
       group by cliente_id
    ), lista as (
      select fecha_llamada as fecha, cliente_id, nombre, closer, nivel, puntaje, left(motivo, 200) as motivo, show_up, estado_llamada
        from base
       where v_nivel = 'todos' or nivel = v_nivel
       order by puntaje desc nulls last, fecha_llamada desc, nombre
       limit 10
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'cliente', v_cli,
      'total_leads', (select count(*) from base),
      'por_nivel', jsonb_build_object(
        'caliente',      (select count(*) from base where nivel = 'caliente'),
        'tibio',         (select count(*) from base where nivel = 'tibio'),
        'frio',          (select count(*) from base where nivel = 'frio'),
        'sin_calificar', (select count(*) from base where nivel = 'sin_calificar')),
      'puntaje_promedio', (select round(avg(puntaje), 1) from base where puntaje is not null),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(t) order by t.leads desc, t.cliente_id) from pc t), '[]'::jsonb),
      'nivel_de_la_lista', v_nivel,
      'leads', coalesce((select jsonb_agg(to_jsonb(t) order by t.puntaje desc nulls last, t.fecha desc, t.nombre) from lista t), '[]'::jsonb),
      'nota', 'La lista trae hasta 10 leads. Un lead sin calificar es uno que la IA todavia no puntuo (o sin respuestas de formulario).'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- FINANZAS 1. Cobros del periodo (tabla de pagos). neto_usd = cobrado + devoluciones (las devoluciones son pagos negativos).
--   Total, por cliente, por mes, y top 10 por concepto, programa y closer.
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_fin_cobros(
  p_cliente text default null, p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_ids text[] := public.ia_chat_clientes_ok(public.ia_chat_cliente(p_cliente), 'pagos');
  v_d date;
  v_h date;
begin
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, false) p;
  return (
    with base as (
      select p.cliente_id, to_char(p.fecha, 'YYYY-MM') as periodo, p.monto_usd,
             coalesce(nullif(btrim(p.concepto), ''), '(sin concepto)') as concepto,
             coalesce(nullif(btrim(p.programa), ''), '(sin programa)') as programa,
             coalesce(nullif(btrim(p.closer), ''), '(sin closer)')     as closer
        from public.fin_pagos p
       where p.fecha between v_d and v_h
         and p.cliente_id = any(v_ids)
    ), g as (
      select cliente_id, periodo, grouping(cliente_id, periodo) as nivel,
             round(coalesce(sum(monto_usd), 0), 2)                                       as neto_usd,
             round(coalesce(sum(monto_usd) filter (where monto_usd > 0), 0), 2)          as cobrado_usd,
             round(coalesce(sum(monto_usd) filter (where monto_usd < 0), 0), 2)          as devoluciones_usd,
             count(*) filter (where monto_usd > 0)                                       as pagos,
             count(*) filter (where monto_usd < 0)                                       as devoluciones
        from base
       group by grouping sets ((), (cliente_id), (periodo))
    )
    select jsonb_build_object(
      'periodo', jsonb_build_object('desde', v_d, 'hasta', v_h),
      'cliente', v_cli,
      'total', (select to_jsonb(t) - array['nivel', 'cliente_id', 'periodo'] from g t where t.nivel = 3),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'periodo'] order by t.neto_usd desc, t.cliente_id)
                                 from g t where t.nivel = 1), '[]'::jsonb),
      'por_mes', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'cliente_id'] order by t.periodo)
                             from g t where t.nivel = 2), '[]'::jsonb),
      'por_concepto', coalesce((select jsonb_agg(to_jsonb(x) order by x.neto_usd desc, x.concepto)
                                  from (select concepto, round(sum(monto_usd), 2) as neto_usd, count(*) as movimientos
                                          from base group by concepto order by sum(monto_usd) desc limit 10) x), '[]'::jsonb),
      'por_programa', coalesce((select jsonb_agg(to_jsonb(x) order by x.neto_usd desc, x.programa)
                                  from (select programa, round(sum(monto_usd), 2) as neto_usd, count(*) as movimientos
                                          from base group by programa order by sum(monto_usd) desc limit 10) x), '[]'::jsonb),
      'por_closer', coalesce((select jsonb_agg(to_jsonb(x) order by x.neto_usd desc, x.closer)
                                from (select closer, round(sum(monto_usd), 2) as neto_usd, count(*) as movimientos
                                        from base group by closer order by sum(monto_usd) desc limit 10) x), '[]'::jsonb),
      'nota', 'Montos en USD. neto_usd = cobrado_usd + devoluciones_usd (las devoluciones son negativas). Un closer o setter ve solo los pagos donde figura.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- FINANZAS 2. Ingresos, gastos y net cash flow por cliente y mes (meses completos que toca el periodo).
--   ingreso_real = pagos; gastos = P&L de Opps (staff, softwares, others, sin_categoria); net = ingreso_real - gastos
--   (regla de la app desde el 14/10). revenue_opps_usd = lo declarado en Opps, para contrastar.
--   Solo clientes donde el usuario ve la plata (fin_ve_plata).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_fin_resultado(
  p_cliente text default null, p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_ids text[] := public.ia_chat_clientes_ok(public.ia_chat_cliente(p_cliente), 'plata');
  v_d date;
  v_h date;
  v_m1 date;
  v_m2 date;
begin
  select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, false) p;
  v_m1 := date_trunc('month', v_d::timestamp)::date;
  v_m2 := date_trunc('month', v_h::timestamp)::date;
  return (
    with pnl as (
      select cliente_id, anio, mes,
             sum(monto_usd) filter (where categoria = 'revenue')       as revenue_opps,
             sum(monto_usd) filter (where categoria = 'staff')         as staff,
             sum(monto_usd) filter (where categoria = 'softwares')     as softwares,
             sum(monto_usd) filter (where categoria = 'others')        as others,
             sum(monto_usd) filter (where categoria = 'sin_categoria') as sin_categoria,
             sum(monto_usd) filter (where categoria <> 'revenue')      as gastos
        from public.fin_pnl
       where cliente_id = any(v_ids) and make_date(anio, mes, 1) between v_m1 and v_m2
       group by cliente_id, anio, mes
    ), pagos as (
      select cliente_id, extract(year from fecha)::int as anio, extract(month from fecha)::int as mes,
             sum(monto_usd) as ingreso
        from public.fin_pagos
       where cliente_id = any(v_ids) and fecha >= v_m1 and fecha < (v_m2 + interval '1 month')::date
       group by 1, 2, 3
    ), cm as (
      select coalesce(p.cliente_id, g.cliente_id) as cliente_id,
             to_char(make_date(coalesce(p.anio, g.anio), coalesce(p.mes, g.mes), 1), 'YYYY-MM') as periodo,
             coalesce(g.ingreso, 0)       as ingreso_real,
             coalesce(p.gastos, 0)        as gastos,
             coalesce(p.staff, 0)         as staff,
             coalesce(p.softwares, 0)     as softwares,
             coalesce(p.others, 0)        as others,
             coalesce(p.sin_categoria, 0) as sin_categoria,
             coalesce(p.revenue_opps, 0)  as revenue_opps
        from pnl p
        full join pagos g on g.cliente_id = p.cliente_id and g.anio = p.anio and g.mes = p.mes
    ), g as (
      select cliente_id, periodo, grouping(cliente_id, periodo) as nivel,
             round(sum(ingreso_real), 2)  as ingreso_real_usd,
             round(sum(gastos), 2)        as gastos_usd,
             round(sum(ingreso_real) - sum(gastos), 2) as net_cash_flow_usd,
             round(sum(staff), 2)         as gastos_staff_usd,
             round(sum(softwares), 2)     as gastos_softwares_usd,
             round(sum(others), 2)        as gastos_otros_usd,
             round(sum(sin_categoria), 2) as gastos_sin_categoria_usd,
             round(sum(revenue_opps), 2)  as revenue_opps_usd,
             bool_and(ingreso_real = 0 and revenue_opps > 0) as sin_pagos_cargados
        from cm
       group by grouping sets ((), (cliente_id), (periodo), (cliente_id, periodo))
    )
    select jsonb_build_object(
      'meses', jsonb_build_object('desde', to_char(v_m1, 'YYYY-MM'), 'hasta', to_char(v_m2, 'YYYY-MM')),
      'cliente', v_cli,
      'total', coalesce((select to_jsonb(t) - array['nivel', 'cliente_id', 'periodo', 'sin_pagos_cargados'] from g t where t.nivel = 3),
                        jsonb_build_object('ingreso_real_usd', 0, 'gastos_usd', 0, 'net_cash_flow_usd', 0)),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'periodo', 'sin_pagos_cargados'] order by t.cliente_id)
                                 from g t where t.nivel = 1), '[]'::jsonb),
      'por_mes', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel', 'cliente_id', 'sin_pagos_cargados'] order by t.periodo)
                             from g t where t.nivel = 2), '[]'::jsonb),
      'detalle_cliente_mes', coalesce((select jsonb_agg(to_jsonb(t) - array['nivel'] order by t.periodo, t.cliente_id)
                                         from g t where t.nivel = 0), '[]'::jsonb),
      'nota', 'Se toman meses completos. net_cash_flow = ingreso_real (pagos) - gastos (Opps). sin_pagos_cargados = el mes tiene revenue en Opps pero ningun pago cargado.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- FINANZAS 3. Cobranzas: cuotas pendientes. Por defecto solo las vencidas (p_solo_vencidas). p_desde/p_hasta (opcionales)
--   filtran por fecha de vencimiento; sin fechas trae todo lo pendiente. Monto pendiente = monto - cobrado (USD).
--   Rol setter y ventas: sin permiso (la app no les muestra Cobranzas).
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_fin_deudas(
  p_cliente text default null, p_desde date default null, p_hasta date default null,
  p_solo_vencidas boolean default true)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol   text := public.ia_chat_rol();
  v_cli   text := public.ia_chat_cliente(p_cliente);
  v_ids   text[];
  v_solo  boolean := coalesce(p_solo_vencidas, true);
begin
  if v_rol in ('setter', 'ventas') then
    raise exception 'tu rol no ve las cobranzas' using errcode = '42501';
  end if;
  if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
    raise exception 'el periodo es invalido: desde es posterior a hasta' using errcode = '22023';
  end if;
  v_ids := public.ia_chat_clientes_ok(v_cli, 'pagos');
  return (
    with base as (
      select c.cliente_id, c.alumno, c.programa, c.fecha_pago, c.vencida, c.dias_al_vencimiento,
             greatest(coalesce(c.monto, 0) - coalesce(c.monto_cobrado, 0), 0) as pendiente
        from public.fin_v_cobranzas c
       where c.cliente_id = any(v_ids)
         and (not v_solo or c.vencida)
         and (p_desde is null or c.fecha_pago >= p_desde)
         and (p_hasta is null or c.fecha_pago <= p_hasta)
    )
    select jsonb_build_object(
      'cliente', v_cli,
      'solo_vencidas', v_solo,
      'filtro_vencimiento', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
      'total', jsonb_build_object(
        'cuotas', (select count(*) from base),
        'alumnos', (select count(distinct cliente_id || '|' || lower(btrim(alumno))) from base),
        'pendiente_usd', (select round(coalesce(sum(pendiente), 0), 2) from base),
        'cuotas_vencidas', (select count(*) filter (where vencida) from base),
        'pendiente_vencido_usd', (select round(coalesce(sum(pendiente) filter (where vencida), 0), 2) from base),
        'max_dias_de_atraso', (select coalesce(max(-dias_al_vencimiento) filter (where vencida), 0) from base)),
      'por_cliente', coalesce((select jsonb_agg(to_jsonb(x) order by x.pendiente_usd desc, x.cliente_id)
                                 from (select cliente_id, count(*) as cuotas, round(sum(pendiente), 2) as pendiente_usd
                                         from base group by cliente_id) x), '[]'::jsonb),
      'por_programa', coalesce((select jsonb_agg(to_jsonb(x) order by x.pendiente_usd desc, x.programa)
                                  from (select coalesce(nullif(btrim(programa), ''), '(sin programa)') as programa,
                                               count(*) as cuotas, round(sum(pendiente), 2) as pendiente_usd
                                          from base group by 1 order by sum(pendiente) desc limit 10) x), '[]'::jsonb),
      'top_deudores', coalesce((select jsonb_agg(to_jsonb(x) order by x.pendiente_usd desc, x.alumno)
                                  from (select cliente_id, min(alumno) as alumno, count(*) as cuotas,
                                               round(sum(pendiente), 2) as pendiente_usd,
                                               max(-dias_al_vencimiento) filter (where vencida) as dias_de_atraso_max
                                          from base group by cliente_id, lower(btrim(alumno))
                                         order by sum(pendiente) desc, min(alumno) limit 15) x), '[]'::jsonb),
      'nota', 'Pendiente = estado vacio o distinto de pagado/churn/pausado/cancelado, como Cobranzas de la app. Un closer ve solo las cuotas de sus alumnos.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- FINANZAS 4. Ultimos pagos. Con p_alumno (nombre parcial) busca en todo el historial; sin alumno y sin fechas, este mes.
--   p_limite de 1 a 50 (defecto 20). Trae alumno, concepto, programa, monto, closer y metodo; sin telefono.
-- ---------------------------------------------------------------------
create or replace function public.ia_chat_fin_pagos(
  p_cliente text default null, p_desde date default null, p_hasta date default null,
  p_alumno text default null, p_limite integer default 20)
returns jsonb
language plpgsql stable
set search_path = public
as $fn$
declare
  v_rol text := public.ia_chat_rol();
  v_cli text := public.ia_chat_cliente(p_cliente);
  v_ids text[] := public.ia_chat_clientes_ok(public.ia_chat_cliente(p_cliente), 'pagos');
  v_alu text := nullif(lower(btrim(coalesce(p_alumno, ''))), '');
  v_lim int := least(greatest(coalesce(p_limite, 20), 1), 50);
  v_d date;
  v_h date;
begin
  if v_alu is not null then
    v_alu := replace(replace(replace(left(v_alu, 60), '\', '\\'), '%', '\%'), '_', '\_');
  end if;
  if v_alu is null or p_desde is not null or p_hasta is not null then
    select p.desde, p.hasta into v_d, v_h from public.ia_chat_periodo(p_desde, p_hasta, false) p;
  end if;
  return (
    with base as (
      select p.fecha, p.cliente_id, p.alumno, p.concepto, p.programa, p.monto_usd, p.closer, p.metodo_pago
        from public.fin_pagos p
       where p.cliente_id = any(v_ids)
         and (v_d is null or p.fecha between v_d and v_h)
         and (v_alu is null or lower(p.alumno) like '%' || v_alu || '%')
    )
    select jsonb_build_object(
      'periodo', case when v_d is null then null else jsonb_build_object('desde', v_d, 'hasta', v_h) end,
      'cliente', v_cli,
      'alumno_buscado', nullif(btrim(coalesce(p_alumno, '')), ''),
      'total_pagos_encontrados', (select count(*) from base),
      'monto_neto_usd', (select round(coalesce(sum(monto_usd), 0), 2) from base),
      'pagos', coalesce((select jsonb_agg(to_jsonb(x) order by x.fecha desc, x.alumno)
                           from (select fecha, cliente_id, alumno, concepto, programa, monto_usd, closer, metodo_pago
                                   from base order by fecha desc, alumno limit v_lim) x), '[]'::jsonb),
      'nota', 'Muestra los ' || v_lim || ' mas recientes. Montos en USD; negativo = devolucion.'
    )
  );
end
$fn$;

-- ---------------------------------------------------------------------
-- Permisos: solo usuarios con sesion (y service_role, que igual corta por no tener auth.uid()). Nada para anon.
-- ---------------------------------------------------------------------
do $perm$
declare f text;
begin
  foreach f in array array[
    'ia_chat_rol()', 'ia_chat_periodo(date,date,boolean)', 'ia_chat_cliente(text)', 'ia_chat_solo_panel(text)',
    'ia_chat_clientes_ok(text,text)',
    'ia_chat_ventas_resumen(text,date,date)', 'ia_chat_ventas_equipo(text,date,date,text,text)',
    'ia_chat_ventas_leads(text,date,date,text)',
    'ia_chat_fin_cobros(text,date,date)', 'ia_chat_fin_resultado(text,date,date)',
    'ia_chat_fin_deudas(text,date,date,boolean)', 'ia_chat_fin_pagos(text,date,date,text,integer)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end
$perm$;

comment on function public.ia_chat_ventas_resumen(text,date,date) is '158: llamadas agendadas/presentadas/cerradas, total, por cliente y por mes. Invoker: la RLS recorta. Ver docs/dystopita-herramientas.md';
comment on function public.ia_chat_ventas_equipo(text,date,date,text,text) is '158: llamadas por closer o por setter. Invoker.';
comment on function public.ia_chat_ventas_leads(text,date,date,text) is '158: leads por nivel de calificacion de IA. Invoker.';
comment on function public.ia_chat_fin_cobros(text,date,date) is '158: cobros (pagos) netos por cliente, mes, concepto, programa y closer. Invoker.';
comment on function public.ia_chat_fin_resultado(text,date,date) is '158: ingresos, gastos y net cash flow por cliente y mes. Invoker; solo donde fin_ve_plata.';
comment on function public.ia_chat_fin_deudas(text,date,date,boolean) is '158: cuotas pendientes/vencidas. Invoker; no setter ni ventas.';
comment on function public.ia_chat_fin_pagos(text,date,date,text,integer) is '158: ultimos pagos, de un alumno o del periodo. Invoker.';

-- ---------------------------------------------------------------------
-- BLOQUE 2. PRUEBA DE HUMO (solo lectura: no escribe nada). Revisa forma y permisos, y llama a cada herramienta como
--   fundador con el rol authenticated (RLS real). Termina en NOTICE "HUMO 158 OK"; si algo falla, "HUMO 158 FALLO ...".
-- ---------------------------------------------------------------------
do $humo$
declare
  v_n    int;
  v_uid  uuid;
  v_j    jsonb;
begin
  -- 1) las 12 funciones existen, ninguna es security definer, anon no puede ejecutar, authenticated si
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'ia\_chat\_%' and not p.prosecdef
     and not has_function_privilege('anon', p.oid, 'execute')
     and has_function_privilege('authenticated', p.oid, 'execute');
  if v_n <> 12 then
    raise exception 'HUMO 158 FALLO: esperaba 12 funciones ia_chat_* invoker con permisos correctos y hay %', v_n;
  end if;

  -- 2) sin sesion corta con 42501
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.ia_chat_ventas_resumen();
    raise exception 'HUMO 158 FALLO: sin sesion tendria que cortar';
  exception when sqlstate '42501' then
    null;
  end;

  -- 3) como fundador, con RLS real
  select m.user_id into v_uid from public.crm_members m where m.rol = 'fundador' limit 1;
  if v_uid is null then
    raise notice 'HUMO 158: no hay fundador en crm_members; se omite la parte con sesion';
  else
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    set local role authenticated;
    v_j := public.ia_chat_ventas_resumen(null, current_date - 60, current_date);
    if not (v_j ? 'total' and v_j ? 'por_cliente' and v_j ? 'por_mes') then raise exception 'HUMO 158 FALLO: ventas_resumen sin claves'; end if;
    v_j := public.ia_chat_ventas_equipo(null, current_date - 60, current_date, 'closer', null);
    if not (v_j ? 'personas') then raise exception 'HUMO 158 FALLO: ventas_equipo closer sin claves'; end if;
    v_j := public.ia_chat_ventas_leads(null, current_date - 60, current_date, 'todos');
    if not (v_j ? 'por_nivel' and v_j ? 'leads') then raise exception 'HUMO 158 FALLO: ventas_leads sin claves'; end if;
    v_j := public.ia_chat_fin_cobros(null, current_date - 60, current_date);
    if not (v_j ? 'total' and v_j ? 'por_concepto') then raise exception 'HUMO 158 FALLO: fin_cobros sin claves'; end if;
    v_j := public.ia_chat_fin_resultado(null, current_date - 90, current_date);
    if not (v_j ? 'total' and v_j ? 'detalle_cliente_mes') then raise exception 'HUMO 158 FALLO: fin_resultado sin claves'; end if;
    v_j := public.ia_chat_fin_deudas(null, null, null, true);
    if not (v_j ? 'total' and v_j ? 'top_deudores') then raise exception 'HUMO 158 FALLO: fin_deudas sin claves'; end if;
    v_j := public.ia_chat_fin_pagos(null, null, null, null, 5);
    if not (v_j ? 'pagos') then raise exception 'HUMO 158 FALLO: fin_pagos sin claves'; end if;
    -- parametros invalidos
    begin
      perform public.ia_chat_ventas_leads(null, null, null, 'tibiecito');
      raise exception 'HUMO 158 FALLO: nivel invalido tendria que cortar';
    exception when sqlstate '22023' then null;
    end;
    begin
      perform public.ia_chat_fin_cobros('cliente-que-no-existe');
      raise exception 'HUMO 158 FALLO: cliente inexistente tendria que cortar';
    exception when sqlstate '22023' then null;
    end;
    reset role;
  end if;
  perform set_config('request.jwt.claim.sub', '', true);
  raise notice 'HUMO 158 OK';
end
$humo$;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado). Reemplazar <uuid ...> por el user_id real
-- (select user_id, rol, nombre from crm_members order by rol). El set_config va en el MISMO select que la llamada.
-- Banco 158: cada control con usuario arranca con set_config('role', 'authenticated', true). Sin eso el editor corre como
-- postgres (dueno de las tablas), la RLS NO se aplica y C7/C9 muestran de mas (el closer veia todas las cuotas y el cliente
-- solo panel veia los cobros de otro cliente). En la app (token del usuario) siempre es authenticated.
-- =====================================================================

-- C1. Las 12 funciones, todas invoker (prosecdef = false), con search_path = public. 12 filas.
-- select p.proname, p.prosecdef as definer, p.proconfig
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname like 'ia\_chat\_%' order by 1;

-- C2. anon no ejecuta ninguna (esperado: 0 filas) y authenticated si las 12.
-- select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname like 'ia\_chat\_%' and has_function_privilege('anon', p.oid, 'execute');

-- C3. "Cuantas llamadas agendaron este mes para todos los clientes", como fundador. Comparar total.agendadas_total con
--     la suma de agendadas + agendadas_a_futuro de este mes en fin_v_metricas_ventas (C4).
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_ventas_resumen());

-- C4. La misma cuenta contra la vista de metricas de la app (debe coincidir con total.agendadas_total de C3).
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        sum(agendadas + agendadas_a_futuro) as agendadas_total_de_la_app
--   from public.fin_v_metricas_ventas where periodo = to_char(current_date, 'YYYY-MM');

-- C5. Cobros del mes pasado contra el Resumen de la app (cobrado_usd / neto_usd).
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_fin_cobros(null,
--          (date_trunc('month', current_date) - interval '1 month')::date,
--          (date_trunc('month', current_date) - interval '1 day')::date));

-- C6. Ingresos y gastos de liam, ultimos 3 meses, contra el P&L de la app (net_cash_flow_usd = Pagos - Gastos).
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_fin_resultado('liam', (current_date - interval '90 days')::date, current_date));

-- C7. Deudas vencidas, y por closer: un closer ve SOLO lo suyo (comparar con C7b como fundador). Poner el uuid de un closer.
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid closer>', true) as _,
--        jsonb_pretty(public.ia_chat_fin_deudas());
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_fin_deudas());

-- C8. Permisos por rol: setter y ventas no ven cobranzas (esperado: ERROR 42501 "tu rol no ve las cobranzas"), pero si
--     ven llamadas. Poner el uuid de un setter / de un usuario ventas.
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid setter>', true) as _, public.ia_chat_fin_deudas();
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid setter>', true) as _, jsonb_pretty(public.ia_chat_ventas_resumen());

-- C9. Un cliente "solo panel" (cliente@agus, si ya existe) no ve cobros ni pagos ni deudas de su cliente (esperado: ERROR
--     42501) pero si ingresos y gastos (el P&L lo ve en la app). Poner su uuid.
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid cliente solo panel>', true) as _, public.ia_chat_fin_cobros();
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid cliente solo panel>', true) as _, jsonb_pretty(public.ia_chat_fin_resultado());

-- C10. Leads calificados de los ultimos 30 dias (lista de calientes) y por closer/setter (mide el tiempo de setter: si
--      tarda mas de unos segundos, avisar).
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_ventas_leads(null, current_date - 30, current_date));
-- select set_config('role', 'authenticated', true) as _r, set_config('request.jwt.claim.sub', '<uuid fundador>', true) as _,
--        jsonb_pretty(public.ia_chat_ventas_equipo(null, current_date - 30, current_date, 'setter'));

-- =====================================================================
-- VUELTA ATRAS (no toca datos ni tablas: solo borra las funciones)
-- =====================================================================
-- drop function if exists public.ia_chat_fin_pagos(text,date,date,text,integer);
-- drop function if exists public.ia_chat_fin_deudas(text,date,date,boolean);
-- drop function if exists public.ia_chat_fin_resultado(text,date,date);
-- drop function if exists public.ia_chat_fin_cobros(text,date,date);
-- drop function if exists public.ia_chat_ventas_leads(text,date,date,text);
-- drop function if exists public.ia_chat_ventas_equipo(text,date,date,text,text);
-- drop function if exists public.ia_chat_ventas_resumen(text,date,date);
-- drop function if exists public.ia_chat_clientes_ok(text,text);
-- drop function if exists public.ia_chat_solo_panel(text);
-- drop function if exists public.ia_chat_cliente(text);
-- drop function if exists public.ia_chat_periodo(date,date,boolean);
-- drop function if exists public.ia_chat_rol();
