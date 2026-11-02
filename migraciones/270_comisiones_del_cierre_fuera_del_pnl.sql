-- =====================================================================
-- 270 · Comisiones de closers/setters: salen del Cierre de mes (269), no del P&L de Opps
-- Numero asignado por el jefe. SIN correr, SQL NO probado. Depende de 267 y 269.
--
-- QUE HACE
--   * Tabla nueva fin_pnl_comision_conceptos: patrones (ILIKE) de los items de Opps (fin_pnl.item) que son comisiones de
--     closer/setter. Configurable (alta/edicion, activo, por cliente o para todos). Sembrados activos: %closer% y %setter%.
--     '%comision%' y '%comis%' quedan sembrados INACTIVOS: pueden ser fees (Stripe) o comisiones de otros; Joaquin decide con el control C3.
--   * fin_v_dys_ganancia_mes (267) se reemplaza (mismas columnas + 6 al final):
--       - Mes CON comisiones calculadas por el cierre (hay lineas activas tipo 'comision' en fin_cierre_transferencias con monto > 0):
--         los items de Opps que matchean los patrones se EXCLUYEN de los gastos del cliente y entran las comisiones del cierre:
--         pagador 'cliente' suma a los gastos del cliente (baja su ganancia y el % de Dystopia); pagador 'dystopia' suma a
--         gasto_propio_usd de Dystopia (baja la neta de los socios); 'otro' no resta en ningun lado (se informa en comision_otro_usd).
--       - Mes SIN comisiones calculadas: se mantienen las lineas de Opps (no se excluye nada) y comision_modo = 'opps' avisa que
--         esa comision viene del Sheet. Asi septiembre (u otro mes sin Calcular transferencias) no se infla.
--     Columnas nuevas (al final): gastos_comision_usd, comision_opps_excluida_usd, comision_opps_vigente_usd, comision_otro_usd,
--     comision_modo ('cierre' | 'opps'; null en la fila de Dystopia), comision_dys_usd (solo fila Dystopia).
--     gastos_opps_usd ahora es NETO de las excluidas; gastos_cliente_usd = opps neto + manuales + webinar + comisiones del cierre.
--   * fin_v_cierre_avisos: aviso nuevo 'comision_desde_opps' (cliente y mes con comisiones tomadas de Opps).
--   * fin_cierre_generar: ahora arma PRIMERO las lineas de comision (pagador por defecto 'cliente'), y recien despues calcula la
--     neta, los socios y lo que cada cliente le debe a Dystopia (antes se calculaba la neta primero, y ahora dependen de las comisiones).
--     No pisa el pagador que ya esta en la linea (se edita por renglon en la pantalla).
--   * Default de 'quien pago' en comisiones: las lineas automaticas PENDIENTES (no hechas) de meses abiertos con pagador 'dystopia'
--     pasan a 'cliente' (respaldo en fin_cierre_transf_respaldo_270). Las hechas y los meses cerrados no se tocan.
--   No toca la sync, fin_pagos, fin_pnl ni fin_v_dys_mes (174). Sin deletes.
--
-- ORDEN: BLOQUE 1 (guardas, tabla, semillas) > 2 (vistas) > 3 (funcion) > 4 (default de quien pago) > 5 (humo, termina en
--   ERROR "HUMO 270 OK" y se revierte solo) > controles C1.. de a uno (C5 = sept/oct antes y despues) > front.
--   Correr cada bloque por separado. No correr a las :00/:15/:30/:45 ni a las 9:00.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Guardas, tabla de conceptos, RLS, semillas
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.fin_pnl') is null then v_falta := v_falta || ' fin_pnl'; end if;
  if to_regclass('public.fin_v_dys_ganancia_mes') is null then v_falta := v_falta || ' fin_v_dys_ganancia_mes(267)'; end if;
  if to_regclass('public.fin_cierre_transferencias') is null then v_falta := v_falta || ' fin_cierre_transferencias(269)'; end if;
  if to_regclass('public.fin_cierre_meses') is null then v_falta := v_falta || ' fin_cierre_meses(269)'; end if;
  if to_regclass('public.fin_v_cierre_ventas') is null then v_falta := v_falta || ' fin_v_cierre_ventas(269)'; end if;
  if to_regclass('public.fin_v_cierre_avisos') is null then v_falta := v_falta || ' fin_v_cierre_avisos(269)'; end if;
  if to_regprocedure('public.fin_cierre_generar(date)') is null then v_falta := v_falta || ' fin_cierre_generar(269)'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if to_regprocedure('public.fin_dys_puede_ver()') is null then v_falta := v_falta || ' fin_dys_puede_ver(174)'; end if;
  if v_falta <> '' then raise exception 'GUARDA 270: faltan:%', v_falta; end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 15, 30, 45) then
    raise exception 'GUARDA 270: no correr en los minutos :00/:15/:30/:45 (corre la sync). Reintentar.';
  end if;
