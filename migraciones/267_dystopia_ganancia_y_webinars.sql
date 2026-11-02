-- =====================================================================
-- 267_dystopia_ganancia_y_webinars.sql
-- (1) El % de Dystopia pasa a calcularse sobre la GANANCIA del cliente, no sobre su facturacion.
-- (2) Apartado Webinars: registro, ingresos, gastos por concepto y resultado.
-- Numero asignado por el jefe (2/11/2026). SIN CORRER, SQL NO PROBADO contra Postgres.
--
-- REGLAS (Joaquin, 2/11/2026)
--   * Ganancia del cliente = facturacion del mes - TODOS los gastos del cliente.
--       facturacion = la misma del P&L (063): pagos del mes desde el primer pago cargado; antes de eso, el revenue de Opps.
--       gastos del cliente = gastos de Opps (fin_pnl, todo lo que no es revenue)
--                          + gastos manuales del cliente de fin_gastos (reparto 'comision' o 'cliente', incluye la IA del cliente)
--                          + gastos de webinar del cliente que NO estan ya en Opps (en_opps = false).
--   * Ganancia de Dystopia por cliente = ganancia del cliente x % vigente ese mes (fin_comision_agencia, desde/hasta).
--     Sin recorte: si la ganancia es negativa, la cuenta da negativo (formula literal).
--   * Porcentajes desde 2026-10-01: Agus 25, Liam 30, Teo 40. Meses anteriores: NO se tocan los porcentajes que ya
--     tiene la app (la 174 sembro liam 30 / agus 25 / teo 40 desde 2026-01-01). Si algun cliente no tuviera ninguna
--     fila, se siembra 25% hasta 2026-09-30 (las planillas no traen el porcentaje: DUDA, ver resumen del chat).
--   * Gastos propios de Dystopia = fin_gastos con reparto 'dystopia' (entidad dystopia, IA sin asignar, etc.)
--     + gastos fijos de fin_dys_gastos_fijos (sueldo de Joaquin: 1.000 USD por mes, desde 2026-10-01, editable).
--     Ya NO se resta a Dystopia "su % de los gastos compartidos": el % sobre la ganancia ya los descuenta.
--   * Ganancia bruta de Dystopia = suma de lo que le toca de cada cliente. Neta = bruta - gastos propios.
--
-- WEBINARS
--   * fin_webinars: un registro por webinar. Ventana de ingresos editable (por defecto fecha .. fecha + 14 dias).
--   * Ingresos = pagos del cliente en la ventana con fuente Webinar (fuente_ingreso = 'Webinar', 228) o con
--     'webinar' / 'replay' en fuente_lead (209/236), mas ajustes manuales (fin_webinar_ajustes): ventas probables
--     (se muestran aparte, no entran al cash) y pagos sin fuente asignados a mano (por clave de pago).
--   * Gastos por concepto en fin_webinar_gastos. UN gasto se carga UNA vez, aca, marcado con su webinar.
--     Si ese gasto ya figura en Opps del mes (ej. el Zoom 500 de octubre, todo septiembre de AF) se marca
--     en_opps = true: cuenta para el resultado del webinar pero NO suma de nuevo a los gastos del cliente.
--   * Reglas fijas en fin_webinar_reglas: Zoom 500 Liam / 500 Agus por webinar; landings Agus 300 / Liam 200.
--
-- Todo nuevo: no modifica ni borra datos existentes (solo INSERT de porcentajes, webinars y gastos de arranque,
-- idempotentes). No toca la sync, fin_pagos ni las vistas de la 174 (fin_v_dys_mes queda para comparar).
-- Depende de: 001, 062 (fin_pagos.clave), 174, 209 (fuente_lead), 228 (fuente_ingreso).
-- ORDEN: BLOQUE 1 (guardas, tablas, permisos) > BLOQUE 2 (porcentajes y semillas) > BLOQUE 3 (vistas)
--   > BLOQUE 4 (humo, termina en ERROR "HUMO 267 OK" y se revierte solo) > controles C1.. de a uno > front.
--   Correr cada bloque por separado. No correr a las :00/:15/:30/:45 ni a las 9:00.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas, tablas, RLS
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.fin_comision_agencia') is null then v_falta := v_falta || ' fin_comision_agencia(001)'; end if;
  if to_regclass('public.fin_pagos') is null then v_falta := v_falta || ' fin_pagos'; end if;
  if to_regclass('public.fin_pnl') is null then v_falta := v_falta || ' fin_pnl'; end if;
  if to_regclass('public.fin_gastos') is null then v_falta := v_falta || ' fin_gastos(174)'; end if;
  if to_regclass('public.fin_gastos_mes_base') is null then v_falta := v_falta || ' fin_gastos_mes_base(174)'; end if;
  if to_regclass('public.crm_clients') is null then v_falta := v_falta || ' crm_clients'; end if;
  if to_regprocedure('public.fin_dys_puede_ver()') is null then v_falta := v_falta || ' fin_dys_puede_ver(174)'; end if;
  if to_regprocedure('public.fin_gastos_puede_ver()') is null then v_falta := v_falta || ' fin_gastos_puede_ver(174)'; end if;
  if to_regprocedure('public.fin_gastos_puede_editar()') is null then v_falta := v_falta || ' fin_gastos_puede_editar(174)'; end if;
  if v_falta <> '' then raise exception 'GUARDA 267: faltan:%', v_falta; end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'fin_pagos'
         and column_name in ('clave', 'fuente_lead', 'fuente_ingreso', 'monto_usd', 'fecha', 'cliente_id')) <> 6 then
    raise exception 'GUARDA 267: fin_pagos no tiene clave(062), fuente_lead(209), fuente_ingreso(228), monto_usd, fecha y cliente_id';
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 15, 30, 45) then
    raise exception 'GUARDA 267: no correr en los minutos :00/:15/:30/:45 (corre la sync). Reintentar.';
  end if;
