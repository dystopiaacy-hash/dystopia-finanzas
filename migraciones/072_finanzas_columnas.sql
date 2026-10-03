-- =====================================================================
-- 072_finanzas_columnas.sql  ·  FINANZAS: columnas configurables
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion).
-- Numeracion global, compartida con CRM, Ventas y Producto.
-- Evitar :00, :15, :30 y :45 y las 9:00.
--
-- Mismo patron que la 071 de Producto, adaptado (FASE0-COLUMNAS-FINANZAS.md).
-- Decisiones (03/10):
--   - Cambia la estructura SOLO un fundador. El resto edita valores.
--   - Una configuracion por cliente, igual para todos los usuarios.
--   - Columnas nuevas por cliente (liam no ve las de teo), solo en Pagos.
--   - Pagos y el formulario de carga: renombrar, mover, ocultar, agregar.
--     Resumen, P&L, Conciliacion: solo renombrar, mover, ocultar
--     (son calculos). Resumen y Conciliacion muestran todos los clientes:
--     su configuracion es una sola, global (cliente_id null).
--   - Pagos con "Todos los clientes": columnas del sistema con su nombre
--     por defecto, sin columnas nuevas (lo resuelve la app).
--
-- Que hace:
--   1. fin_columnas: una fila por columna que se toco.
--        Del sistema: solo etiqueta, orden y visible; la clave interna no
--        cambia, asi renombrar no rompe calculos ni filtros. Se ocultan,
--        no se borran. "alumno" (Pagos) no se oculta.
--        Nuevas (solo Pagos): texto | numero | fecha | casilla | opcion |
--        link. Borrar = archivar: el dato queda.
--   2. fin_pagos_extra: valores de las columnas nuevas, por CLAVE del pago
--      (062), no por fila. Las filas de la planilla se recrean cada 15 min
--      pero su clave no cambia: asi las columnas nuevas sirven tambien
--      para pagos de la planilla. Se escribe de a una clave por vez.
--   3. fin_v_pagos_extra_huerfanos: valores cuyo pago ya no existe (se
--      corrigio en el Sheet o se anulo).
--   4. fin_pagos.editado_por / editado_en.
--   5. Funciones:
--        fin_columnas_de(cliente, vista) -> jsonb  (lectura: lo que pinta
--          la app, con el orden de hoy x 10 para lo no guardado)
--        fin_columna_guardar(cliente, vista, clave, etiqueta, visible, opciones)
--        fin_columna_crear(cliente, etiqueta, tipo, opciones) -> clave
--        fin_columnas_ordenar(cliente, vista, claves[])
--        fin_columna_archivar(cliente, clave, archivar)
--        fin_columna_opcion_renombrar(cliente, clave, viejo, nuevo)
--        fin_pago_extra_guardar(cliente, clave_pago, columna, valor)
--          fundador, cliente y closers/setters del cliente
--        fin_pago_editar(clave_pago, campo, valor)
--          fundador y cliente, SOLO filas 'app'. Nunca monto, tc, clave.
--          Fecha, closer y setter bloqueados si el pago esta en una
--          liquidacion cerrada.
--
-- No toca: pagos existentes, P&L, comisiones, la sync.
-- Se puede correr dos veces.
-- =====================================================================

begin;
set local lock_timeout = '8s';
lock table public.fin_pagos in access exclusive mode;

-- =====================================================================
-- 1. Columnas del sistema por vista (orden de hoy)
-- =====================================================================
create or replace function public.fin_columnas_sistema(p_vista text)
returns text[]
language sql immutable set search_path = public
as $$
  select case p_vista
    when 'pagos' then array['fecha', 'alumno', 'telefono', 'programa', 'concepto', 'monto_usd',
                            'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante',
                            'nota', 'origen', 'fila_planilla']
    when 'pnl' then array['revenue_declarado', 'ingreso_real', 'staff', 'softwares', 'others',
                          'sin_categoria', 'gastos_total', 'net_cash_flow', 'dividends_released',
                          'opening_balance', 'closing_balance']
    when 'resumen' then array['ingreso_real', 'revenue_declarado', 'diferencia', 'gastos_total',
                              'net_cash_flow', 'cantidad_pagos', 'sincronizacion']
    when 'conciliacion' then array['mes', 'revenue_opps', 'revenue_pagos', 'cantidad_pagos',
                                   'diferencia', 'diferencia_pct']
  end;
