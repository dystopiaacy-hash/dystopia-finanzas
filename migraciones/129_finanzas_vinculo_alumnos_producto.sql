-- 129_finanzas_vinculo_alumnos_producto.sql  (numero asignado por el jefe)
-- Vinculo explicito alumno de Finanzas <-> ficha de Producto (cs_clientes.id).
--
-- COMO IDENTIFICA FINANZAS A UN ALUMNO: no hay tabla de alumnos. Un alumno es el TEXTO `alumno` de
-- fin_pagos y fin_cuotas (con `telefono` opcional) dentro de un cliente. La sync borra y reescribe esas
-- filas cada 15 min, asi que el vinculo NO vive ahi: la clave es (cliente_id, alumno normalizado), con la
-- misma normalizacion que cs_norm_nombre de Producto (minusculas, sin acentos, solo a-z0-9 y espacios).
-- cliente_id de Finanzas = programa_id de Producto ('liam', 'teo', 'agus').
--
-- QUE CREA (todo nuevo; no altera ninguna tabla ni funcion existente, no toca cs_*, solo las lee):
--   Tabla  fin_cs_vinculo (cliente_id, alumno_norm) -> cs_cliente_id, estado, origen, fechas.
--          estado: 'vinculado' | 'no_producto' (marcado a mano) | 'desvinculado' (se saco a mano; la
--          vinculacion automatica NO lo vuelve a vincular). Sin FK a cs_clientes (otra app): un vinculo
--          cuya ficha ya no existe se trata como sin vincular y la vinculacion automatica lo rehace.
--   Reglas de la vinculacion automatica (solo dentro del mismo programa, solo si el resultado es UNICO):
--     0. pago_clave: cs_clientes.pago_clave = clave de un pago del alumno (alta de Producto desde ese pago).
--     1. telefono: ultimos 8 digitos (cs_norm_tel) del telefono de sus pagos/cuotas = el de la ficha.
--     2. nombre: nombre normalizado = nombre de la ficha o un alias de cs_clientes_alias.
--     Si el telefono da 1 ficha y el nombre da otra distinta: ambiguo (no se vincula). Si el telefono da
--     varias y el nombre desempata a una: se vincula. Todo lo demas ambiguo o sin candidato queda sin vincular.
--   Funciones internas (solo service_role / postgres): fin_cs_norm_nombre, fin_cs_norm_tel, fin_cs_tokens,
--     fin_cs_nombres, fin_cs_alumnos, fin_cs_match, fin_cs_exigir.
--   Funciones de la app (authenticated; verifican permiso adentro):
--     fin_cs_resumen(p_cliente), fin_cs_lista(p_cliente, p_filtro), fin_cs_buscar(p_cliente, p_q, p_limite),
--     fin_cs_marcar(p_cliente, p_alumno_norm, p_accion, p_cs_cliente_id), fin_cs_vincular_auto(p_cliente)
--     Permiso: fundador o quien puede editar pagos del cliente (fin_puede_anular). anon: nada.
--   Funcion para PRODUCTO (solo lectura, sin montos salvo que se pida):
--     public.fin_cs_estado_pagos(p_cliente text, p_cs_ids uuid[] default null, p_montos boolean default false)
--     Ver el comentario de la funcion (columnas y reglas) mas abajo.
--   Cron fin_cs_vincular_auto: minutos 3, 18, 33 y 48 (la sync corre en :00/:15/:30/:45). Solo mira alumnos
--     sin vinculo; no corre dentro de la sync ni la enlentece.
--
-- Requiere: 001 (fin_*), 075 (fin_ve_plata, fin_puede_anular), y de Producto cs_clientes (con pago_clave, 070)
-- y cs_hoy(). cs_clientes_alias (127 de Producto) es OPCIONAL: si no existe, el nombre solo cruza con cs_clientes.nombre.
-- Correr (no a :00/:15/:30/:45 ni a las 9:00). Re-ejecutable. Sin begin/commit: cada sentencia es atomica.

-- ---------------------------------------------------------------------
-- 0. Guardas
-- ---------------------------------------------------------------------
do $$
declare v_falta text := '';
begin
  if to_regclass('public.fin_pagos') is null then v_falta := v_falta || ' fin_pagos'; end if;
  if to_regclass('public.fin_cuotas') is null then v_falta := v_falta || ' fin_cuotas'; end if;
  if to_regclass('public.fin_fuentes') is null then v_falta := v_falta || ' fin_fuentes'; end if;
  if to_regclass('public.crm_clients') is null then v_falta := v_falta || ' crm_clients'; end if;
  if to_regclass('public.cs_clientes') is null then v_falta := v_falta || ' cs_clientes(Producto)'; end if;
  if to_regprocedure('public.fin_ve_plata(text)') is null then v_falta := v_falta || ' fin_ve_plata(075)'; end if;
  if to_regprocedure('public.fin_puede_anular(text)') is null then v_falta := v_falta || ' fin_puede_anular(075)'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador'; end if;
  if to_regprocedure('public.cs_hoy()') is null then v_falta := v_falta || ' cs_hoy(Producto)'; end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'cs_clientes' and column_name = 'pago_clave') then
    v_falta := v_falta || ' cs_clientes.pago_clave(070 de Producto)';
  end if;
  if v_falta <> '' then
    raise exception 'GUARDA 129: faltan:%. No se aplica nada.', v_falta;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Normalizacion (identica a cs_norm_nombre / cs_norm_tel de Producto, 070)
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_norm_nombre(p text)
returns text
language sql immutable parallel safe set search_path = ''
as $$
  select nullif(btrim(regexp_replace(
           translate(lower(coalesce(p, '')), 'áéíóúàèìòùäëïöüâêîôûñç', 'aeiouaeiouaeiouaeiounc'),
           '[^a-z0-9]+', ' ', 'g')), '')
$$;

create or replace function public.fin_cs_norm_tel(p text)
returns text
language sql immutable parallel safe set search_path = ''
as $$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 8
              then right(regexp_replace(p, '\D', '', 'g'), 8) end