end
$g$;

-- Gastos fijos de la propia agencia (sueldo de Joaquin). Un monto por mes entre desde y hasta (null = abierto).
create table if not exists public.fin_dys_gastos_fijos (
  id        bigint generated always as identity primary key,
  concepto  text    not null check (btrim(concepto) <> ''),
  monto_usd numeric not null check (monto_usd > 0),
  desde     date    not null,
  hasta     date,
  nota      text,
  activo    boolean not null default true,
  creado_por uuid   default auth.uid(),
  creado_en timestamptz not null default now(),
  constraint fin_dys_fijos_periodo_ck check (hasta is null or hasta >= desde)
);
comment on table public.fin_dys_gastos_fijos is '267: gastos mensuales fijos de Dystopia (sueldo de Joaquin). Un monto por cada mes entre desde y hasta.';

create table if not exists public.fin_webinars (
  id             bigint generated always as identity primary key,
  cliente_id     text    not null references public.crm_clients(id),
  nombre         text    not null check (btrim(nombre) <> ''),
  fecha          date    not null,
  fecha_replay   date,
  ventana_dias   int     not null default 14 check (ventana_dias between 0 and 120),
  ventana_desde  date,   -- null = la fecha del webinar
  ventana_hasta  date,   -- null = fecha + ventana_dias
  registrados    int check (registrados is null or registrados >= 0),
  asistentes     int check (asistentes is null or asistentes >= 0),
  compradores    int check (compradores is null or compradores >= 0),
  llamadas       int check (llamadas is null or llamadas >= 0),
  cash_informado numeric,   -- cash segun las metricas externas (solo referencia, no se suma)
  nota           text,
  activo         boolean not null default true,
  creado_por     uuid    default auth.uid(),
  creado_en      timestamptz not null default now(),
  constraint fin_webinars_ventana_ck check (ventana_desde is null or ventana_hasta is null or ventana_hasta >= ventana_desde)
);
create unique index if not exists fin_webinars_uq on public.fin_webinars (cliente_id, fecha, lower(btrim(nombre)));