end
$g$;

create table if not exists public.fin_pnl_comision_conceptos (
  id         bigint generated always as identity primary key,
  patron     text not null check (btrim(patron) <> ''),                 -- ILIKE sobre fin_pnl.item (con % como comodin)
  cliente_id text references public.crm_clients(id),                    -- null = vale para todos los clientes
  activo     boolean not null default true,
  nota       text,
  creado_en  timestamptz not null default now()
);
create unique index if not exists fin_pnl_comision_conceptos_uq
  on public.fin_pnl_comision_conceptos (lower(btrim(patron)), coalesce(cliente_id, '*'));

alter table public.fin_pnl_comision_conceptos enable row level security;
revoke all on table public.fin_pnl_comision_conceptos from public, anon, authenticated;
grant all on table public.fin_pnl_comision_conceptos to service_role;
grant select, insert, update on table public.fin_pnl_comision_conceptos to authenticated;
grant usage on sequence public.fin_pnl_comision_conceptos_id_seq to authenticated;
drop policy if exists fin_pnl_comision_conceptos_sel on public.fin_pnl_comision_conceptos;
create policy fin_pnl_comision_conceptos_sel on public.fin_pnl_comision_conceptos for select to authenticated using ((select public.es_fundador()));
drop policy if exists fin_pnl_comision_conceptos_ins on public.fin_pnl_comision_conceptos;
create policy fin_pnl_comision_conceptos_ins on public.fin_pnl_comision_conceptos for insert to authenticated with check ((select public.es_fundador()));
drop policy if exists fin_pnl_comision_conceptos_upd on public.fin_pnl_comision_conceptos;
create policy fin_pnl_comision_conceptos_upd on public.fin_pnl_comision_conceptos for update to authenticated
  using ((select public.es_fundador())) with check ((select public.es_fundador()));

insert into public.fin_pnl_comision_conceptos (patron, cliente_id, activo, nota)
select v.patron, null, v.activo, v.nota
  from (values
    ('%closer%',   true,  '270: items de Opps con la palabra closer (ej. Male Closer)'),
    ('%setter%',   true,  '270: items de Opps con la palabra setter (ej. Male Setter)'),
    ('%comision%', false, '270: INACTIVO. Activar solo si todo lo que dice comision en Opps es de closer/setter (puede haber fees)'),
    ('%comis%',    false, '270: INACTIVO. Abreviatura (ej. "comis"); mismo cuidado que %comision%')
  ) as v(patron, activo, nota)
 where not exists (select 1 from public.fin_pnl_comision_conceptos c
                    where lower(btrim(c.patron)) = lower(v.patron) and c.cliente_id is null);

