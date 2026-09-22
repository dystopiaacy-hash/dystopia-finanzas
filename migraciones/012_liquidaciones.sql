-- =====================================================================
-- 012_liquidaciones.sql
-- FASE 3 de VENTAS: liquidacion mensual congelada.
--
-- Problema que resuelve: fin_v_comisiones es una vista sobre fin_pagos,
-- y el sync reemplaza fin_pagos entero cada 15 minutos. Si alguien edita
-- la planilla en octubre, la comision de agosto cambia sola. Una vez que
-- la plata se pago, eso no puede pasar.
--
-- Reglas confirmadas con la agencia:
--   Un periodo cerrado NO se recalcula nunca.
--   Los refunds se imputan al mes en que ocurren, no al mes original.
--   Las comisiones rigen desde el mes de lanzamiento; lo anterior se
--   puede cerrar como 'historico' para referencia, sin pagar.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Cabecera: un periodo por cliente
-- ---------------------------------------------------------------------
create table if not exists fin_liquidaciones (
  id           bigserial primary key,
  cliente_id   text        not null references crm_clients(id),
  periodo      text        not null,
  estado       text        not null default 'abierta',
  tipo         text        not null default 'pagable',
  cerrada_en   timestamptz,
  cerrada_por  uuid        references auth.users(id),
  bloqueos     jsonb,
  nota         text,
  creada       timestamptz not null default now(),
  unique (cliente_id, periodo),
  constraint fin_liq_periodo_check check (periodo ~ '^\d{4}-\d{2}$'),
  constraint fin_liq_estado_check  check (estado in ('abierta', 'cerrada')),
  constraint fin_liq_tipo_check    check (tipo in ('pagable', 'historico'))
);

comment on column fin_liquidaciones.tipo is
  'historico = periodo anterior al lanzamiento, se congela como referencia pero no se paga.';
comment on column fin_liquidaciones.bloqueos is
  'Foto de lo que estaba sin asignar al momento de cerrar. Deja constancia de que se cerro sabiendolo.';

-- ---------------------------------------------------------------------
-- 2. Detalle congelado. El sync NUNCA toca esta tabla.
--    Los datos se copian, no se referencian: pago_id queda como dato
--    historico sin foreign key, porque el pago original desaparece en
--    la proxima corrida del sync.
-- ---------------------------------------------------------------------
create table if not exists fin_liquidacion_items (
  id              bigserial primary key,
  liquidacion_id  bigint  not null references fin_liquidaciones(id) on delete cascade,
  vendedor_id     bigint  not null references fin_vendedores(id),
  vendedor_nombre text    not null,
  rol             text    not null,
  pago_id         bigint,
  fecha           date    not null,
  alumno          text,
  programa        text,
  alias_usado     text,
  base_usd        numeric not null,
  pct             numeric not null,
  comision_usd    numeric not null,
  origen          text    not null default 'calculo',
  nota            text,
  constraint fin_liq_item_origen_check check (origen in ('calculo', 'ajuste'))
);

comment on column fin_liquidacion_items.origen is
  'ajuste = linea cargada a mano: correccion de un periodo anterior o refund que llega tarde.';
comment on column fin_liquidacion_items.pago_id is
  'Sin foreign key a proposito: el pago original se borra en cada corrida del sync.';

create index if not exists fin_liq_items_liq_idx
  on fin_liquidacion_items (liquidacion_id);
create index if not exists fin_liq_items_vendedor_idx
  on fin_liquidacion_items (vendedor_id);

-- ---------------------------------------------------------------------
-- 3. RLS
-- ---------------------------------------------------------------------
alter table fin_liquidaciones       enable row level security;
alter table fin_liquidacion_items   enable row level security;

drop policy if exists fin_liq_lectura on fin_liquidaciones;
create policy fin_liq_lectura on fin_liquidaciones
for select using (
  es_fundador()
  or tiene_acceso(cliente_id)
  or cliente_id in (select fin_clientes_del_usuario())
);

drop policy if exists fin_liq_escritura on fin_liquidaciones;
create policy fin_liq_escritura on fin_liquidaciones
for all using (es_fundador()) with check (es_fundador());

-- Un vendedor ve SOLO sus propias lineas. El cliente ve las de su cliente.
drop policy if exists fin_liq_items_lectura on fin_liquidacion_items;
create policy fin_liq_items_lectura on fin_liquidacion_items
for select using (
  es_fundador()
  or exists (
    select 1 from fin_liquidaciones l
    where l.id = fin_liquidacion_items.liquidacion_id
      and tiene_acceso(l.cliente_id)
  )
  or exists (
    select 1 from fin_personas p
    where p.user_id = auth.uid()
      and p.vendedor_id = fin_liquidacion_items.vendedor_id
  )
);

drop policy if exists fin_liq_items_escritura on fin_liquidacion_items;
create policy fin_liq_items_escritura on fin_liquidacion_items
for all using (es_fundador()) with check (es_fundador());