create table if not exists public.fin_webinar_ajustes (
  id         bigint generated always as identity primary key,
  webinar_id bigint  not null references public.fin_webinars(id),
  tipo       text    not null check (tipo in ('venta_probable', 'pago_sin_fuente', 'otro')),
  concepto   text    not null check (btrim(concepto) <> ''),
  monto_usd  numeric not null check (monto_usd <> 0),
  pago_clave text,   -- si es un pago existente asignado a mano: su clave (fin_pagos.clave); el monto se lee del pago
  nota       text,
  activo     boolean not null default true,   -- false = no se cuenta (baja logica)
  creado_por uuid    default auth.uid(),
  creado_en  timestamptz not null default now()
);
create unique index if not exists fin_webinar_ajustes_pago_uq on public.fin_webinar_ajustes (webinar_id, pago_clave) where pago_clave is not null and activo;

create table if not exists public.fin_webinar_gastos (
  id         bigint generated always as identity primary key,
  webinar_id bigint  not null references public.fin_webinars(id),
  concepto   text    not null check (concepto in ('ads_webinar', 'ads_replay', 'zoom', 'landing', 'ghl', 'manychat',
                                                  'whatsapp', 'addevent', 'comision_closer', 'otros')),
  monto_usd  numeric not null check (monto_usd >= 0),
  fecha      date    not null,   -- fija el mes en el que suma a los gastos del cliente
  fuente     text,               -- de donde sale el dato (Meta Ads, GHL, ManyChat, Zoom, WhatsApp, planilla...)
  nota       text,
  en_opps    boolean not null default false,   -- true = ya esta en los gastos de Opps de ese mes: no se suma de nuevo al cliente
  activo     boolean not null default true,
  creado_por uuid    default auth.uid(),
  creado_en  timestamptz not null default now()
);
create index if not exists fin_webinar_gastos_web_idx on public.fin_webinar_gastos (webinar_id) where activo;

-- Montos fijos por cliente y concepto (Zoom, landings): el front los ofrece al armar un webinar.
create table if not exists public.fin_webinar_reglas (
  cliente_id text    not null references public.crm_clients(id),
  concepto   text    not null check (concepto in ('ads_webinar', 'ads_replay', 'zoom', 'landing', 'ghl', 'manychat',
                                                  'whatsapp', 'addevent', 'comision_closer', 'otros')),
  monto_usd  numeric not null check (monto_usd >= 0),
  nota       text,
  primary key (cliente_id, concepto)
);

-- RLS: ve quien ve Dystopia o Gastos; edita quien edita gastos (fundador). Sin delete: la baja es logica.
do $r$
declare t text;
begin
  foreach t in array array['fin_dys_gastos_fijos', 'fin_webinars', 'fin_webinar_ajustes', 'fin_webinar_gastos', 'fin_webinar_reglas']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    execute format('grant select, insert, update on table public.%I to authenticated', t);
    execute format('grant all on table public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || '_sel', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.fin_dys_puede_ver()) or (select public.fin_gastos_puede_ver()))', t || '_sel', t);
    execute format('drop policy if exists %I on public.%I', t || '_ins', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.fin_gastos_puede_editar()))', t || '_ins', t);
    execute format('drop policy if exists %I on public.%I', t || '_upd', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.fin_gastos_puede_editar())) with check ((select public.fin_gastos_puede_editar()))', t || '_upd', t);
  end loop;
end
$r$;
-- fin_comision_agencia ya tiene su policy de fundador y los grants (001): el front edita los porcentajes ahi.

-- ---------------------------------------------------------------------
-- BLOQUE 2. Porcentajes, sueldo, reglas y webinars de arranque (solo INSERT, idempotente)
-- ---------------------------------------------------------------------
-- Cliente sin ninguna fila de porcentaje: 25% hasta 2026-09-30 (duda abierta).
insert into public.fin_comision_agencia (cliente_id, desde, hasta, porcentaje, nota)
select v.c, date '2026-01-01', date '2026-09-30', 25, '267: sin porcentaje previo en la app ni en las planillas; se deja 25% (a confirmar)'
  from (values ('liam'), ('agus'), ('teo')) as v(c)
 where exists (select 1 from public.crm_clients k where k.id = v.c)
   and not exists (select 1 from public.fin_comision_agencia a where a.cliente_id = v.c);

