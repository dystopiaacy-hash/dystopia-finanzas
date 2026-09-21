-- 002_seed_config.sql — Dystopia Finanzas: fuentes y alias de columnas.
-- Valores reales de CONFIG-FUENTES.md (relevados el 2026-09-21) y alias de
-- CONTRATO.md. Idempotente: se puede correr dos veces.
-- Requiere 001_esquema_fin.sql.
--
-- No se insertan las hojas de tipo `form` (Cargar Pago): son formularios.
-- Las hojas de las planillas de CRM entran con activo = false (fase 6).

begin;

-- ---------------------------------------------------------------------------
-- 1. fin_fuentes
-- ---------------------------------------------------------------------------
insert into public.fin_fuentes
  (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, fila_encabezado, anio, tope_monto, activo)
values
  -- Planillas de Finanzas (activas)
  ('liam',  '1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo', 2122278614, 'Opps',             'opps',   null,           4, 2026, null,  true),
  ('liam',  '1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo',  667978021, 'Pagos',            'pagos',  null,           1, null, 10000, true),
  ('liam',  '1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo',  677639895, 'Cuotas',           'cuotas', 'cuotas_ancho', 2, null, 10000, true),
  ('agus',  '13LtPK8GKJm9L86xtRaf3oK7Px8XVysX5_c75-iGzxoI', 2122278614, 'Opps',             'opps',   null,           4, 2026, null,  true),
  ('agus',  '13LtPK8GKJm9L86xtRaf3oK7Px8XVysX5_c75-iGzxoI',  667978021, 'Pagos',            'pagos',  null,           1, null, 10000, true),
  ('teo',   '1Ucqc0bV4Y7QoVi1QSoVUGDBj8j-jNs97iz1evNlx4J4', 2122278614, 'Opps',             'opps',   null,           4, 2026, null,  true),
  ('teo',   '1Ucqc0bV4Y7QoVi1QSoVUGDBj8j-jNs97iz1evNlx4J4',  667978021, 'Pagos',            'pagos',  null,           1, null, 10000, true),
  ('mauro', '156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ', 2122278614, 'Opps',             'opps',   null,           4, 2026, null,  true),
  ('mauro', '156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ',  667978021, 'Historico Pagos',  'pagos',  null,           1, null, 10000, true),
  ('mauro', '156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ', 1304167527, 'Pagos Por Cobrar', 'cuotas', 'cuotas_ancho', 2, null, 10000, true),
  ('lucas', '1i3D4rGie3W1svlhf8jWLZHcPLc_Hl2GvALbo_uQI7rQ',          0, 'Opps',             'opps',   null,           4, 2026, null,  true),
  ('lucas', '1i3D4rGie3W1svlhf8jWLZHcPLc_Hl2GvALbo_uQI7rQ',  188432479, 'PAGOS',            'pagos',  null,           1, null, 10000, true),
  -- Planillas de CRM (fase 6, inactivas). fila_encabezado = 1 hasta relevarlas.
  ('liam',  '1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg',          0, 'Data',                'data',            null,           1, null, null,  false),
  ('liam',  '1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg',   33291330, 'Trazabilidad - Data', 'trazabilidad',    null,           1, null, null,  false),
  ('liam',  '1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg', 2019205895, 'PAGOS NO TOCAR',      'pagos_historico', null,           1, null, 10000, false),
  ('teo',   '1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U',          0, 'DATA',                'data',            null,           1, null, null,  false),
  ('teo',   '1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U',   99965983, 'TRAZABILIDAD',        'trazabilidad',    null,           1, null, null,  false),
  ('teo',   '1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U',   93797201, 'CUOTAS',              'cuotas',          'cuotas_plano', 1, null, 10000, false),
  ('mauro', '1jZXCyAZSDWnC2FlRDxB9w7KoO9pyPxIpZ-Kzhfb3u54',   10320787, 'Data',                'data',            null,           1, null, null,  false),
  ('mauro', '1jZXCyAZSDWnC2FlRDxB9w7KoO9pyPxIpZ-Kzhfb3u54', 1602859939, 'Trazabilidad - DATA', 'trazabilidad',    null,           1, null, null,  false),
  ('lucas', '13nn8Z25bZF25I5y2spkaB7_4j637rfWtJfsTyQJgSBI',          0, 'DATA',                'data',            null,           1, null, null,  false),
  ('lucas', '13nn8Z25bZF25I5y2spkaB7_4j637rfWtJfsTyQJgSBI',   72433952, 'Trazabilidad Data',   'trazabilidad',    null,           1, null, null,  false)
