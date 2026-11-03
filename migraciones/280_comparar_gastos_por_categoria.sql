-- =====================================================================
-- 280 · Comparar mes a mes (Finanzas): gastos por categoria (ads, Zoom, landings)
--
-- SIN CORRER. SQL NO probado (la sesion no tiene permiso para ejecutar SQL).
--
-- Para que sirve: la pantalla nueva «Comparar» (#/comparar, solo fundador) pone dos meses lado a lado.
-- Casi todo sale de lo que ya existe en el front (fin_v_dys_ganancia_mes, fin_cierre_meses, fin_cierre_transferencias,
-- fin_v_cierre_ventas, fin_v_cash_collected_concepto). Lo unico que NO existe es el gasto del cliente abierto en
-- ads / Zoom / landings: en Opps (fin_pnl) y en Gastos (fin_gastos) cada gasto es un texto libre. Esta migracion agrega:
--   1. fin_comparar_patrones: tabla chica (categoria, patron ILIKE, prioridad, activo) que decide a que categoria
--      pertenece un gasto por su texto. Sembrada con ads / zoom / landings. Se edita a mano si algo queda mal clasificado.
--   2. fin_comparar_gastos(mes): una fila por cliente y categoria con el monto en USD, sumando lo MISMO que suma
--      fin_v_dys_ganancia_mes en gastos del cliente: Opps (sin revenue) + gastos de Gastos (reparto distinto de
--      100% Dystopia) + gastos de webinar que no estan ya en Opps. Lo que no matchea ningun patron NO sale: el front
--      lo calcula como «Otros» (total del cliente menos lo clasificado) y las comisiones salen de la vista.
--      Webinars: ads_webinar y ads_replay = ads, zoom = zoom, landing = landings (por concepto, sin patrones).
--   Solo fundador (security definer). No toca fin_pagos, la sync ni datos existentes.
--
-- Meses cerrados: la foto (snapshot) del cierre no trae esta apertura, asi que estas tres categorias se calculan
-- en vivo. Gastos y gastos de webinar de un mes cerrado estan bloqueados por trigger (269); Opps viene de la sync.
--
-- ORDEN: BLOQUE 0 (guardas) > BLOQUE 1 (tabla + funcion) > BLOQUE 2 (humo, termina en ERROR «HUMO 280 OK», se revierte
--   solo) > controles C1.. DE A UNO (el editor muestra solo el ultimo) > front.
-- No correr a las :00/:15/:30/:45 ni a las 9:00 (corre la sync).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (solo lectura)
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.fin_pnl') is null then v_falta := v_falta || ' fin_pnl(001)'; end if;
  if to_regclass('public.fin_gastos_mes_base') is null then v_falta := v_falta || ' fin_gastos_mes_base(174)'; end if;
  if to_regclass('public.fin_webinar_gastos') is null or to_regclass('public.fin_webinars') is null then
    v_falta := v_falta || ' fin_webinar_gastos/fin_webinars(267)';
  end if;
  if to_regclass('public.fin_v_dys_ganancia_mes') is null then v_falta := v_falta || ' fin_v_dys_ganancia_mes(267/270)'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if v_falta <> '' then
    raise exception 'GUARDA 280: faltan:%. No se toca nada.', v_falta;
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 14, 15, 29, 30, 44, 45, 59) then
    raise exception 'GUARDA 280: correla en otro minuto (la sync corre a :00/:15/:30/:45).';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Tabla de patrones + funcion
-- ---------------------------------------------------------------------
create table if not exists public.fin_comparar_patrones (
  id        bigint generated always as identity primary key,
  categoria text    not null check (categoria in ('ads', 'zoom', 'landings')),
  patron    text    not null check (btrim(patron) <> ''),   -- ILIKE, ej. %zoom%
  prioridad int     not null default 100,                   -- menor = gana si un texto matchea varios
  activo    boolean not null default true,
  nota      text
);
create unique index if not exists fin_comparar_patrones_uq on public.fin_comparar_patrones (categoria, lower(patron));
alter table public.fin_comparar_patrones enable row level security;
drop policy if exists fin_comparar_patrones_fundador on public.fin_comparar_patrones;
create policy fin_comparar_patrones_fundador on public.fin_comparar_patrones for all to authenticated
  using (public.es_fundador()) with check (public.es_fundador());
