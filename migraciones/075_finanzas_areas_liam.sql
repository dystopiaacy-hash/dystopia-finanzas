-- =====================================================================
-- 075_finanzas_areas_liam.sql
-- FINANZAS: permisos por area para Liam (BPF), catalogos y pagos editables.
--
-- MECANISMO (el que ya existe, sin tablas de roles nuevas):
--   crm_members.rol          = el area del usuario. Valores nuevos: finanzas,
--                              ventas, producto, contenido (se suman al CHECK
--                              si existe; los viejos no cambian).
--   crm_asignaciones         = a que cliente pertenece (como siempre).
--   fin_clientes_areas (NEW) = interruptor por CLIENTE: los clientes que
--                              estan en esta tabla usan los permisos por area.
--                              Hoy solo liam. El resto no cambia en nada.
--
-- Usuarios (se crean a mano en Authentication, con Auto Confirm, ANTES):
--   fundador@agencia.dystopia  fundador            OPCIONAL: el fundador ya tiene usuario.
--                                                  Si no existe se saltea; si existe y ya es
--                                                  fundador no se toca.
--   cliente@liam.dystopia      cliente  + liam     solo lectura
--   finanzas@liam.dystopia     finanzas + liam     ve todo Finanzas, carga pagos
--   ventas@liam.dystopia       ventas   + liam     solo Cargar pago
--   producto@liam.dystopia     producto + liam     nada de plata
--   contenido@liam.dystopia    contenido + liam    nada de plata
--   Si algun usuario todavia no existe, se saltea (aviso) y se puede volver
--   a correr esta migracion cuando exista: es idempotente.
--
-- MARCA que deja la 075 (la 077 y la 081 detectan por esto que se corrio):
--   tabla public.fin_clientes_areas, funciones public.fin_asignado(text) y
--   public.fin_ve_plata(text), columna fin_pagos.importado_en, y el CHECK de
--   crm_members.rol con 'finanzas','ventas','producto','contenido' entre
--   comillas simples (forma ARRAY['finanzas'::text, ...]).
--   Todo va en UNA transaccion (begin ... commit): o queda todo o nada.
--
-- Que cambia en la base:
--   1. crm_members.rol admite los 4 roles nuevos.
--   2. fin_clientes_areas + fin_ve_plata(): el rol 'finanzas' lee lo mismo
--      que 'cliente' (misma lista de tablas y vistas), solo de sus clientes.
--   3. fin_puede_cargar / fin_puede_anular: en un cliente por areas
--      cargan fundador, finanzas y ventas; editan y anulan SOLO fundador.
--      En los demas clientes quedan EXACTAMENTE como estaban (066).
--   4. fin_pagos.importado_en: pagos pasados de planilla a app sin autor.
--   5. fin_pago_extra_guardar y fin_columnas_de siguen la misma regla.
--   6. Catalogos de liam: COMUNIDAD, 3RA CUOTA RENEWAL y los programas que
--      faltaban. fin_catalogo_agregar: alta de opciones de concepto, metodo
--      de pago y quien recibe desde Cargar pago.
--   7. fin_clientes_carga() devuelve ademas puede_extras.
--   8. fin_diag_permisos(): matriz de permisos por usuario (para controlar).
--
-- NO toca: fin_llamadas, fin_personas, lista de closers, politicas de
-- fin_catalogos (Ventas). NO corre SQL de datos de liam: eso es la 076.
-- NO correr a las :00/:15/:30/:45 (corre la sync).
-- =====================================================================

begin;
set local lock_timeout = '10s';
lock table public.crm_members, public.fin_pagos, public.fin_fuentes, public.fin_pnl, public.fin_pnl_saldos,
  public.fin_cuotas, public.fin_liquidaciones, public.fin_liquidacion_items, public.fin_vendedores,
  public.fin_vendedor_asignaciones, public.fin_pagos_anulados,
  public.fin_columnas, public.fin_pagos_extra, public.fin_catalogos, public.fin_catalogo_alias
  in access exclusive mode;