-- Desde octubre 2026. Las filas anteriores no se tocan: la vigente es la de desde mas reciente.
insert into public.fin_comision_agencia (cliente_id, desde, hasta, porcentaje, nota)
select v.c, date '2026-10-01', null, v.pct, '267: % sobre la ganancia del cliente, desde octubre 2026 (Joaquin, 2/11/2026)'
  from (values ('agus', 25::numeric), ('liam', 30::numeric), ('teo', 40::numeric)) as v(c, pct)
 where exists (select 1 from public.crm_clients k where k.id = v.c)
   and not exists (select 1 from public.fin_comision_agencia a where a.cliente_id = v.c and a.desde >= date '2026-10-01');

insert into public.fin_dys_gastos_fijos (concepto, monto_usd, desde, nota)
select 'Sueldo Joaquín', 1000, date '2026-10-01', '267: 1.000 USD por mes. Desde octubre 2026 (fecha de arranque a confirmar; editable)'
 where not exists (select 1 from public.fin_dys_gastos_fijos f where f.concepto = 'Sueldo Joaquín');

insert into public.fin_webinar_reglas (cliente_id, concepto, monto_usd, nota)
select v.c, v.k, v.m, v.n
  from (values ('liam', 'zoom', 500::numeric, 'Zoom 1.000/mes: 500 Liam y 500 Agus, uno por webinar'),
               ('agus', 'zoom', 500::numeric, 'Zoom 1.000/mes: 500 Liam y 500 Agus, uno por webinar'),
               ('agus', 'landing', 300::numeric, 'Landing por webinar (la cobra Joaquin)'),
               ('liam', 'landing', 200::numeric, 'Landing por webinar (la cobra Joaquin)')) as v(c, k, m, n)
 where exists (select 1 from public.crm_clients k2 where k2.id = v.c)
   and not exists (select 1 from public.fin_webinar_reglas r where r.cliente_id = v.c and r.concepto = v.k);

-- Los 5 webinars (insumos 2-11/webinars-resumen.md). cash_informado = cash de las metricas externas (referencia).
insert into public.fin_webinars (cliente_id, nombre, fecha, registrados, asistentes, compradores, llamadas, cash_informado, nota)
select v.c, v.n, v.f::date, v.reg, v.asis, v.comp, v.ll, v.cash, v.nota
  from (values
    ('agus', 'AF 20/09',            '2026-09-20', 2338, 1199, 42,   null::int, 46709::numeric, 'Show-up 36,8%. ROAS informado 48,4x. Gastos imputados ya estan en Opps de septiembre.'),
    ('agus', 'AF 25/10',            '2026-10-25', 3013, 1630, 13,   null,      16420,          '13 compradores confirmados. +5.300 de ventas probables. 19 pagos sin fuente por 12.051 (sin asignar). Meta: 22 campanas 20-25/10.'),
    ('agus', 'AF 15/11',            '2026-11-15', null, null, null, null,      null,           'Domingo 18 hs. Vacio: cargar gastos y metricas.'),
    ('liam', 'BPF 14/10',           '2026-10-14', 832,  null, 11,   62,        12799,          '11 clientes (+1 a confirmar). ROAS informado 11,4x. CAC 102.'),
    ('liam', 'Liam Wharton 11/11',  '2026-11-11', null, null, null, null,      null,           'Miercoles 18 hs. Vacio: cargar gastos y metricas.')
  ) as v(c, n, f, reg, asis, comp, ll, cash, nota)
 where exists (select 1 from public.crm_clients k where k.id = v.c)
   and not exists (select 1 from public.fin_webinars w where w.cliente_id = v.c and w.fecha = v.f::date and lower(btrim(w.nombre)) = lower(v.n));

