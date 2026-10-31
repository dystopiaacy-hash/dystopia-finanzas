-- =====================================================================
-- 266_liam_catalogo_ivo_franco_lagrega.sql
-- FINANZAS. Suma a IVO y a FRANCO LAGREGA a los catalogos de LIAM (aprobado por Joaquin):
--   a) quien recibe  -> fin_catalogos (dimension 'quien_recibe') + fin_catalogo_alias (aprobado = true)
--   b) closer y setter -> fin_vendedores + fin_vendedor_asignaciones (es_closer y es_setter) + fin_personas (alias, campo 'ambos')
-- Formato = el de la 064 (catalogos), 010/077/116 (vendedores y alias). De ahi salen las listas de Cargar pago
-- (fin_carga_config: 'quien_recibe', 'closers', 'setters'); en el codigo JS NO hay listas fijas.
--
-- NO toca pagos (ni texto crudo ni *_id), ni columnas, ni otros valores del catalogo. Los 19 pagos de la 262 con
-- quien_recibe 'IVO' / 'FRANCO LAGREGA' quedan con quien_recibe_id nulo hasta que se corra el paso OPCIONAL del final
-- (el trigger de la 064 solo completa en INSERT).
-- Franco Lagrega ya existe como vendedor (closer de teo, 010): se reutiliza, solo se le suma la asignacion a liam.
-- Idempotente (re-correrla no agrega nada). Registro de lo agregado: fin_catalogos_agregados_266 (para la vuelta atras).
-- Guardas: minuto (no :00/:14/:15/:29/:30/:44/:45 por la sync), existe la 064, existe cliente liam, y ningun alias
-- de liam ('IVO', 'FRANCO LAGREGA', 'FRAN LAGREGA') apunta ya a OTRO vendedor.
-- Controles C1 a C5 y vuelta atras al final (de a uno).
-- =====================================================================

begin;

set local lock_timeout = '10s';
lock table public.fin_catalogos, public.fin_catalogo_alias, public.fin_vendedores,
           public.fin_vendedor_asignaciones, public.fin_personas
  in share row exclusive mode;

do $g$
declare m int := extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int;
        v_otro text;
begin
  if m % 15 in (0, 14) then
    raise exception 'GUARDA 266: minuto % (corre la sync en :00/:15/:30/:45). Correr en otro minuto. No se toca nada.', m;
  end if;
  if to_regclass('public.fin_catalogo_alias') is null or to_regprocedure('public.fin_normalizar_alias(text)') is null then
    raise exception 'GUARDA 266: falta la 064 (fin_catalogo_alias). No se toca nada.';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception 'GUARDA 266: no existe el cliente liam. No se toca nada.';
  end if;
  -- un alias de liam que ya apunta a otro vendedor se "llevaria" sus pagos: se frena.
  select v.nombre into v_otro
    from public.fin_personas x join public.fin_vendedores v on v.id = x.vendedor_id
   where x.cliente_id = 'liam'
     and lower(btrim(x.alias)) in ('ivo', 'franco lagrega', 'fran lagrega')
     and v.nombre_norm not in (public.fin_normalizar_nombre('Ivo'), public.fin_normalizar_nombre('Franco Lagrega'))
   limit 1;
  if v_otro is not null then
    raise exception 'GUARDA 266: un alias de liam (IVO / FRANCO LAGREGA) ya apunta a "%". Resolver a mano. No se toca nada.', v_otro;
  end if;
end
$g$;

-- Registro de lo que agrega esta migracion (vuelta atras sin tocar lo que ya existia).
create table if not exists public.fin_catalogos_agregados_266 (
  tipo text   not null check (tipo in ('catalogo', 'alias_catalogo', 'vendedor', 'asignacion', 'persona')),
  id   bigint not null,
  primary key (tipo, id)
);
alter table public.fin_catalogos_agregados_266 enable row level security;
revoke all on public.fin_catalogos_agregados_266 from anon, authenticated;
grant all on public.fin_catalogos_agregados_266 to service_role;
comment on table public.fin_catalogos_agregados_266 is '266: filas que agrego la 266 (catalogo, alias, vendedor, asignacion, persona). Se borran para volver atras.';