$$;

-- Palabras de 3 o mas letras de un nombre ya normalizado (para sugerir parecidos).
create or replace function public.fin_cs_tokens(p text)
returns text[]
language sql immutable parallel safe set search_path = ''
as $$
  select coalesce(array(select t from unnest(string_to_array(coalesce(p, ''), ' ')) t where length(t) >= 3), '{}'::text[])
$$;

-- ---------------------------------------------------------------------
-- 2. Tabla del vinculo (la sync no la toca: no tiene fuente_id ni sync_id)
-- ---------------------------------------------------------------------
create table if not exists public.fin_cs_vinculo (
  cliente_id     text        not null references public.crm_clients(id),
  alumno_norm    text        not null check (btrim(alumno_norm) <> ''),
  alumno_ejemplo text,
  estado         text        not null check (estado in ('vinculado', 'no_producto', 'desvinculado')),
  cs_cliente_id  uuid,
  origen         text        not null check (origen in ('auto_pago_clave', 'auto_telefono', 'auto_nombre', 'manual')),
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid,
  primary key (cliente_id, alumno_norm),
  constraint fin_cs_vinculo_cs_ck check ((estado = 'vinculado') = (cs_cliente_id is not null))
);
create index if not exists fin_cs_vinculo_cs_idx on public.fin_cs_vinculo (cs_cliente_id) where cs_cliente_id is not null;
comment on table public.fin_cs_vinculo is
  '129: alumno de Finanzas (cliente_id + nombre normalizado) -> cs_clientes.id. Vive aparte de fin_pagos/fin_cuotas porque la sync los reescribe cada 15 min.';

alter table public.fin_cs_vinculo enable row level security;
revoke all on public.fin_cs_vinculo from anon, public, authenticated;
grant select on public.fin_cs_vinculo to authenticated;
grant all on public.fin_cs_vinculo to service_role;
drop policy if exists fin_cs_vinculo_lectura on public.fin_cs_vinculo;
create policy fin_cs_vinculo_lectura on public.fin_cs_vinculo for select to authenticated
  using (public.es_fundador() or public.fin_ve_plata(cliente_id));
-- Sin policies de escritura: se escribe solo por fin_cs_marcar / fin_cs_vincular_auto (security definer).

-- ---------------------------------------------------------------------
-- 3. Permiso comun
--    modo 'gestion'  : fundador o quien edita pagos del cliente (fin_puede_anular)
--    modo 'lectura'  : fundador o quien ve la plata del cliente (fin_ve_plata)
--    modo 'fundador' : solo fundador (cliente null = todos)
--    Sin sesion: solo service_role o postgres (cron, Edge Functions de servicio, SQL Editor).
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_exigir(p_cliente text, p_modo text)
returns void
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_rol text;
begin
  if auth.uid() is null then
    v_rol := coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role');
    if v_rol = 'service_role' or session_user in ('postgres', 'supabase_admin') then
      return;
    end if;
    raise exception 'fin: sesion requerida' using errcode = '42501';
  end if;
  if p_cliente is not null and not exists (select 1 from public.crm_clients c where c.id = p_cliente) then
    raise exception 'fin: cliente invalido (%)', p_cliente using errcode = '22023';
  end if;
  if p_modo = 'fundador' or p_cliente is null then
    if not coalesce(public.es_fundador(), false) then
      raise exception 'fin: solo el fundador puede hacer esto' using errcode = '42501';
    end if;
  elsif p_modo = 'gestion' then
    if not coalesce(public.fin_puede_anular(p_cliente), false) then
      raise exception 'fin: sin permiso para vincular alumnos de %', p_cliente using errcode = '42501';
    end if;
  else
    if not (coalesce(public.es_fundador(), false) or coalesce(public.fin_ve_plata(p_cliente), false)) then
      raise exception 'fin: sin acceso a los pagos de %', p_cliente using errcode = '42501';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Nombres de las fichas de un programa (nombre + alias si la tabla existe)
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_nombres(p_programa text)
returns table (cs_id uuid, nom text, es_alias boolean)
language plpgsql stable security definer set search_path = ''
as $$
begin
  return query
    select c.id, public.fin_cs_norm_nombre(c.nombre), false
      from public.cs_clientes c where c.programa_id = p_programa;
  if to_regclass('public.cs_clientes_alias') is not null then
    return query execute
      'select a.cliente_id, public.fin_cs_norm_nombre(a.alias), true
         from public.cs_clientes_alias a where a.programa_id = $1'
      using p_programa;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. Alumnos de un cliente en Finanzas (pagos + cuotas), uno por nombre normalizado
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_alumnos(p_cliente text)
returns table (alumno_norm text, alumno text, telefonos text[], claves text[],
               n_pagos int, n_cuotas int, ultimo_pago date)
language sql stable security definer set search_path = ''
as $$
  with todo as (
    select public.fin_cs_norm_nombre(p.alumno) as an, p.alumno as nombre, p.telefono as tel,
           p.clave, p.fecha, p.monto_usd, 'p' as o
      from public.fin_pagos p where p.cliente_id = p_cliente
    union all
    select public.fin_cs_norm_nombre(q.alumno), q.alumno, q.telefono, null, null, null, 'c'
      from public.fin_cuotas q where q.cliente_id = p_cliente
  )
  select t.an,
         (array_agg(t.nombre order by (t.o = 'p') desc, t.fecha desc nulls last, t.nombre))[1],
         coalesce(array_agg(distinct public.fin_cs_norm_tel(t.tel))
                    filter (where public.fin_cs_norm_tel(t.tel) is not null), '{}'::text[]),
         coalesce(array_agg(distinct t.clave) filter (where t.clave is not null), '{}'::text[]),
         (count(*) filter (where t.o = 'p'))::int,
         (count(*) filter (where t.o = 'c'))::int,
         max(t.fecha) filter (where t.o = 'p' and t.monto_usd > 0)
    from todo t
   where t.an is not null
   group by t.an
