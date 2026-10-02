-- =====================================================================
-- 035_prueba_closer.sql
-- (numerado 035 porque 031 a 034 los usa el modulo Finanzas)
-- Prueba el camino de CLOSER, que esta escrito desde la 024 y nunca se
-- ejecuto con un usuario real. El 25/09 probamos solo el de setter.
--
-- Son dos caminos distintos dentro de la misma politica:
--   setter -> se deduce de la fuente y del calendario de setters
--   closer -> matchea el alias de fin_personas contra la columna
--             "Encargado de la llamada" de la planilla
--
-- Que uno funcione no dice nada del otro.
--
-- REUSA el usuario prueba@dystopia.test que ya existe. Lo pasa a closer
-- y le mueve el vinculo a un alias de closer real. Al final esta el
-- bloque para devolverlo a setter o desvincularlo del todo.
--
-- IMPORTANTE: vincular el usuario de prueba OCUPA la fila de alias de
-- esa persona. Mientras dure la prueba, si al closer real se le crea la
-- cuenta, no va a poder vincularse. Por eso conviene desvincular apenas
-- termines.
-- =====================================================================


-- =====================================================================
-- BLOQUE A - ELEGIR EL ALIAS (solo lectura)
-- Closers con volumen en el mes en curso, que es lo que se va a ver.
-- =====================================================================

-- El vinculo se trae con un LEFT JOIN y un agregado, no con una
-- subconsulta en el SELECT: Postgres no acepta ahi adentro columnas de
-- la consulta externa que no sean columnas agrupadas, y aca se agrupa
-- por la EXPRESION btrim(l.closer), no por la columna.
-- El join no multiplica filas porque fin_personas tiene indice unico
-- sobre (cliente_id, lower(btrim(alias))).
select l.cliente_id,
       btrim(l.closer)                                  as alias_en_la_planilla,
       count(*)                                         as llamadas_totales,
       count(*) filter (where l.fecha_llamada >= date_trunc('month', current_date))
                                                        as este_mes,
       count(*) filter (where l.fecha_llamada > current_date)
                                                        as a_futuro,
       max(p.user_id::text)                             as ya_vinculado_a,
       max(p.campo)                                     as campo_cargado
from fin_llamadas l
left join fin_personas p
       on p.cliente_id = l.cliente_id
      and lower(btrim(p.alias)) = lower(btrim(l.closer))
where nullif(btrim(l.closer), '') is not null
group by l.cliente_id, btrim(l.closer)
having count(*) >= 20
order by este_mes desc, llamadas_totales desc
limit 15;


-- =====================================================================
-- BLOQUE B - PASAR EL USUARIO DE PRUEBA A CLOSER
-- Editar las dos variables y correr el bloque entero.
-- =====================================================================

do $$
declare
  -- >>> EDITAR <<<
  v_cliente text := 'liam';
  v_alias   text := 'LUCAS DEZA';   -- del bloque A, tal cual la planilla
  -- <<< NO EDITAR ABAJO >>>
  v_email   text := 'prueba@dystopia.test';
  v_uid     uuid;
  v_fila    bigint;
  v_de_otro uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(v_email);
  if v_uid is null then
    raise exception 'No existe %. Crealo en Authentication > Users.', v_email;
  end if;

  -- 1. Soltar el vinculo anterior, para no dejar dos alias apuntando al
  --    mismo usuario. Sin esto, la prueba de closer heredaria ademas las
  --    llamadas del setter y el conteo no probaria nada.
  update fin_personas set user_id = null where user_id = v_uid;

  -- 2. El rol. La politica elige la rama por ROL, no por campo: un
  --    usuario con campo 'ambos' pero rol 'setter' entra solo por la
  --    rama de setter.
  update crm_members set rol = 'closer' where user_id = v_uid;

  -- 3. Acceso al cliente, para que el selector no salga vacio.
  insert into crm_asignaciones (user_id, cliente_id)
  values (v_uid, v_cliente) on conflict do nothing;

  -- 4. Vincular a la fila de alias del closer.
  select p.id, p.user_id into v_fila, v_de_otro
  from fin_personas p
  where coalesce(p.cliente_id, '*') = v_cliente
    and lower(btrim(p.alias)) = lower(btrim(v_alias));

  if v_fila is null then
    raise exception 'No existe la fila de alias % en %. Elegí uno del bloque A.', v_alias, v_cliente;
  end if;
  if v_de_otro is not null and v_de_otro <> v_uid then
    raise exception 'El alias % en % ya es de otro usuario (%). Elegí otro.', v_alias, v_cliente, v_de_otro;
  end if;

  update fin_personas
     set user_id = v_uid,
         campo   = case when campo = 'setter' then 'ambos' else coalesce(campo, 'closer') end
   where id = v_fila;

  raise notice 'Listo: % es closer % de %', v_email, v_alias, v_cliente;
