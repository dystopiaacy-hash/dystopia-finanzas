-- =====================================================================
-- 025_atribucion_setter.sql
-- Marca cada fuente como "del setter" o "de landing", segun la regla que
-- dio la agencia el 24/09. Requiere la 023 corrida.
--
-- POR QUE: la hoja Data no tiene columna de setter, asi que no se puede
-- saber quien agendo una llamada. La regla de la agencia permite deducir
-- SI hubo setter a partir de la fuente. Y como hoy hay un solo setter por
-- cliente, saber que hubo setter alcanza para saber cual.
--
-- ESO ULTIMO ES FRAGIL Y HAY QUE DEJARLO ESCRITO: el dia que un cliente
-- tenga dos setters, esta atribucion deja de identificar a la persona y
-- pasa a medir el canal. No se rompe con un error: sigue dando numeros,
-- y son de otra cosa. Por eso la resolucion del setter concreto NO se
-- hace aca. Va en la 026, disenada para devolver nulo cuando hay dos,
-- en vez de elegir uno.
--
-- LA REGLA TAL CUAL LA DIO LA AGENCIA:
--   setter  <- INSTAGRAM, TT SETTER
--   landing <- LANDING, TT (LANDING)
--
-- Eso cubre 4 de los 25 valores que hay en las planillas. El resto lo
-- decido yo y lo marco abajo. Cambiar cualquiera es un update de una
-- fila.
--
-- EXTIENDO LA REGLA (mismo sentido, distinta escritura):
--   setter  <- TT (SETTER), "TT (SETTER" sin cerrar, TIKTOK (SETTER)
--              son la misma cosa que TT SETTER
--           <- INTAGRAM es el typo de INSTAGRAM
--   landing <- LANDING INSTAGRAM lleva LANDING en el nombre
--           <- TT y TIKTOK a secas, por lo que dijiste el 24/09: "las
--              que sean tiktok van a salir como si fuesen de la landing
--              y si no los otros serian del setter". O sea: TikTok sin
--              aclaracion es contenido que lleva a la landing.
--
-- LO QUE DEJO SIN DEFINIR (259 llamadas, 11 % del total): WEBINAR,
-- PRE WEBINAR, YOUTUBE, YOUTUBE VENTAS, LEAD MAGNET, TT (WPP),
-- INSTAGRAM (CUENTA NEC), PRODUCTO, CLASE, OUTBOUND GONZA, REFERIDO,
-- WHATSAPP y (SIN FUENTE).
--
-- Dos merecen que las mires:
--   INSTAGRAM (CUENTA NEC) - es Instagram, y por la regla seria del
--     setter. No la marco porque la agencia dijo que es una fuente
--     aparte, y "aparte" puede significar que la trabaja otro.
--   TT (WPP) - TikTok que sigue por WhatsApp. Que haya WhatsApp sugiere
--     que alguien escribio, pero no esta dicho.
-- =====================================================================

begin;

alter table fin_fuentes_mapa
  add column if not exists atribucion text;

alter table fin_fuentes_mapa
  drop constraint if exists fin_fuentes_mapa_atribucion_chk;
alter table fin_fuentes_mapa
  add constraint fin_fuentes_mapa_atribucion_chk
  check (atribucion is null or atribucion in ('setter', 'landing'));

comment on column fin_fuentes_mapa.atribucion is
  'setter = la llamada la agendo el setter del cliente. landing = entro sola. null = sin definir, no se atribuye a nadie.';

-- La regla, aplicada sobre el valor CRUDO de la planilla, no sobre la
-- fuente canonica: TT SETTER y TT quedaron los dos como TIKTOK en la
-- 023 y se atribuyen distinto.
update fin_fuentes_mapa set atribucion = 'setter'
 where fuente_cruda in ('INSTAGRAM', 'INTAGRAM', 'TT SETTER', 'TT (SETTER)',
                        'TT (SETTER', 'TIKTOK (SETTER)');

update fin_fuentes_mapa set atribucion = 'landing'
 where fuente_cruda in ('LANDING', 'TT (LANDING)', 'LANDING INSTAGRAM',
                        'TT', 'TIKTOK');

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. Como quedo repartido, con volumen. Revisa que los numeros grandes
--    esten del lado que corresponde antes de seguir.
select coalesce(f.atribucion, 'SIN DEFINIR') as atribucion,
       f.fuente_cruda,
       count(*) as llamadas,
       string_agg(distinct f.cliente_id, ', ' order by f.cliente_id) as clientes
from fin_fuentes_mapa f
join fin_llamadas l
  on l.cliente_id = f.cliente_id
 and upper(btrim(l.tipo_booking)) = f.fuente_cruda
group by 1, 2
order by 1, llamadas desc;

-- 2. Totales. Con la regla de hoy: setter 1908, landing 173,
--    sin definir 259. Si no da eso, algo no matcheo.
select coalesce(f.atribucion, 'SIN DEFINIR') as atribucion,
       count(*) as llamadas,
       round(100.0 * count(*) / sum(count(*)) over (), 1) as pct
from fin_fuentes_mapa f
join fin_llamadas l
  on l.cliente_id = f.cliente_id
 and upper(btrim(l.tipo_booking)) = f.fuente_cruda
group by 1
order by llamadas desc;

-- 3. Lo que falta definir, por volumen. Cada fila es una decision
--    pendiente de la agencia. Se resuelve con un update.
select f.fuente_cruda,
       string_agg(distinct f.cliente_id, ', ' order by f.cliente_id) as clientes,
       count(*) as llamadas
from fin_fuentes_mapa f
join fin_llamadas l
  on l.cliente_id = f.cliente_id
 and upper(btrim(l.tipo_booking)) = f.fuente_cruda
where f.atribucion is null
group by f.fuente_cruda
order by llamadas desc;


-- =====================================================================
-- INSPECCION PARA LA 026 (solo lectura)
-- Necesito los tipos y el contenido de las tablas de vendedores para
-- escribir la resolucion del setter sin adivinar.
-- =====================================================================

select table_name, column_name, data_type, is_nullable
from information_schema.columns
where table_name in ('fin_vendedores', 'fin_vendedor_asignaciones', 'fin_personas')
order by table_name, ordinal_position;

-- Cuantos setters tiene cada cliente hoy, segun las asignaciones.
-- Tiene que dar 1 por cliente. Si da 0, falta cargarlo. Si da 2 o mas,
-- la atribucion por fuente no sirve para ese cliente.
select a.cliente_id,
       count(*) filter (where a.es_setter) as setters,
       count(*) filter (where a.es_closer) as closers,
       string_agg(v.nombre, ', ' order by v.nombre)
         filter (where a.es_setter) as quienes
from fin_vendedor_asignaciones a
join fin_vendedores v on v.id = a.vendedor_id
group by a.cliente_id
order by a.cliente_id;
