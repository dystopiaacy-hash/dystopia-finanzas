-- =====================================================================
-- 011_comisiones.sql
-- FASE 2 de VENTAS: calculo de comisiones de vendedores.
--
-- Reglas implementadas:
--   closer 10%, setter 5%, sobre monto_usd (bruto), en USD.
--   Si el mismo vendedor figura como closer Y setter en la misma fila: 15%.
--   pct_override reemplaza el porcentaje de esa persona en ese cliente
--   (caso Male en agus: unica vendedora, cierra por chat, 15% siempre).
--   Columna vacia = cerro el cliente o un dueno, no hay comision de
--   vendedor y el cash entero va al reparto cliente/agencia.
--   mauro queda excluido.
--
-- fin_v_comisiones es una VISTA, no una tabla: el sync reemplaza
-- fin_pagos completo cada 15 minutos y cualquier fila colgada de un
-- pago se perderia. La foto congelada llega en la Fase 3.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Porcentaje propio por persona y cliente
-- ---------------------------------------------------------------------
alter table fin_vendedor_asignaciones
  add column if not exists pct_override numeric;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'fin_asig_pct_check'
  ) then
    alter table fin_vendedor_asignaciones
      add constraint fin_asig_pct_check
      check (pct_override is null or (pct_override >= 0 and pct_override <= 100));
  end if;
end $$;

comment on column fin_vendedor_asignaciones.pct_override is
  'Reemplaza el 10/5/15 normal para esta persona en este cliente. Null = regla estandar.';

update fin_vendedor_asignaciones a
set pct_override = 15
from fin_vendedores v
where v.id = a.vendedor_id
  and v.nombre_norm = fin_normalizar_nombre('Male')
  and a.cliente_id = 'agus'
  and a.pct_override is distinct from 15;

-- ---------------------------------------------------------------------
-- 2. Resolucion de cada pago a sus vendedores
--    El lateral con limit 1 evita duplicar si existiera un alias
--    comodin (cliente_id null) ademas del especifico.
-- ---------------------------------------------------------------------
create or replace view fin_v_pago_vendedores
with (security_invoker = true) as
select
  p.id                                as pago_id,
  p.cliente_id,
  p.fecha,
  to_char(p.fecha, 'YYYY-MM')         as periodo,
  p.alumno,
  p.programa,
  p.monto_usd,
  p.moneda_origen,
  nullif(btrim(p.closer), '')         as closer_crudo,
  nullif(btrim(p.setter), '')         as setter_crudo,
  c.vendedor_id                       as closer_vid,
  c.pct_override                      as closer_pct,
  c.comisiona                         as closer_comisiona,
  s.vendedor_id                       as setter_vid,
  s.pct_override                      as setter_pct,
  s.comisiona                         as setter_comisiona
from fin_pagos p
left join lateral (
  select a.vendedor_id, a.pct_override, a.comisiona
  from fin_personas x
  join fin_vendedor_asignaciones a
    on a.vendedor_id = x.vendedor_id
   and a.cliente_id  = p.cliente_id
  where lower(btrim(x.alias)) = lower(btrim(p.closer))
    and (x.cliente_id is null or x.cliente_id = p.cliente_id)
  order by (x.cliente_id is not null) desc
  limit 1
) c on true
left join lateral (
  select a.vendedor_id, a.pct_override, a.comisiona
  from fin_personas x
  join fin_vendedor_asignaciones a
    on a.vendedor_id = x.vendedor_id
   and a.cliente_id  = p.cliente_id
  where lower(btrim(x.alias)) = lower(btrim(p.setter))
    and (x.cliente_id is null or x.cliente_id = p.cliente_id)
  order by (x.cliente_id is not null) desc
  limit 1
) s on true
where p.cliente_id <> 'mauro';

-- ---------------------------------------------------------------------
-- 3. Una linea por comision
-- ---------------------------------------------------------------------
create or replace view fin_v_comisiones
with (security_invoker = true) as

-- CASO A: el mismo vendedor cierra y setea la misma venta -> 15%
select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  r.closer_vid                                   as vendedor_id,
  'ambos'::text                                  as rol,
  coalesce(r.closer_pct, 15)                     as pct,
  case when r.closer_comisiona
       then round(r.monto_usd * coalesce(r.closer_pct, 15) / 100, 2)
       else 0 end                                as comision_usd,
  case when r.closer_comisiona then 'calculado' else 'no_comisiona' end as estado,
  r.closer_crudo                                 as alias_usado
from fin_v_pago_vendedores r
where r.monto_usd is not null
  and r.closer_vid is not null
  and r.closer_vid = r.setter_vid

union all

-- CASO B: closer, cuando no es tambien el setter de esa fila
select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  r.closer_vid,
  'closer',
  coalesce(r.closer_pct, 10),
  case when r.closer_comisiona
       then round(r.monto_usd * coalesce(r.closer_pct, 10) / 100, 2)
       else 0 end,
  case when r.closer_comisiona then 'calculado' else 'no_comisiona' end,
  r.closer_crudo
from fin_v_pago_vendedores r
where r.monto_usd is not null
  and r.closer_vid is not null
  and r.closer_vid is distinct from r.setter_vid

union all

-- CASO C: setter, cuando no es tambien el closer de esa fila
select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  r.setter_vid,
  'setter',
  coalesce(r.setter_pct, 5),
  case when r.setter_comisiona
       then round(r.monto_usd * coalesce(r.setter_pct, 5) / 100, 2)
       else 0 end,
  case when r.setter_comisiona then 'calculado' else 'no_comisiona' end,
  r.setter_crudo
