-- =====================================================================
-- 015_alias_llamadas.sql
-- Alias de vendedores de la hoja Data (llamadas).
--
-- Son un set DISTINTO al de Pagos: las mismas personas aparecen escritas
-- de otra forma, y hay gente que solo figura en Data.
-- Sacado de fin_llamadas con datos reales al 2026-09-22.
--
-- En Data solo existe el closer (el "encargado de la llamada"), asi que
-- todos los alias van con campo = 'closer'. No hay setter.
--
-- Idempotente: se puede correr mas de una vez.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Vista: nombres de Data que faltan mapear
--    fin_v_alias_sin_mapear solo mira fin_pagos, asi que hoy los
--    nombres de las llamadas no aparecen en ningun lado.
-- ---------------------------------------------------------------------
create or replace view fin_v_alias_llamadas_sin_mapear
with (security_invoker = true) as
select
  l.cliente_id,
  btrim(l.closer)          as alias,
  count(*)                 as llamadas,
  min(l.fecha_llamada)     as primera,
  max(l.fecha_llamada)     as ultima
from fin_llamadas l
where nullif(btrim(l.closer), '') is not null
  and not exists (
    select 1 from fin_personas p
    where lower(btrim(p.alias)) = lower(btrim(l.closer))
      and (p.cliente_id is null or p.cliente_id = l.cliente_id)
  )
group by l.cliente_id, btrim(l.closer)
order by llamadas desc;

-- ---------------------------------------------------------------------
-- 2. Personas nuevas que solo aparecen en Data
-- ---------------------------------------------------------------------
insert into fin_vendedores (nombre, es_persona, notas) values
  ('Liam Wickham',       true, 'cliente de BPF; atiende llamadas el mismo'),
  ('Lucas Auletta',      true, 'cliente; atiende llamadas el mismo'),
  ('Ignacio Mazzei',     true, 'closer de liam mar-2026. OJO: hay DOS Ignacios en liam'),
  ('Ignacio Colombetti', true, 'closer de liam mar a sep-2026. OJO: hay DOS Ignacios en liam'),
  ('Fabian Silva',       true, 'closer de liam may-2026'),
  ('Matias Ortuno',      true, '1 sola llamada en liam, 2026-03-09. Confirmar quien es'),
  ('Maxi Sandoval',      true, 'closer de lucas desde ago-2026'),
  ('Agustin Turone',     true, 'closer de lucas desde sep-2026; en la planilla tambien "Agutin Turrone"'),
  ('Lauty Tiseyra',      true, 'closer de mauro, el de mas volumen'),
  ('Facundo Came',       true, 'closer de mauro mar a jun-2026'),
  ('Alejandro Exeni',    true, 'closer de mauro; en la planilla figura "Alejando Exeni"'),
  ('Felipe Byrne',       true, 'closer de teo abr-2026. NO confundir con Felipe Vatovec de lucas'),
  ('Emi Gonda',          true, 'closer de teo mar-2026'),
  ('Alejo',              true, '1 sola llamada en teo, 2026-03-12. Confirmar quien es')
on conflict (nombre_norm) do nothing;

-- Gonza: ahora conocemos el apellido completo
update fin_vendedores
set nombre = 'Gonza Guglielmino'
where nombre_norm = fin_normalizar_nombre('Gonza')
  and nombre <> 'Gonza Guglielmino';

-- ---------------------------------------------------------------------
-- 3. Asignaciones nuevas
--    Incluye los cruces que aparecieron en Data: Lucas Deza atiende
--    liam y mauro, Valentin Morello atiende liam y teo, Franco Randisi
--    atiende lucas y mauro.
-- ---------------------------------------------------------------------
insert into fin_vendedor_asignaciones (vendedor_id, cliente_id, es_setter, es_closer, comisiona)
select v.id, x.cliente_id, false, true, x.comisiona
from (values
  -- liam
  ('Valentin Morello',   'liam',  true),
  ('Liam Wickham',       'liam',  true),
  ('Ignacio Mazzei',     'liam',  true),
  ('Ignacio Colombetti', 'liam',  true),
  ('Fabian Silva',       'liam',  true),
  ('Matias Ortuno',      'liam',  true),
  -- lucas
  ('Maxi Sandoval',      'lucas', true),
  ('Agustin Turone',     'lucas', true),
  ('Lucas Auletta',      'lucas', true),
  -- mauro
  ('Lauty Tiseyra',      'mauro', true),
  ('Facundo Came',       'mauro', true),
  ('Lucas Deza',         'mauro', true),
  ('Alejandro Exeni',    'mauro', true),
  ('Franco Randisi',     'mauro', true),
  -- teo
  ('Felipe Byrne',       'teo',   true),
  ('Emi Gonda',          'teo',   true),
  ('Alejo',              'teo',   true)
) as x(nombre, cliente_id, comisiona)
join fin_vendedores v on v.nombre_norm = fin_normalizar_nombre(x.nombre)
on conflict (vendedor_id, cliente_id) do nothing;