-- Gastos de arranque. Fuente que empieza con '267:' (marca para la vuelta atras). en_opps = ya esta en Opps del mes:
--   AF 20/09: ads 1.023,31 (949,14+74,17), Zoom 378, Joaco 300 (landing), AddEvent 36 y Male Closer en Opps de septiembre.
--   Octubre: el unico gasto de webinar en Opps es el Zoom 500 de Liam y de Agus.
insert into public.fin_webinar_gastos (webinar_id, concepto, monto_usd, fecha, fuente, nota, en_opps)
select w.id, v.k, v.m, w.fecha, v.fuente, v.nota, v.opps
  from (values
    ('agus', '2026-09-20', 'ads_webinar',     949.14,  true,  '267: metricas AF 20/09', 'Ads del webinar'),
    ('agus', '2026-09-20', 'ads_replay',       74.17,  true,  '267: metricas AF 20/09', 'Ads del replay'),
    ('agus', '2026-09-20', 'zoom',            378,     true,  '267: metricas AF 20/09', null),
    ('agus', '2026-09-20', 'landing',         300,     true,  '267: metricas AF 20/09', null),
    ('agus', '2026-09-20', 'addevent',         36,     true,  '267: metricas AF 20/09', null),
    ('agus', '2026-09-20', 'comision_closer', 4279.38, true,  '267: metricas AF 20/09', 'Estimada (9,4%). Es parte del closer de Opps de septiembre (Male Closer 9.915,20).'),
    ('agus', '2026-10-25', 'ads_webinar',     2219.15, false, '267: Meta Ads', '22 campanas 20-25/10; sin separar replay'),
    ('agus', '2026-10-25', 'ghl',              104.74, false, '267: GHL', 'Workflows de octubre (todo octubre de la subcuenta)'),
    ('agus', '2026-10-25', 'ghl',               49.69, false, '267: GHL', 'Mails de octubre (todo octubre de la subcuenta)'),
    ('agus', '2026-10-25', 'zoom',             500,    true,  '267: regla Zoom 500', 'Ya esta en Opps de octubre (ZOOM webinar 50%)'),
    ('agus', '2026-10-25', 'landing',          300,    false, '267: regla landing Agus 300', null),
    ('liam', '2026-10-14', 'ads_webinar',     1070.89, false, '267: metricas BPF 14/10', null),
    ('liam', '2026-10-14', 'ads_replay',        52.55, false, '267: metricas BPF 14/10', null),
    ('liam', '2026-10-14', 'ghl',               14.78, false, '267: GHL', 'Mails de octubre'),
    ('liam', '2026-10-14', 'ghl',               20.04, false, '267: GHL', 'Workflows de octubre'),
    ('liam', '2026-10-14', 'zoom',             500,    true,  '267: regla Zoom 500', 'Ya esta en Opps de octubre (Zoom webinar 50%)'),
    ('liam', '2026-10-14', 'landing',          200,    false, '267: regla landing Liam 200', null)
  ) as v(c, f, k, m, opps, fuente, nota)
  join public.fin_webinars w on w.cliente_id = v.c and w.fecha = v.f::date
 where not exists (select 1 from public.fin_webinar_gastos g where g.webinar_id = w.id and g.fuente like '267:%');

-- Ajustes de AF 25/10: probables (cuentan aparte, no son cash) y los 19 pagos sin fuente (inactivo: no se cuentan hasta asignarlos).
insert into public.fin_webinar_ajustes (webinar_id, tipo, concepto, monto_usd, nota, activo)
select w.id, v.tipo, v.concepto, v.monto, v.nota, v.activo
  from (values
    ('venta_probable',  'Ventas probables (resumen 2/11)', 5300::numeric, '267: probables segun las metricas', true),
    ('pago_sin_fuente', '19 pagos sin fuente (resumen 2/11)', 12051::numeric, '267: NO se cuentan hasta confirmar que son del webinar; asignarlos de a uno en la pantalla y dar de baja esta fila', false)
  ) as v(tipo, concepto, monto, nota, activo)
  join public.fin_webinars w on w.cliente_id = 'agus' and w.fecha = date '2026-10-25'
 where not exists (select 1 from public.fin_webinar_ajustes a where a.webinar_id = w.id and a.nota like '267:%');

