-- 132_finanzas_estado_pagos_producto.sql  (numero asignado por el jefe)
-- Estado de pagos del alumno PARA PRODUCTO (CSM y consultores), SIN montos, con permiso por programa de Producto.
--
-- Decision de Joaquin: en Producto la CSM y los consultores ven el estado de pagos del alumno, nunca montos.
--
-- QUE HACE:
--   1. Refactor sin cambio de comportamiento: la logica de public.fin_cs_estado_pagos (129) pasa a una funcion
--      interna comun public.fin_cs_estado_pagos_base(p_cliente, p_cs_ids, p_montos) (sin chequeo de permiso;
--      solo service_role / postgres). fin_cs_estado_pagos conserva firma, columnas, permiso (fundador /
--      fin_ve_plata / service_role) y resultados: ahora solo verifica permiso y llama a la base.
--   2. Funcion nueva para Producto:
--        public.cs_estado_pagos_alumno(p_cs_ids uuid[])
--          returns table (cs_cliente_id uuid, programa_id text, vinculo text, nombres_finanzas int,
--                         cuotas_total int, cuotas_pagadas int, cuotas_pendientes int, cuotas_otras int,
--                         cuotas_atrasadas int, max_dias_atraso int, proximo_vencimiento date, ultimo_pago date)
--      - Una fila por ficha pedida que quien llama PUEDE ver: es_fundador() o cs_puede_ver(programa_id de la
--        ficha); sin sesion, solo service_role / postgres (ven todas). Las fichas que no puede ver NO aparecen
--        (ni se revela si existen). Maximo 500 ids por llamada. Para una sola ficha: array[<uuid>].
--      - vinculo = 'vinculado' (hay al menos un alumno de Finanzas vinculado a la ficha, 129) o 'sin_vinculo'.
--        Con 'sin_vinculo' todos los contadores y fechas vienen NULL: Producto debe tratarlo como
--        "sin dato de pagos", no como "al dia".
--      - NUNCA devuelve montos (la columna ni existe). Cuotas: solo fuentes activas, igual que la 129.
--      - Permisos: anon nada; authenticated solo EJECUTA esta funcion (y la 129 como antes); ninguna tabla nueva.
--
-- Requiere: 129 (fin_cs_vinculo, fin_cs_estado_pagos, fin_cs_exigir) y de Producto cs_puede_ver(text), cs_clientes.
-- Correr (no a :00/:15/:30/:45 ni a las 9:00). Re-ejecutable. Sin begin/commit: cada sentencia es atomica.

-- ---------------------------------------------------------------------
-- 0. Guardas
-- ---------------------------------------------------------------------
do $$
declare v_falta text := '';
begin
  if to_regclass('public.fin_cs_vinculo') is null then v_falta := v_falta || ' fin_cs_vinculo(129)'; end if;
  if to_regprocedure('public.fin_cs_estado_pagos(text, uuid[], boolean)') is null then v_falta := v_falta || ' fin_cs_estado_pagos(129)'; end if;
  if to_regprocedure('public.fin_cs_exigir(text, text)') is null then v_falta := v_falta || ' fin_cs_exigir(129)'; end if;
  if to_regprocedure('public.fin_cs_norm_nombre(text)') is null then v_falta := v_falta || ' fin_cs_norm_nombre(129)'; end if;
  if to_regprocedure('public.cs_puede_ver(text)') is null then v_falta := v_falta || ' cs_puede_ver(Producto)'; end if;
  if to_regprocedure('public.cs_hoy()') is null then v_falta := v_falta || ' cs_hoy(Producto)'; end if;
  if to_regclass('public.cs_clientes') is null then v_falta := v_falta || ' cs_clientes(Producto)'; end if;
  if v_falta <> '' then
    raise exception 'GUARDA 132: faltan:%. No se aplica nada (correr la 129 primero).', v_falta;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Base comun (la logica de la 129, tal cual, sin chequeo de permiso)
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_estado_pagos_base(
  p_cliente text, p_cs_ids uuid[] default null, p_montos boolean default false)
returns table (
  cs_cliente_id uuid, nombres_finanzas int,
  cuotas_total int, cuotas_pagadas int, cuotas_pendientes int, cuotas_otras int, cuotas_atrasadas int,
  max_dias_atraso int, proximo_vencimiento date, ultimo_pago date,
  monto_pagado numeric, monto_pendiente numeric, monto_atrasado numeric)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_hoy date := public.cs_hoy();
