-- =====================================================================
-- 010_semilla_alias.sql
-- FASE 1: carga de vendedores y alias CONFIRMADOS.
-- Solo los 4 clientes activos. mauro queda fuera (no comisiona).
--
-- NO incluye alias ambiguos. Esos se cargan cuando la agencia confirme
-- quien es quien. Ver la lista al final del archivo.
--
-- Idempotente: se puede correr mas de una vez sin duplicar.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Personas y entidades
-- ---------------------------------------------------------------------
insert into fin_vendedores (nombre, es_persona, notas) values
  ('Male',           true,  'setter de agus; cierra por chat, cobra 15%'),
  ('Lucas Deza',     true,  null),
  ('Juani Arocas',   true,  'trabaja para liam y teo'),
  ('Andres',         true,  'aparece con y sin tilde en liam'),
  ('Nacho',          true,  'dueno de la agencia; cobra cuando cierra'),
  ('Valentin Morello', true, 'dueno de la agencia; cobra cuando cierra'),
  ('Teo North',      true,  'cliente; sin setter ni closer la comision se divide con la agencia'),
  ('Fran Escudero',  true,  'closer de lucas abr-jul; NO es Franco Randisi'),
  ('Franco Randisi', true,  'closer de lucas jul-ago; NO es Fran Escudero'),
  ('Juan Cruz',      true,  'en lucas figura como closer y como setter'),
  ('German Mujica',  true,  null),
  ('Felipe Vatovec', true,  'en la planilla aparece tambien como "felipe vatotec"'),
  ('Donato Morello', true,  'setter de lucas y de teo'),
  ('Gonza',          true,  'closer de teo'),
  ('Franco Lagrega', true,  'closer de teo'),
  ('BPF',            false, 'NO es una persona: es el negocio de liam. No comisiona.')
on conflict (nombre_norm) do nothing;