$$;

-- Ocultas por defecto (existen pero hoy no se muestran).
create or replace function public.fin_columnas_ocultas_por_defecto(p_vista text)
returns text[]
language sql immutable set search_path = public
as $$
  select case p_vista when 'pagos' then array['telefono', 'nota'] else array[]::text[] end;
$$;

-- =====================================================================
-- 2. Tablas
-- =====================================================================
create table if not exists public.fin_columnas (
  id          bigint generated always as identity primary key,
  cliente_id  text references public.crm_clients(id),
  vista       text    not null,
  clave       text    not null,
  sistema     boolean not null,
  etiqueta    text,
  orden       integer,
  visible     boolean not null default true,
  tipo        text,
  opciones    jsonb   not null default '[]'::jsonb,
  archivada   boolean not null default false,
  creado_en   timestamptz not null default now(),
  creado_por  uuid,
  constraint fin_columnas_vista_ck check (vista in ('pagos', 'pnl', 'resumen', 'conciliacion')),
  constraint fin_columnas_global_ck check (
    (vista in ('resumen', 'conciliacion')) = (cliente_id is null)),
  constraint fin_columnas_tipo_ck check (
    (sistema and tipo is null) or
    (not sistema and vista = 'pagos' and tipo in ('texto', 'numero', 'fecha', 'casilla', 'opcion', 'link'))),
  constraint fin_columnas_etiqueta_ck check (etiqueta is null or char_length(btrim(etiqueta)) between 1 and 60)
);

create unique index if not exists fin_columnas_uq
  on public.fin_columnas (coalesce(cliente_id, '*'), vista, clave);

comment on table public.fin_columnas is
  '072: columnas configurables de Finanzas. Del sistema: solo etiqueta/orden/visible. Nuevas: solo en Pagos, por cliente.';

create table if not exists public.fin_pagos_extra (
  cliente_id     text  not null references public.crm_clients(id),
  clave          text  not null,
  valores        jsonb not null default '{}'::jsonb,
  actualizado_en timestamptz not null default now(),
  actualizado_por uuid,
  primary key (cliente_id, clave)
);

comment on table public.fin_pagos_extra is
  '072: valores de las columnas nuevas de Pagos, por clave del pago (no por fila: la sync recrea las filas).';

alter table public.fin_pagos
  add column if not exists editado_por uuid,
  add column if not exists editado_en  timestamptz;

-- RLS: lectura igual que lo que cada uno ya ve; escritura solo por funciones.
alter table public.fin_columnas enable row level security;
drop policy if exists fin_columnas_lectura on public.fin_columnas;
create policy fin_columnas_lectura on public.fin_columnas for select to authenticated
  using (cliente_id is null or public.es_fundador() or public.tiene_acceso(cliente_id)
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = fin_columnas.cliente_id));
revoke all on public.fin_columnas from anon, authenticated;
grant select on public.fin_columnas to authenticated;
grant all on public.fin_columnas to service_role;

alter table public.fin_pagos_extra enable row level security;
drop policy if exists fin_pagos_extra_lectura on public.fin_pagos_extra;
create policy fin_pagos_extra_lectura on public.fin_pagos_extra for select to authenticated
  using (public.es_fundador() or public.tiene_acceso(cliente_id)
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = fin_pagos_extra.cliente_id));
revoke all on public.fin_pagos_extra from anon, authenticated;
grant select on public.fin_pagos_extra to authenticated;
grant all on public.fin_pagos_extra to service_role;

-- =====================================================================
-- 3. Huerfanos
-- =====================================================================
create or replace view public.fin_v_pagos_extra_huerfanos
with (security_invoker = true) as
select e.cliente_id, e.clave, e.valores, e.actualizado_en,
       exists (select 1 from public.fin_pagos_anulados a where a.clave = e.clave) as anulado
