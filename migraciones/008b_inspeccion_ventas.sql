-- 008b_inspeccion_ventas.sql
-- SOLO LECTURA. Nombres de columna corregidos segun el esquema real.
-- IMPORTANTE: el SQL Editor frena en el primer error.
-- Correr UN BLOQUE A LA VEZ y exportar cada resultado.

-- =====================================================================
-- BLOQUE A — Objetos fin_* que existen
-- =====================================================================
select
  c.relname                                  as objeto,
  case c.relkind when 'r' then 'tabla'
                 when 'v' then 'vista'
                 when 'm' then 'vista_materializada'
                 else c.relkind::text end    as tipo,
  c.relrowsecurity                           as rls_activa
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname like 'fin\_%'
order by c.relname;


-- =====================================================================
-- BLOQUE B — Clave primaria y unicidad de fin_pagos
-- Objetivo: saber si un pago tiene id estable entre corridas del sync
-- =====================================================================
select
  con.conname                    as restriccion,
  con.contype                    as tipo,
  pg_get_constraintdef(con.oid)  as definicion
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = 'fin_pagos';


-- =====================================================================
-- BLOQUE C — Fuentes cargadas (activas e inactivas)
-- =====================================================================
select id, cliente_id, tipo, forma, nombre_hoja_esperado, anio, activo
from fin_fuentes
order by cliente_id, tipo, anio;


-- =====================================================================
-- BLOQUE D — Volumen de pagos por cliente y estado de la moneda
-- =====================================================================
select
  cliente_id,
  count(*)                                              as pagos,
  min(fecha)                                            as desde,
  max(fecha)                                            as hasta,
  count(*) filter (where monto_usd is not null)         as con_monto_usd,
  count(*) filter (where monto_usd is null)             as sin_monto_usd,
  count(*) filter (where moneda_origen = 'USD')         as origen_usd,
  count(*) filter (where moneda_origen is distinct from 'USD'
                     and moneda_origen is not null)     as origen_otra,
  count(*) filter (where moneda_origen is null)         as origen_null,
  count(*) filter (where tc_usado is not null)          as con_tc,
  round(sum(monto_usd), 2)                              as total_usd
from fin_pagos
group by cliente_id
order by cliente_id;


-- =====================================================================
-- BLOQUE E — Valores que toma cada campo de control
-- Objetivo: saber como se marcan refunds, cuotas y monedas
-- =====================================================================
select 'estado' as campo, coalesce(estado, '(null)') as valor, count(*) as filas
from fin_pagos group by estado
union all
select 'moneda_origen', coalesce(moneda_origen, '(null)'), count(*)
from fin_pagos group by moneda_origen
union all
select 'moneda_cobro', coalesce(moneda_cobro, '(null)'), count(*)
from fin_pagos group by moneda_cobro
union all
select 'tc_fuente', coalesce(tc_fuente, '(null)'), count(*)
from fin_pagos group by tc_fuente
union all
select 'metodo_pago', coalesce(metodo_pago, '(null)'), count(*)
from fin_pagos group by metodo_pago
order by campo, filas desc;


-- =====================================================================
-- BLOQUE F — EL MAS IMPORTANTE: nombres crudos de closers y setters
-- Esto alimenta la tabla de alias de la Fase 1.
-- Exportalo a CSV, no lo copies a mano.
-- =====================================================================
select
  cliente_id,
  'closer'                                        as campo,
  coalesce(nullif(btrim(closer), ''), '(vacio)')  as nombre_crudo,
  count(*)                                        as veces,
  round(sum(monto_usd), 2)                        as usd_involucrado,
  min(fecha)                                      as primera,
  max(fecha)                                      as ultima
from fin_pagos
group by cliente_id, coalesce(nullif(btrim(closer), ''), '(vacio)')

union all

select
  cliente_id,
  'setter',
  coalesce(nullif(btrim(setter), ''), '(vacio)'),
  count(*),
  round(sum(monto_usd), 2),
  min(fecha),
  max(fecha)
from fin_pagos
group by cliente_id, coalesce(nullif(btrim(setter), ''), '(vacio)')

order by cliente_id, campo, veces desc;


-- =====================================================================
-- BLOQUE G — Cuotas: cuanto pesa monto_restante
-- =====================================================================
select
  cliente_id,
  count(*) filter (where monto_restante is not null
                     and monto_restante <> 0)   as con_restante,
  count(*) filter (where monto_restante = 0)    as saldados,
  count(*) filter (where monto_restante is null) as sin_dato,
  count(*) filter (where monto_usd < 0)         as montos_negativos
from fin_pagos
group by cliente_id
order by cliente_id;


-- =====================================================================
-- BLOQUE H — Funciones de rol que reutiliza VENTAS
-- =====================================================================
select
  p.proname                                    as funcion,
  pg_get_function_identity_arguments(p.oid)    as argumentos,
  pg_get_function_result(p.oid)                as retorna,
  p.prosecdef                                  as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('es_fundador', 'rol_actual', 'tiene_acceso')
order by p.proname;


-- =====================================================================
-- BLOQUE I — Roles existentes y si el campo acepta uno nuevo
-- Clave para el rol 'vendedor' de la Fase 2
-- =====================================================================
select rol, count(*) as personas
from crm_members
group by rol
order by rol;

select
  con.conname                    as restriccion,
  pg_get_constraintdef(con.oid)  as definicion
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('crm_members', 'crm_asignaciones');


-- =====================================================================
-- BLOQUE J — Columnas de las tablas de identidad
-- VENTAS necesita ligar un usuario de auth con un vendedor
-- =====================================================================
select table_name, ordinal_position as pos, column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public'
  and table_name in ('crm_members', 'crm_asignaciones', 'crm_clients')
order by table_name, ordinal_position;


-- =====================================================================
-- BLOQUE K — Ids de cliente reales
-- =====================================================================
select id, nombre from crm_clients order by id;


-- =====================================================================
-- BLOQUE L — Crones, version y extensiones
-- =====================================================================
select jobid, schedule, jobname, active from cron.job order by jobname;

select version();

select extname, extversion from pg_extension order by extname;