revoke all on table public.fin_comparar_patrones from public, anon;
grant select, insert, update, delete on table public.fin_comparar_patrones to authenticated;
grant all on table public.fin_comparar_patrones to service_role;

comment on table public.fin_comparar_patrones is
  '280: patrones ILIKE sobre el texto de un gasto (item de Opps, categoria + descripcion de Gastos) para abrirlo en ads / zoom / landings en Comparar. Lo que no matchea es «Otros».';

insert into public.fin_comparar_patrones (categoria, patron, prioridad, nota)
select v.categoria, v.patron, v.prioridad, v.nota
  from (values
    ('zoom',     '%zoom%',          10, 'Zoom'),
    ('landings', '%landing%',       20, 'Landings'),
    ('landings', '%funnel%',        20, 'Funnels / landings'),
    ('landings', '%clickfunnels%',  20, 'Funnels / landings'),
    ('ads',      '%ads%',           30, 'Publicidad'),
    ('ads',      '%adset%',         30, 'Publicidad'),
    ('ads',      '%publicidad%',    30, 'Publicidad'),
    ('ads',      '%anuncio%',       30, 'Publicidad'),
    ('ads',      '%facebook%',      30, 'Publicidad'),
    ('ads',      '%meta %',         30, 'Publicidad (Meta)'),
    ('ads',      '%tiktok%',        30, 'Publicidad'),
    ('ads',      '%youtube ads%',   30, 'Publicidad'),
    ('ads',      '%google ads%',    30, 'Publicidad')
  ) as v(categoria, patron, prioridad, nota)
 where not exists (select 1 from public.fin_comparar_patrones p where p.categoria = v.categoria and lower(p.patron) = lower(v.patron));

-- Clasificador: la categoria de un texto (null = ninguna).
create or replace function public.fin_comparar_categoria(p_texto text)
returns text language sql stable set search_path = public as $f$
  select p.categoria
    from public.fin_comparar_patrones p
   where p.activo and coalesce(p_texto, '') ilike p.patron
   order by p.prioridad, p.id
   limit 1
$f$;
revoke all on function public.fin_comparar_categoria(text) from public, anon;
grant execute on function public.fin_comparar_categoria(text) to authenticated, service_role;

-- Gastos del cliente en el mes, abiertos en ads / zoom / landings. Mismas fuentes que fin_v_dys_ganancia_mes.
create or replace function public.fin_comparar_gastos(p_mes date)
returns table (cliente_id text, categoria text, monto_usd numeric)
language plpgsql stable security definer set search_path = public as $f$
declare v_mes date := date_trunc('month', p_mes)::date;
begin
  if not coalesce(public.es_fundador(), false) then raise exception 'Solo fundador'; end if;
  return query
  with fuentes as (
    select n.cliente_id::text as cli, public.fin_comparar_categoria(n.item) as cat, n.monto_usd as monto
      from public.fin_pnl n
     where n.cliente_id in ('liam', 'agus', 'teo') and n.categoria <> 'revenue'
       and make_date(n.anio, n.mes, 1) = v_mes
    union all
    select b.entidad::text, public.fin_comparar_categoria(coalesce(b.categoria, '') || ' ' || coalesce(b.descripcion, '')), b.monto_usd
      from public.fin_gastos_mes_base b
     where b.entidad in ('liam', 'agus', 'teo') and b.reparto <> 'dystopia' and b.mes = v_mes
    union all
    select w.cliente_id::text,
           case g.concepto when 'ads_webinar' then 'ads' when 'ads_replay' then 'ads' when 'zoom' then 'zoom' when 'landing' then 'landings' end,
           g.monto_usd
      from public.fin_webinar_gastos g
      join public.fin_webinars w on w.id = g.webinar_id
     where g.activo and w.activo and not g.en_opps and w.cliente_id in ('liam', 'agus', 'teo')
       and (date_trunc('month', g.fecha))::date = v_mes
  )
  select f.cli, f.cat, round(sum(f.monto), 2)
    from fuentes f
   where f.cat is not null
   group by f.cli, f.cat
   order by f.cli, f.cat;
