-- =====================================================================
-- 009_vendedores.sql
-- FASE 1 de VENTAS: personas canonicas + alias mapeados.
-- Correr en el SQL Editor de Supabase. Transaccional e idempotente.
--
-- NO toca fin_pagos, fin_cuotas, ni las politicas RLS existentes.
-- La unica modificacion sobre algo existente es hacer nullable
-- fin_personas.user_id, verificado como seguro:
-- las politicas fin_pagos_lectura y fin_cuotas_lectura filtran por
-- (p.user_id = auth.uid()), que con user_id nulo evalua a falso.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Normalizacion de nombres
--    SOLO para buscar y agrupar en la UI.
--    NO se usa en las politicas RLS, que comparan con lower(btrim()).
--    Consecuencia: "Andres" y "Andrés" necesitan DOS filas de alias.
-- ---------------------------------------------------------------------
create or replace function fin_normalizar_nombre(p_texto text)
returns text
language sql
immutable
as $$
  select nullif(
    btrim(
      regexp_replace(
        lower(translate(coalesce(p_texto, ''),
                        'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ',
                        'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC')),
        '\s+', ' ', 'g')
    ),
  '');
$$;

-- ---------------------------------------------------------------------
-- 2. Personas. Una fila por PERSONA, no por persona-cliente.
--    Juani trabaja para liam y para teo y es una sola fila.
-- ---------------------------------------------------------------------
create table if not exists fin_vendedores (
  id            bigserial primary key,
  nombre        text        not null,
  nombre_norm   text        generated always as (fin_normalizar_nombre(nombre)) stored,
  es_persona    boolean     not null default true,
  activo        boolean     not null default true,
  notas         text,
  creado        timestamptz not null default now()
);

comment on column fin_vendedores.es_persona is
  'false para entradas que aparecen en la columna closer/setter pero no son un vendedor: "BPF", "Mauro/Dystopia". Sirven para mapear el alias y excluirlo de comisiones.';

create unique index if not exists fin_vendedores_nombre_uq
  on fin_vendedores (nombre_norm);

-- ---------------------------------------------------------------------
-- 3. Asignaciones: quien trabaja para que cliente y en que rol
-- ---------------------------------------------------------------------
create table if not exists fin_vendedor_asignaciones (
  id           bigserial primary key,
  vendedor_id  bigint  not null references fin_vendedores(id) on delete cascade,
  cliente_id   text    not null references crm_clients(id)    on delete cascade,
  es_setter    boolean not null default false,
  es_closer    boolean not null default false,
  comisiona    boolean not null default true,
  desde        date,
  hasta        date,
  unique (vendedor_id, cliente_id)
);

comment on column fin_vendedor_asignaciones.comisiona is
  'false para los duenos de la agencia y para el cliente mismo cuando cierran. Pendiente de confirmar con la agencia.';

-- ---------------------------------------------------------------------
-- 4. fin_personas pasa a ser la tabla de ALIAS
--    Ya existia con (user_id, cliente_id, alias) y esta vacia.
-- ---------------------------------------------------------------------
alter table fin_personas alter column user_id drop not null;

alter table fin_personas
  add column if not exists vendedor_id bigint references fin_vendedores(id) on delete set null;

alter table fin_personas
  add column if not exists campo text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'fin_personas_campo_check'
  ) then
    alter table fin_personas
      add constraint fin_personas_campo_check
      check (campo is null or campo in ('setter', 'closer', 'ambos'));
  end if;
end $$;

-- Un mismo alias no puede estar dos veces para el mismo cliente.
-- coalesce porque cliente_id nulo significa "todos los clientes".
create unique index if not exists fin_personas_alias_cliente_uq
  on fin_personas (coalesce(cliente_id, '*'), lower(btrim(alias)));

comment on column fin_personas.cliente_id is
  'NUNCA dejar en null salvo que la persona deba ver los pagos de TODOS los clientes: las politicas RLS tratan el null como comodin.';

-- ---------------------------------------------------------------------
-- 5. Que clientes ve el usuario actual (reutilizable en la Fase 2)
-- ---------------------------------------------------------------------
create or replace function fin_clientes_del_usuario()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select distinct p.cliente_id
  from fin_personas p
  where p.user_id = auth.uid()
    and p.cliente_id is not null;
$$;

-- ---------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------
alter table fin_vendedores             enable row level security;
alter table fin_vendedor_asignaciones  enable row level security;

drop policy if exists fin_vendedores_lectura on fin_vendedores;
create policy fin_vendedores_lectura on fin_vendedores
for select using (
  es_fundador()
  or exists (
    select 1
    from fin_vendedor_asignaciones a
    where a.vendedor_id = fin_vendedores.id
      and (
        tiene_acceso(a.cliente_id)
        or a.cliente_id in (select fin_clientes_del_usuario())
      )
  )
);

drop policy if exists fin_vendedores_escritura on fin_vendedores;
create policy fin_vendedores_escritura on fin_vendedores
for all using (es_fundador()) with check (es_fundador());

drop policy if exists fin_asignaciones_lectura on fin_vendedor_asignaciones;
create policy fin_asignaciones_lectura on fin_vendedor_asignaciones
for select using (
  es_fundador()
  or tiene_acceso(cliente_id)
  or cliente_id in (select fin_clientes_del_usuario())
);