on conflict (spreadsheet_id, gid, tipo) do update set
  cliente_id           = excluded.cliente_id,
  nombre_hoja_esperado = excluded.nombre_hoja_esperado,
  forma                = excluded.forma,
  fila_encabezado      = excluded.fila_encabezado,
  anio                 = excluded.anio,
  tope_monto           = excluded.tope_monto,
  activo               = excluded.activo;

-- ---------------------------------------------------------------------------
-- 2. fin_alias_columnas (solo fuentes de pagos de las planillas de Finanzas)
-- ---------------------------------------------------------------------------
with alias (cliente_id, campo_canonico, alias, obligatorio) as (
  values
    ('liam',  'fecha',          'FECHA DE CARGA',         true),
    ('liam',  'programa',       'PROGRAMA',               false),
    ('liam',  'alumno',         'NOMBRE DEL ALUMNO',      true),
    ('liam',  'telefono',       'NUMERO',                 false),
    ('liam',  'concepto',       'CONCEPTO',               false),
    ('liam',  'monto',          'PAGO',                   true),
    ('liam',  'closer',         'CLOSER',                 false),
    ('liam',  'setter',         'SETTER',                 false),
    ('liam',  'comprobante',    'COMPROBANTE',            false),
    ('liam',  'quien_recibe',   'QUIÉN RECIBE',           false),
    ('liam',  'metodo_pago',    'MÉTODO DE PAGO',         false),
    ('agus',  'fecha',          'FECHA DE CARGA',         true),
    ('agus',  'programa',       'PROGRAMA',               false),
    ('agus',  'alumno',         'NOMBRE DEL ALUMNO',      true),
    ('agus',  'telefono',       'NUMERO',                 false),
    ('agus',  'concepto',       'CONCEPTO',               false),
    ('agus',  'monto',          'PAGO',                   true),
    ('agus',  'closer',         'CLOSER',                 false),
    ('agus',  'setter',         'SETTER',                 false),
    ('agus',  'comprobante',    'COMPROBANTE',            false),
    ('agus',  'quien_recibe',   'QUIÉN RECIBE',           false),
    ('agus',  'metodo_pago',    'MÉTODO DE PAGO',         false),
    ('teo',   'fecha',          'Fecha',                  true),
    ('teo',   'programa',       'PROGRAMA',               false),
    ('teo',   'alumno',         'NOMBRE DEL ALUMNO',      true),
    ('teo',   'telefono',       'NUMERO',                 false),
    ('teo',   'concepto',       'CONCEPTO',               false),
    ('teo',   'monto',          'PAGO',                   true),
    ('teo',   'closer',         'CLOSER',                 false),
    ('teo',   'setter',         'SETTER',                 false),
    ('teo',   'comprobante',    'COMPROBANTE',            false),
    ('teo',   'quien_recibe',   'QUIÉN RECIBE',           false),
    ('teo',   'metodo_pago',    'MÉTODO DE PAGO',         false),
    ('mauro', 'fecha',          'Nombre',                 true),
    ('mauro', 'programa',       'PROGRAMA',               false),
    ('mauro', 'alumno',         'NOMBRE DEL ALUMNO',      true),
    ('mauro', 'telefono',       'NUMERO',                 false),
    ('mauro', 'concepto',       'CONCEPTO',               false),
    ('mauro', 'monto',          'PAGO',                   true),
    ('mauro', 'monto_pesos',    'PESOS',                  false),
    ('mauro', 'closer',         'CLOSER',                 false),
    ('mauro', 'setter',         'SETTER',                 false),
    ('mauro', 'comprobante',    'COMPROBANTE',            false),
    ('mauro', 'quien_recibe',   'QUIÉN RECIBE',           false),
    ('mauro', 'metodo_pago',    'MÉTODO DE PAGO',         false),
    ('mauro', 'monto_restante', 'Monto Restante a Pagar', false),
    ('lucas', 'fecha',          'FECHA DE CARGA',         true),
    ('lucas', 'programa',       'PROGRAMA',               false),
    ('lucas', 'alumno',         'Nombre',                 true),
    ('lucas', 'telefono',       'NUMERO',                 false),
    ('lucas', 'concepto',       'CONCEPTO',               false),
    ('lucas', 'monto',          'MONTO EN USD',           true),
    ('lucas', 'closer',         'Closer',                 false),
    ('lucas', 'setter',         'SETTER',                 false),
    ('lucas', 'comprobante',    'COMPROBANTE',            false),
    ('lucas', 'quien_recibe',   'Quien Recibe',           false),
    ('lucas', 'metodo_pago',    'MÉTODO DE PAGO',         false),
    ('lucas', 'estado',         'ESTADO',                 false)
)
insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio)
select f.id, a.campo_canonico, a.alias, a.obligatorio
from alias a
join public.fin_fuentes f
  on f.cliente_id = a.cliente_id and f.tipo = 'pagos' and f.activo