-- ---------------------------------------------------------------------
-- 4. Alias de Data
--    La RLS compara con lower(btrim()), SIN quitar tildes: por eso
--    "Valentin Morello" y "Valentín Morello" necesitan DOS filas.
--    cliente_id NUNCA va en null: null significa "todos los clientes".
-- ---------------------------------------------------------------------
insert into fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
select null, x.cliente_id, x.alias, v.id, 'closer'
from (values
  -- liam
  ('liam',  'Valentin Morello',   'Valentin Morello'),
  ('liam',  'Valen Morello',      'Valentin Morello'),
  ('liam',  'Liam Wickham',       'Liam Wickham'),
  ('liam',  'Liam',               'Liam Wickham'),
  ('liam',  'Ignacio Mazzei',     'Ignacio Mazzei'),
  ('liam',  'Ignacio Colombetti', 'Ignacio Colombetti'),
  ('liam',  'Fabian Silva',       'Fabian Silva'),
  ('liam',  'Matias Ortuño',      'Matias Ortuno'),
  -- lucas
  ('lucas', 'Fran',               'Fran Escudero'),
  ('lucas', 'fran',               'Fran Escudero'),
  ('lucas', 'franco',             'Franco Randisi'),
  ('lucas', 'German',             'German Mujica'),
  ('lucas', 'Maxi Sandoval',      'Maxi Sandoval'),
  ('lucas', 'Agustin Turone',     'Agustin Turone'),
  ('lucas', 'Agutin Turrone',     'Agustin Turone'),
  ('lucas', 'juan',               'Juan Cruz'),
  ('lucas', 'Juan',               'Juan Cruz'),
  ('lucas', 'lucas',              'Lucas Auletta'),
  -- mauro
  ('mauro', 'Lauty Tiseyra',      'Lauty Tiseyra'),
  ('mauro', 'lauty Tiseyra',      'Lauty Tiseyra'),
  ('mauro', 'Facundo Came',       'Facundo Came'),
  ('mauro', 'Lucas Deza',         'Lucas Deza'),
  ('mauro', 'Alejando Exeni',     'Alejandro Exeni'),
  ('mauro', 'Franco Randisi',     'Franco Randisi'),
  ('mauro', 'franco randisi',     'Franco Randisi'),
  ('mauro', 'franco Randisi',     'Franco Randisi'),
  -- teo
  ('teo',   'GONZA GUGLIELMINO',  'Gonza Guglielmino'),
  ('teo',   'Valentin Morello',   'Valentin Morello'),
  ('teo',   'Valentín Morello',   'Valentin Morello'),
  ('teo',   'Teo North',          'Teo North'),
  ('teo',   'TEO NORTH',          'Teo North'),
  ('teo',   'Felipe Byrne',       'Felipe Byrne'),
  ('teo',   'Emi Gonda',          'Emi Gonda'),
  ('teo',   'Alejo',              'Alejo')
) as x(cliente_id, alias, vendedor)
join fin_vendedores v on v.nombre_norm = fin_normalizar_nombre(x.vendedor)
on conflict do nothing;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================
select 'llamadas sin mapear' as control,
       count(*) as alias_pendientes,
       coalesce(sum(llamadas), 0) as llamadas_afectadas
from fin_v_alias_llamadas_sin_mapear;

select 'cobertura por cliente' as control, cliente_id,
       count(*) as llamadas,
       count(*) filter (where exists (
         select 1 from fin_personas p
         where lower(btrim(p.alias)) = lower(btrim(l.closer))
           and (p.cliente_id is null or p.cliente_id = l.cliente_id)
       )) as con_vendedor
from fin_llamadas l
where nullif(btrim(l.closer), '') is not null
group by cliente_id
order by cliente_id;

select 'alias huerfanos' as control, count(*) as valor_esperado_0
from fin_personas where vendedor_id is null;

select 'alias comodin' as control, count(*) as valor_esperado_0
from fin_personas where cliente_id is null;

select 'personas que trabajan para 2+ clientes' as control,
       v.nombre, count(*) as clientes
from fin_vendedor_asignaciones a
join fin_vendedores v on v.id = a.vendedor_id
group by v.nombre having count(*) > 1
order by 3 desc, 2;

commit;

-- =====================================================================
-- PENDIENTE DE CONFIRMAR CON LA AGENCIA
--
-- 1. DOS Ignacios en liam: Ignacio Mazzei (32 llamadas, marzo) e
--    Ignacio Colombetti (22 llamadas, marzo a septiembre). En la hoja
--    de PAGOS de liam hay un solo "Nacho", con 10 pagos y 12.000 USD.
--    No se puede saber a cual corresponde. Los pagos quedan igual como
--    estan: el alias "Nacho" ya apunta al vendedor "Nacho".
--
-- 2. "Alejandro Exeni" figura en la planilla de mauro como
--    "Alejando Exeni", sin la r. Se carga el alias tal cual.
--
-- 3. "Agustin Turone" aparece tambien como "Agutin Turrone".
--    Confirmar cual es el nombre correcto.
--
-- 4. Una sola llamada cada uno, sin identificar:
--    "Matias Ortuño" en liam (2026-03-09) y "Alejo" en teo (2026-03-12).
--
-- 5. Los clientes atienden llamadas ellos mismos: Liam Wickham (45),
--    Teo North (16) y Lucas Auletta (1). Los duenos tambien: Valentin
--    Morello suma 61 en liam y 55 en teo. Todos quedan con
--    comisiona = true por defecto. Si la agencia define que no cobran,
--    es un update de una linea, sin migracion.
-- =====================================================================