from public.fin_pagos_extra e
where not exists (select 1 from public.fin_pagos p where p.cliente_id = e.cliente_id and p.clave = e.clave);

revoke all on public.fin_v_pagos_extra_huerfanos from anon;
grant select on public.fin_v_pagos_extra_huerfanos to authenticated;
grant all on public.fin_v_pagos_extra_huerfanos to service_role;

-- =====================================================================
-- 4. Lectura: lo que pinta la app
-- =====================================================================
-- Columnas del sistema sin fila guardada: orden = posicion de hoy x 10
-- (si no, una columna nueva aparece antes que la primera).
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
         or exists (select 1 from public.fin_personas p where p.user_id = auth.uid() and p.cliente_id = p_cliente));
$$;

-- =====================================================================
-- 5. Estructura (solo fundador)
-- =====================================================================
create or replace function public.fin_columnas_exigir_fundador()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'fin: solo un fundador cambia las columnas' using errcode = '42501';
  end if;
end;
$$;

create or replace function public.fin_columnas_cliente_ok(p_cliente text, p_vista text)
returns text
language plpgsql stable set search_path = public
as $$
begin
  if public.fin_columnas_sistema(p_vista) is null then
    raise exception 'fin: vista invalida (%)', p_vista using errcode = '22023';
  end if;
  if p_vista in ('resumen', 'conciliacion') then
    return null;
  end if;
  if p_cliente is null or not exists (select 1 from public.crm_clients where id = p_cliente) then
    raise exception 'fin: el cliente % no existe', p_cliente using errcode = 'P0002';
  end if;
  return p_cliente;
end;
$$;

create or replace function public.fin_columnas_opciones_limpias(p jsonb)
returns jsonb
language plpgsql immutable set search_path = public
as $$
declare v jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'fin: las opciones van como lista' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(o order by n), '[]'::jsonb) into v
  from (select btrim(e) as o, min(ord) as n
          from jsonb_array_elements_text(p) with ordinality as t(e, ord)
         where btrim(e) <> '' group by btrim(e)) x;
  if jsonb_array_length(v) > 50 then
    raise exception 'fin: hasta 50 opciones por columna' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements_text(v) e where char_length(e) > 60) then
    raise exception 'fin: cada opcion tiene hasta 60 caracteres' using errcode = '22023';
  end if;
  return v;
end;
$$;