on conflict (fuente_id, campo_canonico, alias) do update set
  obligatorio = excluded.obligatorio;

-- ---------------------------------------------------------------------------
-- 3. Prueba de humo (solo asserts; no escribe nada extra que revertir).
-- ---------------------------------------------------------------------------
do $$
declare v int;
begin
  select count(*) into v from public.fin_fuentes;
  if v < 22 then raise exception 'seed: se esperaban al menos 22 fuentes, hay %', v; end if;

  select count(*) into v from public.fin_fuentes where activo;
  if v <> 12 then raise exception 'seed: se esperaban 12 fuentes activas, hay %', v; end if;

  select count(*) into v from public.fin_fuentes where spreadsheet_id ilike '%PEGAR%';
  if v <> 0 then raise exception 'seed: quedaron placeholders'; end if;

  select count(*) into v from public.fin_alias_columnas;
  if v < 58 then raise exception 'seed: se esperaban 58 alias, hay %', v; end if;

  -- Cada fuente de pagos activa tiene sus 3 campos obligatorios.
  select count(*) into v
  from public.fin_fuentes f
  where f.tipo = 'pagos' and f.activo
    and (select count(distinct campo_canonico) from public.fin_alias_columnas a
         where a.fuente_id = f.id and a.obligatorio
           and a.campo_canonico in ('fecha', 'alumno', 'monto')) <> 3;
  if v <> 0 then raise exception 'seed: % fuentes de pagos sin fecha/alumno/monto obligatorios', v; end if;

  -- Una sola fuente activa por (cliente, tipo): la Edge Function asume eso.
  select count(*) into v from (
    select cliente_id, tipo from public.fin_fuentes where activo
    group by 1, 2 having count(*) > 1) d;
  if v <> 0 then raise exception 'seed: hay clientes con dos fuentes activas del mismo tipo'; end if;

  raise notice 'prueba de humo 002: OK';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Query de control
-- ---------------------------------------------------------------------------
select f.cliente_id, f.tipo, f.nombre_hoja_esperado, f.gid, f.forma, f.anio, f.tope_monto, f.activo,
       (select count(*) from public.fin_alias_columnas a where a.fuente_id = f.id) as alias
from public.fin_fuentes f
order by f.activo desc, f.cliente_id, f.tipo;

commit;