end $$;


-- =====================================================================
-- BLOQUE C - QUE DEBERIA VER
-- Replica EXACTA de la rama de closer de la politica. Si esto y la
-- pantalla no coinciden, hay algo mal.
-- =====================================================================

with u as (select id from auth.users where lower(email) = lower('prueba@dystopia.test'))
select case when l.fecha_llamada is null then 'SIN FECHA'
            when l.fecha_llamada > current_date then 'PROXIMAS'
            else to_char(l.fecha_llamada, 'YYYY-MM') end as pestania,
       count(*) as llamadas
from fin_llamadas l
where exists (
  select 1 from fin_personas p
  where p.user_id    = (select id from u)
    and p.campo      in ('closer', 'ambos')
    and p.cliente_id = l.cliente_id
    and lower(btrim(p.alias)) = lower(btrim(l.closer))
)
group by 1
order by 1;

-- EL CONTROL QUE IMPORTA: el mismo alias existe en mas de un cliente
-- (Lucas Deza esta en liam y en mauro; Valentin Morello en liam y teo).
-- La politica exige p.cliente_id = l.cliente_id, asi que NO deberia ver
-- las del otro cliente. Esto lo mide.
with u as (select id from auth.users where lower(email) = lower('prueba@dystopia.test'))
select l.cliente_id, count(*) as llamadas_con_ese_alias,
       count(*) filter (where exists (
         select 1 from fin_personas p
         where p.user_id    = (select id from u)
           and p.campo      in ('closer', 'ambos')
           and p.cliente_id = l.cliente_id
           and lower(btrim(p.alias)) = lower(btrim(l.closer))
       )) as las_que_veria
from fin_llamadas l
where lower(btrim(l.closer)) = lower(btrim('LUCAS DEZA'))   -- EDITAR si usaste otro
group by l.cliente_id
order by l.cliente_id;


-- =====================================================================
-- BLOQUE D - EN INCOGNITO
--   1. La barra tiene solo Llamadas y el badge dice Closer.
--   2. Cada mes coincide con el bloque C.
--   3. La columna Closer muestra siempre el mismo nombre: el suyo.
--   4. En "las_que_veria" del otro cliente tiene que haber 0.
-- =====================================================================


-- =====================================================================
-- BLOQUE E - DEVOLVERLO A SETTER (o desvincular)
-- Correr apenas termines, para liberar la fila de alias.
-- =====================================================================

-- do $$
-- declare v_uid uuid;
-- begin
--   select id into v_uid from auth.users where lower(email) = lower('prueba@dystopia.test');
--   update fin_personas set user_id = null where user_id = v_uid;
--   -- Para volver a probar setter, descomentar las dos lineas:
--   -- update crm_members set rol = 'setter' where user_id = v_uid;
--   -- update fin_personas set user_id = v_uid
--   --  where cliente_id = 'liam' and lower(btrim(alias)) = 'juani arocas';
-- end $$;