begin
  return query
  with v as (
    select vv.cs_cliente_id as cid, array_agg(vv.alumno_norm) as nombres
      from public.fin_cs_vinculo vv
     where vv.cliente_id = p_cliente and vv.estado = 'vinculado'
       and (p_cs_ids is null or vv.cs_cliente_id = any(p_cs_ids))
     group by vv.cs_cliente_id),
  cu as (
    select v.cid, q.fecha_pago, q.monto, q.monto_cobrado,
           case when lower(btrim(coalesce(q.estado, ''))) in ('pagado', 'pagada', 'cuota pagada') then 'pagada'
                when lower(btrim(coalesce(q.estado, ''))) in ('churn', 'pausado', 'cancelado') then 'otra'
                else 'pendiente' end as clase
      from v
      join public.fin_cuotas q
        on q.cliente_id = p_cliente and public.fin_cs_norm_nombre(q.alumno) = any(v.nombres)
      join public.fin_fuentes f on f.id = q.fuente_id and f.activo),
  cq as (
    select cu.cid,
           count(*)::int as total,
           (count(*) filter (where cu.clase = 'pagada'))::int as pagadas,
           (count(*) filter (where cu.clase = 'pendiente'))::int as pendientes,
           (count(*) filter (where cu.clase = 'otra'))::int as otras,
           (count(*) filter (where cu.clase = 'pendiente' and cu.fecha_pago < v_hoy))::int as atrasadas,
           max(v_hoy - cu.fecha_pago) filter (where cu.clase = 'pendiente' and cu.fecha_pago < v_hoy) as max_atraso,
           min(cu.fecha_pago) filter (where cu.clase = 'pendiente' and cu.fecha_pago >= v_hoy) as prox,
           sum(greatest(coalesce(cu.monto, 0) - coalesce(cu.monto_cobrado, 0), 0))
             filter (where cu.clase = 'pendiente') as m_pend,
           sum(greatest(coalesce(cu.monto, 0) - coalesce(cu.monto_cobrado, 0), 0))
             filter (where cu.clase = 'pendiente' and cu.fecha_pago < v_hoy) as m_atr
      from cu group by cu.cid),
  pg as (
    select v.cid,
           max(p.fecha) filter (where p.monto_usd > 0) as ult,
           sum(p.monto_usd) as neto
      from v
      join public.fin_pagos p
        on p.cliente_id = p_cliente and public.fin_cs_norm_nombre(p.alumno) = any(v.nombres)
     group by v.cid)
  select v.cid, cardinality(v.nombres),
         coalesce(cq.total, 0), coalesce(cq.pagadas, 0), coalesce(cq.pendientes, 0), coalesce(cq.otras, 0),
         coalesce(cq.atrasadas, 0), cq.max_atraso::int, cq.prox, pg.ult,
         case when p_montos then coalesce(pg.neto, 0) end,
         case when p_montos then coalesce(cq.m_pend, 0) end,
         case when p_montos then coalesce(cq.m_atr, 0) end
    from v
    left join cq on cq.cid = v.cid
    left join pg on pg.cid = v.cid
   order by v.cid;
end $$;

comment on function public.fin_cs_estado_pagos_base(text, uuid[], boolean) is
  '132: logica comun de fin_cs_estado_pagos y cs_estado_pagos_alumno. SIN chequeo de permiso: solo service_role / postgres.';

-- fin_cs_estado_pagos: misma firma, columnas y permiso que en la 129; ahora delega en la base.
create or replace function public.fin_cs_estado_pagos(
  p_cliente text, p_cs_ids uuid[] default null, p_montos boolean default false)
returns table (
  cs_cliente_id uuid, nombres_finanzas int,
  cuotas_total int, cuotas_pagadas int, cuotas_pendientes int, cuotas_otras int, cuotas_atrasadas int,
  max_dias_atraso int, proximo_vencimiento date, ultimo_pago date,
  monto_pagado numeric, monto_pendiente numeric, monto_atrasado numeric)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public.fin_cs_exigir(p_cliente, 'lectura');
  return query select * from public.fin_cs_estado_pagos_base(p_cliente, p_cs_ids, p_montos);
end $$;

