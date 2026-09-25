-- =====================================================================
-- 027_rls_setter_llamadas.sql
-- Conecta las tres piezas para que un setter vea sus llamadas.
-- Requiere la 025 y la 026 corridas.
--
-- NO TOCA fin_v_llamadas_clasificadas. La atribucion va en una vista
-- nueva al costado, asi no hay que reconstruir la cadena de vistas de
-- metricas y no se arriesga nada de lo que ya funciona.
--
-- COMO SE ATRIBUYE UNA LLAMADA A UN SETTER, ahora que la hoja Data no
-- tiene columna de setter. Tienen que darse las cuatro cosas:
--
--   1. La persona logueada tiene fila en fin_personas con campo setter
--      o ambos, para ESE cliente.
--   2. Esa persona es el setter que fin_setter_periodo marca para el
--      cliente y el mes de la llamada.
--   3. La fuente cruda de la llamada esta marcada 'setter' en
--      fin_fuentes_mapa (la regla de la 025).
--   4. La llamada ya tiene fecha.
--
-- Si falta cualquiera, no la ve. Un mes con el setter sin determinar no
-- le muestra nada a nadie, que es lo correcto: es preferible que falten
-- llamadas a que aparezcan las de otro.
--
-- LO QUE ESTO NO ES: no es el dato real, es una deduccion. Mientras
-- haya UN setter por cliente y por mes el resultado coincide con la
-- realidad. El dia que haya dos a la vez deja de coincidir y no avisa.
-- Por eso la tabla de la 026 tiene una fila por MES: un mes con dos
-- setters se marca sin determinar a mano y nadie ve nada de ese mes.
--
-- La solucion definitiva sigue siendo la columna de setter en Data.
-- =====================================================================

begin;

-- =====================================================================
-- 1. La rama de setter en la RLS de fin_llamadas.
--    Las ramas de fundador, cliente y closer quedan igual que en la 024.
-- =====================================================================

drop policy if exists fin_llamadas_lectura on fin_llamadas;
create policy fin_llamadas_lectura on fin_llamadas
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
    or (rol_actual() = 'closer' and exists (
          select 1 from fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_llamadas.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_llamadas.closer))
        ))
    or (rol_actual() = 'setter'
        and fin_llamadas.fecha_llamada is not null
        and exists (
          select 1
          from fin_personas p
          join fin_setter_periodo sp
            on sp.cliente_id  = fin_llamadas.cliente_id
           and sp.periodo     = to_char(fin_llamadas.fecha_llamada, 'YYYY-MM')
           and sp.vendedor_id = p.vendedor_id
          join fin_fuentes_mapa fm
            on fm.cliente_id   = fin_llamadas.cliente_id
           and fm.fuente_cruda = upper(btrim(fin_llamadas.tipo_booking))
          where p.user_id     = auth.uid()
            and p.campo       in ('setter', 'ambos')
            and p.cliente_id  = fin_llamadas.cliente_id
            and fm.atribucion = 'setter'
        ))
  );


-- =====================================================================
-- 2. Vista de atribucion, una fila por llamada. Las pantallas la unen
--    por llamada_id en vez de repetir la regla.
--    fm y sp tienen clave unica por (cliente, valor) y (cliente, mes),
--    asi que el join no multiplica filas.
-- =====================================================================

create or replace view fin_v_llamadas_setter
with (security_invoker = true) as
select
  l.id                                        as llamada_id,
  l.cliente_id,
  to_char(l.fecha_llamada, 'YYYY-MM')         as periodo,
  upper(btrim(l.tipo_booking))                as fuente_cruda,
  fm.fuente                                   as fuente,
  fm.atribucion                               as atribucion,
  -- Solo se llena si la fuente es del setter: una llamada de landing no
  -- tiene setter aunque haya uno cargado ese mes.
  case when fm.atribucion = 'setter' then sp.vendedor_id end
                                              as setter_vendedor_id,
  case when fm.atribucion = 'setter' then v.nombre end
                                              as setter,
  sp.origen                                   as origen_setter
from fin_llamadas l
left join fin_fuentes_mapa fm
       on fm.cliente_id   = l.cliente_id
      and fm.fuente_cruda = upper(btrim(l.tipo_booking))
left join fin_setter_periodo sp
       on sp.cliente_id = l.cliente_id
      and sp.periodo    = to_char(l.fecha_llamada, 'YYYY-MM')
left join fin_vendedores v
       on v.id = sp.vendedor_id;

comment on view fin_v_llamadas_setter is
  'Atribucion deducida de setter por llamada. setter_vendedor_id null = no se puede determinar. Ver 025 y 026.';

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. Una fila por llamada, el join no multiplico nada.
select 'la vista multiplica filas' as control, count(*) as valor_esperado_0
from (
  select llamada_id from fin_v_llamadas_setter
  group by llamada_id having count(*) > 1
) x;

-- 2. Cobertura real. Es mas exigente que el control 2 de la 026: ahi
--    contaba meses con setter conocido, aca ademas exige que la fuente
--    sea del setter.
select s.cliente_id,
       count(*)                                                as llamadas,
       count(*) filter (where s.atribucion = 'setter')          as fuente_de_setter,
       count(*) filter (where s.atribucion = 'landing')         as fuente_de_landing,
       count(*) filter (where s.setter_vendedor_id is not null) as con_setter,
       round(100.0 * count(*) filter (where s.setter_vendedor_id is not null)
             / nullif(count(*) filter (where s.atribucion = 'setter'), 0), 1)
                                                                as pct_de_las_del_setter
from fin_v_llamadas_setter s
join fin_llamadas l on l.id = s.llamada_id
where l.fecha_llamada <= current_date
group by s.cliente_id
order by pct_de_las_del_setter desc nulls last;

-- 3. Lo que va a ver cada setter cuando se le abra el acceso.
select s.setter, s.cliente_id, s.periodo, s.origen_setter, count(*) as llamadas
from fin_v_llamadas_setter s
join fin_llamadas l on l.id = s.llamada_id
where s.setter_vendedor_id is not null and l.fecha_llamada <= current_date
group by s.setter, s.cliente_id, s.periodo, s.origen_setter
order by s.setter, s.cliente_id, s.periodo;

-- 4. CONTROL DE FUGA: el setter atribuido tiene que estar asignado a
--    ese cliente en fin_vendedor_asignaciones.
select 'setter atribuido sin asignacion al cliente' as control,
       count(*) as valor_esperado_0
from fin_v_llamadas_setter s
where s.setter_vendedor_id is not null
  and not exists (
    select 1 from fin_vendedor_asignaciones a
    where a.vendedor_id = s.setter_vendedor_id
      and a.cliente_id  = s.cliente_id
      and a.es_setter
  );

-- 5. Llamadas de fuente "del setter" en meses sin setter determinado.
--    Son las que nadie va a ver. Cada fila es un renglon que la agencia
--    completa en fin_setter_periodo.
select s.cliente_id, s.periodo, count(*) as huerfanas
from fin_v_llamadas_setter s
join fin_llamadas l on l.id = s.llamada_id
where s.atribucion = 'setter'
  and s.setter_vendedor_id is null
  and l.fecha_llamada <= current_date
group by s.cliente_id, s.periodo
order by huerfanas desc;