end
$f$;
revoke all on function public.fin_comparar_gastos(date) from public, anon;
grant execute on function public.fin_comparar_gastos(date) to authenticated, service_role;

comment on function public.fin_comparar_gastos(date) is
  '280: gastos del cliente del mes abiertos en ads / zoom / landings (Opps + Gastos + webinars fuera de Opps). Solo fundador. Lo que no matchea es «Otros» en el front.';

-- ---------------------------------------------------------------------
-- BLOQUE 2. Humo (se revierte solo: termina SIEMPRE en ERROR «HUMO 280 OK: ...»). Hay que correr antes el BLOQUE 1.
-- ---------------------------------------------------------------------
do $h$
declare
  t text; v_cat text; v_txt text := '';
begin
  foreach t in array array['Zoom Pro', 'ZOOM webinar', 'Landing page', 'Meta Ads octubre', 'Facebook ads', 'TikTok ads', 'Sueldo editor', 'Software', 'Comisiones closer', 'Zoom + ads'] loop
    v_cat := public.fin_comparar_categoria(t);
    v_txt := v_txt || ' [' || t || ' = ' || coalesce(v_cat, 'otros') || ']';
  end loop;
  if public.fin_comparar_categoria('Zoom Pro') is distinct from 'zoom'
     or public.fin_comparar_categoria('Landing page') is distinct from 'landings'
     or public.fin_comparar_categoria('Meta Ads octubre') is distinct from 'ads'
     or public.fin_comparar_categoria('Zoom + ads') is distinct from 'zoom'
     or public.fin_comparar_categoria('Sueldo editor') is not null then
    raise exception 'HUMO 280 FALLO: el clasificador no da lo esperado:%', v_txt;
  end if;
  raise exception 'HUMO 280 OK (se revierte solo): patrones %, clasificador:%', (select count(*) from public.fin_comparar_patrones), v_txt;
end
$h$;

-- =====================================================================
-- CONTROLES (de a uno). Los que usan la funcion necesitan un fundador en la sesion del editor:
--   select set_config('request.jwt.claim.sub', '<uuid de un fundador>', true);  (en la MISMA ejecucion que el control)
-- =====================================================================

-- C1. Patrones sembrados.
select categoria, patron, prioridad, activo from public.fin_comparar_patrones order by prioridad, categoria, patron;

-- C2. Gastos abiertos de octubre 2026 (cambiar el uuid y el mes). Comparar contra Gastos del cliente de fin_v_dys_ganancia_mes.
-- select set_config('request.jwt.claim.sub', '<uuid de un fundador>', true);
-- select * from public.fin_comparar_gastos('2026-10-01');

-- C3. Gastos de Opps de octubre que NO matchean ningun patron (si algo importante cae aca, agregar el patron en C5).
-- select n.cliente_id, n.categoria, n.item, n.monto_usd
--   from public.fin_pnl n
--  where n.cliente_id in ('liam', 'agus', 'teo') and n.categoria <> 'revenue' and make_date(n.anio, n.mes, 1) = '2026-10-01'
--    and public.fin_comparar_categoria(n.item) is null
--  order by n.cliente_id, n.monto_usd desc;

-- C4. Total clasificado contra total de gastos del cliente (lo que falta es «Otros» + comisiones).
-- select set_config('request.jwt.claim.sub', '<uuid de un fundador>', true);
-- select g.entidad, g.gastos_cliente_usd, g.gastos_comision_usd,
--        (select coalesce(sum(c.monto_usd), 0) from public.fin_comparar_gastos('2026-10-01') c where c.cliente_id = g.entidad) as clasificado
--   from public.fin_v_dys_ganancia_mes g where g.mes = '2026-10-01' and g.entidad <> 'dystopia';

-- C5. Agregar un patron (ejemplo; editar y correr solo si hace falta):
-- insert into public.fin_comparar_patrones (categoria, patron, prioridad, nota) values ('ads', '%manychat%', 30, 'ejemplo');

-- =====================================================================
-- VUELTA ATRAS (solo si hace falta; no toca datos existentes):
--   drop function if exists public.fin_comparar_gastos(date);
--   drop function if exists public.fin_comparar_categoria(text);
--   drop table if exists public.fin_comparar_patrones;
-- =====================================================================
