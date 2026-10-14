-- =====================================================================
-- 114_finanzas_diagnostico_agus_teo.sql
-- FINANZAS: diagnostico de SOLO LECTURA (no cambia nada, no tiene vuelta
-- atras porque no escribe). Sale de la revision visual del 14/10:
--   (1) Agus y Teo no aparecen en selectores ni menu de Finanzas.
--   (5) Cobranzas con Programa/Closer vacios, cuotas sin fecha o sin estado;
--       Pagos con Programa/Concepto/Fuente vacios.
--   (6) Programas repetidos en el formulario y origen de "BPF"/"Liam Wickham"
--       en la lista de closers.
--
-- Por que no hay cambios de datos: el front ya lista a TODOS los clientes
-- que devuelve crm_clients por RLS (js/sesion.js, ORDEN liam/agus/teo). Si en
-- la revision solo salio Liam, lo mas probable es que la sesion fuera un
-- usuario con un solo cliente asignado (en la pantalla el menu decia
-- "Resumen" a secas, que es lo que muestra clienteUnico()). Los controles
-- C1 a C4 lo confirman o lo descartan. Si C2 muestra que agus/teo no estan
-- en crm_clients o no tienen fuentes, ahi si hace falta una migracion de
-- datos (se escribe despues, con su numero).
--
-- Correr los controles DE A UNO (el editor muestra solo el ultimo).
-- Los que usan es_fundador()/rol_actual() necesitan un usuario logueado:
-- en el SQL Editor correr antes, en la misma ejecucion:
--   select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- Sin datos personales en este archivo (los controles devuelven nombres de
-- alumnos solo si se piden: C9 y C10 devuelven conteos).
-- =====================================================================

-- ---------------------------------------------------------------------
-- (1) AGUS Y TEO
-- ---------------------------------------------------------------------

-- C1. Clientes que existen y quien los ve: esperado liam, agus, teo.
-- select id, nombre, orden from public.crm_clients order by orden, id;

-- C2. Estado de las fuentes por cliente: tipos, si estan activas y si estan cortadas.
-- select cliente_id, tipo, activo, cortada_en is not null as cortada, forma
--   from public.fin_fuentes
--  where cliente_id in ('liam', 'agus', 'teo')
--  order by cliente_id, tipo;

-- C3. Quien tiene cada cliente asignado (para ver con que usuario se hizo la revision):
--     un usuario con rol cliente y solo 'liam' explica que no vea a Agus ni a Teo.
-- select m.rol, m.nombre, (select string_agg(a.cliente_id, ',' order by a.cliente_id)
--                            from public.crm_asignaciones a where a.user_id = m.user_id) as clientes
--   from public.crm_members m order by m.rol, m.nombre;

-- C4. Datos ya sincronizados por cliente (si agus/teo tienen filas, el P&L tiene con que mostrarse).
-- select c.id as cliente,
--        (select count(*) from public.fin_pagos  x where x.cliente_id = c.id) as pagos,
--        (select count(*) from public.fin_pnl    x where x.cliente_id = c.id) as items_opps,
--        (select count(*) from public.fin_cuotas x where x.cliente_id = c.id) as cuotas,
--        (select count(*) from public.fin_catalogos x where x.cliente_id = c.id and x.activo) as opciones_catalogo,
--        (select count(*) from public.fin_vendedor_asignaciones x where x.cliente_id = c.id) as vendedores_asignados
--   from public.crm_clients c where c.id in ('liam', 'agus', 'teo') order by c.orden;

-- C5. Carga de pagos desde la app (como fundador, ver nota de set_config arriba):
--     habilitada = false en agus/teo es normal mientras su planilla de Pagos no este cortada (067 para agus).
-- select * from public.fin_clientes_carga();

-- ---------------------------------------------------------------------
-- (5) COBRANZAS Y PAGOS
-- ---------------------------------------------------------------------

-- C6. Cuotas: cuantas hay, cuantas sin programa, sin closer, sin fecha o sin estado, por cliente.
-- select cliente_id, count(*) as cuotas,
--        count(*) filter (where programa is null or btrim(programa) = '') as sin_programa,
--        count(*) filter (where closer   is null or btrim(closer)   = '') as sin_closer,
--        count(*) filter (where fecha_pago is null)                       as sin_fecha,
--        count(*) filter (where estado   is null or btrim(estado)   = '') as sin_estado
--   from public.fin_cuotas group by cliente_id order by cliente_id;

-- C7. Pagos: sin programa, sin concepto, sin metodo, sin closer, por cliente.
-- select cliente_id, count(*) as pagos,
--        count(*) filter (where programa is null or btrim(programa) = '') as sin_programa,
--        count(*) filter (where concepto is null or btrim(concepto) = '') as sin_concepto,
--        count(*) filter (where programa is null and concepto is null)     as sin_ambos,
--        count(*) filter (where metodo_pago is null or btrim(metodo_pago) = '') as sin_metodo,
--        count(*) filter (where closer is null or btrim(closer) = '')     as sin_closer
--   from public.fin_pagos group by cliente_id order by cliente_id;

-- C8. Columna "Fuente" de Pagos (la crea la 076 para liam como x_fuente_bpf): cuantos pagos tienen valor.
-- select count(*) as pagos_liam,
--        count(*) filter (where e.valores ? 'x_fuente_bpf' and btrim(e.valores ->> 'x_fuente_bpf') <> '') as con_fuente
--   from public.fin_pagos p
--   left join public.fin_pagos_extra e on e.cliente_id = p.cliente_id and e.clave = p.clave
--  where p.cliente_id = 'liam';

-- ---------------------------------------------------------------------
-- (6) PROGRAMAS REPETIDOS Y LISTA DE CLOSERS
-- ---------------------------------------------------------------------

-- C9. Programas del catalogo con cuantos pagos usan cada uno (para decidir cual queda).
--     No fusiona nada: es solo la lista que ve el formulario Cargar pago.
-- select k.cliente_id, k.id, k.valor, k.activo,
--        (select count(*) from public.fin_pagos p where p.cliente_id = k.cliente_id and p.programa_id = k.id) as pagos
--   from public.fin_catalogos k
--  where k.dimension = 'programa'
--  order by k.cliente_id, k.valor;

-- C10. Alias que apuntan a cada programa (si "BPF 1 A 1" y "1 a 1 Blueprint Financiero" son alias
--      del mismo programa o programas distintos):
-- select a.cliente_id, a.catalogo_id, k.valor as programa, a.crudo_norm as alias, a.aprobado
--   from public.fin_catalogo_alias a join public.fin_catalogos k on k.id = a.catalogo_id
--  where a.dimension = 'programa' order by a.cliente_id, a.catalogo_id, a.crudo_norm;

-- C11. De donde sale cada closer del formulario: fin_vendedores + asignacion es_closer al cliente
--      (fin_carga_opciones, 066). es_persona = false es "BPF" (negocio), pero la RPC no filtra por ese campo.
-- select a.cliente_id, v.id, v.nombre, v.es_persona, v.activo, a.es_closer, a.es_setter, a.comisiona, a.hasta
--   from public.fin_vendedor_asignaciones a join public.fin_vendedores v on v.id = a.vendedor_id
--  where a.es_closer and v.activo and a.hasta is null
--  order by a.cliente_id, v.nombre;