-- Renombrar / mostrar u ocultar / opciones (sistema o nuevas).
-- etiqueta null = nombre por defecto. opciones null = no tocar.
create or replace function public.fin_columna_guardar(
  p_cliente text, p_vista text, p_clave text, p_etiqueta text, p_visible boolean, p_opciones jsonb default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_cli text;
  v_sis boolean;
  v_col public.fin_columnas%rowtype;
begin
  perform public.fin_columnas_exigir_fundador();
  v_cli := public.fin_columnas_cliente_ok(p_cliente, p_vista);
  v_sis := p_clave = any (public.fin_columnas_sistema(p_vista));
  if p_vista = 'pagos' and p_clave = 'alumno' and p_visible is false then
    raise exception 'fin: la columna Alumno no se oculta' using errcode = '22023';
  end if;

  if v_sis then
    insert into public.fin_columnas (cliente_id, vista, clave, sistema, etiqueta, visible, creado_por)
    values (v_cli, p_vista, p_clave, true, nullif(btrim(p_etiqueta), ''), coalesce(p_visible, true), auth.uid())
    on conflict (coalesce(cliente_id, '*'), vista, clave) do update
      set etiqueta = excluded.etiqueta, visible = excluded.visible;
    return;
  end if;

  select * into v_col from public.fin_columnas
   where coalesce(cliente_id, '*') = coalesce(v_cli, '*') and vista = p_vista and clave = p_clave and not sistema;
  if not found then
    raise exception 'fin: la columna % no existe para %', p_clave, coalesce(v_cli, 'todos') using errcode = 'P0002';
  end if;
  if nullif(btrim(p_etiqueta), '') is null then
    raise exception 'fin: una columna nueva necesita nombre' using errcode = '22023';
  end if;
  update public.fin_columnas
     set etiqueta = btrim(p_etiqueta),
         visible  = coalesce(p_visible, visible),
         opciones = case when p_opciones is null or tipo <> 'opcion' then opciones
                         else public.fin_columnas_opciones_limpias(p_opciones) end
   where id = v_col.id;
end;
$$;

create or replace function public.fin_columna_crear(
  p_cliente text, p_etiqueta text, p_tipo text, p_opciones jsonb default '[]'::jsonb)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  v_cli   text;
  v_slug  text;
  v_clave text;
  v_orden int;
begin
  perform public.fin_columnas_exigir_fundador();
  v_cli := public.fin_columnas_cliente_ok(p_cliente, 'pagos');
  if nullif(btrim(p_etiqueta), '') is null then
    raise exception 'fin: la columna necesita nombre' using errcode = '22023';
  end if;
  if p_tipo is null or p_tipo not in ('texto', 'numero', 'fecha', 'casilla', 'opcion', 'link') then
    raise exception 'fin: tipo de columna invalido (%)', p_tipo using errcode = '22023';
  end if;
  v_slug := left(trim(both '_' from regexp_replace(
              translate(lower(btrim(p_etiqueta)), 'áéíóúüñ', 'aeiouun'), '[^a-z0-9]+', '_', 'g')), 30);
  if v_slug = '' then v_slug := 'col'; end if;
  v_clave := 'x_' || v_slug || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);
  select greatest(coalesce(max(orden), 0), cardinality(public.fin_columnas_sistema('pagos')) * 10) + 10
    into v_orden from public.fin_columnas where cliente_id = v_cli and vista = 'pagos';
  insert into public.fin_columnas (cliente_id, vista, clave, sistema, etiqueta, orden, visible, tipo, opciones, creado_por)
  values (v_cli, 'pagos', v_clave, false, btrim(p_etiqueta), v_orden, true, p_tipo,
          case when p_tipo = 'opcion' then public.fin_columnas_opciones_limpias(coalesce(p_opciones, '[]'::jsonb))
               else '[]'::jsonb end,
          auth.uid());
  return v_clave;
end;
$$;

-- Orden completo: la lista de claves en el orden nuevo (x 10).
create or replace function public.fin_columnas_ordenar(p_cliente text, p_vista text, p_claves text[])
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_cli text;
  v_mal text;
  i int;
begin
  perform public.fin_columnas_exigir_fundador();
  v_cli := public.fin_columnas_cliente_ok(p_cliente, p_vista);
  if p_claves is null or cardinality(p_claves) = 0 then
    raise exception 'fin: falta el orden de las columnas' using errcode = '22023';
  end if;
  if cardinality(p_claves) <> (select count(distinct c) from unnest(p_claves) c) then
    raise exception 'fin: hay columnas repetidas en el orden' using errcode = '22023';
  end if;
  select c into v_mal from unnest(p_claves) c
   where not (c = any (public.fin_columnas_sistema(p_vista)))
     and not exists (select 1 from public.fin_columnas f
                      where coalesce(f.cliente_id, '*') = coalesce(v_cli, '*') and f.vista = p_vista and f.clave = c)
   limit 1;
  if v_mal is not null then
    raise exception 'fin: la columna % no existe', v_mal using errcode = 'P0002';
  end if;
  for i in 1 .. cardinality(p_claves) loop
    insert into public.fin_columnas (cliente_id, vista, clave, sistema, orden, visible, creado_por)
    values (v_cli, p_vista, p_claves[i], true, i * 10,
            not (p_claves[i] = any (public.fin_columnas_ocultas_por_defecto(p_vista))), auth.uid())
    on conflict (coalesce(cliente_id, '*'), vista, clave) do update set orden = i * 10;
  end loop;
end;
$$;

