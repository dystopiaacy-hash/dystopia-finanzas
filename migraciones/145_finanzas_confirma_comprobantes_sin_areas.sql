-- 145_finanzas_confirma_comprobantes_sin_areas.sql
--
-- Decision de Joaquin (16/10): el rol finanzas confirma comprobantes tambien en agus y teo (clientes SIN permisos por area).
--
-- Que pasaba: fin_comp_puede_confirmar (143) YA incluye a finanzas asignado (crm_asignaciones) en cualquier cliente,
-- pero confirmar un comprobante = guardar el pago con fin_pago_cargar, que exige fin_puede_cargar (075). En un cliente sin
-- areas (agus, teo) fin_puede_cargar deja pasar a fundador, cliente y closer/setter vinculados en fin_personas, pero NO a
-- finanzas. Resultado: veia la bandeja y no podia cargar el pago.
--
-- Que cambia (UNA sola funcion): fin_puede_cargar suma, en clientes SIN areas, al rol finanzas asignado al cliente
-- (fin_asignado). Es la misma regla que ya tiene finanzas en un cliente por areas (liam). Todo lo demas de la funcion es
-- identico a la 075. No se toca fin_pago_cargar, fin_comp_*, fin_puede_anular, fin_ve_plata ni ninguna politica.
--
-- Efectos colaterales (no hay forma de abrir la carga del comprobante sin abrir el alta de pago, es la misma funcion):
--   * finanzas ve "Cargar pago" y puede dar de alta un pago a mano en agus/teo (no solo desde un comprobante).
--   * finanzas ve la grilla Pagos de agus/teo y puede completar columnas nuevas (fin_pago_extra_guardar, regla "sin areas").
--   * finanzas puede sumar opciones de concepto / metodo / quien recibe (fin_catalogo_agregar).
--   NO puede editar, anular ni devolver pagos (fin_puede_anular no cambia: en agus/teo sigue siendo fundador y cliente).
--   Lo que YA veia finanzas (fin_ve_plata) no cambia.
-- Closer, setter y cliente: fin_comp_puede_confirmar no cambia (solo fundador y finanzas asignado). Su permiso de cargar
-- pagos tampoco cambia (la guarda de abajo aborta si cambia para cualquiera que no sea finanzas asignado).
--
-- Otros requisitos que NO resuelve esta migracion (datos, no permisos):
--   * El usuario finanzas tiene que estar en crm_asignaciones con agus / teo (ver control C3).
--   * La planilla de Pagos del cliente tiene que estar cortada (fin_fuentes tipo 'pagos' con cortada_en): si no,
--     fin_pago_cargar dice "la carga en la app todavia no esta habilitada" (ver control C2, columna habilitada).
--
-- Depende de: 066/075 (fin_puede_cargar, fin_cliente_por_areas, fin_asignado), 143 (fin_comp_*).
-- Sin begin/commit (el SQL Editor pasa por un pooler): cada bloque `do` es atomico y re-ejecutable.
-- Correr (no a :00/:15/:30/:45 ni a las 9:00). Orden: este archivo entero (el 1.er bloque cambia la funcion y se
-- autoverifica; el 2.o es la prueba de humo, que se revierte) y despues los controles C1 a C5 de a uno.
-- No hace falta tocar el front ni redeployar nada.

-- ---------------------------------------------------------------------
-- 1. Cambio + guardas: foto del permiso de cargar de todos los usuarios x clientes, cambio, foto de nuevo.
--    Si cambia algo que no sea "finanzas asignado, cliente sin areas: de false a true", aborta y no queda nada.
-- ---------------------------------------------------------------------
do $m145$
declare
  v_def  text;
  r      record;
  v_ant  jsonb := '{}'::jsonb;
  v_des  jsonb := '{}'::jsonb;
  v_k    text;
  v_a    boolean;
  v_d    boolean;
  v_cam  int := 0;
  v_mal  text := '';
  v_n    int := 0;