-- respaldo del default de quien pago (BLOQUE 4)
create table if not exists public.fin_cierre_transf_respaldo_270 (
  transferencia_id bigint primary key,
  pagador_anterior text not null,
  respaldado_en    timestamptz not null default now()
);
alter table public.fin_cierre_transf_respaldo_270 enable row level security;
revoke all on table public.fin_cierre_transf_respaldo_270 from public, anon, authenticated;
grant all on table public.fin_cierre_transf_respaldo_270 to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Vistas (fin_v_dys_ganancia_mes = la de la 267 + comisiones del cierre; las columnas nuevas van AL FINAL)
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
), op as (   -- Opps: revenue declarado, gastos y, aparte, las lineas que son comisiones de closer/setter (270)
  select n.cliente_id as entidad, make_date(n.anio, n.mes, 1) as mes,
         coalesce(sum(n.monto_usd) filter (where n.categoria = 'revenue'), 0) as revenue_declarado,
         coalesce(sum(n.monto_usd) filter (where n.categoria <> 'revenue'), 0) as gastos_opps_bruto,
         coalesce(sum(n.monto_usd) filter (where n.categoria <> 'revenue' and exists (
           select 1 from public.fin_pnl_comision_conceptos r
            where r.activo and (r.cliente_id is null or r.cliente_id = n.cliente_id)
              and lower(coalesce(n.item, '')) like lower(r.patron))), 0) as comision_opps
    from public.fin_pnl n
   where n.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
), calc as (   -- meses con comisiones calculadas por el cierre (lineas activas con monto)
  select distinct t.mes
    from public.fin_cierre_transferencias t
   where t.tipo = 'comision' and t.activo and t.monto_usd > 0
), comi as (   -- comisiones del cierre por cliente y mes, segun quien pago
  select t.cliente_id as entidad, t.mes,
         coalesce(sum(t.monto_usd) filter (where t.pagador_tipo = 'cliente'), 0) as com_cliente,
         coalesce(sum(t.monto_usd) filter (where t.pagador_tipo = 'otro'), 0) as com_otro
    from public.fin_cierre_transferencias t
   where t.tipo = 'comision' and t.activo and t.cliente_id in ('liam', 'agus', 'teo')
   group by 1, 2
), comi_dys as (   -- comisiones que paga Dystopia (cualquier cliente, o sin cliente): gasto propio del mes
  select t.mes, sum(t.monto_usd) as monto
    from public.fin_cierre_transferencias t
   where t.tipo = 'comision' and t.activo and t.pagador_tipo = 'dystopia'
   group by t.mes
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
  union select entidad, mes from comi
), cli as (
  select k.entidad, k.mes,
         case when i.primer_mes is null or k.mes < i.primer_mes then coalesce(o.revenue_declarado, 0)
              else coalesce(p.ingreso_real, 0) end as facturacion_usd,
         case when i.primer_mes is null or k.mes < i.primer_mes then 'opps' else 'pagos' end as fuente_facturacion,
         (c.mes is not null) as mes_calculado,
         coalesce(o.gastos_opps_bruto, 0) - case when c.mes is not null then coalesce(o.comision_opps, 0) else 0 end as gastos_opps_usd,
         coalesce(m.gastos_manual, 0) as gastos_manual_usd,
         coalesce(w.gastos_webinar, 0) as gastos_webinar_usd,
         coalesce(cm.com_cliente, 0) as gastos_comision_usd,
         case when c.mes is not null then coalesce(o.comision_opps, 0) else 0 end as comision_opps_excluida_usd,
         case when c.mes is null then coalesce(o.comision_opps, 0) else 0 end as comision_opps_vigente_usd,
         coalesce(cm.com_otro, 0) as comision_otro_usd,
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
    left join calc c on c.mes = k.mes
    left join comi cm on cm.entidad = k.entidad and cm.mes = k.mes
), cli2 as (
  select c.*,
         c.gastos_opps_usd + c.gastos_manual_usd + c.gastos_webinar_usd + c.gastos_comision_usd as gastos_cliente_usd,
         c.facturacion_usd - (c.gastos_opps_usd + c.gastos_manual_usd + c.gastos_webinar_usd + c.gastos_comision_usd) as ganancia_cliente_usd
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
  select mes from cli2 union select mes from propio union select mes from fij union select mes from comi_dys
)
select c.mes, c.entidad, c.facturacion_usd, c.fuente_facturacion,
       c.gastos_opps_usd, c.gastos_manual_usd, c.gastos_webinar_usd, c.gastos_cliente_usd, c.ganancia_cliente_usd,
       c.porcentaje,
       round(c.ganancia_cliente_usd * coalesce(c.porcentaje, 0) / 100, 2) as ganancia_dystopia_usd,
       round(c.facturacion_usd * coalesce(c.porcentaje, 0) / 100, 2) as ingreso_viejo_usd,   -- calculo anterior (% sobre facturacion), para comparar
       (c.gastos_cliente_usd = 0 and c.facturacion_usd <> 0) as sin_gastos,
       (c.porcentaje is null) as falta_porcentaje,
       0::numeric as gasto_propio_usd, 0::numeric as sueldo_usd, 0::numeric as gasto_ia_propio_usd,
       c.gastos_comision_usd, c.comision_opps_excluida_usd, c.comision_opps_vigente_usd, c.comision_otro_usd,
       (case when c.mes_calculado then 'cierre' else 'opps' end)::text as comision_modo,
       0::numeric as comision_dys_usd
  from cli2 c
 where public.fin_dys_puede_ver()