drop policy if exists fin_asignaciones_escritura on fin_vendedor_asignaciones;
create policy fin_asignaciones_escritura on fin_vendedor_asignaciones
for all using (es_fundador()) with check (es_fundador());

-- fin_personas ya tenia RLS activa. Se agrega escritura solo fundador
-- sin tocar ninguna politica de lectura existente.
drop policy if exists fin_personas_escritura on fin_personas;
create policy fin_personas_escritura on fin_personas
for all using (es_fundador()) with check (es_fundador());

-- ---------------------------------------------------------------------
-- 7. Vista de trabajo: alias que faltan mapear
--    Ordenada por plata involucrada, para atacar primero lo que importa.
-- ---------------------------------------------------------------------
create or replace view fin_v_alias_sin_mapear
with (security_invoker = true) as
with crudos as (
  select cliente_id, 'closer'::text as campo,
         btrim(closer) as alias, monto_usd, fecha
  from fin_pagos
  where nullif(btrim(closer), '') is not null
  union all
  select cliente_id, 'setter'::text,
         btrim(setter), monto_usd, fecha
  from fin_pagos
  where nullif(btrim(setter), '') is not null
)
select
  c.cliente_id,
  c.campo,
  c.alias,
  count(*)                     as pagos,
  round(sum(c.monto_usd), 2)   as usd_involucrado,
  min(c.fecha)                 as primera,
  max(c.fecha)                 as ultima
from crudos c
where not exists (
  select 1 from fin_personas p
  where lower(btrim(p.alias)) = lower(c.alias)
    and (p.cliente_id is null or p.cliente_id = c.cliente_id)
)
group by c.cliente_id, c.campo, c.alias
order by usd_involucrado desc;

-- ---------------------------------------------------------------------
-- 8. Vista de cobertura: cuanta plata queda sin poder comisionar
-- ---------------------------------------------------------------------
create or replace view fin_v_cobertura_vendedores
with (security_invoker = true) as
select
  cliente_id,
  count(*)                                                    as pagos,
  round(sum(monto_usd), 2)                                    as usd_total,
  count(*) filter (where nullif(btrim(closer), '') is null)   as sin_closer,
  round(sum(monto_usd) filter (
    where nullif(btrim(closer), '') is null), 2)              as usd_sin_closer,
  count(*) filter (where nullif(btrim(setter), '') is null)   as sin_setter,
  round(sum(monto_usd) filter (
    where nullif(btrim(setter), '') is null), 2)              as usd_sin_setter
from fin_pagos
group by cliente_id
order by cliente_id;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================
select 'tablas creadas' as control, count(*) as valor_esperado_2
from information_schema.tables
where table_schema = 'public'
  and table_name in ('fin_vendedores', 'fin_vendedor_asignaciones');

select 'user_id nullable' as control, is_nullable as valor_esperado_YES
from information_schema.columns
where table_schema = 'public'
  and table_name = 'fin_personas'
  and column_name = 'user_id';

select 'columnas nuevas en fin_personas' as control, count(*) as valor_esperado_2
from information_schema.columns
where table_schema = 'public'
  and table_name = 'fin_personas'
  and column_name in ('vendedor_id', 'campo');

select 'normalizacion' as control,
       fin_normalizar_nombre('  ANDRÉS   Pérez ') as valor_esperado_andres_perez;

select 'alias sin mapear' as control, count(*) as valor_esperado_73
from fin_v_alias_sin_mapear;

select * from fin_v_cobertura_vendedores;

-- =====================================================================
-- PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
savepoint humo;

insert into fin_vendedores (nombre, notas)
values ('ZZZ Prueba Humo', 'fila de prueba, se borra sola');

insert into fin_vendedor_asignaciones (vendedor_id, cliente_id, es_closer)
select id, 'liam', true from fin_vendedores where nombre = 'ZZZ Prueba Humo';

insert into fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
select null, 'liam', 'LUCAS', id, 'closer'
from fin_vendedores where nombre = 'ZZZ Prueba Humo';

-- Esperado: 'LUCAS' con cliente liam ya NO aparece sin mapear.
select 'humo: LUCAS de liam desaparecio' as prueba,
       count(*) as valor_esperado_0
from fin_v_alias_sin_mapear
where cliente_id = 'liam' and alias = 'LUCAS';

-- Esperado: 'Lucas' (minuscula) SIGUE sin mapear, porque la RLS y esta
-- vista comparan con lower(btrim) y 'Lucas' coincide... verificamos.
select 'humo: variantes de Lucas restantes' as prueba,
       string_agg(alias, ', ') as aliases_que_quedan
from fin_v_alias_sin_mapear
where cliente_id = 'liam' and alias ilike 'lucas%';

-- Esperado: el alias no se puede duplicar para el mismo cliente.
do $$
begin
  begin
    insert into fin_personas (user_id, cliente_id, alias)
    values (null, 'liam', 'lucas');
    raise exception 'FALLO: se permitio un alias duplicado';
  exception when unique_violation then
    raise notice 'OK: el indice unico rechaza alias duplicados';
  end;
end $$;

rollback to savepoint humo;

select 'humo revertido' as control, count(*) as valor_esperado_0
from fin_vendedores where nombre = 'ZZZ Prueba Humo';

commit;
