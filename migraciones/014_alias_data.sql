-- 014_alias_data.sql — Dystopia Finanzas: alias de columnas de la hoja Data.
-- Ver CONTRATO-DATA.md §2 (mapeo por cliente) y §4.1 (liam por posicion).
--
-- Carga fin_alias_columnas para las 4 fuentes tipo 'data' sembradas en 002
-- (liam, lucas, teo, mauro). NO las activa: fin_fuentes.activo queda como
-- esta (false). Las columnas IGNORAR del contrato no se cargan.
--
-- - liam: las columnas 1 y 2 se llaman las dos "Encargado de la llamada".
--   closer va con posicion = 1 y fecha_llamada con posicion = 2. El parser
--   lee esas columnas por posicion y exige que el encabezado coincida.
-- - mauro: 'nombre' tiene dos alias (Nombre y Apellido). parsers/data.js
--   concatena las dos columnas en orden.
-- - mauro col 11: el encabezado real tiene un salto de linea
--   ("Que paso en la llamda?\nContexto + Phatom"). El parser compara con
--   normalizar(), que colapsa espacios y saltos, asi que el alias va con un
--   espacio. El typo "llamda" es el de la planilla.
-- - Encabezados con espacio al final en la planilla ("Celular ", "Programa ")
--   se cargan sin el espacio: normalizar() recorta.
--
-- pruebas/data.mjs lee las filas de VALUES de este archivo: si se cambia el
-- formato de una fila (una por linea, 5 valores), actualizar la prueba.
--
-- Idempotente: upsert por (fuente_id, campo_canonico, alias). Requiere 002 y 013.

begin;

do $$
declare v_falta text;
begin
  select string_agg(c, ', ') into v_falta
  from unnest(array['liam', 'lucas', 'teo', 'mauro']) as c
  where (select count(*) from public.fin_fuentes f where f.cliente_id = c and f.tipo = 'data') <> 1;
  if v_falta is not null then
    raise exception '014: se esperaba exactamente una fuente tipo data para: %', v_falta;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'fin_alias_columnas' and column_name = 'posicion') then
    raise exception '014: falta fin_alias_columnas.posicion (correr 013 antes)';
  end if;
end $$;

insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, posicion)
select f.id, x.campo, x.alias, x.obligatorio, x.posicion
from (values
  -- liam (BPF)
  ('liam',  'closer',          'Encargado de la llamada',                  true,  1),
  ('liam',  'fecha_llamada',   'Encargado de la llamada',                  true,  2),
  ('liam',  'nombre',          'Nombre',                                   true,  null),
  ('liam',  'calificacion',    'Calificacion',                             false, null),
  ('liam',  'show_up',         'Show up',                                  false, null),
  ('liam',  'contexto_setter', 'Contexto',                                 false, null),
  ('liam',  'contexto_closer', 'Contexto Closer',                          false, null),
  ('liam',  'cc_dia1',         'CC DIA 1',                                 false, null),
  ('liam',  'cc_seguimiento',  'CC Seguimiento',                           false, null),
  ('liam',  'cc_cerrado',      'CC TRATO CERRADO',                         false, null),
  ('liam',  'monto_restante',  'Monto restante a pagar',                   false, null),
  ('liam',  'telefono',        'Teléfono',                                 false, null),
  ('liam',  'tipo_booking',    'tipo de booking',                          false, null),
  -- lucas (CCYVDAA)
  ('lucas', 'nombre',          'Nombre',                                   true,  null),
  ('lucas', 'fecha_llamada',   'Fecha de llamada',                         true,  null),
  ('lucas', 'closer',          'Encargado de la llamada',                  true,  null),
  ('lucas', 'show_up',         'Show up',                                  false, null),
  ('lucas', 'calificacion',    'Calificacion',                             false, null),
  ('lucas', 'contexto_setter', 'Contexto Setter',                          false, null),
  ('lucas', 'contexto_closer', 'Contexto Closer',                          false, null),
  ('lucas', 'tipo_booking',    'Tipo de Booking',                          false, null),
  ('lucas', 'instagram',       'Cuenta de IG',                             false, null),
  ('lucas', 'telefono',        'Celular',                                  false, null),
  ('lucas', 'programa',        'Programa',                                 false, null),
  ('lucas', 'cc_dia1',         'CC DIA 1',                                 false, null),
  ('lucas', 'cc_cerrado',      'CC TRATO CERRADO',                         false, null),
  ('lucas', 'cc_seguimiento',  'CC en Seguimiento',                        false, null),
  ('lucas', 'monto_restante',  'Monto restante a pagar',                   false, null),
  -- teo (NEC)
  ('teo',   'nombre',          'Nombre Completo',                          true,  null),
  ('teo',   'fecha_llamada',   'Fecha de llamada',                         true,  null),
  ('teo',   'closer',          'Encargado de la llamada',                  true,  null),
  ('teo',   'show_up',         'Show up',                                  false, null),
  ('teo',   'calificacion',    'Calificacion',                             false, null),
  ('teo',   'estado_llamada',  'Estado de la llamada',                     false, null),
  ('teo',   'tipo_booking',    'Fuente',                                   false, null),
  ('teo',   'telefono',        'Telefono',                                 false, null),
  ('teo',   'instagram',       'instagram',                                false, null),
  ('teo',   'contexto_closer', 'CONTEXTO CLOSER',                          false, null),
  ('teo',   'programa',        'Programa',                                 false, null),
  ('teo',   'cc_dia1',         'CC DIA 1',                                 false, null),
  ('teo',   'cc_cerrado',      'CC TRATO CERRADO',                         false, null),
  ('teo',   'cc_seguimiento',  'CC en Seguimiento',                        false, null),
  ('teo',   'monto_restante',  'Monto restante a pagar',                   false, null),
  -- mauro (AA)
  ('mauro', 'nombre',          'Nombre',                                   true,  null),
  ('mauro', 'nombre',          'Apellido',                                 true,  null),
  ('mauro', 'fecha_llamada',   'Fecha de llamada',                         true,  null),
  ('mauro', 'closer',          'Encargado de la llamada',                  true,  null),
  ('mauro', 'show_up',         'Show up',                                  false, null),
  ('mauro', 'calificacion',    'Calificacion',                             false, null),
  ('mauro', 'estado_llamada',  'Estado de la llamada',                     false, null),
  ('mauro', 'contexto_setter', 'CONTEXTO SETTER',                          false, null),
  ('mauro', 'contexto_closer', 'Que paso en la llamda? Contexto + Phatom', false, null),
  ('mauro', 'programa',        'Programa',                                 false, null),
  ('mauro', 'cc_dia1',         'CC DIA 1',                                 false, null),
  ('mauro', 'cc_cerrado',      'CC TRATO CERRADO',                         false, null),
  ('mauro', 'cc_seguimiento',  'CC en Seguimiento',                        false, null),
  ('mauro', 'monto_restante',  'Monto restante a pagar',                   false, null),
  ('mauro', 'tipo_booking',    'tipo de booking',                          false, null),
  ('mauro', 'telefono',        'telefono',                                 false, null),
  ('mauro', 'instagram',       'instagram',                                false, null)
) as x(cliente_id, campo, alias, obligatorio, posicion)
join public.fin_fuentes f on f.cliente_id = x.cliente_id and f.tipo = 'data'
on conflict (fuente_id, campo_canonico, alias) do update
  set obligatorio = excluded.obligatorio,
      posicion    = excluded.posicion;