union all
select d.mes, 'dystopia', 0, 'n/a', 0, 0, 0, 0, 0, null::numeric, 0, 0, false, false,
       coalesce(p.monto, 0) + coalesce(f.monto, 0) + coalesce(cd.monto, 0), coalesce(f.monto, 0), coalesce(p.monto_ia, 0),
       0::numeric, 0::numeric, 0::numeric, 0::numeric, null::text, coalesce(cd.monto, 0)
  from meses_dys d
  left join propio p on p.mes = d.mes
  left join fij f on f.mes = d.mes
  left join comi_dys cd on cd.mes = d.mes
 where public.fin_dys_puede_ver();

-- Avisos del cierre: la 269 + comisiones tomadas de Opps (mes sin comisiones calculadas).
create or replace view public.fin_v_cierre_avisos as
select (date_trunc('month', p.fecha))::date as mes, 'pago_sin_fuente'::text as tipo, p.cliente_id, count(*)::int as cantidad,
       coalesce(sum(p.monto_usd), 0) as monto_usd
  from public.fin_pagos p
 where p.cliente_id in ('liam', 'agus', 'teo') and p.fuente_ingreso is null and nullif(btrim(p.fuente_lead), '') is null
   and public.es_fundador()
 group by 1, 3
union all
select v.mes, case v.rol when 'closer' then 'sin_closer' else 'sin_setter' end, v.cliente_id, count(distinct v.pago_clave)::int,
       coalesce(sum(v.monto_usd), 0)
  from public.fin_v_cierre_ventas v
 where v.falta_persona
 group by v.mes, v.rol, v.cliente_id
union all
select g.mes, 'sin_gastos', g.entidad, 1, g.facturacion_usd
  from public.fin_v_dys_ganancia_mes g
 where g.sin_gastos and g.entidad <> 'dystopia'
union all
select g.mes, 'sin_porcentaje', g.entidad, 1, g.facturacion_usd
  from public.fin_v_dys_ganancia_mes g
 where g.falta_porcentaje and g.entidad <> 'dystopia' and g.facturacion_usd <> 0
union all
select t.mes, 'transferencia_pendiente', t.cliente_id, count(*)::int, coalesce(sum(t.monto_usd), 0)
  from public.fin_cierre_transferencias t
 where t.activo and t.estado = 'pendiente' and t.monto_usd > 0 and public.es_fundador()
 group by t.mes, t.cliente_id
union all
select t.mes, 'diferencia_con_calculo', t.cliente_id, count(*)::int, coalesce(sum(t.monto_calc - t.monto_usd), 0)
  from public.fin_cierre_transferencias t
 where t.activo and t.estado = 'hecha' and t.monto_calc is not null and t.monto_calc <> t.monto_usd and public.es_fundador()
 group by t.mes, t.cliente_id
union all
select g.mes, 'comision_desde_opps', g.entidad, 1, g.comision_opps_vigente_usd
  from public.fin_v_dys_ganancia_mes g
 where g.entidad <> 'dystopia' and g.comision_modo = 'opps' and g.comision_opps_vigente_usd <> 0;