-- ---------------------------------------------------------------------
-- BLOQUE 3. Vistas (publicas: filtran por permiso adentro; corren con permisos del dueño como las de la 174)
-- ---------------------------------------------------------------------
create or replace view public.fin_v_dys_ganancia_mes as
with hoy as (
  select (date_trunc('month', now() at time zone 'America/Argentina/Buenos_Aires'))::date as mes_actual
), pg as (   -- pagos por mes (mismo criterio que fin_v_pnl_mensual, 063)
  select p.cliente_id as entidad, (date_trunc('month', p.fecha))::date as mes, sum(p.monto_usd) as ingreso_real
    from public.fin_pagos p
   where p.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
), inicio as (
  select entidad, min(mes) as primer_mes from pg group by entidad
), op as (   -- Opps: revenue declarado y gastos
  select n.cliente_id as entidad, make_date(n.anio, n.mes, 1) as mes,
         coalesce(sum(n.monto_usd) filter (where n.categoria = 'revenue'), 0) as revenue_declarado,
         coalesce(sum(n.monto_usd) filter (where n.categoria <> 'revenue'), 0) as gastos_opps
    from public.fin_pnl n
   where n.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
), man as (   -- gastos manuales del cliente (la IA del cliente incluida); los 100% Dystopia van a Dystopia
  select b.entidad, b.mes, sum(b.monto_usd) as gastos_manual
    from public.fin_gastos_mes_base b
   where b.entidad in ('liam', 'agus', 'teo') and b.reparto <> 'dystopia'
   group by 1, 2
), web as (   -- gastos de webinar que no estan ya en Opps
  select w.cliente_id as entidad, (date_trunc('month', g.fecha))::date as mes, sum(g.monto_usd) as gastos_webinar
    from public.fin_webinar_gastos g
    join public.fin_webinars w on w.id = g.webinar_id
   where g.activo and w.activo and not g.en_opps and w.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
), claves as (
  select entidad, mes from pg union select entidad, mes from op
  union select entidad, mes from man union select entidad, mes from web
), cli as (
  select k.entidad, k.mes,
         case when i.primer_mes is null or k.mes < i.primer_mes then coalesce(o.revenue_declarado, 0)
              else coalesce(p.ingreso_real, 0) end as facturacion_usd,
         case when i.primer_mes is null or k.mes < i.primer_mes then 'opps' else 'pagos' end as fuente_facturacion,
         coalesce(o.gastos_opps, 0) as gastos_opps_usd,
         coalesce(m.gastos_manual, 0) as gastos_manual_usd,
         coalesce(w.gastos_webinar, 0) as gastos_webinar_usd,
         (select a.porcentaje from public.fin_comision_agencia a
           where a.cliente_id = k.entidad and a.desde <= ((k.mes + interval '1 month')::date - 1)
             and (a.hasta is null or a.hasta >= k.mes)
           order by a.desde desc limit 1) as porcentaje
    from claves k
    left join inicio i on i.entidad = k.entidad
    left join pg p on p.entidad = k.entidad and p.mes = k.mes
    left join op o on o.entidad = k.entidad and o.mes = k.mes
    left join man m on m.entidad = k.entidad and m.mes = k.mes
    left join web w on w.entidad = k.entidad and w.mes = k.mes
), cli2 as (
  select c.*, c.gastos_opps_usd + c.gastos_manual_usd + c.gastos_webinar_usd as gastos_cliente_usd,
         c.facturacion_usd - (c.gastos_opps_usd + c.gastos_manual_usd + c.gastos_webinar_usd) as ganancia_cliente_usd
    from cli c
), propio as (   -- gastos 100% Dystopia (incluye la IA sin asignar)
  select b.mes, sum(b.monto_usd) as monto, sum(b.monto_usd) filter (where b.categoria_clave = 'ia') as monto_ia
    from public.fin_gastos_mes_base b
   where b.reparto = 'dystopia'
   group by b.mes
), fij as (   -- gastos fijos mensuales de Dystopia (sueldo), un monto por mes hasta el mes actual
  select (m)::date as mes, sum(f.monto_usd) as monto
    from public.fin_dys_gastos_fijos f
   cross join hoy
   cross join lateral generate_series(
          (date_trunc('month', f.desde))::timestamp,
          (least((date_trunc('month', coalesce(f.hasta, hoy.mes_actual)))::date, hoy.mes_actual))::timestamp,
          interval '1 month') as m
   where f.activo
   group by 1
), meses_dys as (
  select mes from cli2 union select mes from propio union select mes from fij
)
select c.mes, c.entidad, c.facturacion_usd, c.fuente_facturacion,
       c.gastos_opps_usd, c.gastos_manual_usd, c.gastos_webinar_usd, c.gastos_cliente_usd, c.ganancia_cliente_usd,
       c.porcentaje,
       round(c.ganancia_cliente_usd * coalesce(c.porcentaje, 0) / 100, 2) as ganancia_dystopia_usd,
       round(c.facturacion_usd * coalesce(c.porcentaje, 0) / 100, 2) as ingreso_viejo_usd,   -- calculo anterior (% sobre facturacion), para comparar
       (c.gastos_cliente_usd = 0 and c.facturacion_usd <> 0) as sin_gastos,
       (c.porcentaje is null) as falta_porcentaje,
       0::numeric as gasto_propio_usd, 0::numeric as sueldo_usd, 0::numeric as gasto_ia_propio_usd
  from cli2 c
 where public.fin_dys_puede_ver()
