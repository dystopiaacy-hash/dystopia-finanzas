-- =====================================================================
-- 028_usuarios_prueba.sql
-- Da de alta un closer o un setter de prueba y verifica que vea lo justo.
-- NO es una migracion de esquema: no cambia tablas, solo carga filas.
--
-- ANTES DE CORRER: crear el usuario en Supabase, en Authentication >
-- Users > Add user, con email y contrasena. Esto no se puede hacer desde
-- el SQL Editor. Despues volves aca con ese email.
--
-- Hay que correr los bloques EN ORDEN y leyendo lo que devuelve cada uno.
-- El bloque A es para elegir a quien imitar; el B da de alta; el C
-- verifica desde el lado del fundador; el D es la prueba de verdad, que
-- es loguearse.
-- =====================================================================


-- =====================================================================
-- BLOQUE A - ELEGIR A QUIEN IMITAR (solo lectura)
-- =====================================================================

-- Closers con mas llamadas, por cliente. Conviene elegir uno con
-- bastante volumen para que la prueba sea visible.
select l.cliente_id,
       btrim(l.closer)                    as alias_en_la_planilla,
       count(*)                           as llamadas,
       count(*) filter (where l.fecha_llamada >= date_trunc('month', current_date))
                                          as este_mes,
       v.id                               as vendedor_id,
       v.nombre                           as vendedor
from fin_llamadas l
left join fin_personas p
       on p.cliente_id = l.cliente_id
      and lower(btrim(p.alias)) = lower(btrim(l.closer))
left join fin_vendedores v on v.id = p.vendedor_id
where nullif(btrim(l.closer), '') is not null
group by l.cliente_id, btrim(l.closer), v.id, v.nombre
having count(*) >= 20
order by llamadas desc
limit 15;

-- Setters, con cuantas llamadas les toca segun la atribucion de la 027.
-- Esto es lo que va a ver cada uno.
select v.nombre as setter, v.id as vendedor_id,
       s.cliente_id, count(*) as llamadas
from fin_v_llamadas_setter s
join fin_vendedores v on v.id = s.setter_vendedor_id
join fin_llamadas l on l.id = s.llamada_id
where l.fecha_llamada <= current_date
group by v.nombre, v.id, s.cliente_id
order by llamadas desc;


-- =====================================================================
-- BLOQUE B - ALTA
-- Editar las cuatro variables de arriba del bloque y correrlo entero.
-- Es idempotente: correrlo dos veces no duplica nada.
-- =====================================================================

do $$
declare
  -- >>> EDITAR ESTAS CUATRO <<<
  v_email    text := 'prueba@dystopia.test';  -- el usuario ya creado en Auth
  v_rol      text := 'setter';                        -- 'closer' o 'setter'
  v_cliente  text := 'liam';
  v_alias    text := 'Juani Arocas';
  -- Para SETTER: el nombre del vendedor, tal cual esta en fin_vendedores.
  --   Juani Arocas en liam tiene 135 llamadas atribuidas: sirve de prueba.
  -- Para CLOSER: el alias tal cual aparece en la columna de la planilla.
  --   Sacalo del bloque A; si inventas uno, el listado da vacio y parece
  --   que la app fallo cuando en realidad el alias no existe.
  -- <<< NO EDITAR DE ACA PARA ABAJO >>>
  v_uid      uuid;
  -- fin_personas.vendedor_id es bigint (los ids de vendedores son 4, 5, 11, 14…),
  -- no uuid. auth.users.id si es uuid: son dos tipos distintos en la misma
  -- tabla y confundirlos rompe el insert.
  v_vendedor_id bigint;
  v_persona_id       bigint;
  v_user_existente   uuid;
  v_campo_existente  text;