revoke all on public.fin_v_dys_ganancia_mes, public.fin_v_cierre_avisos from public, anon, authenticated;
grant select on public.fin_v_dys_ganancia_mes, public.fin_v_cierre_avisos to authenticated;
grant select on public.fin_v_dys_ganancia_mes, public.fin_v_cierre_avisos to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 3. fin_cierre_generar: comisiones primero, despues neta / socios / clientes
-- ---------------------------------------------------------------------
create or replace function public.fin_cierre_generar(p_mes date)
returns integer language plpgsql security definer set search_path = public as $f$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_bruta numeric; v_propio numeric; v_neta numeric; v_n int; v_n2 int;
begin
  if not coalesce(public.es_fundador(), false) then raise exception 'Solo fundador'; end if;
  if exists (select 1 from public.fin_cierre_meses m where m.mes = v_mes and m.estado = 'cerrado') then
    raise exception 'El mes % esta cerrado: reabrirlo para recalcular', to_char(v_mes, 'YYYY-MM');
  end if;

  -- PASO 1. Comisiones de closers y setters, una linea por persona y cliente. Quien pago: 'cliente' por defecto
  -- (en una linea que ya existe no se pisa: se edita por renglon). Las comisiones restan de la ganancia del cliente o de
  -- la neta de Dystopia segun el pagador (fin_v_dys_ganancia_mes), por eso van antes de calcular la neta.
  with cand as (
    select 'com:' || v.cliente_id || ':' || v.persona_norm as clave_auto, 'comision'::text as tipo, min(v.persona) as destinatario,
           'Comisiones ' || to_char(v_mes, 'YYYY-MM') || ' (' || string_agg(distinct v.rol, ' + ') || ', '
             || count(distinct v.pago_clave) || ' ventas)' as concepto,
           sum(v.comision_usd) as monto_usd, v.cliente_id, 'cliente'::text as pagador_tipo
      from public.fin_v_cierre_ventas v
     where v.mes = v_mes and v.persona_norm is not null and not v.no_comisiona
     group by v.cliente_id, v.persona_norm
    having sum(v.comision_usd) <> 0
  ), ins as (
    insert into public.fin_cierre_transferencias as t
      (mes, tipo, destinatario, concepto, monto_usd, monto_calc, cliente_id, pagador_tipo, auto, clave_auto)
    select v_mes, c.tipo, c.destinatario, c.concepto, c.monto_usd, c.monto_usd, c.cliente_id, c.pagador_tipo, true, c.clave_auto
      from cand c
    on conflict (mes, clave_auto) do update
      set monto_calc = excluded.monto_usd,
          monto_usd = case when t.estado = 'pendiente' then excluded.monto_usd else t.monto_usd end,
          concepto = case when t.estado = 'pendiente' then excluded.concepto else t.concepto end,
          destinatario = case when t.estado = 'pendiente' then excluded.destinatario else t.destinatario end,
          activo = case when t.estado = 'pendiente' and not t.baja_manual then true else t.activo end,
          actualizado_en = now()
    returning 1
  ), baja as (
    update public.fin_cierre_transferencias t
       set activo = false, actualizado_en = now()
     where t.mes = v_mes and t.auto and t.tipo = 'comision' and t.estado = 'pendiente' and t.activo
       and not exists (select 1 from cand c where c.clave_auto = t.clave_auto)
    returning 1
  )
  select (select count(*) from ins) + (select count(*) from baja) into v_n;

  -- PASO 2. Neta, socios y lo que cada cliente le transfiere a Dystopia (ya con las comisiones del paso 1)
  select coalesce(sum(g.ganancia_dystopia_usd), 0), coalesce(sum(g.gasto_propio_usd), 0) into v_bruta, v_propio
    from public.fin_v_dys_ganancia_mes g where g.mes = v_mes;
  v_neta := v_bruta - v_propio;

  with cand as (
    -- sueldo y demas gastos fijos vigentes en el mes
    select 'fijo:' || f.id as clave_auto,
           case when f.concepto ilike 'sueldo%' then 'sueldo' else 'equipo' end as tipo,
           coalesce(nullif(btrim(regexp_replace(f.concepto, '^sueldo\s*', '', 'i')), ''), f.concepto) as destinatario,
           f.concepto || ' ' || to_char(v_mes, 'YYYY-MM') as concepto,
           f.monto_usd as monto_usd, null::text as cliente_id, 'dystopia'::text as pagador_tipo
      from public.fin_dys_gastos_fijos f
     where f.activo and date_trunc('month', f.desde)::date <= v_mes
       and (f.hasta is null or date_trunc('month', f.hasta)::date >= v_mes)
    union all
    -- reparto de la ganancia neta entre socios
    select 'socio:' || s.id, 'socio', s.nombre,
           'Reparto de la ganancia neta ' || to_char(v_mes, 'YYYY-MM') || ' (' || s.porcentaje || '% de ' || round(v_neta, 2) || ')',
           round(v_neta * s.porcentaje / 100, 2), null::text, 'dystopia'
      from public.fin_cierre_socios s
     where s.activo and v_neta > 0 and date_trunc('month', s.desde)::date <= v_mes
       and (s.hasta is null or date_trunc('month', s.hasta)::date >= v_mes)
    union all
    -- lo que cada cliente le transfiere a Dystopia
    select 'cli:' || g.entidad, 'cliente', 'Dystopia',
           'Participacion de Dystopia ' || to_char(v_mes, 'YYYY-MM') || ' (' || coalesce(g.porcentaje, 0) || '% de la ganancia del cliente)',
           g.ganancia_dystopia_usd, g.entidad, 'cliente'
      from public.fin_v_dys_ganancia_mes g
     where g.mes = v_mes and g.entidad <> 'dystopia' and g.ganancia_dystopia_usd > 0
  ), ins as (
    insert into public.fin_cierre_transferencias as t
      (mes, tipo, destinatario, concepto, monto_usd, monto_calc, cliente_id, pagador_tipo, auto, clave_auto)
    select v_mes, c.tipo, c.destinatario, c.concepto, c.monto_usd, c.monto_usd, c.cliente_id, c.pagador_tipo, true, c.clave_auto
      from cand c
    on conflict (mes, clave_auto) do update
      set monto_calc = excluded.monto_usd,
          monto_usd = case when t.estado = 'pendiente' then excluded.monto_usd else t.monto_usd end,
          concepto = case when t.estado = 'pendiente' then excluded.concepto else t.concepto end,
          destinatario = case when t.estado = 'pendiente' then excluded.destinatario else t.destinatario end,
          activo = case when t.estado = 'pendiente' and not t.baja_manual then true else t.activo end,
          actualizado_en = now()
    returning 1
  ), baja as (
    update public.fin_cierre_transferencias t
       set activo = false, actualizado_en = now()
     where t.mes = v_mes and t.auto and t.tipo <> 'comision' and t.estado = 'pendiente' and t.activo
       and not exists (select 1 from cand c where c.clave_auto = t.clave_auto)
    returning 1
  )
  select (select count(*) from ins) + (select count(*) from baja) into v_n2;
  return v_n + v_n2;
