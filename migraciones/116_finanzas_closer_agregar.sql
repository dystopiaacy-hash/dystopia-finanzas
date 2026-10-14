-- 116_finanzas_closer_agregar.sql  (version corregida por el banco del jefe, 102/102)
-- Agregar closers desde la app (Cargar pago), sin tocar SQL ni codigo.
--
-- Crea UNA funcion: public.fin_closer_agregar(p_cliente, p_nombre, p_es_persona)
--   * Permiso: fundador, o rol 'finanzas' asignado a ese cliente (fin_asignado) que ademas pueda
--     cargar pagos ahi (fin_puede_cargar). Nadie mas.
--   * Duplicados: se busca en fin_vendedores por nombre normalizado (nombre_norm, unico).
--     Si existe, NO se crea otro: solo se lo asigna como closer del cliente.
--   * Si el nombre ya es alias (del cliente o GLOBAL) de OTRO vendedor, no hace nada y avisa:
--     crearlo cambiaria a quien se le atribuyen los pagos viejos con ese closer.
--   * Crea/actualiza fin_vendedor_asignaciones (es_closer = true). Si la asignacion estaba terminada
--     se reabre SOLO como closer (es_setter = false, desde = hoy).
--   * Crea el alias en fin_personas (vendedor_id, cliente, campo 'closer'), que es lo que
--     exige fin_pago_cargar (066). Para un vendedor existente el alias es su nombre canonico.
--     Si el vendedor ya tenia alias en el cliente como 'setter', pasa a 'ambos'.
--   * Un vendedor que existe pero esta inactivo (activo = false) solo lo reactiva un fundador.
-- No cambia datos existentes, no toca la lista actual de closers ni de programas.
-- Devuelve {id, nombre, nuevo, ya_asignado, reactivado}.
--
-- Correr (no a :00/:15/:30/:45 ni a las 9:00). Es un solo create or replace, re-ejecutable.