begin
  select id into v_uid from auth.users where lower(email) = lower(v_email);
  if v_uid is null then
    raise exception 'No existe el usuario %. Crealo primero en Authentication > Users.', v_email;
  end if;

  if v_rol not in ('closer', 'setter') then
    raise exception 'El rol tiene que ser closer o setter, no %', v_rol;
  end if;

  -- 1. Rol. Sin esto la app lo rechaza en el login.
  insert into crm_members (user_id, rol, nombre)
  values (v_uid, v_rol, v_alias)
  on conflict (user_id) do update set rol = excluded.rol;

  -- 2. Acceso al cliente. Sin esto el selector de clientes sale vacio y
  --    la app dice "no tenes clientes asignados". Da el NOMBRE del
  --    cliente, no sus datos: desde la 024 las tablas de plata piden
  --    ademas que el rol sea 'cliente'.
  insert into crm_asignaciones (user_id, cliente_id)
  values (v_uid, v_cliente)
  on conflict do nothing;

  -- 3. La persona. fin_personas ya tiene una fila por alias de cada
  --    planilla, con user_id en null. Vincular un usuario es COMPLETAR esa
  --    fila, no crear otra: hay un unico index sobre (cliente_id, alias) y
  --    duplicarla esta prohibido, con razon. Si se creara una segunda fila,
  --    el mismo alias apuntaria a dos personas.
  select p.id, p.user_id, p.campo, p.vendedor_id
    into v_persona_id, v_user_existente, v_campo_existente, v_vendedor_id
  from fin_personas p
  where coalesce(p.cliente_id, '*') = coalesce(v_cliente, '*')
    and lower(btrim(p.alias)) = lower(btrim(v_alias));

  if v_persona_id is null then
    -- No hay fila de alias: se busca el vendedor por nombre y se crea.
    select (array_agg(v.id))[1] into v_vendedor_id
    from fin_vendedores v
    join fin_vendedor_asignaciones a on a.vendedor_id = v.id
    where a.cliente_id = v_cliente
      and fin_normalizar_nombre(v.nombre) = fin_normalizar_nombre(v_alias);

    insert into fin_personas (user_id, cliente_id, alias, campo, vendedor_id)
    values (v_uid, v_cliente, v_alias, v_rol, v_vendedor_id);
    raise notice 'Cree la fila de alias % en %', v_alias, v_cliente;

  else
    -- La fila existe. Tres chequeos antes de tocarla.
    if v_user_existente is not null and v_user_existente <> v_uid then
      raise exception 'El alias % en % ya esta vinculado a otro usuario (%). No lo piso.',
        v_alias, v_cliente, v_user_existente;
    end if;

    if v_campo_existente is not null
       and v_campo_existente <> v_rol
       and v_campo_existente <> 'ambos' then
      raise exception 'El alias % en % esta cargado como % y vos pedis %. Si la persona hace las dos cosas, poné campo = ambos a mano y volvé a correr.',
        v_alias, v_cliente, v_campo_existente, v_rol;
    end if;

    if v_vendedor_id is null then
      select (array_agg(v.id))[1] into v_vendedor_id
      from fin_vendedores v
      join fin_vendedor_asignaciones a on a.vendedor_id = v.id
      where a.cliente_id = v_cliente
        and fin_normalizar_nombre(v.nombre) = fin_normalizar_nombre(v_alias);
    end if;

    update fin_personas
       set user_id     = v_uid,
           campo       = coalesce(v_campo_existente, v_rol),
           vendedor_id = v_vendedor_id
     where id = v_persona_id;
    raise notice 'Vincule el usuario a la fila de alias que ya existia (id %)', v_persona_id;
  end if;

  if v_vendedor_id is null then
    raise warning 'El alias % en % no tiene vendedor asociado. Un CLOSER igual va a ver sus llamadas (van por alias), pero un SETTER no va a ver ninguna.', v_alias, v_cliente;
  end if;

  raise notice 'Listo: % como % de %, alias %, vendedor_id %',
    v_email, v_rol, v_cliente, v_alias, coalesce(v_vendedor_id::text, 'sin asociar');
end $$;


-- =====================================================================
-- BLOQUE C - QUE DEBERIA VER (desde el fundador, antes de loguearte)
-- Esto calcula lo mismo que la RLS, pero mirando desde afuera. Si da
-- cero, no tiene sentido que te loguees: algo falta del alta.
-- =====================================================================

with quien as (
  select u.id as uid, u.email, m.rol, p.cliente_id, p.alias, p.campo, p.vendedor_id
  from auth.users u
  join crm_members m on m.user_id = u.id
  join fin_personas p on p.user_id = u.id
  where lower(u.email) = lower('prueba@dystopia.test')  -- EDITAR
)
select q.email, q.rol, q.cliente_id, q.alias,
       (select count(*) from crm_asignaciones a
         where a.user_id = q.uid)                              as clientes_visibles,
       case q.rol
         when 'closer' then (
           select count(*) from fin_llamadas l
           where l.cliente_id = q.cliente_id
             and lower(btrim(l.closer)) = lower(btrim(q.alias)))
         when 'setter' then (
           select count(*) from fin_v_llamadas_setter s
           join fin_llamadas l on l.id = s.llamada_id
           where s.setter_vendedor_id = q.vendedor_id
             and l.fecha_llamada <= current_date)
       end                                                     as llamadas_que_deberia_ver
from quien q;


-- =====================================================================
-- BLOQUE D - LA PRUEBA DE VERDAD
--
-- Lo de arriba calcula lo que la RLS deberia dar. Lo unico que prueba
-- que la RLS hace eso es entrar con el usuario. En una ventana de
-- incognito, en dystopia-ventas.vercel.app:
--
--   1. La barra lateral tiene SOLO "Llamadas". Ni Dashboard, ni Fuentes,
--      ni Closers, ni Comisiones.
--   2. El listado trae la misma cantidad que dio el bloque C.
--      Si trae MAS, hay una fuga y hay que frenar todo.
--   3. Escribir a mano .../app#comisiones: tiene que caer en Llamadas.
--   4. El selector de clientes muestra solo el cliente asignado.
--   5. Abrir una fila: se ve el contexto, el telefono y el instagram.
--   6. Cambiar de area a Finanzas desde la barra de arriba: ahi tambien
--      hay que mirar que no vea de mas.
--
-- Y despues, con tu propio usuario de fundador, revisar que las cinco
-- pantallas sigan funcionando igual que antes.
-- =====================================================================


-- =====================================================================
-- BORRAR EL USUARIO DE PRUEBA cuando termines
-- =====================================================================
-- do $$
-- declare v_uid uuid;
-- begin
--   select id into v_uid from auth.users where lower(email) = lower('prueba@dystopia.test');
--   delete from fin_personas     where user_id = v_uid;
--   delete from crm_asignaciones where user_id = v_uid;
--   delete from crm_members      where user_id = v_uid;
--   -- el usuario de Auth se borra desde Authentication > Users
-- end $$;