begin
  -- Guarda 1: lo que hay que tener
  if to_regprocedure('public.fin_puede_cargar(text)') is null
     or to_regprocedure('public.fin_cliente_por_areas(text)') is null
     or to_regprocedure('public.fin_asignado(text)') is null
     or to_regprocedure('public.fin_comp_puede_confirmar(text)') is null then
    raise exception 'GUARDA 145: faltan fin_puede_cargar / fin_cliente_por_areas / fin_asignado (075) o fin_comp_puede_confirmar (143). No se aplica nada.';
  end if;
  -- Guarda 2: la funcion vigente tiene que ser la de la 075 (si alguien la cambio a mano, no la pisamos a ciegas)
  v_def := pg_get_functiondef('public.fin_puede_cargar(text)'::regprocedure);
  if position('fin_cliente_por_areas' in v_def) = 0 or position('fin_personas' in v_def) = 0 then
    raise exception 'GUARDA 145: fin_puede_cargar no tiene la forma de la 075. Revisar a mano antes de seguir. No se aplica nada.';
  end if;

  -- Foto ANTES
  for r in select m.user_id, m.rol, c.id as cliente
             from public.crm_members m cross join public.crm_clients c
            where m.user_id is not null and c.id <> 'mauro' loop
    perform set_config('request.jwt.claim.sub', r.user_id::text, true);
    v_ant := v_ant || jsonb_build_object(r.user_id::text || '|' || r.cliente, public.fin_puede_cargar(r.cliente));
    v_n := v_n + 1;
  end loop;

  -- CAMBIO
  execute $f$
    create or replace function public.fin_puede_cargar(p_cliente text)
    returns boolean
    language sql stable security definer set search_path = ''
    as $b$
      select auth.uid() is not null and (
        coalesce(public.es_fundador(), false)
        or case when public.fin_cliente_por_areas(p_cliente)
             then public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(p_cliente)
             else (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
                  or (public.rol_actual() = 'finanzas' and public.fin_asignado(p_cliente))
                  or exists (select 1 from public.fin_personas p
                              where p.user_id = auth.uid() and p.cliente_id = p_cliente)
           end
      );
    $b$
  $f$;

  -- Foto DESPUES y comparacion
  for r in select m.user_id, m.rol, c.id as cliente
             from public.crm_members m cross join public.crm_clients c
            where m.user_id is not null and c.id <> 'mauro' loop
    perform set_config('request.jwt.claim.sub', r.user_id::text, true);
    v_k := r.user_id::text || '|' || r.cliente;
    v_a := (v_ant ->> v_k)::boolean;
    v_d := public.fin_puede_cargar(r.cliente);
    if v_a is distinct from v_d then
      if r.rol = 'finanzas' and v_a = false and v_d = true
         and not public.fin_cliente_por_areas(r.cliente) and public.fin_asignado(r.cliente) then
        v_cam := v_cam + 1;
      else
        v_mal := v_mal || ' [' || r.rol || ' ' || r.cliente || ' ' || coalesce(v_a::text, 'null') || '->' || coalesce(v_d::text, 'null') || ']';
      end if;
    end if;
  end loop;

  -- Sin sesion: nunca puede
  perform set_config('request.jwt.claim.sub', '', true);
  if public.fin_puede_cargar('agus') or public.fin_puede_cargar('teo') or public.fin_puede_cargar('liam') then
    v_mal := v_mal || ' [sin sesion puede cargar]';
  end if;

  if v_mal <> '' then
    raise exception 'GUARDA 145: el cambio altero permisos que no debia:%. Se revierte todo.', v_mal;
  end if;
  raise notice 'M145 OK: % combinaciones usuario x cliente revisadas; % pasaron de no poder a poder cargar (todas finanzas asignado, cliente sin areas).', v_n, v_cam;
end $m145$;

-- ---------------------------------------------------------------------
-- 2. Prueba de humo (se revierte sola). Mira el NOTICE: tiene que decir "HUMO 145 OK".
--    a) finanzas asignado a un cliente sin areas: puede cargar y confirmar.
--    b) closer / setter / cliente (cualquiera asignado): NO confirman.
--    c) si hay un cliente sin areas con la planilla de pagos cortada y un finanzas asignado: ciclo completo
--       fin_pago_cargar + fin_comp_confirmar sobre un comprobante de prueba.
-- ---------------------------------------------------------------------
do $humo$
declare
  r        record;
  v_fin    uuid;
  v_cli    text;
  v_n_fin  int := 0;
  v_n_otro int := 0;
  v_comp   uuid := gen_random_uuid();
  v_prog   bigint; v_conc bigint; v_met bigint;
  v_res    jsonb;
  v_est    text;
  v_ciclo  boolean := false;