-- ---------------------------------------------------------------------
-- 2. PARA PRODUCTO: estado de pagos por ficha, sin montos, permiso por programa de Producto
-- ---------------------------------------------------------------------
create or replace function public.cs_estado_pagos_alumno(p_cs_ids uuid[])
returns table (
  cs_cliente_id uuid, programa_id text, vinculo text, nombres_finanzas int,
  cuotas_total int, cuotas_pagadas int, cuotas_pendientes int, cuotas_otras int, cuotas_atrasadas int,
  max_dias_atraso int, proximo_vencimiento date, ultimo_pago date)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_srv  boolean := false;   -- sin sesion y service_role / postgres: ve todo
  v_prog text;
begin
  if auth.uid() is null then
    perform public.fin_cs_exigir(null, 'fundador');   -- sin sesion solo pasa service_role / postgres
    v_srv := true;
  end if;
  if p_cs_ids is null or cardinality(p_cs_ids) = 0 then
    return;
  end if;
  if cardinality(p_cs_ids) > 500 then
    raise exception 'cs: maximo 500 fichas por llamada' using errcode = '22023';
  end if;
  for v_prog in
    select distinct c.programa_id from public.cs_clientes c
     where c.id = any(p_cs_ids)
       and (v_srv or coalesce(public.es_fundador(), false) or coalesce(public.cs_puede_ver(c.programa_id), false))
     order by 1
  loop
    return query
    select c.id, c.programa_id,
           case when e.cs_cliente_id is null then 'sin_vinculo' else 'vinculado' end,
           e.nombres_finanzas, e.cuotas_total, e.cuotas_pagadas, e.cuotas_pendientes, e.cuotas_otras,
           e.cuotas_atrasadas, e.max_dias_atraso, e.proximo_vencimiento, e.ultimo_pago
      from public.cs_clientes c
      left join public.fin_cs_estado_pagos_base(v_prog, p_cs_ids, false) e on e.cs_cliente_id = c.id
     where c.programa_id = v_prog and c.id = any(p_cs_ids)
     order by c.id;
  end loop;
end $$;

comment on function public.cs_estado_pagos_alumno(uuid[]) is
  '132: estado de pagos por ficha de Producto, SIN montos. Solo fichas que el llamador puede ver (es_fundador o cs_puede_ver del programa); sin sesion, service_role/postgres. vinculo sin_vinculo = sin dato (contadores NULL).';

-- ---------------------------------------------------------------------
-- 3. Permisos
-- ---------------------------------------------------------------------
revoke all on function public.fin_cs_estado_pagos_base(text, uuid[], boolean) from public, anon, authenticated;
grant execute on function public.fin_cs_estado_pagos_base(text, uuid[], boolean) to service_role;

revoke all on function public.fin_cs_estado_pagos(text, uuid[], boolean) from public, anon;
grant execute on function public.fin_cs_estado_pagos(text, uuid[], boolean) to authenticated, service_role;

revoke all on function public.cs_estado_pagos_alumno(uuid[]) from public, anon;
grant execute on function public.cs_estado_pagos_alumno(uuid[]) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 4. Prueba de humo (se autorrevierte; no deja ningun dato)
--    Misma ficha que la del humo de la 129: telefono unico y SIN alumno de Finanzas coincidente
--    (pago_clave, telefono, nombre/alias ni vinculo previo), para que nombres_finanzas sea 1.
-- ---------------------------------------------------------------------
do $$
declare
  v_cs    record;
  v_fp    bigint;
  v_fc    bigint;
  v_fund  uuid;
  v_hoy   date := public.cs_hoy();
  v_r     record;
  v_n     int;
  v_m     record;
  v_esp   int;
  v_vistos int := 0;