end
$f$;

revoke all on function public.fin_cierre_generar(date) from public, anon;
grant execute on function public.fin_cierre_generar(date) to authenticated;

-- ---------------------------------------------------------------------
-- BLOQUE 4. Default de "quien pago" en comisiones: PENDIENTES automaticas de meses abiertos, de 'dystopia' a 'cliente'
--   (con respaldo; las hechas y los meses cerrados no se tocan). Despues de esto, "Calcular transferencias" de cada mes
--   recalcula la neta y los socios.
-- ---------------------------------------------------------------------
do $d$
begin
  insert into public.fin_cierre_transf_respaldo_270 (transferencia_id, pagador_anterior)
  select t.id, t.pagador_tipo
    from public.fin_cierre_transferencias t
   where t.tipo = 'comision' and t.auto and t.estado = 'pendiente' and t.pagador_tipo = 'dystopia'
     and not exists (select 1 from public.fin_cierre_meses m where m.mes = t.mes and m.estado = 'cerrado')
  on conflict (transferencia_id) do nothing;

  update public.fin_cierre_transferencias t
     set pagador_tipo = 'cliente', pagador_texto = null, actualizado_en = now()
   where t.id in (select transferencia_id from public.fin_cierre_transf_respaldo_270)
     and t.tipo = 'comision' and t.auto and t.estado = 'pendiente' and t.pagador_tipo = 'dystopia'
     and not exists (select 1 from public.fin_cierre_meses m where m.mes = t.mes and m.estado = 'cerrado');