union all
select d.mes, 'dystopia', 0, 'n/a', 0, 0, 0, 0, 0, null::numeric, 0, 0, false, false,
       coalesce(p.monto, 0) + coalesce(f.monto, 0), coalesce(f.monto, 0), coalesce(p.monto_ia, 0)
  from meses_dys d
  left join propio p on p.mes = d.mes
  left join fij f on f.mes = d.mes
 where public.fin_dys_puede_ver();

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
    select sum(p.monto_usd) as usd, count(*) as n
      from public.fin_pagos p
     where p.cliente_id = w.cliente_id
       and p.fecha between coalesce(w.ventana_desde, w.fecha) and coalesce(w.ventana_hasta, w.fecha + w.ventana_dias)
       and (p.fuente_ingreso = 'Webinar' or p.fuente_lead ilike '%webinar%' or p.fuente_lead ilike '%replay%')
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
                and (p.fuente_ingreso = 'Webinar' or p.fuente_lead ilike '%webinar%' or p.fuente_lead ilike '%replay%'))
  ) aj on true
  left join lateral (
    select sum(g.monto_usd) as total,
           sum(g.monto_usd) filter (where g.concepto in ('ads_webinar', 'ads_replay')) as ads,
           sum(g.monto_usd) filter (where g.en_opps) as en_opps
      from public.fin_webinar_gastos g
     where g.webinar_id = w.id and g.activo
  ) gs on true
 where w.activo and (public.fin_dys_puede_ver() or public.fin_gastos_puede_ver());

revoke all on public.fin_v_dys_ganancia_mes, public.fin_v_webinar_resultado from public, anon, authenticated;
grant select on public.fin_v_dys_ganancia_mes, public.fin_v_webinar_resultado to authenticated;
grant select on public.fin_v_dys_ganancia_mes, public.fin_v_webinar_resultado to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 4. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 267 OK")
-- ---------------------------------------------------------------------
do $h$
declare v_web bigint; v_ok boolean;
begin
  insert into public.fin_webinars (cliente_id, nombre, fecha) values ('liam', 'HUMO 267', date '2030-01-01') returning id into v_web;
  insert into public.fin_webinar_gastos (webinar_id, concepto, monto_usd, fecha) values (v_web, 'zoom', 1, date '2030-01-01');
  begin
    insert into public.fin_webinar_gastos (webinar_id, concepto, monto_usd, fecha) values (v_web, 'inventado', 1, date '2030-01-01');
    raise exception 'HUMO 267: aceptó un concepto inválido';
  exception when check_violation then null;
  end;
  begin
    insert into public.fin_webinars (cliente_id, nombre, fecha) values ('liam', ' humo 267 ', date '2030-01-01');
    raise exception 'HUMO 267: aceptó un webinar duplicado';
  exception when unique_violation then null;
  end;
  select exists (select 1 from pg_policies where tablename = 'fin_webinars' and policyname = 'fin_webinars_sel') into v_ok;
  if not v_ok then raise exception 'HUMO 267: falta la policy de lectura de fin_webinars'; end if;
  raise exception 'HUMO 267 OK';
end
$h$;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno; las vistas filtran por fundador: poner el uuid de un fundador en la misma ejecucion)
-- ---------------------------------------------------------------------
-- C1. Tablas y filas de arranque. Esperado: fijos 1, webinars 5, gastos 17, ajustes 2, reglas 4.
-- select (select count(*) from public.fin_dys_gastos_fijos) as fijos, (select count(*) from public.fin_webinars where activo) as webinars,
--        (select count(*) from public.fin_webinar_gastos where fuente like '267:%') as gastos,
--        (select count(*) from public.fin_webinar_ajustes where nota like '267:%') as ajustes,
--        (select count(*) from public.fin_webinar_reglas) as reglas;