begin
  begin
    select c.id, c.programa_id, c.telefono into v_cs
      from public.cs_clientes c
     where public.fin_cs_norm_tel(c.telefono) is not null
       and exists (select 1 from public.crm_clients k where k.id = c.programa_id)
       and (select count(*) from public.cs_clientes d
             where d.programa_id = c.programa_id
               and public.fin_cs_norm_tel(d.telefono) = public.fin_cs_norm_tel(c.telefono)) = 1
       and not exists (select 1 from public.fin_cs_vinculo vv where vv.cs_cliente_id = c.id)
       and not exists (select 1 from public.fin_pagos p
                        where p.cliente_id = c.programa_id
                          and ((c.pago_clave is not null and p.clave = c.pago_clave)
                            or public.fin_cs_norm_tel(p.telefono) = public.fin_cs_norm_tel(c.telefono)
                            or public.fin_cs_norm_nombre(p.alumno) in
                               (select n.nom from public.fin_cs_nombres(c.programa_id) n
                                 where n.cs_id = c.id and n.nom is not null)))
       and not exists (select 1 from public.fin_cuotas q
                        where q.cliente_id = c.programa_id
                          and (public.fin_cs_norm_tel(q.telefono) = public.fin_cs_norm_tel(c.telefono)
                            or public.fin_cs_norm_nombre(q.alumno) in
                               (select n.nom from public.fin_cs_nombres(c.programa_id) n
                                 where n.cs_id = c.id and n.nom is not null)))
     order by (c.programa_id = 'liam') desc, c.created_at
     limit 1;
    if not found then
      raise notice 'smoke 132: no hay ficha de Producto con telefono unico y sin alumno de Finanzas coincidente; se omite la parte con datos';
      raise exception 'SMOKE_OK';
    end if;

    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values (v_cs.programa_id, 'SMOKE_132', 1, 'Smoke', 'pagos', 10000) returning id into v_fp;
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, tope_monto)
    values (v_cs.programa_id, 'SMOKE_132', 2, 'Smoke', 'cuotas', 'cuotas_plano', 10000) returning id into v_fc;

    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, telefono, monto_usd, monto_origen, moneda_origen, concepto) values
      (v_cs.programa_id, v_fp, 1, v_hoy - 20, 'Zz Smoke 132', v_cs.telefono, 100, 100, 'USD', 'SMOKE'),
      (v_cs.programa_id, v_fp, 2, v_hoy - 5,  'ZZ  SMOKE 132', null,          50,  50,  'USD', 'SMOKE');
    insert into public.fin_cuotas (cliente_id, fuente_id, alumno, programa, numero_cuota, monto, monto_cobrado, fecha_pago, estado, fila_planilla) values
      (v_cs.programa_id, v_fc, 'Zz Smoke 132', 'Prog Z', 1, 100, 100, v_hoy - 30, 'Pagado',    1),
      (v_cs.programa_id, v_fc, 'Zz Smoke 132', 'Prog Z', 2, 100,  20, v_hoy - 10, 'Pendiente', 2),
      (v_cs.programa_id, v_fc, 'Zz Smoke 132', 'Prog Z', 3, 100,   0, v_hoy + 10, null,        3);

    -- sin vinculo todavia: la ficha aparece, con vinculo 'sin_vinculo' y contadores NULL (no "al dia")
    select * into v_r from public.cs_estado_pagos_alumno(array[v_cs.id]);
    if not found then raise exception 'smoke 132: la ficha no aparece (service_role/postgres)'; end if;
    if v_r.vinculo <> 'sin_vinculo' or v_r.cuotas_total is not null or v_r.ultimo_pago is not null then
      raise exception 'smoke 132: sin vinculo = %', to_jsonb(v_r);
    end if;

    -- vinculacion automatica (la de la 129) y estado
    select count(*) into v_n from public.fin_cs_vincular_auto(v_cs.programa_id);
    select * into v_r from public.cs_estado_pagos_alumno(array[v_cs.id]);
    if v_r.vinculo <> 'vinculado' or v_r.programa_id <> v_cs.programa_id or v_r.nombres_finanzas <> 1
       or v_r.cuotas_total <> 3 or v_r.cuotas_pagadas <> 1 or v_r.cuotas_pendientes <> 2 or v_r.cuotas_atrasadas <> 1
       or v_r.max_dias_atraso <> 10 or v_r.proximo_vencimiento <> v_hoy + 10 or v_r.ultimo_pago <> v_hoy - 5 then
      raise exception 'smoke 132: estado = %', to_jsonb(v_r);
    end if;

    -- nunca montos: ni columna (la funcion no tiene ninguna que empiece con monto)
    if exists (select 1 from jsonb_object_keys(to_jsonb(v_r)) k where k like 'monto%') then
      raise exception 'smoke 132: la funcion devuelve columnas de monto';
    end if;

    -- el refactor no cambio fin_cs_estado_pagos (mismas cifras, con y sin montos)
    select * into v_r from public.fin_cs_estado_pagos(v_cs.programa_id, array[v_cs.id]);
    if v_r.cuotas_total <> 3 or v_r.cuotas_pendientes <> 2 or v_r.max_dias_atraso <> 10 or v_r.monto_pagado is not null then
      raise exception 'smoke 132: fin_cs_estado_pagos (sin montos) = %', to_jsonb(v_r);
    end if;
    select * into v_r from public.fin_cs_estado_pagos(v_cs.programa_id, array[v_cs.id], true);
    if v_r.monto_pagado <> 150 or v_r.monto_pendiente <> 180 or v_r.monto_atrasado <> 80 then
      raise exception 'smoke 132: fin_cs_estado_pagos (montos) = %', to_jsonb(v_r);
    end if;

    -- arrays vacio / nulo: sin filas; id inexistente: sin filas
    select count(*) into v_n from public.cs_estado_pagos_alumno(null);
    if v_n <> 0 then raise exception 'smoke 132: array nulo devolvio filas'; end if;
    select count(*) into v_n from public.cs_estado_pagos_alumno(array[gen_random_uuid()]);
    if v_n <> 0 then raise exception 'smoke 132: ficha inexistente devolvio filas'; end if;

    -- con sesion de fundador: ve la ficha
    select m.user_id into v_fund from public.crm_members m where m.rol = 'fundador' limit 1;
    if v_fund is null then
      raise notice 'smoke 132: no hay fundador en crm_members; se omiten las pruebas con sesion';
    else
      perform set_config('request.jwt.claim.sub', v_fund::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_fund, 'role', 'authenticated')::text, true);
      select * into v_r from public.cs_estado_pagos_alumno(array[v_cs.id]);
      if not found or v_r.vinculo <> 'vinculado' then raise exception 'smoke 132: el fundador no ve la ficha'; end if;

      -- miembros no fundadores: ven la ficha si y solo si cs_puede_ver(programa) (hasta 15)
      for v_m in
        select m.user_id from public.crm_members m
         where m.rol <> 'fundador' and m.user_id is not null order by m.user_id limit 15
      loop
        perform set_config('request.jwt.claim.sub', v_m.user_id::text, true);
        perform set_config('request.jwt.claims', jsonb_build_object('sub', v_m.user_id, 'role', 'authenticated')::text, true);
        v_esp := case when coalesce(public.es_fundador(), false) or coalesce(public.cs_puede_ver(v_cs.programa_id), false)
                      then 1 else 0 end;
        select count(*) into v_n from public.cs_estado_pagos_alumno(array[v_cs.id]);
        if v_n <> v_esp then
          raise exception 'smoke 132: miembro % ve % filas y cs_puede_ver espera %', v_m.user_id, v_n, v_esp;
        end if;
        v_vistos := v_vistos + 1;
      end loop;
      raise notice 'smoke 132: % miembros no fundadores verificados contra cs_puede_ver', v_vistos;

      -- usuario sin permiso (no es miembro): sin filas, no revela la ficha
      perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      select count(*) into v_n from public.cs_estado_pagos_alumno(array[v_cs.id]);
      if v_n <> 0 then raise exception 'smoke 132: un usuario sin permiso vio la ficha'; end if;
    end if;

    -- permisos
    if has_function_privilege('anon', 'public.cs_estado_pagos_alumno(uuid[])', 'execute')
       or has_function_privilege('anon', 'public.fin_cs_estado_pagos(text, uuid[], boolean)', 'execute')
       or has_function_privilege('authenticated', 'public.fin_cs_estado_pagos_base(text, uuid[], boolean)', 'execute')
       or not has_function_privilege('authenticated', 'public.cs_estado_pagos_alumno(uuid[])', 'execute')
       or not has_function_privilege('service_role', 'public.cs_estado_pagos_alumno(uuid[])', 'execute') then
      raise exception 'smoke 132: permisos incorrectos';
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 132: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ===========================================================================
-- CONTROLES: correr DE A UNO (el editor muestra solo el ultimo resultado).
-- Como postgres no hay sesion (ve todo, como service_role). Para probar un usuario real, en la misma
-- ejecucion:  select set_config('request.jwt.claim.sub', '<uuid>', true);
-- ===========================================================================
-- C1. Permisos (esperado: anon_nueva false, anon_vieja false, auth_base false, auth_nueva true,
--     service_nueva true). La 132 no da ningun permiso de tabla.
--   select has_function_privilege('anon', 'public.cs_estado_pagos_alumno(uuid[])', 'execute') as anon_nueva,
--          has_function_privilege('anon', 'public.fin_cs_estado_pagos(text, uuid[], boolean)', 'execute') as anon_vieja,
--          has_function_privilege('authenticated', 'public.fin_cs_estado_pagos_base(text, uuid[], boolean)', 'execute') as auth_base,
--          has_function_privilege('authenticated', 'public.cs_estado_pagos_alumno(uuid[])', 'execute') as auth_nueva,
--          has_function_privilege('service_role', 'public.cs_estado_pagos_alumno(uuid[])', 'execute') as service_nueva;
--
-- C2. Sin montos: columnas que devuelve (esperado: ninguna empieza con monto).
--   select pg_get_function_result('public.cs_estado_pagos_alumno(uuid[])'::regprocedure) as columnas,
--          pg_get_function_result('public.cs_estado_pagos_alumno(uuid[])'::regprocedure) like '%monto%' as tiene_monto;
--
-- C3. Cobertura por programa (como postgres): fichas, con vinculo, sin vinculo. Esperado: con_vinculo =
--     fichas con al menos un alumno vinculado en fin_cs_vinculo (C3b).
--   select c.programa_id, count(*) as fichas,
--          count(*) filter (where e.vinculo = 'vinculado') as con_vinculo,
--          count(*) filter (where e.vinculo = 'sin_vinculo') as sin_vinculo,
--          sum(e.cuotas_atrasadas) as cuotas_atrasadas, max(e.max_dias_atraso) as max_dias_atraso
--     from public.cs_clientes c
--     cross join lateral public.cs_estado_pagos_alumno(array[c.id]) e
--    group by c.programa_id order by 1;
--   -- C3b (comparar): select cliente_id, count(distinct cs_cliente_id) from public.fin_cs_vinculo
--   --                  where estado = 'vinculado' group by 1 order by 1;
--
-- C4. Misma cifra que la funcion de Finanzas (esperado: 0 filas de diferencia). Reemplazar 'liam'.
--   select a.cs_cliente_id
--     from public.fin_cs_estado_pagos('liam') a
--     left join public.cs_estado_pagos_alumno(array(select id from public.cs_clientes where programa_id = 'liam')) b
--            on b.cs_cliente_id = a.cs_cliente_id
--    where b.cs_cliente_id is null
--       or (a.cuotas_total, a.cuotas_pagadas, a.cuotas_pendientes, a.cuotas_atrasadas, a.max_dias_atraso, a.proximo_vencimiento, a.ultimo_pago)
--          is distinct from
--          (b.cuotas_total, b.cuotas_pagadas, b.cuotas_pendientes, b.cuotas_atrasadas, b.max_dias_atraso, b.proximo_vencimiento, b.ultimo_pago);
--
-- C5. Como un consultor / CSM de Producto (reemplazar el uuid de un miembro con rol producto y cs_puede_ver
--     sobre liam). Esperado: filas = fichas de liam; con otro usuario sin acceso a liam: 0 filas.
--   select set_config('request.jwt.claim.sub', '<uuid del consultor>', true);   -- ejecutar junto con la de abajo
--   select count(*) as filas, count(*) filter (where vinculo = 'vinculado') as con_vinculo
--     from public.cs_estado_pagos_alumno(array(select id from public.cs_clientes where programa_id = 'liam'));
--
-- C6. Un usuario sin acceso a Producto (p. ej. cliente de otro programa): esperado 0 filas.
--   select set_config('request.jwt.claim.sub', '<uuid sin acceso>', true);
--   select count(*) from public.cs_estado_pagos_alumno(array(select id from public.cs_clientes limit 50));
--
-- ---------------------------------------------------------------------
-- VUELTA ATRAS (deja la 129 como estaba: fin_cs_estado_pagos con su cuerpo propio):
--   1. Volver a correr la seccion 9 (create or replace de fin_cs_estado_pagos) de la 129.
--   2. drop function if exists public.cs_estado_pagos_alumno(uuid[]);
--   3. drop function if exists public.fin_cs_estado_pagos_base(text, uuid[], boolean);
--   -- Orden: primero 1 (para que fin_cs_estado_pagos deje de depender de la base), despues 2 y 3.
--   -- Si Producto ya llama a cs_estado_pagos_alumno, fallara con "function does not exist".