$$;

-- ---------------------------------------------------------------------
-- 6. Motor de match: para TODOS los alumnos del cliente, estado actual del vinculo y
--    resultado de las reglas (unico / ambiguo / sin_candidato) con los candidatos por regla.
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_match(p_cliente text)
returns table (
  alumno_norm text, alumno text, telefonos text[], n_pagos int, n_cuotas int, ultimo_pago date,
  estado_actual text, origen_actual text, cs_actual uuid,
  resultado text, regla text, cs_cliente_id uuid,
  por_clave uuid[], por_tel uuid[], por_nombre uuid[])
language sql stable security definer set search_path = ''
as $$
  with al as (select * from public.fin_cs_alumnos(p_cliente)),
  cs as (
    select c.id, c.pago_clave, public.fin_cs_norm_tel(c.telefono) as tel
      from public.cs_clientes c where c.programa_id = p_cliente),
  nm as (select n.cs_id, n.nom from public.fin_cs_nombres(p_cliente) n where n.nom is not null),
  a as (
    select al.*,
      array(select cs.id from cs
             where cs.pago_clave is not null and cs.pago_clave = any(al.claves) order by cs.id) as k,
      array(select cs.id from cs
             where cs.tel is not null and cs.tel = any(al.telefonos) order by cs.id) as t,
      array(select distinct nm.cs_id from nm where nm.nom = al.alumno_norm order by 1) as n
    from al),
  b as (
    select a.*, array(select unnest(a.t) intersect select unnest(a.n)) as i from a),
  c as (
    select b.*,
      case when cardinality(b.k) = 1 then b.k[1]
           when cardinality(b.t) = 1 and (cardinality(b.n) = 0 or b.t[1] = any(b.n)) then b.t[1]
           when cardinality(b.t) = 0 and cardinality(b.n) = 1 then b.n[1]
           when cardinality(b.t) > 1 and cardinality(b.i) = 1 then b.i[1]
      end as elegido
    from b)
  select c.alumno_norm, c.alumno, c.telefonos, c.n_pagos, c.n_cuotas, c.ultimo_pago,
         v.estado_vig, v.origen, v.cs_cliente_id,
         case when c.elegido is not null then 'unico'
              when cardinality(c.k) + cardinality(c.t) + cardinality(c.n) = 0 then 'sin_candidato'
              else 'ambiguo' end,
         case when c.elegido is null then null
              when cardinality(c.k) = 1 then 'pago_clave'
              when cardinality(c.t) >= 1 then 'telefono'
              else 'nombre' end,
         c.elegido, c.k, c.t, c.n
    from c
    left join lateral (
      select case when vv.estado = 'vinculado'
                   and not exists (select 1 from cs where cs.id = vv.cs_cliente_id)
                  then null else vv.estado end as estado_vig,
             vv.origen, vv.cs_cliente_id
        from public.fin_cs_vinculo vv
       where vv.cliente_id = p_cliente and vv.alumno_norm = c.alumno_norm) v on true
$$;

