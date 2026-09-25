-- =====================================================================
-- 029_setter_funciones.sql
-- Arregla que un setter no vea ninguna llamada. Requiere la 027.
--
-- EL BUG: la politica de setter de fin_llamadas (027) hace un join
-- contra fin_fuentes_mapa y fin_setter_periodo. Una politica RLS se
-- evalua con los permisos del que consulta, no del que la escribio. Y en
-- la 024 restringi fin_fuentes_mapa a fundador y cliente.
--
-- Resultado: para un setter ese join no devuelve nada, el exists da
-- falso y no ve una sola llamada. Le puse un candado a una tabla que la
-- propia politica necesita leer.
--
-- Verificado: el usuario de prueba (setter de liam, vendedor 4) deberia
-- ver 137 llamadas y la pantalla le mostro cero.
--
-- LA CORRECCION, y por que asi: en vez de aflojar fin_fuentes_mapa, la
-- resolucion pasa a funciones SECURITY DEFINER. Una politica que depende
-- de la RLS de otra tabla es fragil: cualquiera que ajuste esa otra
-- tabla rompe esta sin enterarse, que es exactamente lo que paso. Con
-- funciones, la politica se explica sola.
--
-- Las funciones no conceden nada nuevo. Responden "quien era el setter
-- de esta llamada", que es un hecho, no un permiso. Quien puede ver la
-- llamada lo sigue decidiendo la politica.
-- =====================================================================

-- Todo va en una transaccion: si algo falla no queda nada a medias, y
-- hay que volver a correr el archivo entero.
begin;

-- =====================================================================
-- 1. Quien era el setter de una llamada.
--    Null si la fuente no es del setter, o si ese mes no tiene setter
--    determinado. SECURITY DEFINER para no depender de la RLS de
--    fin_fuentes_mapa ni de fin_setter_periodo.
-- =====================================================================

create or replace function fin_setter_de_llamada(
  p_cliente text, p_fecha date, p_booking text)
returns bigint
language sql stable security definer set search_path to 'public' as $$
  select sp.vendedor_id
  from fin_fuentes_mapa fm
  join fin_setter_periodo sp
    on sp.cliente_id = p_cliente
   and sp.periodo    = to_char(p_fecha, 'YYYY-MM')
  where fm.cliente_id   = p_cliente
    and fm.fuente_cruda = upper(btrim(p_booking))
    and fm.atribucion   = 'setter'
  limit 1;
$$;

comment on function fin_setter_de_llamada is
  'Setter atribuido a una llamada, deducido de la fuente (025) y del calendario de setters (026). Null = no se puede determinar.';

-- La fuente unificada y su atribucion, para que las pantallas las
-- muestren sin necesitar permiso sobre la tabla de mapeo.
create or replace function fin_fuente_de_llamada(p_cliente text, p_booking text)
returns text
language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select fm.fuente from fin_fuentes_mapa fm
      where fm.cliente_id = p_cliente
        and fm.fuente_cruda = upper(btrim(p_booking))),
    nullif(upper(btrim(p_booking)), ''),
    '(SIN FUENTE)');
$$;

create or replace function fin_atribucion_de_llamada(p_cliente text, p_booking text)
returns text
language sql stable security definer set search_path to 'public' as $$
  select fm.atribucion from fin_fuentes_mapa fm
   where fm.cliente_id = p_cliente
     and fm.fuente_cruda = upper(btrim(p_booking));
$$;

-- De donde salio el dato del setter de ese mes: 'pagos' (evidencia
-- directa), 'actual' (rellenado con el setter de hoy) o 'manual'. La
-- pantalla lo muestra para que se sepa que tan firme es la atribucion.
create or replace function fin_origen_setter_de_llamada(p_cliente text, p_fecha date)
returns text
language sql stable security definer set search_path to 'public' as $$
  select sp.origen from fin_setter_periodo sp
   where sp.cliente_id = p_cliente
     and sp.periodo    = to_char(p_fecha, 'YYYY-MM');
$$;

-- El nombre de un vendedor. Acotada a proposito: solo la responde para
-- fundadores, para un cliente con acceso, o para el propio vendedor.
-- Si no, devuelve null. Una funcion SECURITY DEFINER que devuelva
-- cualquier nombre por id deja enumerar el padron de vendedores.
create or replace function fin_nombre_vendedor(p_vendedor_id bigint)
returns text
language sql stable security definer set search_path to 'public' as $$
  select v.nombre
  from fin_vendedores v
  where v.id = p_vendedor_id
    and (
      es_fundador()
      or exists (select 1 from fin_personas p
                  where p.user_id = auth.uid() and p.vendedor_id = v.id)
      or (rol_actual() = 'cliente' and exists (
            select 1 from fin_vendedor_asignaciones a
            where a.vendedor_id = v.id and tiene_acceso(a.cliente_id)))
    );