-- ---------------------------------------------------------------------
-- 0. Guardas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.fin_pago_editar(text,text,text)') is null
     or to_regprocedure('public.fin_pago_extra_guardar(text,text,text,jsonb)') is null
     or to_regprocedure('public.fin_columnas_de(text,text)') is null then
    raise exception 'GUARDA 075: falta la 072 (columnas y edicion de pagos). No se aplica nada.';
  end if;
  if to_regprocedure('public.fin_puede_cargar(text)') is null or to_regclass('public.fin_pagos_anulados') is null then
    raise exception 'GUARDA 075: falta la 066 (carga de pagos). No se aplica nada.';
  end if;
  if to_regclass('public.crm_asignaciones') is null or to_regprocedure('public.rol_actual()') is null
     or to_regprocedure('public.es_fundador()') is null or to_regprocedure('public.tiene_acceso(text)') is null then
    raise exception 'GUARDA 075: faltan crm_asignaciones / es_fundador / rol_actual / tiene_acceso. No se aplica nada.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. crm_members.rol: admitir los roles por area (mismo patron que la 001)
-- ---------------------------------------------------------------------
-- Se compara el CONJUNTO de valores, no el texto: Postgres devuelve el CHECK
-- como  rol = ANY ('{a,b}'::text[])  (forma de produccion) o como
-- rol = ANY (ARRAY['a'::text, 'b'::text]). Se aceptan las dos.
-- El CHECK nuevo se escribe en la forma ARRAY[...] a proposito: asi cada valor
-- queda entre comillas simples en pg_get_constraintdef y la guarda de la 077
-- (que busca '''finanzas''' etc.) lo reconoce.
do $$
declare
  r      record;
  v_txt  text;
  v_cur  text[];
  v_all  text[];
  v_resto text;
  v_def2 text;
  v_new  text[] := array['finanzas', 'ventas', 'producto', 'contenido'];