-- ---------------------------------------------------------------------
-- 1. QUIEN RECIBE de liam (fin_catalogos + alias aprobados)
-- ---------------------------------------------------------------------
with nuevos as (
  insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
  select 'liam', 'quien_recibe', x.valor,
         (select coalesce(max(c.orden), 0) from public.fin_catalogos c where c.cliente_id = 'liam' and c.dimension = 'quien_recibe') + x.n
    from (values ('Franco Lagrega', 1), ('Ivo', 2)) as x(valor, n)
  on conflict (cliente_id, dimension, valor) do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'catalogo', id from nuevos
on conflict do nothing;

with nuevos as (
  insert into public.fin_catalogo_alias (cliente_id, columna, crudo_norm, dimension, catalogo_id, aprobado)
  select 'liam', 'quien_recibe', public.fin_normalizar_alias(a.texto), 'quien_recibe', c.id, true
    from (values ('franco lagrega', 'Franco Lagrega'), ('fran lagrega', 'Franco Lagrega'), ('ivo', 'Ivo')) as a(texto, valor)
    join public.fin_catalogos c on c.cliente_id = 'liam' and c.dimension = 'quien_recibe' and c.valor = a.valor
  on conflict (cliente_id, columna, crudo_norm, dimension) do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'alias_catalogo', id from nuevos
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. CLOSER Y SETTER de liam (vendedores, asignaciones, alias)
-- ---------------------------------------------------------------------
with nuevos as (
  insert into public.fin_vendedores (nombre, es_persona, notas)
  values ('Ivo', true, 'closer, setter y quien recibe de liam (266, aprobado por Joaquin). Ver si es la misma persona que Ivan Binsztein (077)')
  on conflict (nombre_norm) do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'vendedor', id from nuevos
on conflict do nothing;
-- 'Franco Lagrega' ya existe desde la 010; si no estuviera, se crea.
with nuevos as (
  insert into public.fin_vendedores (nombre, es_persona, notas)
  values ('Franco Lagrega', true, 'closer de teo (010); closer, setter y quien recibe de liam (266)')
  on conflict (nombre_norm) do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'vendedor', id from nuevos
on conflict do nothing;

with nuevos as (
  insert into public.fin_vendedor_asignaciones (vendedor_id, cliente_id, es_setter, es_closer, comisiona)
  select v.id, 'liam', true, true, true
    from public.fin_vendedores v
   where v.nombre_norm in (public.fin_normalizar_nombre('Ivo'), public.fin_normalizar_nombre('Franco Lagrega'))
  on conflict (vendedor_id, cliente_id) do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'asignacion', id from nuevos
on conflict do nothing;

-- La RLS y la vista de comisiones comparan lower(btrim()) SIN quitar tildes; cliente_id nunca va en null.
with nuevos as (
  insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
  select null, 'liam', x.alias, v.id, 'ambos'
    from (values ('IVO', 'Ivo'), ('FRANCO LAGREGA', 'Franco Lagrega'), ('FRAN LAGREGA', 'Franco Lagrega')) as x(alias, vendedor)
    join public.fin_vendedores v on v.nombre_norm = public.fin_normalizar_nombre(x.vendedor)
  on conflict do nothing
  returning id
)
insert into public.fin_catalogos_agregados_266 (tipo, id) select 'persona', id from nuevos
on conflict do nothing;

commit;

-- =====================================================================
-- CONTROLES (de a uno: el editor muestra solo el ultimo resultado)
-- =====================================================================

-- C1. Lo agregado. Primera vez: catalogo 2, alias_catalogo 3, vendedor 1 (solo Ivo), asignacion 2, persona 3. Re-correr: no suma.
-- select tipo, count(*) from public.fin_catalogos_agregados_266 group by tipo order by tipo;

-- C2. Quien recibe de liam (los 2 nuevos al final del orden, activos).
-- select id, valor, orden, activo from public.fin_catalogos
--  where cliente_id = 'liam' and dimension = 'quien_recibe' order by orden, valor;

-- C3. Closers y setters de liam como los ve Cargar pago (Ivo y Franco Lagrega en ambas listas).
-- select v.nombre, a.es_closer, a.es_setter, a.comisiona, a.hasta
--   from public.fin_vendedores v join public.fin_vendedor_asignaciones a on a.vendedor_id = v.id
--  where a.cliente_id = 'liam' and v.nombre_norm in ('ivo', 'franco lagrega');

-- C4. Alias de liam. Esperado: 3 filas, campo 'ambos', ninguna con vendedor nulo.
-- select p.alias, p.campo, v.nombre from public.fin_personas p left join public.fin_vendedores v on v.id = p.vendedor_id
--  where p.cliente_id = 'liam' and lower(btrim(p.alias)) in ('ivo', 'franco lagrega', 'fran lagrega');

-- C5. Pagos de liam con quien recibe IVO / FRANCO LAGREGA y su id (el id sigue nulo hasta el paso opcional).
-- select quien_recibe, count(*) as pagos, count(quien_recibe_id) as con_id, round(sum(monto_usd), 2) as usd
--   from public.fin_pagos where cliente_id = 'liam' and public.fin_normalizar_alias(quien_recibe) in ('ivo', 'franco lagrega')
--  group by 1;

-- =====================================================================
-- PASO OPCIONAL (solo si Joaquin lo autoriza: TOCA pagos, solo completa quien_recibe_id nulo)
-- Sin esto, esos pagos siguen saliendo en Pagos > Pendientes de catalogo.
-- =====================================================================
-- update public.fin_pagos p
--    set quien_recibe_id = public.fin_resolver_alias(p.cliente_id, 'quien_recibe', 'quien_recibe', p.quien_recibe)
--  where p.cliente_id = 'liam' and p.quien_recibe_id is null
--    and public.fin_normalizar_alias(p.quien_recibe) in ('ivo', 'franco lagrega');

-- =====================================================================
-- VUELTA ATRAS (solo borra lo que registro esta migracion; no toca pagos)
-- =====================================================================
-- begin;
-- delete from public.fin_personas where id in (select id from public.fin_catalogos_agregados_266 where tipo = 'persona');
-- delete from public.fin_vendedor_asignaciones where id in (select id from public.fin_catalogos_agregados_266 where tipo = 'asignacion');
-- delete from public.fin_vendedores where id in (select id from public.fin_catalogos_agregados_266 where tipo = 'vendedor');
-- delete from public.fin_catalogo_alias where id in (select id from public.fin_catalogos_agregados_266 where tipo = 'alias_catalogo');
-- delete from public.fin_catalogos where id in (select id from public.fin_catalogos_agregados_266 where tipo = 'catalogo');
-- drop table public.fin_catalogos_agregados_266;
-- commit;
-- (fin_pagos.quien_recibe_id tiene on delete set null: borrar el catalogo deja esos ids en nulo.)