create or replace function public.fin_closer_agregar(
  p_cliente text, p_nombre text, p_es_persona boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_nombre  text;
  v_norm    text;
  v_id      bigint;
  v_activo  boolean;
  v_canon   text;
  v_alias   text;
  v_nuevo   boolean := false;
  v_ya      boolean := false;
  v_react   boolean := false;
  v_persona boolean := coalesce(p_es_persona, true);
  v_hoy     date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_asig    public.fin_vendedor_asignaciones%rowtype;
  v_otro    text;
  v_pers_id bigint;
begin
  if auth.uid() is null then
    raise exception 'fin: sesion requerida' using errcode = '42501';
  end if;
  if p_cliente is null or not exists (select 1 from public.crm_clients c where c.id = p_cliente) then
    raise exception 'fin: cliente invalido' using errcode = '22023';
  end if;
  if not (coalesce(public.es_fundador(), false)
          or (public.rol_actual() = 'finanzas' and public.fin_asignado(p_cliente)
              and public.fin_puede_cargar(p_cliente))) then
    raise exception 'fin: solo fundador o finanzas del cliente pueden agregar closers (%)', p_cliente using errcode = '42501';
  end if;

  -- Limpieza: ancho cero fuera, espacios raros y caracteres de control a espacio, despues colapsar y recortar.
  v_nombre := regexp_replace(coalesce(p_nombre, ''), '[\u200B\u200C\u200D\u2060\uFEFF]', '', 'g');
  v_nombre := regexp_replace(v_nombre, '[\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000[:cntrl:]]', ' ', 'g');
  v_nombre := btrim(regexp_replace(v_nombre, '\s+', ' ', 'g'));
  if char_length(v_nombre) < 2 or char_length(v_nombre) > 60 then
    raise exception 'fin: el nombre tiene que tener entre 2 y 60 caracteres' using errcode = '22023';
  end if;

  v_norm := public.fin_normalizar_nombre(v_nombre);
  select v.id, v.activo, v.nombre into v_id, v_activo, v_canon
    from public.fin_vendedores v where v.nombre_norm = v_norm limit 1;
  v_alias := coalesce(v_canon, v_nombre);

  -- Alias: si el vendedor ya tiene uno en este cliente (o global), no se crea otro.
  -- Si hay que crearlo, el texto no puede ser alias de OTRO vendedor en este cliente ni global
  -- (fin_v_pago_vendedores prefiere el alias del cliente: crearlo se "llevaria" pagos viejos).
  if v_id is null or not exists (select 1 from public.fin_personas x
                                  where x.vendedor_id = v_id and (x.cliente_id = p_cliente or x.cliente_id is null)) then
    select v.nombre into v_otro
      from public.fin_personas x join public.fin_vendedores v on v.id = x.vendedor_id
     where lower(btrim(x.alias)) = lower(v_alias)
       and (x.cliente_id = p_cliente or x.cliente_id is null)
       and x.vendedor_id is distinct from v_id
     order by (x.cliente_id is not null) desc, x.id
     limit 1;
    if v_otro is not null then
      raise exception 'fin: "%" ya es alias de % en %; elegilo de la lista o usa el nombre completo', v_alias, v_otro, p_cliente
        using errcode = '23505';
    end if;
  end if;

  if v_id is null then
    insert into public.fin_vendedores (nombre, es_persona) values (v_nombre, v_persona)
    on conflict (nombre_norm) do nothing
    returning id into v_id;
    if v_id is null then  -- lo creo otro en paralelo
      select v.id, v.activo, v.nombre into v_id, v_activo, v_canon from public.fin_vendedores v where v.nombre_norm = v_norm;
      v_alias := v_canon;
    else
      v_nuevo := true; v_activo := true; v_canon := v_nombre;
    end if;
  end if;
  if not v_activo then
    if not coalesce(public.es_fundador(), false) then
      raise exception 'fin: "%" existe pero esta inactivo; pedile a un fundador que lo reactive', v_canon using errcode = '42501';
    end if;
    update public.fin_vendedores set activo = true where id = v_id;
    v_react := true;
  end if;

  -- Asignacion como closer de este cliente (una fila por vendedor y cliente).
  select * into v_asig from public.fin_vendedor_asignaciones a
   where a.vendedor_id = v_id and a.cliente_id = p_cliente;
  if not found then
    insert into public.fin_vendedor_asignaciones (vendedor_id, cliente_id, es_closer, comisiona, desde)
    values (v_id, p_cliente, true,
            coalesce((select v.es_persona from public.fin_vendedores v where v.id = v_id), true), v_hoy)
    on conflict (vendedor_id, cliente_id) do nothing;
  elsif v_asig.hasta is not null and v_asig.hasta < v_hoy then
    -- terminada: se reabre solo como closer
    update public.fin_vendedor_asignaciones
       set es_closer = true, es_setter = false, hasta = null, desde = v_hoy
     where id = v_asig.id;
  elsif v_asig.es_closer then
    v_ya := true;
  else
    update public.fin_vendedor_asignaciones set es_closer = true where id = v_asig.id;
  end if;

  -- Alias (lo usa fin_pago_cargar y fin_v_pago_vendedores).
  if exists (select 1 from public.fin_personas x
              where x.vendedor_id = v_id and (x.cliente_id = p_cliente or x.cliente_id is null)) then
    update public.fin_personas set campo = 'ambos'
     where vendedor_id = v_id and cliente_id = p_cliente and campo = 'setter';
  else
    select x.id into v_pers_id from public.fin_personas x
     where x.cliente_id = p_cliente and lower(btrim(x.alias)) = lower(v_alias) and x.vendedor_id is null
     order by x.id limit 1;
    if v_pers_id is not null then
      -- alias huerfano con ese texto: se engancha al vendedor (sus pagos viejos pasan a atribuirse)
      update public.fin_personas set vendedor_id = v_id,
             campo = case when campo = 'setter' then 'ambos' else coalesce(campo, 'closer') end
       where id = v_pers_id;
    else
      insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
      values (null, p_cliente, v_alias, v_id, 'closer');
    end if;
  end if;

  return jsonb_build_object(
    'id', v_id,
    'nombre', (select v.nombre from public.fin_vendedores v where v.id = v_id),
    'nuevo', v_nuevo,
    'ya_asignado', v_ya,
    'reactivado', v_react);
end $$;

revoke all on function public.fin_closer_agregar(text, text, boolean) from public, anon;
grant execute on function public.fin_closer_agregar(text, text, boolean) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno, solo lectura; el editor muestra solo el ultimo resultado)
-- ---------------------------------------------------------------------
-- C1: la funcion existe y no es ejecutable por anon (esperado: existe = true, anon = false).
-- select to_regprocedure('public.fin_closer_agregar(text,text,boolean)') is not null as existe,
--        has_function_privilege('anon', 'public.fin_closer_agregar(text,text,boolean)', 'execute') as anon;
--
-- C2: despues de agregar un closer de prueba desde la app, aparece una sola vez y con alias
--     (reemplazar 'liam' y el nombre).
-- select v.id, v.nombre, v.es_persona, v.activo, a.cliente_id, a.es_closer, a.hasta, p.alias
--   from public.fin_vendedores v
--   join public.fin_vendedor_asignaciones a on a.vendedor_id = v.id
--   left join public.fin_personas p on p.vendedor_id = v.id and p.cliente_id = a.cliente_id
--  where a.cliente_id = 'liam' and v.nombre_norm = public.fin_normalizar_nombre('NOMBRE DE PRUEBA');
--
-- C3: sin duplicados por nombre normalizado (esperado: 0 filas; la unicidad ya la fuerza el indice).
-- select nombre_norm, count(*) from public.fin_vendedores group by 1 having count(*) > 1;
--
-- C4: closers sin alias en algun cliente donde estan asignados (informativo).
-- select v.nombre, a.cliente_id from public.fin_vendedor_asignaciones a
--   join public.fin_vendedores v on v.id = a.vendedor_id
--  where a.es_closer and a.hasta is null and not exists (
--        select 1 from public.fin_personas p where p.vendedor_id = v.id
--           and (p.cliente_id = a.cliente_id or p.cliente_id is null));

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (la funcion es nueva; no cambia datos existentes)
-- ---------------------------------------------------------------------
-- drop function if exists public.fin_closer_agregar(text, text, boolean);
-- Los closers ya creados desde la app quedan (son datos); para sacar uno de un cliente:
--   update public.fin_vendedor_asignaciones set hasta = current_date
--    where cliente_id = '<cliente>' and vendedor_id = <id>;