-- C2. Porcentaje vigente por cliente en septiembre y octubre. Esperado octubre: agus 25, liam 30, teo 40.
-- select k.cliente_id, m.mes,
--        (select a.porcentaje from public.fin_comision_agencia a
--          where a.cliente_id = k.cliente_id and a.desde <= ((m.mes + interval '1 month')::date - 1)
--            and (a.hasta is null or a.hasta >= m.mes) order by a.desde desc limit 1) as pct
--   from (values ('liam'), ('agus'), ('teo')) k(cliente_id)
--  cross join (values (date '2026-09-01'), (date '2026-10-01')) m(mes) order by 1, 2;

-- C3. Septiembre y octubre: calculo nuevo contra el viejo (ingreso_viejo_usd = % sobre facturacion).
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, entidad, facturacion_usd, gastos_cliente_usd, ganancia_cliente_usd, porcentaje,
--        ganancia_dystopia_usd as nuevo, ingreso_viejo_usd as viejo, sin_gastos, falta_porcentaje
--   from public.fin_v_dys_ganancia_mes where mes in (date '2026-09-01', date '2026-10-01') and entidad <> 'dystopia' order by mes, entidad;
-- (misma sesion o ejecucion que el set_config)

-- C4. Totales de septiembre y octubre: bruta, gastos propios y neta.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select mes, sum(ganancia_dystopia_usd) as bruta, sum(gasto_propio_usd) as gastos_propios, sum(sueldo_usd) as sueldo,
--        sum(ganancia_dystopia_usd) - sum(gasto_propio_usd) as neta, sum(ingreso_viejo_usd) as bruta_vieja
--   from public.fin_v_dys_ganancia_mes where mes in (date '2026-09-01', date '2026-10-01') group by mes order by mes;

-- C5. Resultado de los 5 webinars. Mirar cash_vs_informado_usd: si no es 0, hay pagos sin fuente Webinar/Replay.
-- select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- select nombre, fecha, ventana_desde, ventana_hasta, ingreso_pagos_usd, pagos_n, ingreso_ajustes_usd, ingreso_probable_usd, cash_usd,
--        gastos_usd, gastos_en_opps_usd, ads_usd, ganancia_usd, roas, cash_informado, cash_vs_informado_usd
--   from public.fin_v_webinar_resultado order by fecha;

-- C6. Pagos candidatos sin fuente en la ventana de AF 25/10 (para asignar a mano desde la pantalla).
-- select count(*) as sin_fuente, sum(monto_usd) as usd from public.fin_pagos
--  where cliente_id = 'agus' and fecha between date '2026-10-25' and date '2026-11-08'
--    and fuente_ingreso is null and coalesce(btrim(fuente_lead), '') = '';

-- C7. Seguridad: anon y public sin acceso a las tablas y vistas nuevas. Esperado: 0 filas.
-- select grantee, table_name, privilege_type from information_schema.role_table_grants
--  where table_schema = 'public' and grantee in ('anon', 'PUBLIC')
--    and table_name in ('fin_dys_gastos_fijos', 'fin_webinars', 'fin_webinar_ajustes', 'fin_webinar_gastos', 'fin_webinar_reglas',
--                       'fin_v_dys_ganancia_mes', 'fin_v_webinar_resultado');

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (solo lo de esta migracion)
-- ---------------------------------------------------------------------
-- drop view if exists public.fin_v_webinar_resultado; drop view if exists public.fin_v_dys_ganancia_mes;
-- delete from public.fin_comision_agencia where nota like '267:%';
-- drop table if exists public.fin_webinar_gastos, public.fin_webinar_ajustes, public.fin_webinar_reglas, public.fin_webinars, public.fin_dys_gastos_fijos;
-- Opcional (NO incluido, es modificar datos): cerrar el porcentaje anterior con
--   update public.fin_comision_agencia set hasta = date '2026-09-30' where hasta is null and desde < date '2026-10-01' and cliente_id in ('liam','agus','teo');
-- No hace falta: la vigente de cada mes es la fila con desde mas reciente.