-- ---------------------------------------------------------------------
-- 2. Asignaciones
-- ---------------------------------------------------------------------
insert into fin_vendedor_asignaciones (vendedor_id, cliente_id, es_setter, es_closer, comisiona)
select v.id, x.cliente_id, x.es_setter, x.es_closer, x.comisiona
from (values
  ('Male',             'agus',  true,  true,  true),
  ('Lucas Deza',       'liam',  false, true,  true),
  ('Juani Arocas',     'liam',  true,  true,  true),
  ('Juani Arocas',     'teo',   true,  true,  true),
  ('Andres',           'liam',  true,  false, true),
  ('Nacho',            'liam',  false, true,  true),
  ('Valentin Morello', 'teo',   false, true,  true),
  ('Teo North',        'teo',   false, true,  true),
  ('Fran Escudero',    'lucas', false, true,  true),
  ('Franco Randisi',   'lucas', false, true,  true),
  ('Juan Cruz',        'lucas', true,  true,  true),
  ('German Mujica',    'lucas', false, true,  true),
  ('Felipe Vatovec',   'lucas', false, true,  true),
  ('Donato Morello',   'lucas', true,  false, true),
  ('Donato Morello',   'teo',   true,  false, true),
  ('Gonza',            'teo',   false, true,  true),
  ('Franco Lagrega',   'teo',   false, true,  true),
  ('BPF',              'liam',  false, true,  false)
) as x(nombre, cliente_id, es_setter, es_closer, comisiona)
join fin_vendedores v on v.nombre_norm = fin_normalizar_nombre(x.nombre)
on conflict (vendedor_id, cliente_id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Alias
--    OJO: la RLS compara con lower(btrim()), SIN quitar tildes.
--    Por eso "Andrés" y "ANDRES" necesitan dos filas.
--    user_id queda en null: se completa cuando la persona tenga login.
--    cliente_id NUNCA va en null: null significa "todos los clientes".
-- ---------------------------------------------------------------------
insert into fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
select null, x.cliente_id, x.alias, v.id, x.campo
from (values
  -- agus
  ('agus',  'MALE',            'Male',             'ambos'),
  -- liam
  ('liam',  'BPF',             'BPF',              'closer'),
  ('liam',  'LUCAS',           'Lucas Deza',       'closer'),
  ('liam',  'Lucas',           'Lucas Deza',       'closer'),
  ('liam',  'LUCAS DEZA',      'Lucas Deza',       'closer'),
  ('liam',  'Juani',           'Juani Arocas',     'ambos'),
  ('liam',  'JUANI',           'Juani Arocas',     'ambos'),
  ('liam',  'JUANI AROCAS',    'Juani Arocas',     'ambos'),
  ('liam',  'Andrés',          'Andres',           'setter'),
  ('liam',  'ANDRES',          'Andres',           'setter'),
  ('liam',  'Nacho',           'Nacho',            'closer'),
  -- lucas
  ('lucas', 'Fran Escudero',   'Fran Escudero',    'closer'),
  ('lucas', 'Franco Randisi',  'Franco Randisi',   'closer'),
  ('lucas', 'Juan Cruz',       'Juan Cruz',        'ambos'),
  ('lucas', 'German Mujica',   'German Mujica',    'closer'),
  ('lucas', 'felipe vatovec',  'Felipe Vatovec',   'closer'),
  ('lucas', 'felipe vatotec',  'Felipe Vatovec',   'closer'),
  ('lucas', 'DONATO',          'Donato Morello',   'setter'),
  -- teo
  ('teo',   'GONZA',           'Gonza',            'closer'),
  ('teo',   'Gonza',           'Gonza',            'closer'),
  ('teo',   'FRANCO LAGREGA',  'Franco Lagrega',   'closer'),
  ('teo',   'JUANI AROCAS',    'Juani Arocas',     'ambos'),
  ('teo',   'juani',           'Juani Arocas',     'ambos'),
  ('teo',   'DONATO',          'Donato Morello',   'setter'),
  ('teo',   'TEO',             'Teo North',        'closer'),
  ('teo',   'VALEN',           'Valentin Morello', 'closer')
) as x(cliente_id, alias, vendedor, campo)
join fin_vendedores v on v.nombre_norm = fin_normalizar_nombre(x.vendedor)
on conflict do nothing;

-- =====================================================================
-- QUERY DE CONTROL
-- =====================================================================
select 'vendedores'   as tabla, count(*) as filas from fin_vendedores
union all
select 'asignaciones', count(*) from fin_vendedor_asignaciones
union all
select 'alias',        count(*) from fin_personas;

-- Cuanto queda sin mapear despues de la semilla
select cliente_id, campo, alias, pagos, usd_involucrado
from fin_v_alias_sin_mapear
where cliente_id <> 'mauro'
order by usd_involucrado desc;

-- Ningun alias debe haber quedado sin vendedor
select 'alias huerfanos' as control, count(*) as valor_esperado_0
from fin_personas where vendedor_id is null;

-- Ningun alias debe tener cliente_id nulo (seria comodin)
select 'alias comodin' as control, count(*) as valor_esperado_0
from fin_personas where cliente_id is null;

commit;

-- =====================================================================
-- PENDIENTE DE CONFIRMAR CON LA AGENCIA
-- Estos alias NO se cargaron porque adivinar es pagarle a la persona
-- equivocada. Ordenados por plata involucrada.
--
--  teo   setter  JUAN              60 pagos   18.409 USD
--  liam  setter  Juan              36 pagos   36.400 USD
--    Hipotesis: los dos son Juani Arocas, que era setter de Blueprint
--    y de North Ecom. Pero en lucas hay un Juan Cruz distinto.
--    Son 54.809 USD decididos por una corazonada. Preguntar.
--
--  liam  closer  NAZA              16 pagos   13.700 USD   quien es
--  liam  setter  Agus              22 pagos   20.900 USD   es el cliente Agus Friedrichs
--  teo   closer  FELIPE             5 pagos    1.470 USD   es Felipe Vatovec de lucas
--  lucas closer  Gian               4 pagos    1.126 USD   nombre completo
--  lucas setter  Santiago           7 pagos    1.520 USD   es Santiago Poterala
--  teo   closer  EMI                2 pagos    1.664 USD   quien es
--  teo   setter  JULIAN CESCO       1 pago     1.980 USD   confirmar
--  teo   closer  joaco fernandez    1 pago       800 USD   confirmar
--  teo   closer  juan               1 pago       300 USD   mismo caso que JUAN
--  teo   setter  Juan / juan        2 pagos      650 USD   mismo caso
--
-- SIN ATRIBUCION POSIBLE (la planilla esta vacia):
--  teo    92 pagos   62.560 USD sin closer, 93 sin setter
--  liam   20 pagos   17.312 USD sin closer, 63 sin setter
--  lucas   4 pagos    2.099 USD sin closer, 38 sin setter
--  agus    6 pagos    4.595 USD sin closer (agus no tiene setters)
-- =====================================================================