-- ---------------------------------------------------------------------
-- 4. Que bloquea cerrar un periodo
-- ---------------------------------------------------------------------
create or replace function fin_bloqueos_periodo(p_cliente text, p_periodo text)
returns jsonb
language sql
stable
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'estado',       b.estado,
      'rol',          b.rol,
      'alias',        b.alias,
      'pagos',        b.pagos,
      'usd_afectado', b.usd_afectado
    )),
    '[]'::jsonb)
  from fin_v_comisiones_bloqueos b
  where b.cliente_id = p_cliente
    and b.periodo    = p_periodo;
$$;

-- ---------------------------------------------------------------------
-- 5. Cerrar un periodo
--    Copia las lineas calculadas y las congela.
--    Se niega si el periodo ya esta cerrado.
--    Se niega si hay bloqueos, salvo p_forzar = true, y en ese caso
--    deja constancia de lo que se ignoro.
-- ---------------------------------------------------------------------
create or replace function fin_cerrar_periodo(
  p_cliente text,
  p_periodo text,
  p_tipo    text default 'pagable',
  p_forzar  boolean default false,
  p_nota    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_liq_id    bigint;
  v_bloqueos  jsonb;
  v_lineas    integer;
  v_total     numeric;
begin
  -- auth.uid() es null cuando corre desde el SQL Editor o con service_role,
  -- que ya tienen acceso total. El guard aplica a usuarios autenticados.
  if auth.uid() is not null and not es_fundador() then
    raise exception 'Solo un fundador puede cerrar un periodo';
  end if;

  if p_periodo !~ '^\d{4}-\d{2}$' then
    raise exception 'Periodo invalido: % (formato esperado YYYY-MM)', p_periodo;
  end if;

  if exists (
    select 1 from fin_liquidaciones
    where cliente_id = p_cliente and periodo = p_periodo and estado = 'cerrada'
  ) then
    raise exception 'El periodo % de % ya esta cerrado. Un periodo cerrado no se recalcula: cargá un ajuste en el periodo abierto.', p_periodo, p_cliente;
  end if;

  v_bloqueos := fin_bloqueos_periodo(p_cliente, p_periodo);

  if jsonb_array_length(v_bloqueos) > 0 and not p_forzar then
    return jsonb_build_object(
      'cerrado',  false,
      'motivo',   'hay bloqueos sin resolver',
      'bloqueos', v_bloqueos
    );
  end if;

  insert into fin_liquidaciones (cliente_id, periodo, estado, tipo, cerrada_en, cerrada_por, bloqueos, nota)
  values (p_cliente, p_periodo, 'cerrada', p_tipo, now(), auth.uid(), v_bloqueos, p_nota)
  on conflict (cliente_id, periodo) do update
    set estado      = 'cerrada',
        tipo        = excluded.tipo,
        cerrada_en  = excluded.cerrada_en,
        cerrada_por = excluded.cerrada_por,
        bloqueos    = excluded.bloqueos,
        nota        = excluded.nota
  returning id into v_liq_id;

  -- Las lineas de calculo se reemplazan; los ajustes cargados a mano se conservan.
  delete from fin_liquidacion_items
  where liquidacion_id = v_liq_id and origen = 'calculo';

  insert into fin_liquidacion_items (
    liquidacion_id, vendedor_id, vendedor_nombre, rol, pago_id,
    fecha, alumno, programa, alias_usado, base_usd, pct, comision_usd, origen
  )
  select
    v_liq_id, c.vendedor_id, v.nombre, c.rol, c.pago_id,
    c.fecha, c.alumno, c.programa, c.alias_usado,
    c.monto_usd, c.pct, c.comision_usd, 'calculo'
  from fin_v_comisiones c
  join fin_vendedores v on v.id = c.vendedor_id
  where c.cliente_id = p_cliente
    and c.periodo    = p_periodo
    and c.estado     = 'calculado';

  select count(*), coalesce(sum(comision_usd), 0)
  into v_lineas, v_total
  from fin_liquidacion_items
  where liquidacion_id = v_liq_id;

  return jsonb_build_object(
    'cerrado',      true,
    'liquidacion',  v_liq_id,
    'cliente',      p_cliente,
    'periodo',      p_periodo,
    'tipo',         p_tipo,
    'lineas',       v_lineas,
    'comision_usd', v_total,
    'bloqueos',     v_bloqueos
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. Vistas de consulta
-- ---------------------------------------------------------------------

-- Lo que cobra cada vendedor en un periodo ya cerrado
create or replace view fin_v_liquidacion_vendedor
with (security_invoker = true) as
select
  l.cliente_id,
  l.periodo,
  l.estado,
  l.tipo,
  i.vendedor_id,
  i.vendedor_nombre,
  count(*)                      as lineas,
  round(sum(i.base_usd), 2)     as base_usd,
  round(sum(i.comision_usd), 2) as comision_usd
from fin_liquidaciones l
join fin_liquidacion_items i on i.liquidacion_id = l.id
group by l.cliente_id, l.periodo, l.estado, l.tipo, i.vendedor_id, i.vendedor_nombre
order by l.periodo desc, l.cliente_id, comision_usd desc;

-- Periodos abiertos y cerrados, con lo que el calculo dice hoy
create or replace view fin_v_periodos
with (security_invoker = true) as
select
  c.cliente_id,
  c.periodo,
  coalesce(l.estado, 'abierta')                        as estado,
  l.tipo,
  l.cerrada_en,
  round(sum(c.comision_usd) filter
    (where c.estado = 'calculado'), 2)                 as comision_calculada_hoy,
  count(*) filter (where c.estado = 'sin_asignar')     as lineas_bloqueadas,
  round(sum(c.monto_usd) filter
    (where c.estado = 'sin_asignar'), 2)               as usd_bloqueado
from fin_v_comisiones c
left join fin_liquidaciones l
  on l.cliente_id = c.cliente_id and l.periodo = c.periodo
group by c.cliente_id, c.periodo, l.estado, l.tipo, l.cerrada_en
order by c.periodo desc, c.cliente_id;

-- Alerta: lo congelado dejo de coincidir con lo que calcula hoy.
-- Significa que alguien edito la planilla de un mes ya pagado.
create or replace view fin_v_liquidaciones_desviadas
with (security_invoker = true) as
select
  l.cliente_id,
  l.periodo,
  l.cerrada_en,
  round(coalesce(cong.total, 0), 2)                       as congelado_usd,
  round(coalesce(hoy.total, 0), 2)                        as calculado_hoy_usd,
  round(coalesce(hoy.total, 0) - coalesce(cong.total, 0), 2) as diferencia_usd
from fin_liquidaciones l
left join lateral (
  select sum(i.comision_usd) as total
  from fin_liquidacion_items i
  where i.liquidacion_id = l.id and i.origen = 'calculo'
) cong on true
left join lateral (
  select sum(c.comision_usd) as total
  from fin_v_comisiones c
  where c.cliente_id = l.cliente_id
    and c.periodo    = l.periodo
    and c.estado     = 'calculado'
) hoy on true
where l.estado = 'cerrada'
  and abs(coalesce(hoy.total, 0) - coalesce(cong.total, 0)) > 0.01
order by abs(coalesce(hoy.total, 0) - coalesce(cong.total, 0)) desc;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================
select 'tablas creadas' as control, count(*) as valor_esperado_2
from information_schema.tables
where table_schema = 'public'
  and table_name in ('fin_liquidaciones', 'fin_liquidacion_items');

select 'funciones creadas' as control, count(*) as valor_esperado_2
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('fin_cerrar_periodo', 'fin_bloqueos_periodo');

-- Estado actual de cada periodo, todos abiertos todavia
select * from fin_v_periodos;

-- =====================================================================
-- PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
savepoint humo;

-- lucas 2026-06 no tiene bloqueos: tiene que cerrar limpio
select 'humo: cierre limpio' as prueba,
       fin_cerrar_periodo('lucas', '2026-06') as resultado;

-- Cerrar dos veces tiene que fallar
do $$
begin
  begin
    perform fin_cerrar_periodo('lucas', '2026-06');
    raise exception 'FALLO: permitio cerrar dos veces el mismo periodo';
  exception when others then
    if sqlerrm like '%ya esta cerrado%' then
      raise notice 'OK: rechaza cerrar un periodo ya cerrado';
    else
      raise;
    end if;
  end;
end $$;

-- Un periodo CON bloqueos no tiene que cerrar, y forzado si.
-- Se elige el periodo en tiempo real en vez de hardcodearlo: cual esta
-- bloqueado depende de que alias falte mapear en este momento.
do $$
declare
  v_cli text;
  v_per text;
  v_res jsonb;
begin
  select cliente_id, periodo into v_cli, v_per
  from fin_v_comisiones_bloqueos
  where estado = 'sin_asignar'
  limit 1;

  if v_cli is null then
    raise notice 'SALTEADO: no quedan periodos bloqueados para probar';
    return;
  end if;

  v_res := fin_cerrar_periodo(v_cli, v_per);
  if (v_res->>'cerrado')::boolean then
    raise exception 'FALLO: cerro % % teniendo bloqueos', v_cli, v_per;
  end if;
  raise notice 'OK: rechaza cerrar % % con bloqueos', v_cli, v_per;

  v_res := fin_cerrar_periodo(v_cli, v_per, 'pagable', true, 'prueba de humo');
  if not (v_res->>'cerrado')::boolean then
    raise exception 'FALLO: no cerro forzado';
  end if;

  if jsonb_array_length(v_res->'bloqueos') = 0 then
    raise exception 'FALLO: cerro forzado sin dejar constancia de los bloqueos';
  end if;
  raise notice 'OK: cierre forzado deja constancia de % bloqueos',
    jsonb_array_length(v_res->'bloqueos');
end $$;

-- Lo congelado tiene que coincidir con lo calculado, sin desviacion
select 'humo: sin desviacion' as prueba, count(*) as valor_esperado_0
from fin_v_liquidaciones_desviadas;

select 'humo: detalle por vendedor' as prueba, *
from fin_v_liquidacion_vendedor
where cliente_id = 'lucas' and periodo = '2026-06';

rollback to savepoint humo;

select 'humo revertido' as control, count(*) as valor_esperado_0
from fin_liquidaciones;

commit;