begin
  begin
    -- a) finanzas asignado, cliente sin areas
    for r in select m.user_id, a.cliente_id
               from public.crm_members m
               join public.crm_asignaciones a on a.user_id = m.user_id
               join public.crm_clients c on c.id = a.cliente_id and c.id <> 'mauro'
              where m.rol = 'finanzas' and not public.fin_cliente_por_areas(a.cliente_id) loop
      perform set_config('request.jwt.claim.sub', r.user_id::text, true);
      if not public.fin_puede_cargar(r.cliente_id) or not public.fin_comp_puede_confirmar(r.cliente_id) then
        raise exception 'HUMO 145 FALLA: finanzas asignado a % deberia poder cargar y confirmar', r.cliente_id;
      end if;
      v_n_fin := v_n_fin + 1;
      if v_fin is null and public.fin_carga_habilitada(r.cliente_id) then v_fin := r.user_id; v_cli := r.cliente_id; end if;
    end loop;

    -- b) closer, setter y cliente asignados: no confirman
    for r in select m.user_id, m.rol, a.cliente_id
               from public.crm_members m
               join public.crm_asignaciones a on a.user_id = m.user_id
              where m.rol in ('closer', 'setter', 'cliente') loop
      perform set_config('request.jwt.claim.sub', r.user_id::text, true);
      if public.fin_comp_puede_confirmar(r.cliente_id) then
        raise exception 'HUMO 145 FALLA: % no deberia confirmar en %', r.rol, r.cliente_id;
      end if;
      v_n_otro := v_n_otro + 1;
    end loop;

    -- c) ciclo completo, si hay con que
    if v_fin is not null then
      select id into v_prog from public.fin_catalogos where cliente_id = v_cli and dimension = 'programa' and activo order by orden, id limit 1;
      select id into v_conc from public.fin_catalogos where cliente_id = v_cli and dimension = 'concepto' and activo and valor <> 'REFUND' order by orden, id limit 1;
      select id into v_met  from public.fin_catalogos where cliente_id = v_cli and dimension = 'metodo_pago' and activo order by orden, id limit 1;
      if v_prog is not null and v_conc is not null and v_met is not null then
        perform set_config('request.jwt.claim.sub', v_fin::text, true);
        v_res := public.fin_pago_cargar(jsonb_build_object(
          'cliente_id', v_cli,
          'fecha', (now() at time zone 'America/Argentina/Buenos_Aires')::date,
          'alumno', 'Persona De Prueba Humo 145', 'monto_usd', 1.23,
          'programa_id', v_prog, 'concepto_id', v_conc, 'metodo_pago_id', v_met));
        if not coalesce((v_res ->> 'ok')::boolean, false) then raise exception 'HUMO 145 FALLA: fin_pago_cargar no devolvio ok'; end if;
        insert into public.fin_comprobantes (id, cliente_id, archivo_path, archivo_nombre, mime, bytes, subido_por, subido_rol)
        values (v_comp, v_cli, v_cli || '/' || v_comp::text || '.png', 'humo.png', 'image/png', 10, v_fin, 'finanzas');
        perform public.fin_comp_confirmar(v_comp, v_res ->> 'clave');
        select estado into v_est from public.fin_comprobantes where id = v_comp;
        if v_est <> 'confirmado' then raise exception 'HUMO 145 FALLA: el comprobante quedo en %', v_est; end if;
        v_ciclo := true;
      end if;
    end if;

    raise exception 'HUMO_145_OK';
  exception when others then
    if sqlerrm = 'HUMO_145_OK' then
      raise notice 'HUMO 145 OK (revertido): finanzas sin areas revisados=%, closer/setter/cliente que no confirman=%, ciclo completo=%',
        v_n_fin, v_n_otro, case when v_ciclo then 'si (' || v_cli || ')'
                                else 'omitido: ningun finanzas asignado a un cliente sin areas con la planilla de pagos cortada' end;
    else
      raise;
    end if;
  end;