$$;


-- =====================================================================
-- 2. La politica, ahora sin depender de la RLS de otras tablas.
--    Las ramas de fundador, cliente y closer quedan como en la 024.
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
          select 1 from fin_personas p
          where p.user_id     = auth.uid()
            and p.campo       in ('setter', 'ambos')
            and p.cliente_id  = fin_llamadas.cliente_id
            and p.vendedor_id = fin_setter_de_llamada(
                  fin_llamadas.cliente_id,
                  fin_llamadas.fecha_llamada,
                  fin_llamadas.tipo_booking)
        ))
  );


-- =====================================================================
-- 3. La vista, por las mismas funciones. Antes un setter la leia con
--    todas las columnas en null, porque no tiene permiso sobre
--    fin_fuentes_mapa: la pantalla le decia "sin determinar" en todas.
-- =====================================================================

-- drop y no "create or replace": reemplazar una vista no permite sacarle
-- columnas (error 42P16). Nada mas depende de esta vista.
drop view if exists fin_v_llamadas_setter;

create view fin_v_llamadas_setter
with (security_invoker = true) as
select
  l.id                                        as llamada_id,
  l.cliente_id,
  to_char(l.fecha_llamada, 'YYYY-MM')         as periodo,
  upper(btrim(l.tipo_booking))                as fuente_cruda,
  fin_fuente_de_llamada(l.cliente_id, l.tipo_booking)      as fuente,
  fin_atribucion_de_llamada(l.cliente_id, l.tipo_booking)  as atribucion,
  fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking)
                                              as setter_vendedor_id,
  fin_nombre_vendedor(
    fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking))
                                              as setter,
  fin_origen_setter_de_llamada(l.cliente_id, l.fecha_llamada)
                                              as origen_setter
from fin_llamadas l;

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. Como fundador, la vista tiene que dar lo mismo que antes.
--    Esperado por cliente: mismos numeros que el control 2 de la 027.
select s.cliente_id,
       count(*)                                                as llamadas,
       count(*) filter (where s.atribucion = 'setter')          as fuente_de_setter,
       count(*) filter (where s.setter_vendedor_id is not null) as con_setter
from fin_v_llamadas_setter s
join fin_llamadas l on l.id = s.llamada_id
where l.fecha_llamada <= current_date
group by s.cliente_id
order by con_setter desc;

-- 2. Lo que tiene que ver el usuario de prueba, calculado con la MISMA
--    funcion que usa la politica. Esperado: 137, y 65 / 70 / 2 abierto
--    por pestania.
with u as (select id from auth.users where lower(email) = lower('prueba@dystopia.test'))
select case when l.fecha_llamada > current_date
            then 'PROXIMAS' else to_char(l.fecha_llamada, 'YYYY-MM') end as pestania,
       count(*) as llamadas
from fin_llamadas l
where l.fecha_llamada is not null
  and exists (
    select 1 from fin_personas p
    where p.user_id     = (select id from u)
      and p.campo       in ('setter', 'ambos')
      and p.cliente_id  = l.cliente_id
      and p.vendedor_id = fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking)
  )
group by 1
order by 1;

-- 3. CONTROL DE FUGA: la funcion no puede atribuir una llamada a un
--    vendedor que no esta asignado a ese cliente.
select 'setter atribuido sin asignacion al cliente' as control,
       count(*) as valor_esperado_0
from fin_llamadas l
where fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking) is not null
  and not exists (
    select 1 from fin_vendedor_asignaciones a
    where a.vendedor_id = fin_setter_de_llamada(l.cliente_id, l.fecha_llamada, l.tipo_booking)
      and a.cliente_id  = l.cliente_id
      and a.es_setter
  );

-- 4. CONTROL DE FUGA: fin_nombre_vendedor no puede responder por un
--    vendedor cualquiera. Corrido como fundador devuelve nombres (sos
--    fundador); lo que prueba el acotado es correrlo despues como el
--    usuario de prueba y ver que solo le responda por el vendedor 4.
select v.id, v.nombre as nombre_real, fin_nombre_vendedor(v.id) as lo_que_devuelve
from fin_vendedores v
order by v.id
limit 10;