-- ---------------------------------------------------------------------------
-- Query de control: la columna "ok" tiene que dar true en todas las filas.
-- ---------------------------------------------------------------------------
with a as (
  select f.cliente_id, f.activo, c.*
  from public.fin_fuentes f
  join public.fin_alias_columnas c on c.fuente_id = f.id
  where f.tipo = 'data'
)
select 'alias Data: ' || e.cliente_id as control,
       coalesce(n.filas, 0)::text as valor,
       coalesce(n.filas, 0) = e.esperado as ok
from (values ('liam', 13), ('lucas', 15), ('teo', 15), ('mauro', 17)) as e(cliente_id, esperado)
left join (select cliente_id, count(*) as filas from a group by cliente_id) n using (cliente_id)
union all
select 'liam: fecha_llamada por posicion 2',
       string_agg(posicion::text, ','),
       count(*) = 1 and bool_and(posicion = 2 and alias = 'Encargado de la llamada')
from a where cliente_id = 'liam' and campo_canonico = 'fecha_llamada'
union all
select 'liam: closer por posicion 1',
       string_agg(posicion::text, ','),
       count(*) = 1 and bool_and(posicion = 1)
from a where cliente_id = 'liam' and campo_canonico = 'closer'
union all
select 'solo liam usa posicion',
       count(*)::text, count(*) = 2
from a where posicion is not null
union all
select 'obligatorios por cliente (fecha_llamada, closer, nombre)',
       string_agg(distinct cliente_id, ','),
       count(distinct cliente_id) = 4
from (select cliente_id from a where obligatorio
      group by cliente_id
      having count(distinct campo_canonico) = 3
         and bool_and(campo_canonico in ('fecha_llamada', 'closer', 'nombre'))) t
union all
select 'mauro: nombre = Nombre + Apellido',
       string_agg(alias, ' + ' order by alias desc), count(*) = 2
from a where cliente_id = 'mauro' and campo_canonico = 'nombre'
union all
select 'ningun alias de setter en Data',
       count(*)::text, count(*) = 0
from a where campo_canonico = 'setter'
union all
select 'fuentes data siguen inactivas',
       count(*) filter (where activo)::text, count(*) filter (where activo) = 0
from public.fin_fuentes where tipo = 'data';

commit;