create or replace function public.fin_columna_archivar(p_cliente text, p_clave text, p_archivar boolean default true)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform public.fin_columnas_exigir_fundador();
  update public.fin_columnas set archivada = coalesce(p_archivar, true)
   where cliente_id = p_cliente and vista = 'pagos' and clave = p_clave and not sistema;
  if not found then
    raise exception 'fin: solo se archivan columnas nuevas (las del sistema se ocultan)' using errcode = '22023';
  end if;
end;
$$;

-- Renombra la opcion Y los valores ya cargados.
create or replace function public.fin_columna_opcion_renombrar(p_cliente text, p_clave text, p_viejo text, p_nuevo text)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_col public.fin_columnas%rowtype;
  v_n   int;
begin
  perform public.fin_columnas_exigir_fundador();
  select * into v_col from public.fin_columnas
   where cliente_id = p_cliente and vista = 'pagos' and clave = p_clave and tipo = 'opcion';
  if not found then
    raise exception 'fin: % no es una columna de opciones', p_clave using errcode = 'P0002';
  end if;
  if nullif(btrim(p_nuevo), '') is null then
    raise exception 'fin: la opcion necesita nombre' using errcode = '22023';
  end if;
  if not (v_col.opciones ? p_viejo) then
    raise exception 'fin: la opcion "%" no existe', p_viejo using errcode = 'P0002';
  end if;
  if btrim(p_nuevo) <> p_viejo and v_col.opciones ? btrim(p_nuevo) then
    raise exception 'fin: ya existe la opcion "%"', btrim(p_nuevo) using errcode = '22023';
  end if;
  update public.fin_columnas
     set opciones = (select jsonb_agg(case when e = p_viejo then btrim(p_nuevo) else e end order by n)
                       from jsonb_array_elements_text(opciones) with ordinality as t(e, n))
   where id = v_col.id;
  update public.fin_pagos_extra
     set valores = jsonb_set(valores, array[p_clave], to_jsonb(btrim(p_nuevo))),
         actualizado_en = now(), actualizado_por = auth.uid()
   where cliente_id = p_cliente and valores ->> p_clave = p_viejo;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- =====================================================================