-- ---------------------------------------------------------------------
-- 7. Vinculacion automatica (la llama el cron; el fundador / quien edita pagos puede
--    correrla a mano desde la pantalla). Solo toca alumnos SIN fila de vinculo (o con un
--    vinculo cuya ficha ya no existe). Nunca pisa 'manual', 'no_producto' ni 'desvinculado'.
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_vincular_auto(p_cliente text default null)
returns table (cliente text, vinculados int, ambiguos int, sin_candidato int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_cli  text;
  v_vinc int;
  v_amb  int;
  v_sin  int;
begin
  perform public.fin_cs_exigir(p_cliente, case when p_cliente is null then 'fundador' else 'gestion' end);
  for v_cli in
    select k.id from public.crm_clients k
     where (p_cliente is null or k.id = p_cliente)
       and exists (select 1 from public.cs_clientes c where c.programa_id = k.id)
     order by k.id
  loop
    with m as (select * from public.fin_cs_match(v_cli) mm where mm.estado_actual is null),
    ins as (
      insert into public.fin_cs_vinculo as t (cliente_id, alumno_norm, alumno_ejemplo, estado, cs_cliente_id, origen)
      select v_cli, m.alumno_norm, m.alumno, 'vinculado', m.cs_cliente_id, 'auto_' || m.regla
        from m where m.resultado = 'unico'
      on conflict (cliente_id, alumno_norm) do update
         set estado = 'vinculado', cs_cliente_id = excluded.cs_cliente_id, origen = excluded.origen,
             alumno_ejemplo = excluded.alumno_ejemplo, actualizado_en = now()
       where t.estado = 'vinculado'          -- solo rehace un vinculo cuya ficha desaparecio
      returning 1)
    select (select count(*) from ins)::int,
           (count(*) filter (where m.resultado = 'ambiguo'))::int,
           (count(*) filter (where m.resultado = 'sin_candidato'))::int
      into v_vinc, v_amb, v_sin
      from m;
    cliente := v_cli; vinculados := v_vinc; ambiguos := v_amb; sin_candidato := v_sin;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 8. Funciones de la pantalla "Vincular alumnos"
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_resumen(p_cliente text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare r jsonb;
begin
  perform public.fin_cs_exigir(p_cliente, 'gestion');
  select jsonb_build_object(
           'cliente', p_cliente,
           'alumnos', count(*),
           'vinculados', count(*) filter (where m.estado_actual = 'vinculado'),
           'vinculados_auto', count(*) filter (where m.estado_actual = 'vinculado' and m.origen_actual like 'auto%'),
           'vinculados_manual', count(*) filter (where m.estado_actual = 'vinculado' and m.origen_actual = 'manual'),
           'no_producto', count(*) filter (where m.estado_actual = 'no_producto'),
           'pendientes', count(*) filter (where m.estado_actual is null or m.estado_actual = 'desvinculado'),
           'ambiguos', count(*) filter (where (m.estado_actual is null or m.estado_actual = 'desvinculado') and m.resultado = 'ambiguo'),
           'sin_candidato', count(*) filter (where (m.estado_actual is null or m.estado_actual = 'desvinculado') and m.resultado = 'sin_candidato'),
           'fichas_producto', (select count(*) from public.cs_clientes c where c.programa_id = p_cliente))
    into r
    from public.fin_cs_match(p_cliente) m;
  return r;
end $$;

-- p_filtro: 'pendientes' (con candidatos), 'vinculados' o 'no_producto'.
create or replace function public.fin_cs_lista(p_cliente text, p_filtro text default 'pendientes')
returns table (alumno_norm text, alumno text, telefonos text[], n_pagos int, n_cuotas int, ultimo_pago date,
               estado text, origen text, cs_cliente_id uuid, cs_nombre text, resultado text, candidatos jsonb)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
begin
  perform public.fin_cs_exigir(p_cliente, 'gestion');
  if p_filtro not in ('pendientes', 'vinculados', 'no_producto') then
    raise exception 'fin: filtro invalido (%)', p_filtro using errcode = '22023';
  end if;
  return query
  with m as (select * from public.fin_cs_match(p_cliente)),
  f as (
    select m.* from m
     where case p_filtro
             when 'pendientes' then m.estado_actual is null or m.estado_actual = 'desvinculado'
             when 'vinculados' then m.estado_actual = 'vinculado'
             else m.estado_actual = 'no_producto' end),
  cs as (
    select c.id, c.nombre, c.telefono, c.estado, public.fin_cs_norm_nombre(c.nombre) as nom
      from public.cs_clientes c where c.programa_id = p_cliente),
  ex as (
    select f.alumno_norm, u.cs_id, u.motivo
      from f cross join lateral (
        select unnest(f.por_clave) as cs_id, 'pago' as motivo
        union all select unnest(f.por_tel), 'telefono'
        union all select unnest(f.por_nombre), 'nombre') u
     where p_filtro = 'pendientes'),
  fz as (
    select f.alumno_norm, cs.id as cs_id, 'parecido' as motivo
      from f join cs on true
     where p_filtro = 'pendientes'
       and cardinality(array(select unnest(public.fin_cs_tokens(f.alumno_norm))
                             intersect select unnest(public.fin_cs_tokens(cs.nom)))) >= 2
       and not exists (select 1 from ex where ex.alumno_norm = f.alumno_norm and ex.cs_id = cs.id)),
  ca as (
    select e.alumno_norm, e.cs_id, string_agg(distinct e.motivo, ' + ') as motivo
      from (select * from ex union all select * from fz) e
     group by e.alumno_norm, e.cs_id),
  rk as (
    select ca.*, row_number() over (partition by ca.alumno_norm
                                    order by (ca.motivo = 'parecido'), ca.motivo, cs.nombre) as rn,
           cs.nombre, cs.telefono, cs.estado
      from ca join cs on cs.id = ca.cs_id),
  cj as (
    select rk.alumno_norm,
           jsonb_agg(jsonb_build_object('id', rk.cs_id, 'nombre', rk.nombre, 'telefono', rk.telefono,
                                        'estado', rk.estado, 'motivo', rk.motivo) order by rk.rn) as lista
      from rk where rk.rn <= 5 group by rk.alumno_norm)
  select f.alumno_norm, f.alumno, f.telefonos, f.n_pagos, f.n_cuotas, f.ultimo_pago,
         coalesce(f.estado_actual, 'pendiente'), f.origen_actual, f.cs_actual,
         (select c.nombre from cs c where c.id = f.cs_actual),
         f.resultado, coalesce(cj.lista, '[]'::jsonb)
    from f left join cj on cj.alumno_norm = f.alumno_norm
   order by (f.resultado = 'ambiguo') desc, (cj.lista is not null) desc, f.ultimo_pago desc nulls last, f.alumno;
end $$;

-- Buscador de alumnos de Producto del programa (nombre, alias, telefono o email).
create or replace function public.fin_cs_buscar(p_cliente text, p_q text, p_limite int default 15)
returns table (id uuid, nombre text, telefono text, email text, estado text, vinculos int)
language plpgsql stable security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_q text := public.fin_cs_norm_nombre(p_q);
  v_d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  v_e text := lower(btrim(coalesce(p_q, '')));
begin
  perform public.fin_cs_exigir(p_cliente, 'gestion');
  if char_length(btrim(coalesce(p_q, ''))) < 2 then
    return;
  end if;
  return query
  select c.id, c.nombre, c.telefono, c.email, c.estado,
         (select count(*)::int from public.fin_cs_vinculo v
           where v.cliente_id = p_cliente and v.estado = 'vinculado' and v.cs_cliente_id = c.id)
    from public.cs_clientes c
   where c.programa_id = p_cliente
     and ( (v_q is not null and public.fin_cs_norm_nombre(c.nombre) like '%' || v_q || '%')
        or (v_q is not null and exists (select 1 from public.fin_cs_nombres(p_cliente) n
                                         where n.cs_id = c.id and n.nom like '%' || v_q || '%'))
        or (char_length(v_d) >= 4 and regexp_replace(coalesce(c.telefono, ''), '\D', '', 'g') like '%' || v_d || '%')
        or (position('@' in v_e) > 0 and strpos(lower(coalesce(c.email, '')), v_e) > 0) )
   order by c.nombre
   limit least(greatest(coalesce(p_limite, 15), 1), 50);
end $$;

-- p_accion: 'vincular' (con p_cs_cliente_id), 'desvincular' o 'no_producto'.
create or replace function public.fin_cs_marcar(
  p_cliente text, p_alumno_norm text, p_accion text, p_cs_cliente_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ej text;
  v_estado text;
begin
  perform public.fin_cs_exigir(p_cliente, 'gestion');
  if auth.uid() is null then
    raise exception 'fin: sesion requerida' using errcode = '42501';
  end if;
  if p_accion not in ('vincular', 'desvincular', 'no_producto') then
    raise exception 'fin: accion invalida (%)', p_accion using errcode = '22023';
  end if;
  select a.alumno into v_ej from public.fin_cs_alumnos(p_cliente) a where a.alumno_norm = p_alumno_norm;
  if not found then
    raise exception 'fin: el alumno "%" no existe en Finanzas para %', p_alumno_norm, p_cliente using errcode = '22023';
  end if;
  if p_accion = 'vincular' then
    if p_cs_cliente_id is null
       or not exists (select 1 from public.cs_clientes c where c.id = p_cs_cliente_id and c.programa_id = p_cliente) then
      raise exception 'fin: la ficha de Producto no existe en el programa %', p_cliente using errcode = '22023';
    end if;
    v_estado := 'vinculado';
  else
    p_cs_cliente_id := null;
    v_estado := case p_accion when 'no_producto' then 'no_producto' else 'desvinculado' end;
  end if;
  insert into public.fin_cs_vinculo (cliente_id, alumno_norm, alumno_ejemplo, estado, cs_cliente_id, origen, actualizado_por)
  values (p_cliente, p_alumno_norm, v_ej, v_estado, p_cs_cliente_id, 'manual', auth.uid())
  on conflict (cliente_id, alumno_norm) do update
     set estado = excluded.estado, cs_cliente_id = excluded.cs_cliente_id, origen = 'manual',
         alumno_ejemplo = excluded.alumno_ejemplo, actualizado_en = now(), actualizado_por = excluded.actualizado_por;
  return jsonb_build_object('ok', true, 'estado', v_estado, 'cs_cliente_id', p_cs_cliente_id);
end $$;

-- ---------------------------------------------------------------------
-- 9. PARA PRODUCTO: estado de pagos por ficha (cs_clientes.id)
--
--   select * from public.fin_cs_estado_pagos('liam');                                  -- todas las fichas vinculadas
--   select * from public.fin_cs_estado_pagos('liam', array['<uuid>', ...]::uuid[]);    -- solo esas fichas
--   select * from public.fin_cs_estado_pagos('liam', null, true);                      -- con montos (USD)
--
--   Solo devuelve fichas que tienen al menos un alumno de Finanzas vinculado (estado 'vinculado').
--   Una ficha sin fila = sin vinculo: Producto debe tratarla como "sin dato de pagos", no como "al dia".
--   Columnas:
--     cs_cliente_id        uuid  ficha de Producto
--     nombres_finanzas     int   cuantos nombres de Finanzas estan vinculados a la ficha
--     cuotas_total         int   filas de fin_cuotas de esos nombres (solo fuentes ACTIVAS: una cortada esta congelada)
--     cuotas_pagadas       int   estado pagado / pagada / cuota pagada
--     cuotas_pendientes    int   estado vacio o distinto de pagado/churn/pausado/cancelado (igual que fin_v_cobranzas)
--     cuotas_otras         int   churn / pausado / cancelado (no cuentan como pendientes)
--     cuotas_atrasadas     int   pendientes con fecha_pago anterior a cs_hoy()
--     max_dias_atraso      int   dias de la cuota atrasada mas vieja (null si no hay)
--     proximo_vencimiento  date  fecha_pago mas cercana de una pendiente de hoy en adelante
--     ultimo_pago          date  fecha del ultimo pago positivo (fin_pagos) de esos nombres
--     monto_pagado         numeric  suma neta de fin_pagos.monto_usd  | null salvo p_montos = true
--     monto_pendiente      numeric  suma de (monto - monto_cobrado) de las pendientes | null salvo p_montos
--     monto_atrasado       numeric  idem, solo atrasadas | null salvo p_montos
--   Permiso: fundador, quien ve la plata del cliente (fin_ve_plata) o service_role / postgres (cron y Edge
--   Functions de servicio). Un rol de Producto comun NO la puede llamar con su sesion: el aviso diario tiene
--   que llamarla con service_role o desde un cron/funcion security definer (decision pendiente, ver ESTADO-APP).
-- ---------------------------------------------------------------------
create or replace function public.fin_cs_estado_pagos(
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
  perform public.fin_cs_exigir(p_cliente, 'lectura');
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

comment on function public.fin_cs_estado_pagos(text, uuid[], boolean) is
  '129: estado de pagos por ficha de Producto (cs_clientes.id) segun fin_cs_vinculo. Sin montos salvo p_montos = true. Solo fundador, fin_ve_plata del cliente o service_role/postgres.';

-- ---------------------------------------------------------------------
-- 10. Permisos de funciones
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'fin_cs_norm_nombre(text)', 'fin_cs_norm_tel(text)', 'fin_cs_tokens(text)',
    'fin_cs_exigir(text, text)', 'fin_cs_nombres(text)', 'fin_cs_alumnos(text)', 'fin_cs_match(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
  foreach f in array array[
    'fin_cs_resumen(text)', 'fin_cs_lista(text, text)', 'fin_cs_buscar(text, text, int)',
    'fin_cs_marcar(text, text, text, uuid)', 'fin_cs_vincular_auto(text)',
    'fin_cs_estado_pagos(text, uuid[], boolean)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 11. Prueba de humo (se autorrevierte; no deja ningun dato)
--     Usa una ficha REAL de Producto con telefono unico y sin alumno de Finanzas coincidente (la lee, no la modifica) y un alumno
--     "Zz Smoke 129" que solo existe dentro de la prueba.
-- ---------------------------------------------------------------------
do $$
declare
  v_cs    record;
  v_fp    bigint;
  v_fc    bigint;
  v_fund  uuid;
  v_hoy   date := public.cs_hoy();
  v_r     record;
  v_j     jsonb;
  v_n     int;
  v_txt   text;
begin
  begin
    -- normalizacion
    if public.fin_cs_norm_nombre('  José Pérez-Núñez ') <> 'jose perez nunez' then
      raise exception 'smoke 129: norm_nombre = %', public.fin_cs_norm_nombre('  José Pérez-Núñez ');
    end if;
    if public.fin_cs_norm_tel('+54 9 11 5555-5555') <> '55555555' or public.fin_cs_norm_tel('123') is not null then
      raise exception 'smoke 129: norm_tel mal';
    end if;
    if to_regprocedure('public.cs_norm_nombre(text)') is not null then
      execute 'select public.cs_norm_nombre($1)' into v_txt using 'María Ñandú';
      if v_txt is distinct from public.fin_cs_norm_nombre('María Ñandú') then
        raise exception 'smoke 129: la normalizacion difiere de cs_norm_nombre (% vs %)',
          v_txt, public.fin_cs_norm_nombre('María Ñandú');
      end if;
    end if;

    -- Ficha con telefono unico Y sin ningun alumno real de Finanzas que coincida (ni por pago_clave,
    -- ni por telefono, ni por nombre/alias, ni vinculo previo): asi la vinculacion automatica de la
    -- prueba solo ve al alumno "Zz Smoke 129" y nombres_finanzas = 1 aunque haya datos reales.
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
      raise notice 'smoke 129: no hay ficha de Producto con telefono unico y sin alumno de Finanzas coincidente; se omite la parte con datos';
      raise exception 'SMOKE_OK';
    end if;

    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values (v_cs.programa_id, 'SMOKE_129', 1, 'Smoke', 'pagos', 10000) returning id into v_fp;
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, tope_monto)
    values (v_cs.programa_id, 'SMOKE_129', 2, 'Smoke', 'cuotas', 'cuotas_plano', 10000) returning id into v_fc;

    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, telefono, monto_usd, monto_origen, moneda_origen, concepto) values
      (v_cs.programa_id, v_fp, 1, v_hoy - 20, 'Zz Smoke 129', v_cs.telefono, 100, 100, 'USD', 'SMOKE'),
      (v_cs.programa_id, v_fp, 2, v_hoy - 5,  'ZZ  SMOKE 129', null,          50,  50,  'USD', 'SMOKE');
    insert into public.fin_cuotas (cliente_id, fuente_id, alumno, programa, numero_cuota, monto, monto_cobrado, fecha_pago, estado, fila_planilla) values
      (v_cs.programa_id, v_fc, 'Zz Smoke 129', 'Prog Z', 1, 100, 100, v_hoy - 30, 'Pagado',    1),
      (v_cs.programa_id, v_fc, 'Zz Smoke 129', 'Prog Z', 2, 100,  20, v_hoy - 10, 'Pendiente', 2),
      (v_cs.programa_id, v_fc, 'Zz Smoke 129', 'Prog Z', 3, 100,   0, v_hoy + 10, null,        3);

    -- match: un solo alumno normalizado (los dos pagos), unico por telefono, apunta a la ficha
    select * into v_r from public.fin_cs_match(v_cs.programa_id) m where m.alumno_norm = 'zz smoke 129';
    if not found then raise exception 'smoke 129: el alumno de prueba no aparece en fin_cs_match'; end if;
    if v_r.n_pagos <> 2 or v_r.n_cuotas <> 3 then raise exception 'smoke 129: pagos/cuotas = %/%', v_r.n_pagos, v_r.n_cuotas; end if;
    if v_r.resultado <> 'unico' or v_r.regla <> 'telefono' or v_r.cs_cliente_id <> v_cs.id then
      raise exception 'smoke 129: match = % / % / %', v_r.resultado, v_r.regla, v_r.cs_cliente_id;
    end if;
    if v_r.estado_actual is not null then raise exception 'smoke 129: estado_actual deberia ser null'; end if;

    -- vinculacion automatica sin sesion (camino del cron: postgres / service_role)
    select count(*) into v_n from public.fin_cs_vincular_auto(v_cs.programa_id);
    if not exists (select 1 from public.fin_cs_vinculo v
                    where v.cliente_id = v_cs.programa_id and v.alumno_norm = 'zz smoke 129'
                      and v.estado = 'vinculado' and v.cs_cliente_id = v_cs.id and v.origen = 'auto_telefono') then
      raise exception 'smoke 129: la vinculacion automatica no vinculo al alumno de prueba';
    end if;
    -- idempotente
    select coalesce(sum(a.vinculados), 0) into v_n from public.fin_cs_vincular_auto(v_cs.programa_id) a;
    if v_n <> 0 then raise exception 'smoke 129: la segunda pasada vinculo % mas', v_n; end if;

    -- funcion para Producto (sin sesion: camino service_role / postgres)
    select * into v_r from public.fin_cs_estado_pagos(v_cs.programa_id, array[v_cs.id]);
    if not found then raise exception 'smoke 129: fin_cs_estado_pagos no devolvio la ficha'; end if;
    if v_r.cuotas_total <> 3 or v_r.cuotas_pagadas <> 1 or v_r.cuotas_pendientes <> 2 or v_r.cuotas_atrasadas <> 1
       or v_r.max_dias_atraso <> 10 or v_r.proximo_vencimiento <> v_hoy + 10 or v_r.ultimo_pago <> v_hoy - 5
       or v_r.nombres_finanzas <> 1 then
      raise exception 'smoke 129: estado_pagos = %', to_jsonb(v_r);
    end if;
    if v_r.monto_pagado is not null or v_r.monto_pendiente is not null or v_r.monto_atrasado is not null then
      raise exception 'smoke 129: devolvio montos sin pedirlos';
    end if;
    select * into v_r from public.fin_cs_estado_pagos(v_cs.programa_id, array[v_cs.id], true);
    if v_r.monto_pagado <> 150 or v_r.monto_pendiente <> 180 or v_r.monto_atrasado <> 80 then
      raise exception 'smoke 129: montos = %', to_jsonb(v_r);
    end if;

    -- con sesion de fundador: pantalla y acciones manuales
    select m.user_id into v_fund from public.crm_members m where m.rol = 'fundador' limit 1;
    if v_fund is null then
      raise notice 'smoke 129: no hay fundador en crm_members; se omiten las pruebas con sesion';
    else
      perform set_config('request.jwt.claim.sub', v_fund::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_fund, 'role', 'authenticated')::text, true);

      v_j := public.fin_cs_resumen(v_cs.programa_id);
      if (v_j ->> 'vinculados')::int < 1 then raise exception 'smoke 129: resumen = %', v_j; end if;

      -- desvincular: queda desvinculado y la automatica NO lo vuelve a vincular
      perform public.fin_cs_marcar(v_cs.programa_id, 'zz smoke 129', 'desvincular');
      select count(*) into v_n from public.fin_cs_vincular_auto(v_cs.programa_id);
      select v.estado into v_txt from public.fin_cs_vinculo v
       where v.cliente_id = v_cs.programa_id and v.alumno_norm = 'zz smoke 129';
      if v_txt <> 'desvinculado' then raise exception 'smoke 129: tras desvincular estado = %', v_txt; end if;
      if exists (select 1 from public.fin_cs_estado_pagos(v_cs.programa_id, array[v_cs.id])) then
        raise exception 'smoke 129: una ficha desvinculada sigue devolviendo estado';
      end if;
      -- vuelve a pendientes con su candidato por telefono
      select count(*) into v_n from public.fin_cs_lista(v_cs.programa_id, 'pendientes') l
       where l.alumno_norm = 'zz smoke 129' and l.candidatos @> jsonb_build_array(jsonb_build_object('id', v_cs.id));
      if v_n <> 1 then raise exception 'smoke 129: el pendiente no trae su candidato (%)', v_n; end if;

      -- no esta en Producto
      perform public.fin_cs_marcar(v_cs.programa_id, 'zz smoke 129', 'no_producto');
      select count(*) into v_n from public.fin_cs_lista(v_cs.programa_id, 'no_producto') l where l.alumno_norm = 'zz smoke 129';
      if v_n <> 1 then raise exception 'smoke 129: no_producto no aparece'; end if;

      -- vincular a mano
      perform public.fin_cs_marcar(v_cs.programa_id, 'zz smoke 129', 'vincular', v_cs.id);
      select count(*) into v_n from public.fin_cs_lista(v_cs.programa_id, 'vinculados') l
       where l.alumno_norm = 'zz smoke 129' and l.origen = 'manual' and l.cs_cliente_id = v_cs.id;
      if v_n <> 1 then raise exception 'smoke 129: vinculo manual no aparece'; end if;

      -- buscador
      select count(*) into v_n from public.fin_cs_buscar(v_cs.programa_id, regexp_replace(v_cs.telefono, '\D', '', 'g'));
      if v_n < 1 then raise exception 'smoke 129: el buscador no encontro la ficha por telefono'; end if;

      -- ficha de otro programa: rechazada
      begin
        perform public.fin_cs_marcar(v_cs.programa_id, 'zz smoke 129', 'vincular', gen_random_uuid());
        raise exception 'smoke 129: acepto una ficha inexistente';
      exception when sqlstate '22023' then null;
      end;

      -- usuario sin permiso (no es miembro): rechazado
      perform set_config('request.jwt.claim.sub', gen_random_uuid()::text, true);
      perform set_config('request.jwt.claims', jsonb_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
      begin
        perform * from public.fin_cs_lista(v_cs.programa_id, 'pendientes');
        raise exception 'smoke 129: un usuario sin permiso pudo listar';
      exception when sqlstate '42501' then null;
      end;
      begin
        perform * from public.fin_cs_estado_pagos(v_cs.programa_id);
        raise exception 'smoke 129: un usuario sin permiso pudo leer el estado de pagos';
      exception when sqlstate '42501' then null;
      end;
    end if;

    -- anon: nada
    if has_function_privilege('anon', 'public.fin_cs_estado_pagos(text, uuid[], boolean)', 'execute')
       or has_function_privilege('anon', 'public.fin_cs_lista(text, text)', 'execute')
       or has_function_privilege('authenticated', 'public.fin_cs_match(text)', 'execute')
       or has_table_privilege('anon', 'public.fin_cs_vinculo', 'select')
       or has_table_privilege('authenticated', 'public.fin_cs_vinculo', 'insert') then
      raise exception 'smoke 129: permisos de mas';
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 129: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 12. Cron: vinculacion automatica a los :03, :18, :33 y :48 (la sync corre en :00/:15/:30/:45).
-- ---------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'fin_cs_vincular_auto';
select cron.schedule('fin_cs_vincular_auto', '3,18,33,48 * * * *', $cron$ select * from public.fin_cs_vincular_auto(null); $cron$);

-- ---------------------------------------------------------------------
-- 13. Primera pasada (como postgres). Ultimo resultado del editor: vinculados ahora, ambiguos y sin
--     candidato por cliente. Los vinculados por regla salen en C2.
-- ---------------------------------------------------------------------
select * from public.fin_cs_vincular_auto(null);

-- ===========================================================================
-- CONTROLES: correr DE A UNO (el editor muestra solo el ultimo resultado).
-- Como postgres no hay sesion: las funciones de la app dan "sesion requerida" salvo
-- que se ponga el fundador:  select set_config('request.jwt.claim.sub', '<uuid del fundador>', true);
-- en la misma ejecucion. Los controles de abajo usan las funciones internas (sin sesion).
-- ===========================================================================
-- C1. Funciones, cron y permisos (esperado: funciones = 13 (7 internas + 6 de la app), cron_activo true,
--     cron '3,18,33,48 * * * *', anon_lee false, auth_escribe false).
--   select (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname = 'public' and p.proname like 'fin\_cs\_%') as funciones,
--          (select active from cron.job where jobname = 'fin_cs_vincular_auto') as cron_activo,
--          (select schedule from cron.job where jobname = 'fin_cs_vincular_auto') as cron,
--          has_table_privilege('anon', 'public.fin_cs_vinculo', 'select') as anon_lee,
--          has_table_privilege('authenticated', 'public.fin_cs_vinculo', 'insert') as auth_escribe;
--
-- C2. Por cliente: alumnos de Finanzas, vinculados (por regla), ambiguos y sin candidato (lo que pidio el jefe).
--   select k.id as cliente,
--          (select count(*) from public.fin_cs_alumnos(k.id)) as alumnos_finanzas,
--          (select count(*) from public.cs_clientes c where c.programa_id = k.id) as fichas_producto,
--          (select count(*) from public.fin_cs_vinculo v where v.cliente_id = k.id and v.estado = 'vinculado' and v.origen = 'auto_pago_clave') as auto_pago_clave,
--          (select count(*) from public.fin_cs_vinculo v where v.cliente_id = k.id and v.estado = 'vinculado' and v.origen = 'auto_telefono') as auto_telefono,
--          (select count(*) from public.fin_cs_vinculo v where v.cliente_id = k.id and v.estado = 'vinculado' and v.origen = 'auto_nombre') as auto_nombre,
--          (select count(*) from public.fin_cs_match(k.id) m where m.estado_actual is null and m.resultado = 'ambiguo') as ambiguos,
--          (select count(*) from public.fin_cs_match(k.id) m where m.estado_actual is null and m.resultado = 'sin_candidato') as sin_candidato
--     from public.crm_clients k
--    where exists (select 1 from public.cs_clientes c where c.programa_id = k.id)
--    order by k.id;
--
-- C3. Ambiguos de un cliente con sus candidatos (reemplazar 'liam'; trae nombres: no pegar fuera del equipo).
--   select m.alumno, m.n_pagos, m.n_cuotas,
--          (select string_agg(c.nombre, ' | ') from public.cs_clientes c
--            where c.id = any(m.por_clave || m.por_tel || m.por_nombre)) as candidatos
--     from public.fin_cs_match('liam') m
--    where m.estado_actual is null and m.resultado = 'ambiguo' order by m.alumno;
--
-- C4. Vinculos por TELEFONO donde el nombre no coincide ni con el de la ficha (para revisar a ojo:
--     telefono compartido o mal cargado). Reemplazar 'liam'.
--   select v.alumno_ejemplo as alumno_finanzas, c.nombre as ficha_producto, v.origen
--     from public.fin_cs_vinculo v join public.cs_clientes c on c.id = v.cs_cliente_id
--    where v.cliente_id = 'liam' and v.estado = 'vinculado' and v.origen = 'auto_telefono'
--      and public.fin_cs_norm_nombre(c.nombre) <> v.alumno_norm
--      and not exists (select 1 from public.fin_cs_nombres('liam') n where n.cs_id = c.id and n.nom = v.alumno_norm)
--    order by 1;
--
-- C5. Fichas de Producto con mas de un nombre de Finanzas vinculado (normal si hay variantes del nombre;
--     revisar si son personas distintas).
--   select v.cliente_id, c.nombre, count(*) as nombres, string_agg(v.alumno_ejemplo, ' | ') as nombres_finanzas
--     from public.fin_cs_vinculo v join public.cs_clientes c on c.id = v.cs_cliente_id
--    where v.estado = 'vinculado' group by 1, 2 having count(*) > 1 order by 3 desc;
--
-- C6. Vinculos huerfanos (la ficha ya no existe en Producto). Esperado: 0 filas; si aparecen, la
--     vinculacion automatica los rehace y la pantalla los muestra como pendientes.
--   select v.cliente_id, v.alumno_ejemplo, v.cs_cliente_id
--     from public.fin_cs_vinculo v
--    where v.estado = 'vinculado' and not exists (select 1 from public.cs_clientes c where c.id = v.cs_cliente_id);
--
-- C7. La funcion para Producto, resumen por cliente (sin montos). Esperado: fichas_con_dato = vinculados
--     distintos; atrasadas coherentes con Cobranzas.
--   select k.id as cliente, count(*) as fichas_con_dato,
--          sum(e.cuotas_atrasadas) as cuotas_atrasadas, max(e.max_dias_atraso) as max_dias_atraso
--     from public.crm_clients k, lateral public.fin_cs_estado_pagos(k.id) e
--    where exists (select 1 from public.fin_cs_vinculo v where v.cliente_id = k.id and v.estado = 'vinculado')
--    group by k.id order by k.id;
--
-- C8. Cron en marcha (despues de 15 minutos): ultimas corridas.
--   select status::text, return_message, start_time from cron.job_run_details
--    where jobid = (select jobid from cron.job where jobname = 'fin_cs_vincular_auto')
--    order by start_time desc limit 5;
--
-- C9. La sync sigue igual de rapida: la vinculacion automatica con la tabla ya poblada.
--   explain (analyze, costs off) select * from public.fin_cs_vincular_auto(null);
--   -- (corre la pasada de verdad: es idempotente y solo vincula lo nuevo)
--
-- ---------------------------------------------------------------------
-- VUELTA ATRAS (todo es nuevo; no cambia ninguna tabla ni funcion anterior):
--   select cron.unschedule(jobid) from cron.job where jobname = 'fin_cs_vincular_auto';
--   drop function if exists public.fin_cs_estado_pagos(text, uuid[], boolean);
--   drop function if exists public.fin_cs_marcar(text, text, text, uuid);
--   drop function if exists public.fin_cs_buscar(text, text, int);
--   drop function if exists public.fin_cs_lista(text, text);
--   drop function if exists public.fin_cs_resumen(text);
--   drop function if exists public.fin_cs_vincular_auto(text);
--   drop function if exists public.fin_cs_match(text);
--   drop function if exists public.fin_cs_alumnos(text);
--   drop function if exists public.fin_cs_nombres(text);
--   drop function if exists public.fin_cs_exigir(text, text);
--   drop function if exists public.fin_cs_tokens(text);
--   drop function if exists public.fin_cs_norm_tel(text);
--   drop function if exists public.fin_cs_norm_nombre(text);
--   drop table if exists public.fin_cs_vinculo;   -- pierde los vinculos manuales: respaldar antes si importa
--   -- (el front con la pantalla "Vincular alumnos" falla con "function does not exist": sacar la ruta #/vincular)