from fin_v_pago_vendedores r
where r.monto_usd is not null
  and r.setter_vid is not null
  and r.setter_vid is distinct from r.closer_vid

union all

-- CASO D: hay un nombre escrito pero no esta mapeado. BLOQUEA.
select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  null::bigint,
  'closer',
  null::numeric,
  null::numeric,
  'sin_asignar',
  r.closer_crudo
from fin_v_pago_vendedores r
where r.closer_crudo is not null and r.closer_vid is null

union all

select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  null::bigint,
  'setter',
  null::numeric,
  null::numeric,
  'sin_asignar',
  r.setter_crudo
from fin_v_pago_vendedores r
where r.setter_crudo is not null and r.setter_vid is null

union all

-- CASO E: pago cargado sin monto en USD. No se puede comisionar.
select
  r.pago_id, r.cliente_id, r.periodo, r.fecha, r.alumno, r.programa,
  r.monto_usd,
  null::bigint,
  'sin_monto',
  null::numeric,
  null::numeric,
  'sin_monto_usd',
  null
from fin_v_pago_vendedores r
where r.monto_usd is null;

-- ---------------------------------------------------------------------
-- 4. Resumen por vendedor, cliente y mes
-- ---------------------------------------------------------------------
create or replace view fin_v_comisiones_mensual
with (security_invoker = true) as
select
  c.periodo,
  c.cliente_id,
  c.vendedor_id,
  v.nombre                      as vendedor,
  c.rol,
  count(*)                      as pagos,
  round(sum(c.monto_usd), 2)    as base_usd,
  round(sum(c.comision_usd), 2) as comision_usd
from fin_v_comisiones c
join fin_vendedores v on v.id = c.vendedor_id
where c.estado = 'calculado'
group by c.periodo, c.cliente_id, c.vendedor_id, v.nombre, c.rol
order by c.periodo desc, c.cliente_id, comision_usd desc;

-- ---------------------------------------------------------------------
-- 5. Lo que impide liquidar un periodo
-- ---------------------------------------------------------------------
create or replace view fin_v_comisiones_bloqueos
with (security_invoker = true) as
select
  periodo,
  cliente_id,
  estado,
  rol,
  coalesce(alias_usado, '(sin dato)') as alias,
  count(*)                            as pagos,
  round(sum(monto_usd), 2)            as usd_afectado
from fin_v_comisiones
where estado in ('sin_asignar', 'sin_monto_usd')
group by periodo, cliente_id, estado, rol, coalesce(alias_usado, '(sin dato)')
order by usd_afectado desc;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================

-- Ningun pago debe aparecer dos veces con el mismo rol
select 'duplicados por pago y rol' as control, count(*) as valor_esperado_0
from (
  select pago_id, rol from fin_v_comisiones
  where estado = 'calculado'
  group by pago_id, rol having count(*) > 1
) d;

-- Resumen general
select
  estado,
  count(*)                    as lineas,
  round(sum(monto_usd), 2)    as base_usd,
  round(sum(comision_usd), 2) as comision_usd
from fin_v_comisiones
group by estado
order by lineas desc;

-- Comision total por cliente y mes
select periodo, cliente_id,
       round(sum(comision_usd), 2) as comision_usd
from fin_v_comisiones
where estado = 'calculado'
group by periodo, cliente_id
order by periodo desc, cliente_id;

-- Male de agus tiene que dar 15%, no 10%
select 'Male agus' as control, pct, count(*) as pagos,
       round(sum(comision_usd), 2) as comision_usd
from fin_v_comisiones c
join fin_vendedores v on v.id = c.vendedor_id
where v.nombre_norm = fin_normalizar_nombre('Male')
group by pct;

-- Lo que bloquea
select * from fin_v_comisiones_bloqueos;

-- =====================================================================
-- PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
savepoint humo;

-- Si BPF no comisiona, su comision tiene que ser 0 con estado no_comisiona
select 'humo: BPF no comisiona' as prueba,
       coalesce(sum(comision_usd), 0) as valor_esperado_0,
       count(*)                       as lineas
from fin_v_comisiones c
join fin_vendedores v on v.id = c.vendedor_id
where v.nombre_norm = fin_normalizar_nombre('BPF');

-- Al mapear un alias pendiente, tiene que dejar de estar bloqueado
insert into fin_vendedores (nombre, notas) values ('ZZZ Humo', 'prueba')
on conflict (nombre_norm) do nothing;

insert into fin_vendedor_asignaciones (vendedor_id, cliente_id, es_closer)
select id, 'liam', true from fin_vendedores where nombre = 'ZZZ Humo';

insert into fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
select null, 'liam', 'NAZA', id, 'closer'
from fin_vendedores where nombre = 'ZZZ Humo';

-- Esperado: NAZA sale de bloqueos y aparece como calculado al 10%
select 'humo: NAZA ya no bloquea' as prueba, count(*) as valor_esperado_0
from fin_v_comisiones_bloqueos
where cliente_id = 'liam' and alias = 'NAZA';

select 'humo: NAZA calculado' as prueba, pct as valor_esperado_10,
       round(sum(comision_usd), 2) as comision_usd
from fin_v_comisiones c
join fin_vendedores v on v.id = c.vendedor_id
where v.nombre = 'ZZZ Humo' and c.estado = 'calculado'
group by pct;

rollback to savepoint humo;

select 'humo revertido' as control, count(*) as valor_esperado_0
from fin_vendedores where nombre = 'ZZZ Humo';

commit;