-- 6. Valores
-- =====================================================================
-- Columnas nuevas: fundador, cliente y closers/setters del cliente.
-- valor null o texto vacio = borrar el valor.
create or replace function public.fin_pago_extra_guardar(p_cliente text, p_clave_pago text, p_columna text, p_valor jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col public.fin_columnas%rowtype;
  v jsonb := p_valor;
begin
  if not public.fin_puede_cargar(p_cliente) then
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

-- Columnas del sistema: solo filas 'app', solo fundador y cliente.
create or replace function public.fin_pago_editar(p_clave_pago text, p_campo text, p_valor text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v       public.fin_pagos%rowtype;
  v_hoy   date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_txt   text := nullif(btrim(p_valor), '');
  v_id    bigint;
  v_valor text;
  v_alias text;
  v_dim   text;
begin
  select * into v from public.fin_pagos where clave = p_clave_pago;
  if not found then
    raise exception 'fin: el pago no existe' using errcode = 'P0002';
  end if;
  if not public.fin_puede_anular(v.cliente_id) then
    raise exception 'fin: solo un fundador o el cliente edita pagos' using errcode = '42501';
  end if;
  if v.origen <> 'app' then
    raise exception 'fin: este pago viene de la planilla; se corrige en el Sheet' using errcode = '22023';
  end if;
  if p_campo in ('monto_usd', 'tc_usado', 'clave', 'cliente_id', 'origen', 'fila_planilla') then
    raise exception 'fin: % no se edita a mano (para el monto: anular y recargar, o devolver)', p_campo using errcode = '22023';
  end if;
  if v.pago_original_clave is not null and p_campo not in ('nota', 'comprobante') then
    raise exception 'fin: en una devolucion solo se editan la nota y el comprobante' using errcode = '22023';
  end if;
  if p_campo in ('fecha', 'closer', 'setter') and exists (
       select 1 from public.fin_liquidacion_items i join public.fin_liquidaciones l on l.id = i.liquidacion_id
        where l.estado = 'cerrada' and i.pago_clave = v.clave) then
    raise exception 'fin: este pago esta en una liquidacion cerrada; % ya no se cambia', p_campo using errcode = '22023';
  end if;

  case p_campo
    when 'fecha' then
      begin
        if v_txt is null or v_txt::date > v_hoy or v_txt::date < date '2024-01-01' then
          raise exception 'x';
        end if;
      exception when others then
        raise exception 'fin: fecha invalida (no puede ser futura ni anterior a 2024)' using errcode = '22023';
      end;
      update public.fin_pagos set fecha = v_txt::date where id = v.id;
    when 'alumno' then
      if v_txt is null then raise exception 'fin: el alumno no puede quedar vacio' using errcode = '22023'; end if;
      update public.fin_pagos set alumno = v_txt where id = v.id;
    when 'telefono' then
      update public.fin_pagos set telefono = v_txt where id = v.id;
    when 'nota' then
      update public.fin_pagos set nota = v_txt where id = v.id;
    when 'comprobante' then
      if v_txt is not null and v_txt !~* '^https?://' then
        raise exception 'fin: el comprobante tiene que ser un link (https://...)' using errcode = '22023';
      end if;
      update public.fin_pagos set comprobante = v_txt where id = v.id;
    when 'programa', 'concepto', 'metodo_pago', 'quien_recibe' then
      v_dim := p_campo;
      if v_txt is null and p_campo = 'quien_recibe' then
        update public.fin_pagos set quien_recibe = null, quien_recibe_id = null where id = v.id;
      else
        if v_txt !~ '^\d+$' then
          raise exception 'fin: valor de % invalido para %', p_campo, v.cliente_id using errcode = '22023';
        end if;
        select id, valor into v_id, v_valor from public.fin_catalogos
         where id = v_txt::bigint and cliente_id = v.cliente_id and dimension = v_dim and activo;
        if v_id is null then
          raise exception 'fin: valor de % invalido para %', p_campo, v.cliente_id using errcode = '22023';
        end if;
        if p_campo = 'concepto' and v_valor = 'REFUND' then
          raise exception 'fin: REFUND solo se carga con "Devolver"' using errcode = '22023';
        end if;
        case p_campo
          when 'programa'     then update public.fin_pagos set programa = v_valor, programa_id = v_id where id = v.id;
          when 'concepto'     then update public.fin_pagos set concepto = v_valor, concepto_id = v_id where id = v.id;
          when 'metodo_pago'  then update public.fin_pagos set metodo_pago = v_valor, metodo_pago_id = v_id where id = v.id;
          when 'quien_recibe' then update public.fin_pagos set quien_recibe = v_valor, quien_recibe_id = v_id where id = v.id;
        end case;
      end if;
    when 'closer', 'setter' then
      if v_txt is null then
        v_alias := null;
      elsif v_txt !~ '^\d+$' then
        raise exception 'fin: % invalido', p_campo using errcode = '22023';
      else
        select coalesce(
                 (select x.alias from public.fin_personas x where x.vendedor_id = a.vendedor_id and x.cliente_id = v.cliente_id order by x.id limit 1),
                 (select x.alias from public.fin_personas x where x.vendedor_id = a.vendedor_id and x.cliente_id is null order by x.id limit 1))
          into v_alias
          from public.fin_vendedor_asignaciones a
         where a.vendedor_id = v_txt::bigint and a.cliente_id = v.cliente_id
           and ((p_campo = 'closer' and a.es_closer) or (p_campo = 'setter' and a.es_setter))
         limit 1;
        if v_alias is null then
          raise exception 'fin: ese % no esta asignado a % o no tiene alias', p_campo, v.cliente_id using errcode = '22023';
        end if;
      end if;
      if p_campo = 'closer' then
        update public.fin_pagos set closer = v_alias where id = v.id;
      else
        update public.fin_pagos set setter = v_alias where id = v.id;
      end if;
    else
      raise exception 'fin: el campo % no existe', p_campo using errcode = '22023';
  end case;

  update public.fin_pagos set editado_por = auth.uid(), editado_en = now() where id = v.id;
  return jsonb_build_object('ok', true, 'clave', v.clave);
end;
$fn$;

-- =====================================================================
-- 7. Permisos
-- =====================================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public.fin_columnas_de(text,text)',
    'public.fin_columna_guardar(text,text,text,text,boolean,jsonb)',
    'public.fin_columna_crear(text,text,text,jsonb)',
    'public.fin_columnas_ordenar(text,text,text[])',
    'public.fin_columna_archivar(text,text,boolean)',
    'public.fin_columna_opcion_renombrar(text,text,text,text)',
    'public.fin_pago_extra_guardar(text,text,text,jsonb)',
    'public.fin_pago_editar(text,text,text)']
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  foreach f in array array['public.fin_columnas_exigir_fundador()',
                           'public.fin_columnas_cliente_ok(text,text)',
                           'public.fin_columnas_opciones_limpias(jsonb)']
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- 8. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
do $humo$
declare
  v_k    text;
  v_j    jsonb;
  v_n    int;
  v_pago text;
  v_app  text;
  v_err  text;
  v_cat  bigint;
begin
  begin
    perform set_config('request.jwt.claim.sub',
      (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);

    -- 1. sin nada guardado: Pagos de liam = 14 del sistema, orden x10, alumno visible
    v_j := public.fin_columnas_de('liam', 'pagos');
    if jsonb_array_length(v_j) <> 14 or (v_j -> 0 ->> 'orden')::int <> 10 then
      raise exception 'humo 1: columnas por defecto %', jsonb_array_length(v_j);
    end if;

    -- 2. renombrar y ocultar del sistema; alumno no se oculta
    perform public.fin_columna_guardar('liam', 'pagos', 'quien_recibe', 'Cuenta', false);
    v_j := public.fin_columnas_de('liam', 'pagos');
    if not exists (select 1 from jsonb_array_elements(v_j) e
                    where e ->> 'clave' = 'quien_recibe' and e ->> 'etiqueta' = 'Cuenta' and not (e ->> 'visible')::boolean) then
      raise exception 'humo 2: renombrar/ocultar';
    end if;
    begin
      perform public.fin_columna_guardar('liam', 'pagos', 'alumno', null, false);
      raise exception 'humo 3: dejo ocultar alumno';
    exception when invalid_parameter_value then null;
    end;

    -- 3. columna nueva de opciones, despues de la ultima del sistema
    v_k := public.fin_columna_crear('liam', 'Factura emitida', 'opcion', '["Si","No"," Si "]'::jsonb);
    if v_k !~ '^x_factura_emitida_[0-9a-f]{4}$' then raise exception 'humo 4: clave %', v_k; end if;
    select orden into v_n from public.fin_columnas where cliente_id = 'liam' and clave = v_k;
    if v_n <= 140 then raise exception 'humo 5: la nueva quedo antes que las del sistema (orden %)', v_n; end if;
    -- teo no la ve
    if exists (select 1 from jsonb_array_elements(public.fin_columnas_de('teo', 'pagos')) e where e ->> 'clave' = v_k) then
      raise exception 'humo 6: teo ve la columna de liam';
    end if;

    -- 4. valor en un pago de la PLANILLA (por clave) y renombrar la opcion
    select clave into v_pago from public.fin_pagos where cliente_id = 'liam' order by id limit 1;
    perform public.fin_pago_extra_guardar('liam', v_pago, v_k, '"Si"'::jsonb);
    begin
      perform public.fin_pago_extra_guardar('liam', v_pago, v_k, '"Tal vez"'::jsonb);
      raise exception 'humo 7: acepto una opcion inexistente';
    exception when invalid_parameter_value then null;
    end;
    perform public.fin_columna_opcion_renombrar('liam', v_k, 'Si', 'Emitida');
    select valores ->> v_k into v_err from public.fin_pagos_extra where cliente_id = 'liam' and clave = v_pago;
    if v_err is distinct from 'Emitida' then raise exception 'humo 8: renombrar no arrastro el valor (%)', v_err; end if;

    -- 5. ordenar: alumno primero
    perform public.fin_columnas_ordenar('liam', 'pagos', array['alumno', 'fecha']);
    if (public.fin_columnas_de('liam', 'pagos') -> 0 ->> 'clave') <> 'alumno' then
      raise exception 'humo 9: ordenar';
    end if;

    -- 6. editar: una fila de la planilla no se edita; una 'app' si; monto nunca
    begin
      perform public.fin_pago_editar(v_pago, 'alumno', 'Otro');
      raise exception 'humo 10: edito una fila de la planilla';
    exception when invalid_parameter_value then null;
    end;
    insert into public.fin_pagos (cliente_id, fuente_id, origen, fecha, alumno, concepto, monto_usd, monto_origen,
                                  moneda_origen, creado_por, creado_en)
    select 'liam', f.id, 'app', current_date - 1, 'Humo 072', 'PIF', 100, 100, 'USD', auth.uid(), now()
      from public.fin_fuentes f where f.cliente_id = 'liam' and f.tipo = 'pagos' limit 1
    returning clave into v_app;
    perform public.fin_pago_editar(v_app, 'alumno', 'Humo 072 editado');
    select id into v_cat from public.fin_catalogos where cliente_id = 'liam' and dimension = 'concepto' and valor = 'FEE';
    perform public.fin_pago_editar(v_app, 'concepto', v_cat::text);
    if not exists (select 1 from public.fin_pagos where clave = v_app and alumno = 'Humo 072 editado'
                     and concepto = 'FEE' and editado_por is not null) then
      raise exception 'humo 11: editar fila app';
    end if;
    begin
      perform public.fin_pago_editar(v_app, 'monto_usd', '999');
      raise exception 'humo 12: dejo editar el monto';
    exception when invalid_parameter_value then null;
    end;
    if not exists (select 1 from public.fin_pagos where clave = v_app) then
      raise exception 'humo 13: la clave cambio al editar';
    end if;

    -- 7. un no fundador no cambia estructura
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000dead', true);
    begin
      perform public.fin_columna_crear('liam', 'Intruso', 'texto');
      raise exception 'humo 14: un no fundador creo una columna';
    exception when insufficient_privilege then null;
    end;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '072 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;

-- =====================================================================
-- 9. CONTROLES (correr de a uno, despues del Success)
-- =====================================================================
-- C1. Lo nuevo existe. Tiene que dar 1 | 1 | 2 | 8 | 14.
-- select (select count(*) from information_schema.tables where table_name = 'fin_columnas') as columnas,
--        (select count(*) from information_schema.tables where table_name = 'fin_pagos_extra') as extra,
--        (select count(*) from information_schema.columns where table_name = 'fin_pagos'
--           and column_name in ('editado_por', 'editado_en')) as auditoria,
--        (select count(*) from pg_proc where proname in ('fin_columnas_de', 'fin_columna_guardar',
--           'fin_columna_crear', 'fin_columnas_ordenar', 'fin_columna_archivar',
--           'fin_columna_opcion_renombrar', 'fin_pago_extra_guardar', 'fin_pago_editar')) as funciones,
--        cardinality(public.fin_columnas_sistema('pagos')) as columnas_pagos;

-- C2. Nada cambio para la app: 0 configuradas, 0 valores extra y los
--     pagos igual que antes (~1.621). Tiene que dar 0 | 0 | 1621 aprox.
-- select (select count(*) from public.fin_columnas) as configuradas,
--        (select count(*) from public.fin_pagos_extra) as extras,
--        (select count(*) from public.fin_pagos) as pagos;

-- C3. Lo que pintaria la app para Pagos de liam: 14 columnas, orden 10 a
--     140, telefono y nota ocultas. (Las dos sentencias juntas: la primera
--     se hace pasar por el fundador solo durante esta ejecucion.)
-- select set_config('request.jwt.claim.sub',
--   (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);
-- select e ->> 'clave' as clave, (e ->> 'orden')::int as orden, e ->> 'visible' as visible
--   from jsonb_array_elements(public.fin_columnas_de('liam', 'pagos')) e;