end $humo$;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- ---------------------------------------------------------------------
-- C1. La funcion quedo con la regla nueva. Esperado: tiene_regla_finanzas = true.
--   select position('rol_actual() = ''finanzas'' and public.fin_asignado(p_cliente)' in
--                   regexp_replace(pg_get_functiondef('public.fin_puede_cargar(text)'::regprocedure), '\s+', ' ', 'g')) > 0 as tiene_regla_finanzas;
--
-- C2. Matriz por usuario y cliente (como postgres; set_config sirve dentro de la misma ejecucion).
--   Esperado: fundador carga y confirma todo; finanzas asignado carga y confirma en SUS clientes (agus/teo incluidos) y
--   en los demas no; closer, setter y cliente: confirma = false siempre. habilitada = false => fin_pago_cargar rechaza.
--   select m.nombre, m.rol, c.id as cliente,
--          (select set_config('request.jwt.claim.sub', m.user_id::text, true)) as _,
--          public.fin_puede_cargar(c.id) as carga, public.fin_comp_puede_confirmar(c.id) as confirma,
--          public.fin_carga_habilitada(c.id) as habilitada
--     from public.crm_members m cross join public.crm_clients c
--    where c.id <> 'mauro' and m.user_id is not null and m.rol in ('fundador', 'finanzas', 'closer', 'setter', 'cliente')
--    order by m.rol, m.nombre, c.id;
--
-- C3. Que clientes tiene asignados cada finanzas (si agus/teo no aparecen, no van a poder: falta la fila en crm_asignaciones).
--   select m.nombre, m.rol, string_agg(a.cliente_id, ', ' order by a.cliente_id) as clientes
--     from public.crm_members m left join public.crm_asignaciones a on a.user_id = m.user_id
--    where m.rol = 'finanzas' group by m.nombre, m.rol order by m.nombre;
--
-- C4. Planilla de pagos cortada por cliente (sin corte, "Cargar pago" dice "todavia no esta habilitada").
--   select c.id as cliente, public.fin_cliente_por_areas(c.id) as por_areas,
--          (select f.cortada_en from public.fin_fuentes f where f.cliente_id = c.id and f.tipo = 'pagos' order by f.id limit 1) as pagos_cortada_en
--     from public.crm_clients c where c.id <> 'mauro' order by c.orden;
--
-- C5. Nadie que no sea finanzas ganó permiso: cuantos usuarios no finanzas pueden cargar en agus (debe ser igual que antes de la 145:
--   fundador, cliente de agus y los vinculados en fin_personas).
--   select m.rol, count(*) filter (where (select set_config('request.jwt.claim.sub', m.user_id::text, true)) is not null
--                                    and public.fin_puede_cargar('agus')) as pueden_cargar_agus
--     from public.crm_members m where m.user_id is not null group by m.rol order by m.rol;
--
-- ---------------------------------------------------------------------
-- VUELTA ATRAS (no se corre salvo pedido): deja fin_puede_cargar como en la 075.
--   create or replace function public.fin_puede_cargar(p_cliente text)
--   returns boolean
--   language sql stable security definer set search_path = ''
--   as $$
--     select auth.uid() is not null and (
--       coalesce(public.es_fundador(), false)
--       or case when public.fin_cliente_por_areas(p_cliente)
--            then public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(p_cliente)
--            else (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
--                 or exists (select 1 from public.fin_personas p
--                             where p.user_id = auth.uid() and p.cliente_id = p_cliente)
--          end
--     );
--   $$;