begin
  for r in
    select conname, pg_get_constraintdef(oid) as def
    from pg_constraint
    where conrelid = 'public.crm_members'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ~* '\mrol\M\s*=\s*ANY'
  loop
    -- Forma: sacando literales, casts y parentesis solo debe quedar CHECK rol = ANY.
    v_resto := regexp_replace(r.def,
      '''[^'']*''|::(text|character varying|varchar)(\[\])?|ARRAY|[][(),\s]', '', 'gi');
    if upper(v_resto) <> 'CHECKROL=ANY' then
      raise exception 'GUARDA 075: crm_members tiene un CHECK sobre rol con forma no esperada (%: %). Revisar a mano.', r.conname, r.def;
    end if;

    -- Valores permitidos, en cualquiera de las dos formas.
    v_txt := substring(r.def from '''\{([^}]*)\}''');
    if v_txt is not null then
      select array_agg(distinct v order by v) into v_cur
      from (select btrim(btrim(x), '"') as v from unnest(string_to_array(v_txt, ',')) as x) q
      where v <> '';
    else
      select array_agg(distinct m[1] order by m[1]) into v_cur
      from regexp_matches(r.def, '''([^'']+)''', 'g') as m;
    end if;
    if v_cur is null or cardinality(v_cur) = 0 then
      raise exception 'GUARDA 075: no pude leer los valores del CHECK de crm_members (%: %). Revisar a mano.', r.conname, r.def;
    end if;

    -- Ya tiene los 4 nuevos y ya esta en la forma que lee la 077: nada que hacer.
    if v_cur @> v_new
       and r.def ~ '''finanzas''' and r.def ~ '''ventas''' and r.def ~ '''producto''' and r.def ~ '''contenido''' then
      raise notice 'CHECK % ya admite los roles por area: %', r.conname, v_cur;
      continue;
    end if;

    -- Se suman los 4 nuevos sin sacar ninguno de los actuales.
    select array_agg(distinct x order by x) into v_all from unnest(v_cur || v_new) as x;
    execute format('alter table public.crm_members drop constraint %I', r.conname);
    execute format('alter table public.crm_members add constraint %I check (rol = any (array[%s]::text[]))',
                   r.conname, (select string_agg(quote_literal(x), ', ' order by x) from unnest(v_all) as x));

    -- Control: el CHECK nuevo tiene todos los valores (viejos y nuevos) y se lee entre comillas.
    select pg_get_constraintdef(oid) into v_def2 from pg_constraint
     where conrelid = 'public.crm_members'::regclass and conname = r.conname;
    if (select bool_and(v_def2 like '%''' || x || '''%') from unnest(v_all) as x) is not true then
      raise exception 'GUARDA 075: el CHECK % no quedo con los valores esperados: %. Se revierte todo.', r.conname, v_def2;
    end if;
    raise notice 'CHECK % extendido: % -> %', r.conname, v_cur, v_all;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2. Interruptor por cliente y ayudantes de permiso
-- ---------------------------------------------------------------------
create table if not exists public.fin_clientes_areas (
  cliente_id  text primary key references public.crm_clients(id),
  activado_en timestamptz not null default now()
);
comment on table public.fin_clientes_areas is
  '075: clientes con permisos por area (rol finanzas/ventas/...). Fuera de esta tabla, los permisos son los de la 066.';

alter table public.fin_clientes_areas enable row level security;
drop policy if exists fin_clientes_areas_lectura on public.fin_clientes_areas;
create policy fin_clientes_areas_lectura on public.fin_clientes_areas for select to authenticated
  using (public.es_fundador());
revoke all on public.fin_clientes_areas from anon, authenticated;
grant select on public.fin_clientes_areas to authenticated;
grant all on public.fin_clientes_areas to service_role;

insert into public.fin_clientes_areas (cliente_id)
select 'liam' where exists (select 1 from public.crm_clients where id = 'liam')
on conflict (cliente_id) do nothing;

-- El cliente usa permisos por area.
create or replace function public.fin_cliente_por_areas(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.fin_clientes_areas a where a.cliente_id = p_cliente);
$$;

-- El usuario tiene ese cliente en crm_asignaciones.
create or replace function public.fin_asignado(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.crm_asignaciones a where a.user_id = auth.uid() and a.cliente_id = p_cliente);
$$;

-- Lectura de la plata del cliente: fundador, cliente (como siempre) y finanzas.
create or replace function public.fin_ve_plata(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce(public.es_fundador(), false)
      or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
      or (public.rol_actual() = 'finanzas' and public.fin_asignado(p_cliente));
$$;

-- Cargar un pago.
--   Cliente por areas: fundador, finanzas y ventas (asignados al cliente).
--   Resto: igual que la 066 (fundador, cliente, closer/setter vinculados).
create or replace function public.fin_puede_cargar(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and (
    coalesce(public.es_fundador(), false)
    or case when public.fin_cliente_por_areas(p_cliente)
         then public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(p_cliente)
         else (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
              or exists (select 1 from public.fin_personas p
                          where p.user_id = auth.uid() and p.cliente_id = p_cliente)
       end
  );
$$;

-- Editar, anular y devolver.
--   Cliente por areas: SOLO fundador. Resto: fundador y cliente (066).
create or replace function public.fin_puede_anular(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and (
    coalesce(public.es_fundador(), false)
    or (not public.fin_cliente_por_areas(p_cliente)
        and public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
  );
$$;

-- Para la pantalla: clientes donde el usuario puede cargar y que puede hacer.
drop function if exists public.fin_clientes_carga();
create function public.fin_clientes_carga()
returns table (cliente_id text, habilitada boolean, puede_anular boolean, puede_extras boolean)
language sql stable security definer set search_path = ''
as $$
  select c.id,
         public.fin_carga_habilitada(c.id),
         public.fin_puede_anular(c.id),
         (public.fin_puede_anular(c.id) or not public.fin_cliente_por_areas(c.id))
  from public.crm_clients c
  where c.id <> 'mauro' and public.fin_puede_cargar(c.id)
  order by c.orden;
$$;

-- Clientes con permisos por area (la app decide que pantallas ofrecer).
create or replace function public.fin_clientes_por_areas()
returns setof text
language sql stable security definer set search_path = ''
as $$
  select a.cliente_id from public.fin_clientes_areas a where auth.uid() is not null;
$$;

-- ---------------------------------------------------------------------
-- 3. Lectura: finanzas ve lo mismo que cliente (solo de sus clientes)
--    Mismas politicas que la 001 y la 024, cambiando solo la rama cliente.
--    (fin_fuentes_mapa, fin_llamadas y fin_catalogos son de Ventas: no se tocan.)
-- ---------------------------------------------------------------------
drop policy if exists fin_pnl_lectura on public.fin_pnl;
create policy fin_pnl_lectura on public.fin_pnl
  for select to authenticated using (public.fin_ve_plata(cliente_id));

drop policy if exists fin_pnl_saldos_lectura on public.fin_pnl_saldos;
create policy fin_pnl_saldos_lectura on public.fin_pnl_saldos
  for select to authenticated using (public.fin_ve_plata(cliente_id));

drop policy if exists fin_pagos_lectura on public.fin_pagos;
create policy fin_pagos_lectura on public.fin_pagos
  for select using (
    public.fin_ve_plata(cliente_id)
    or (public.rol_actual() = 'closer' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_pagos.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.closer))))
    or (public.rol_actual() = 'setter' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('setter', 'ambos')
            and p.cliente_id = fin_pagos.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.setter))))
  );

drop policy if exists fin_cuotas_lectura on public.fin_cuotas;
create policy fin_cuotas_lectura on public.fin_cuotas
  for select using (
    public.fin_ve_plata(cliente_id)
    or (public.rol_actual() = 'closer' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_cuotas.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_cuotas.closer))))
  );

drop policy if exists fin_liq_lectura on public.fin_liquidaciones;
create policy fin_liq_lectura on public.fin_liquidaciones
  for select using (public.fin_ve_plata(cliente_id));

drop policy if exists fin_liq_items_lectura on public.fin_liquidacion_items;
create policy fin_liq_items_lectura on public.fin_liquidacion_items
  for select using (
    public.es_fundador()
    or exists (
      select 1 from public.fin_liquidaciones l
      where l.id = fin_liquidacion_items.liquidacion_id
        and public.fin_ve_plata(l.cliente_id))
  );

drop policy if exists fin_asignaciones_lectura on public.fin_vendedor_asignaciones;
create policy fin_asignaciones_lectura on public.fin_vendedor_asignaciones
  for select using (public.fin_ve_plata(cliente_id));

drop policy if exists fin_vendedores_lectura on public.fin_vendedores;
create policy fin_vendedores_lectura on public.fin_vendedores
  for select using (
    public.es_fundador()
    or exists (
      select 1 from public.fin_vendedor_asignaciones a
      where a.vendedor_id = fin_vendedores.id
        and public.fin_ve_plata(a.cliente_id))
  );

drop policy if exists fin_pagos_anulados_lectura on public.fin_pagos_anulados;
create policy fin_pagos_anulados_lectura on public.fin_pagos_anulados for select
  using (public.fin_ve_plata(cliente_id));

drop policy if exists fin_columnas_lectura on public.fin_columnas;
create policy fin_columnas_lectura on public.fin_columnas for select to authenticated
  using (cliente_id is null or public.es_fundador() or public.tiene_acceso(cliente_id)
         or public.fin_ve_plata(cliente_id)
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = fin_columnas.cliente_id));

drop policy if exists fin_pagos_extra_lectura on public.fin_pagos_extra;
create policy fin_pagos_extra_lectura on public.fin_pagos_extra for select to authenticated
  using (public.es_fundador() or public.tiene_acceso(cliente_id) or public.fin_ve_plata(cliente_id)
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = fin_pagos_extra.cliente_id));

-- Vistas con filtro de rol propio (003 y 063): se leen de la base y solo
-- se cambia la comparacion de rol. Si no tienen la forma esperada, aborta.
do $$
declare
  v text;
  w text;
begin
  foreach v in array array['fin_v_pnl_mensual', 'fin_v_conciliacion']
  loop
    w := pg_get_viewdef(('public.' || v)::regclass, true);
    if w like '%''finanzas''%' then
      continue;
    end if;
    -- pg_get_viewdef puede devolver rol_actual() o public.rol_actual(), con o sin ::text.
    if w !~ '(public\.)?rol_actual\(\)\s*=\s*''cliente''(::text)?' then
      raise exception 'GUARDA 075: la vista % no tiene el filtro de rol esperado. No se aplica nada.', v;
    end if;
    w := regexp_replace(w, '(public\.)?rol_actual\(\)\s*=\s*''cliente''(::text)?',
                        'public.rol_actual() = ANY (ARRAY[''cliente''::text, ''finanzas''::text])', 'g');
    w := regexp_replace(w, ';\s*$', '');
    execute format('create or replace view public.%I with (security_invoker = true) as %s', v, w);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Pagos pasados de planilla a app (076): sin autor
-- ---------------------------------------------------------------------
alter table public.fin_pagos add column if not exists importado_en timestamptz;
comment on column public.fin_pagos.importado_en is
  '075: pago que vino de la planilla y paso a vivir en la app (corte del cliente). No tiene creado_por.';

alter table public.fin_pagos drop constraint if exists fin_pagos_app_ck;
alter table public.fin_pagos add constraint fin_pagos_app_ck
  check (origen = 'sheet' or importado_en is not null or (creado_por is not null and creado_en is not null));

-- ---------------------------------------------------------------------
-- 5. Funciones de la 072 con la regla por areas
-- ---------------------------------------------------------------------
-- Valores de columnas nuevas: en un cliente por areas solo fundador, o quien
-- cargo el pago hace menos de 15 minutos (para completar la carga).
create or replace function public.fin_pago_extra_guardar(p_cliente text, p_clave_pago text, p_columna text, p_valor jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col public.fin_columnas%rowtype;
  v jsonb := p_valor;
begin
  if not (case when public.fin_cliente_por_areas(p_cliente)
               then public.fin_puede_anular(p_cliente)
                    or (public.fin_puede_cargar(p_cliente) and exists (
                          select 1 from public.fin_pagos x
                           where x.cliente_id = p_cliente and x.clave = p_clave_pago
                             and x.creado_por = auth.uid() and x.creado_en > now() - interval '15 minutes'))
               else public.fin_puede_cargar(p_cliente) end) then
    raise exception 'fin: no tenes acceso a los pagos de %', p_cliente using errcode = '42501';
  end if;
  if not exists (select 1 from public.fin_pagos where cliente_id = p_cliente and clave = p_clave_pago) then
    raise exception 'fin: el pago no existe (puede haber cambiado en la planilla)' using errcode = 'P0002';
  end if;
  select * into v_col from public.fin_columnas
   where cliente_id = p_cliente and vista = 'pagos' and clave = p_columna and not sistema and not archivada;
  if not found then
    raise exception 'fin: la columna % no existe para %', p_columna, p_cliente using errcode = 'P0002';
  end if;

  if v is not null and (jsonb_typeof(v) = 'null'
       or (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '')) then
    v := null;
  end if;

  if v is not null then
    case v_col.tipo
      when 'texto' then
        if jsonb_typeof(v) <> 'string' or char_length(v #>> '{}') > 2000 then
          raise exception 'fin: % espera texto (hasta 2000)', v_col.etiqueta using errcode = '22023';
        end if;
        v := to_jsonb(btrim(v #>> '{}'));
      when 'numero' then
        if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^\s*-?\d+([.,]\d+)?\s*$' then
          v := to_jsonb(replace(btrim(v #>> '{}'), ',', '.')::numeric);
        end if;
        if jsonb_typeof(v) <> 'number' then
          raise exception 'fin: % espera un numero', v_col.etiqueta using errcode = '22023';
        end if;
      when 'fecha' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception 'fin: % espera una fecha (AAAA-MM-DD)', v_col.etiqueta using errcode = '22023';
        end if;
        perform (v #>> '{}')::date;
      when 'casilla' then
        if jsonb_typeof(v) <> 'boolean' then
          raise exception 'fin: % espera si o no', v_col.etiqueta using errcode = '22023';
        end if;
      when 'opcion' then
        if jsonb_typeof(v) <> 'string' or not (v_col.opciones ? (v #>> '{}')) then
          raise exception 'fin: "%" no es una opcion de %', v #>> '{}', v_col.etiqueta using errcode = '22023';
        end if;
      when 'link' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~* '^https?://\S+$' or char_length(v #>> '{}') > 1000 then
          raise exception 'fin: % espera un link que empiece con http', v_col.etiqueta using errcode = '22023';
        end if;
    end case;
  end if;

  insert into public.fin_pagos_extra (cliente_id, clave, valores, actualizado_por)
  values (p_cliente, p_clave_pago, case when v is null then '{}'::jsonb else jsonb_build_object(p_columna, v) end, auth.uid())
  on conflict (cliente_id, clave) do update
    set valores = case when v is null then fin_pagos_extra.valores - p_columna
                       else jsonb_set(fin_pagos_extra.valores, array[p_columna], v) end,
        actualizado_en = now(), actualizado_por = auth.uid();
  return v;
end;
$fn$;

-- Configuracion de columnas: la lee quien ve o carga pagos del cliente.
create or replace function public.fin_columnas_de(p_cliente text, p_vista text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with sis as (
    select s.clave, s.pos
    from unnest(public.fin_columnas_sistema(p_vista)) with ordinality as s(clave, pos)
  ),
  guardadas as (
    select * from public.fin_columnas c
    where c.vista = p_vista
      and coalesce(c.cliente_id, '*') = case when p_vista in ('resumen', 'conciliacion') then '*' else p_cliente end
  ),
  todas as (
    select s.clave, true as sistema, g.etiqueta,
           coalesce(g.orden, s.pos * 10) as orden,
           coalesce(g.visible, not (s.clave = any (public.fin_columnas_ocultas_por_defecto(p_vista)))) as visible,
           null::text as tipo, '[]'::jsonb as opciones, false as archivada
    from sis s left join guardadas g on g.clave = s.clave and g.sistema
    union all
    select g.clave, false, g.etiqueta, coalesce(g.orden, 100000), g.visible, g.tipo, g.opciones, g.archivada
    from guardadas g where not g.sistema
      and (not g.archivada or public.es_fundador())
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'clave', clave, 'sistema', sistema, 'etiqueta', etiqueta, 'orden', orden,
           'visible', visible, 'tipo', tipo, 'opciones', opciones, 'archivada', archivada)
         order by orden, clave), '[]'::jsonb)
  from todas
  where public.fin_columnas_sistema(p_vista) is not null
    and (p_vista in ('resumen', 'conciliacion') or public.es_fundador() or public.tiene_acceso(p_cliente)
         or public.fin_ve_plata(p_cliente) or public.fin_puede_cargar(p_cliente)
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = p_cliente));
$$;

-- ---------------------------------------------------------------------
-- 6. Catalogos de liam (programa, concepto, metodo de pago, quien recibe)
--    Los tres catalogos ya existen separados (064). Se suma lo que faltaba:
--    COMUNIDAD y 3RA CUOTA RENEWAL (conceptos) y los programas que estan en
--    la planilla sin valor de catalogo. REFUERZA FEE, CUOTA RENOVACION y
--    COMPLETA FEE ya estaban en liam.
-- ---------------------------------------------------------------------
insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
select s.cliente_id, s.dimension, s.valor, s.orden
from (values
  ('liam', 'concepto', '3RA CUOTA RENEWAL', 12),
  ('liam', 'concepto', 'COMUNIDAD', 13),
  ('liam', 'programa', 'BPF 1 A 1', 20),
  ('liam', 'programa', 'BPF 1 AÑO', 21),
  ('liam', 'programa', '1 a 1 Blueprint Financiero', 22)
) s(cliente_id, dimension, valor, orden)
where exists (select 1 from public.crm_clients where id = s.cliente_id)
on conflict (cliente_id, dimension, valor) do nothing;

insert into public.fin_catalogo_alias (cliente_id, columna, crudo_norm, dimension, catalogo_id, aprobado)
select s.cliente_id, s.columna, public.fin_normalizar_alias(s.valor), s.dimension, c.id, true
from (values
  ('liam', 'concepto', 'concepto', '3RA CUOTA RENEWAL'),
  ('liam', 'concepto', 'concepto', 'COMUNIDAD'),
  ('liam', 'programa', 'programa', 'BPF 1 A 1'),
  ('liam', 'programa', 'programa', 'BPF 1 AÑO'),
  ('liam', 'programa', 'programa', '1 a 1 Blueprint Financiero')
) s(cliente_id, columna, dimension, valor)
join public.fin_catalogos c
  on c.cliente_id = s.cliente_id and c.dimension = s.dimension and c.valor = s.valor
on conflict (cliente_id, columna, crudo_norm, dimension) do nothing;

-- Completa los *_id de los pagos de liam que ya estaban cargados.
update public.fin_pagos p set
  programa_id     = coalesce(p.programa_id,
                      public.fin_resolver_alias(p.cliente_id, 'programa', 'programa', p.programa)),
  concepto_id     = coalesce(p.concepto_id,
                      public.fin_resolver_alias(p.cliente_id, 'concepto', 'concepto', p.concepto)),
  metodo_pago_id  = coalesce(p.metodo_pago_id,
                      public.fin_resolver_alias(p.cliente_id, 'metodo_pago', 'metodo_pago', p.metodo_pago)),
  quien_recibe_id = coalesce(p.quien_recibe_id,
                      public.fin_resolver_alias(p.cliente_id, 'quien_recibe', 'quien_recibe', p.quien_recibe),
                      public.fin_resolver_alias(p.cliente_id, 'metodo_pago', 'quien_recibe', p.metodo_pago))
where p.cliente_id = 'liam'
  and (p.programa_id is null or p.concepto_id is null or p.metodo_pago_id is null or p.quien_recibe_id is null);

-- Alta de una opcion nueva desde Cargar pago. No cambia politicas de
-- fin_catalogos: la valida esta funcion. Solo estas tres listas.
create or replace function public.fin_catalogo_agregar(p_cliente text, p_dimension text, p_valor text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_valor text := regexp_replace(btrim(coalesce(p_valor, '')), '\s+', ' ', 'g');
  v_id    bigint;
  v_orden int;
begin
  if p_dimension is null or p_dimension not in ('concepto', 'metodo_pago', 'quien_recibe') then
    raise exception 'fin: solo se agregan opciones de concepto, metodo de pago y quien recibe' using errcode = '22023';
  end if;
  if p_cliente is null or not public.fin_puede_cargar(p_cliente) then
    raise exception 'fin: no tenes permiso para agregar opciones de %', p_cliente using errcode = '42501';
  end if;
  if char_length(v_valor) < 2 or char_length(v_valor) > 60 then
    raise exception 'fin: la opcion tiene que tener entre 2 y 60 caracteres' using errcode = '22023';
  end if;

  select id into v_id from public.fin_catalogos
   where cliente_id = p_cliente and dimension = p_dimension and lower(valor) = lower(v_valor)
   order by id limit 1;
  if v_id is not null then
    update public.fin_catalogos set activo = true where id = v_id and not activo;
    return jsonb_build_object('id', v_id, 'valor', v_valor, 'nuevo', false);
  end if;

  select coalesce(max(orden), 0) + 1 into v_orden from public.fin_catalogos
   where cliente_id = p_cliente and dimension = p_dimension;
  insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
  values (p_cliente, p_dimension, v_valor, v_orden)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'valor', v_valor, 'nuevo', true);
end $$;

-- ---------------------------------------------------------------------
-- 7. Usuarios: rol y cliente (busca por mail; si no existe, avisa y sigue)
-- ---------------------------------------------------------------------
do $$
declare
  r     record;
  v_uid uuid;
  n_ok  int := 0;
begin
  for r in
    select * from (values
      ('fundador@agencia.dystopia',  'fundador',  null::text, 'Fundadores'),
      ('cliente@liam.dystopia',      'cliente',   'liam',     'Liam'),
      ('finanzas@liam.dystopia',     'finanzas',  'liam',     'Finanzas BPF'),
      ('ventas@liam.dystopia',       'ventas',    'liam',     'Ventas BPF'),
      ('producto@liam.dystopia',     'producto',  'liam',     'Producto BPF'),
      ('contenido@liam.dystopia',    'contenido', 'liam',     'Contenido BPF')
    ) v(email, rol, cliente, nombre)
  loop
    select id into v_uid from auth.users where lower(email) = r.email limit 1;
    if v_uid is null then
      raise notice '075: el usuario % no existe en Authentication. Se saltea (si hace falta, crearlo y volver a correr la 075).', r.email;
      continue;
    end if;
    -- Un fundador existente no se toca (ni rol, ni nombre, ni asignaciones).
    if exists (select 1 from public.crm_members m where m.user_id = v_uid and m.rol = 'fundador') then
      raise notice '075: % ya es fundador. No se toca.', r.email;
      continue;
    end if;
    insert into public.crm_members (user_id, rol, nombre)
    values (v_uid, r.rol, r.nombre)
    on conflict (user_id) do update set rol = excluded.rol, nombre = excluded.nombre;
    if r.cliente is not null then
      insert into public.crm_asignaciones (user_id, cliente_id)
      select v_uid, r.cliente
       where not exists (select 1 from public.crm_asignaciones a
                          where a.user_id = v_uid and a.cliente_id = r.cliente);
    end if;
    n_ok := n_ok + 1;
  end loop;
  raise notice '075: % usuarios vinculados (fundador@agencia.dystopia es opcional: el fundador ya tiene su usuario)', n_ok;
end $$;

-- ---------------------------------------------------------------------
-- 8. Diagnostico: matriz de permisos por usuario (solo para controlar)
-- ---------------------------------------------------------------------
create or replace function public.fin_diag_permisos(p_cliente text default 'liam')
returns table (email text, rol text, ve_plata boolean, puede_cargar boolean, puede_editar boolean)
language plpgsql security definer set search_path = ''
as $$
declare r record;
begin
  for r in
    select u.id, u.email::text as email, m.rol
      from auth.users u
      left join public.crm_members m on m.user_id = u.id
     where u.email like '%@liam.dystopia' or u.email like '%@agencia.dystopia'
     order by u.email
  loop
    perform set_config('request.jwt.claim.sub', r.id::text, true);
    email := r.email;
    rol := r.rol;
    ve_plata := public.fin_ve_plata(p_cliente);
    puede_cargar := public.fin_puede_cargar(p_cliente);
    puede_editar := public.fin_puede_anular(p_cliente);
    return next;
  end loop;
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- ---------------------------------------------------------------------
-- 9. Permisos de ejecucion
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.fin_puede_cargar(text)', 'public.fin_puede_anular(text)', 'public.fin_clientes_carga()',
    'public.fin_clientes_por_areas()', 'public.fin_catalogo_agregar(text,text,text)',
    'public.fin_pago_extra_guardar(text,text,text,jsonb)', 'public.fin_columnas_de(text,text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  foreach f in array array['public.fin_cliente_por_areas(text)', 'public.fin_asignado(text)', 'public.fin_ve_plata(text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  revoke all on function public.fin_diag_permisos(text) from public, anon, authenticated;
  grant execute on function public.fin_diag_permisos(text) to service_role;
end $$;

commit;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- =====================================================================

-- C1. Usuarios vinculados. Esperado: cliente/finanzas/ventas/producto/contenido @liam.dystopia con su rol
--     y cliente liam; los usuarios del fundador siguen como estaban (fundador@agencia.dystopia es opcional).
--     Si falta alguno de @liam.dystopia, crearlo en Authentication y volver a correr la 075.
-- select u.email, m.rol, (select string_agg(a.cliente_id, ',') from public.crm_asignaciones a where a.user_id = u.id) as clientes
--   from auth.users u left join public.crm_members m on m.user_id = u.id
--  where u.email like '%@liam.dystopia' or u.email like '%@agencia.dystopia' order by 1;

-- C2. Matriz de permisos sobre liam. Esperado:
--     fundador  : ve_plata t, puede_cargar t, puede_editar t
--     cliente   : ve_plata t, puede_cargar f, puede_editar f
--     finanzas  : ve_plata t, puede_cargar t, puede_editar f
--     ventas    : ve_plata f, puede_cargar t, puede_editar f
--     producto  : ve_plata f, puede_cargar f, puede_editar f
--     contenido : ve_plata f, puede_cargar f, puede_editar f
-- select * from public.fin_diag_permisos('liam');

-- C3. Los otros clientes siguen igual: el interruptor solo tiene a liam. Esperado: 1 fila (liam).
-- select * from public.fin_clientes_areas;

-- C4. Las politicas nuevas quedaron. Esperado: 10 filas con true.
-- select policyname, qual like '%fin_ve_plata%' as ok
--   from pg_policies
--  where schemaname = 'public'
--    and policyname in ('fin_pnl_lectura', 'fin_pnl_saldos_lectura', 'fin_pagos_lectura', 'fin_cuotas_lectura',
--                       'fin_liq_lectura', 'fin_liq_items_lectura', 'fin_asignaciones_lectura',
--                       'fin_pagos_anulados_lectura', 'fin_vendedores_lectura', 'fin_columnas_lectura');

-- C5. Las dos vistas dejaron pasar a finanzas. Esperado: 2 filas con true.
-- select c.relname, pg_get_viewdef(c.oid) like '%finanzas%' as ok
--   from pg_class c where c.relname in ('fin_v_pnl_mensual', 'fin_v_conciliacion') and c.relkind = 'v';

-- C6. Lo que ve cada rol con RLS real (cambiar el mail y correr los 3 renglones juntos).
--     Esperado: fundador y finanzas y cliente > 0; ventas, producto y contenido = 0.
-- select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = 'finanzas@liam.dystopia'), true);
-- set local role authenticated;
-- select count(*) as pagos_visibles from public.fin_pagos where cliente_id = 'liam';
-- (despues: reset role;)

-- C7. Catalogos de liam: conceptos y programas nuevos. Esperado: 5 filas.
-- select dimension, valor, activo from public.fin_catalogos
--  where cliente_id = 'liam' and valor in ('3RA CUOTA RENEWAL', 'COMUNIDAD', 'BPF 1 A 1', 'BPF 1 AÑO', '1 a 1 Blueprint Financiero');

-- C8. Nada cambio en los permisos de otros clientes (agus sigue con cliente carga y anula).
--     Esperado: false en las dos columnas porque no es por areas.
-- select public.fin_cliente_por_areas('agus') as agus_por_areas, public.fin_cliente_por_areas('teo') as teo_por_areas;

-- C9. El CHECK de crm_members.rol. Esperado: un solo CHECK de rol con los 9 valores entre comillas:
--     cliente, closer, contenido, editor, finanzas, fundador, producto, setter, ventas.
-- select conname, pg_get_constraintdef(oid) as def from pg_constraint
--  where conrelid = 'public.crm_members'::regclass and contype = 'c';