end
$d$;

-- ---------------------------------------------------------------------
-- BLOQUE 5. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 270 OK"). No usa las vistas (piden fundador).
-- ---------------------------------------------------------------------
do $h$
begin
  if (select count(*) from public.fin_pnl_comision_conceptos where activo and cliente_id is null and patron in ('%closer%', '%setter%')) < 2 then
    raise exception 'HUMO 270: faltan los conceptos de closer y setter activos';
  end if;
  -- un patron repetido (mismo texto y cliente) lo frena el indice unico
  begin
    insert into public.fin_pnl_comision_conceptos (patron) values ('%CLOSER%');
    raise exception 'HUMO 270: acepto un patron repetido';
  exception when unique_violation then null;
  end;
  begin
    insert into public.fin_pnl_comision_conceptos (patron) values ('  ');
    raise exception 'HUMO 270: acepto un patron vacio';
  exception when check_violation then null;
  end;
  -- comision de un mes abierto con pagador cliente y con pagador dystopia
  insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd, cliente_id, pagador_tipo)
  values (date '2099-01-01', 'comision', 'HUMO', 'HUMO 270 cliente', 100, 'liam', 'cliente'),
         (date '2099-01-01', 'comision', 'HUMO', 'HUMO 270 dystopia', 50, 'liam', 'dystopia');
  -- el patron matchea como espera la vista
  if not ('male closer' like lower('%closer%')) or ('stripe fee' like lower('%closer%')) then
    raise exception 'HUMO 270: el patron no matchea como se espera';
  end if;
  raise exception 'HUMO 270 OK';
end
$h$;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno; las vistas y funciones piden fundador: poner el uuid de un fundador en la misma ejecucion)
-- ---------------------------------------------------------------------
-- C1. Conceptos. Esperado: %closer% y %setter% activos, %comision% y %comis% inactivos.
-- select patron, cliente_id, activo, nota from public.fin_pnl_comision_conceptos order by id;
-- C2. LISTA EXACTA de lo que queda excluido de Opps por cliente y mes (patrones activos), con la marca de si el mes tiene
--     comisiones calculadas por el cierre (solo en esos meses se excluye de verdad). Sept/oct 2026:
-- select n.cliente_id, make_date(n.anio, n.mes, 1) as mes, n.item, n.categoria, n.monto_usd,
--        exists (select 1 from public.fin_cierre_transferencias t where t.tipo = 'comision' and t.activo and t.monto_usd > 0
--                 and t.mes = make_date(n.anio, n.mes, 1)) as mes_con_comisiones_del_cierre
--   from public.fin_pnl n
--  where n.categoria <> 'revenue' and n.cliente_id in ('liam', 'agus', 'teo') and make_date(n.anio, n.mes, 1) in (date '2026-09-01', date '2026-10-01')
--    and exists (select 1 from public.fin_pnl_comision_conceptos r where r.activo and (r.cliente_id is null or r.cliente_id = n.cliente_id)
--                 and lower(coalesce(n.item, '')) like lower(r.patron))
--  order by 1, 2, 3;
-- C3. Items de Opps que dicen "comis" y NO matchean ningun patron activo (decidir si activar %comision% / %comis% o agregar un patron):
-- select n.cliente_id, make_date(n.anio, n.mes, 1) as mes, n.item, n.monto_usd
--   from public.fin_pnl n
--  where n.categoria <> 'revenue' and lower(coalesce(n.item, '')) like '%comis%'
--    and not exists (select 1 from public.fin_pnl_comision_conceptos r where r.activo and (r.cliente_id is null or r.cliente_id = n.cliente_id)
--                     and lower(coalesce(n.item, '')) like lower(r.patron))
--  order by 1, 2, 3;
-- C4. Items de Opps por mes que NO se excluyen y parecen personas de ventas (revisar a ojo si falta algun patron): todos los items de sept/oct.
-- select n.cliente_id, make_date(n.anio, n.mes, 1) as mes, n.categoria, n.item, n.monto_usd
--   from public.fin_pnl n
--  where n.categoria <> 'revenue' and n.cliente_id in ('liam', 'agus', 'teo') and make_date(n.anio, n.mes, 1) in (date '2026-09-01', date '2026-10-01')
--  order by 1, 2, 3, 4;
-- C5. SEPTIEMBRE / OCTUBRE por cliente, ANTES (calculo de la 267) y DESPUES (270). Corre con la 270 ya aplicada: "antes" se reconstruye
--     (gastos antes = gastos ahora - comisiones del cierre + comisiones de Opps excluidas). Sept sin Calcular transferencias = antes igual a despues.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select g.mes, g.entidad, g.comision_modo,
--        g.gastos_cliente_usd - g.gastos_comision_usd + g.comision_opps_excluida_usd as gastos_antes,
--        g.gastos_cliente_usd as gastos_despues,
--        g.facturacion_usd - (g.gastos_cliente_usd - g.gastos_comision_usd + g.comision_opps_excluida_usd) as ganancia_antes,
--        g.ganancia_cliente_usd as ganancia_despues,
--        round((g.facturacion_usd - (g.gastos_cliente_usd - g.gastos_comision_usd + g.comision_opps_excluida_usd)) * coalesce(g.porcentaje, 0) / 100, 2) as dystopia_antes,
--        g.ganancia_dystopia_usd as dystopia_despues,
--        g.comision_opps_excluida_usd, g.comision_opps_vigente_usd, g.gastos_comision_usd as comision_cierre_cliente, g.comision_otro_usd
--   from public.fin_v_dys_ganancia_mes g
--  where g.entidad <> 'dystopia' and g.mes in (date '2026-09-01', date '2026-10-01') order by g.mes, g.entidad;
-- C5b. Lo mismo para Dystopia (gastos propios y comisiones que paga Dystopia):
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select mes, gasto_propio_usd, sueldo_usd, comision_dys_usd, gasto_propio_usd - comision_dys_usd as gasto_propio_antes
--   from public.fin_v_dys_ganancia_mes where entidad = 'dystopia' and mes in (date '2026-09-01', date '2026-10-01') order by mes;
-- C6. Calcular las transferencias de octubre (ESCRIBE en fin_cierre_transferencias) y volver a correr C5 / C5b / C7.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select public.fin_cierre_generar(date '2026-10-01');
-- C7. Comisiones de octubre y quien pago (esperado: 'cliente' en las automaticas pendientes; las hechas conservan lo que tenian).
-- select destinatario, cliente_id, monto_usd, pagador_tipo, estado from public.fin_cierre_transferencias
--  where mes = date '2026-10-01' and tipo = 'comision' and activo order by cliente_id, destinatario;
-- C8. Doble conteo: no deberia haber mes 'cierre' con comision_opps_vigente_usd > 0 (esperado 0 filas).
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select mes, entidad, comision_modo, comision_opps_vigente_usd from public.fin_v_dys_ganancia_mes
--  where comision_modo = 'cierre' and comision_opps_vigente_usd <> 0;
-- C9. Meses que siguen tomando las comisiones de Opps (sin Calcular transferencias) y cuanto:
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select mes, entidad, comision_opps_vigente_usd from public.fin_v_dys_ganancia_mes
--  where comision_modo = 'opps' and comision_opps_vigente_usd <> 0 order by mes, entidad;
-- C10. Vuelta atras del default de quien pago (solo las que no se editaron despues):
-- update public.fin_cierre_transferencias t set pagador_tipo = r.pagador_anterior
--   from public.fin_cierre_transf_respaldo_270 r where r.transferencia_id = t.id and t.estado = 'pendiente' and t.pagador_tipo = 'cliente';
-- C11. Vuelta atras de vistas y funcion: volver a correr el bloque 3 de la 267 (fin_v_dys_ganancia_mes), el de la 269 (fin_v_cierre_avisos y fin_cierre_generar);
--      despues: drop table public.fin_pnl_comision_conceptos, public.fin_cierre_transf_respaldo_270;
