-- =====================================================================
-- 073_ventas_columnas_data.sql  ·  VENTAS: columnas configurables de Data
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion).
-- Numeracion global, compartida con CRM, Finanzas y Producto.
-- Evitar :00, :15, :30 y :45 y las 9:00 (la sync escribe fin_llamadas).
--
-- Mismo patron que la 071 de Producto, adaptado a la hoja Data.
-- Independiente de la 072 (Finanzas): no usa ni pisa nada de ella, se
-- puede correr antes o despues.
--
-- Decisiones (03/10):
--   - Cambia la estructura SOLO un fundador. El resto edita valores.
--   - Una configuracion por cliente, igual para todos los usuarios.
--   - Columnas nuevas por cliente. Solo liam, lucas y teo (mauro no).
--   - Editan valores: el fundador (todo) y el closer en sus llamadas
--     (todo menos el closer). El cliente y el setter no editan.
--   - Opciones de estado, show up y calificacion: no se renombran desde
--     la grilla (la 058 y las metricas buscan esos textos exactos).
--   - Closer: solo un alias de fin_personas del cliente.
--
-- La regla que manda: una fila con origen 'sheet' de una fuente que NO
-- esta cortada no se edita. La sync la borra y la vuelve a crear cada
-- 15 min (con otro id), asi que cualquier cambio duraria 15 min. Hoy son
-- TODAS las filas: esta migracion deja la estructura lista y la edicion
-- probada, pero no habilita ninguna fila. Se habilitan solas cuando una
-- fuente se corta o cuando entren filas 'ghl' o 'app'.
--
-- Que hace:
--   1. fin_data_columnas: una fila por columna que se toco.
--        Del sistema (las 18 de la grilla): solo etiqueta, orden y si se
--        muestra. La clave interna no cambia. Se ocultan, no se borran.
--        "nombre" y "fecha_llamada" no se ocultan.
--        Nuevas: texto | numero | fecha | casilla | opcion | link.
--        Borrar = archivar: el dato queda.
--   2. fin_llamadas.campos_extra (jsonb): valores de las columnas nuevas.
--      La sync no la nombra en su insert, asi que entra con el default
--      (y el trigger de la 059 la blinda contra un NULL).
--   3. Funciones:
--        fin_data_columnas_de(cliente) -> jsonb   lo que pinta la app
--        fin_data_permisos(cliente)    -> jsonb   que puede hacer cada uno
--        fin_data_columna_guardar(cliente, clave, etiqueta, visible, opciones)
--        fin_data_columna_crear(cliente, etiqueta, tipo, opciones) -> clave
--        fin_data_columnas_ordenar(cliente, claves[])
--        fin_data_columna_archivar(cliente, clave, archivar)
--        fin_data_opcion_renombrar(cliente, clave, viejo, nuevo)  solo nuevas
--        fin_data_guardar(llamada, clave, valor text)    columnas del sistema
--        fin_data_guardar_extra(llamada, clave, valor jsonb)  columnas nuevas
--
-- No toca: datos de llamadas, la sync, las vistas de metricas, fin_catalogos.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- Lock al principio: fin_llamadas recibe un ALTER y la sync la escribe.
lock table public.fin_llamadas in access exclusive mode;


-- =====================================================================
-- 1. CLAVES DEL SISTEMA (las columnas de la grilla Data, en su orden)
-- =====================================================================
create or replace function public.fin_data_claves_sistema()
returns text[]
language sql immutable parallel safe set search_path = public
as $$
  select array[
    'fecha_llamada', 'hora_llamada', 'nombre', 'closer', 'tipo_booking', 'show_up',
    'calificacion', 'estado_llamada', 'programa', 'cc_dia1', 'cc_cerrado',
    'cc_seguimiento', 'monto_restante', 'telefono', 'instagram', 'email',
    'contexto_setter', 'contexto_closer'
  ]::text[]
$$;

create or replace function public.fin_data_etiqueta_defecto(p_clave text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select case p_clave
    when 'fecha_llamada'   then 'Fecha'
    when 'hora_llamada'    then 'Hora'
    when 'nombre'          then 'Nombre'
    when 'closer'          then 'Closer'
    when 'tipo_booking'    then 'Fuente'
    when 'show_up'         then 'Show up'
    when 'calificacion'    then 'Calificación'
    when 'estado_llamada'  then 'Estado'
    when 'programa'        then 'Programa'
    when 'cc_dia1'         then 'CC día 1'
    when 'cc_cerrado'      then 'CC cerrado'
    when 'cc_seguimiento'  then 'CC seguimiento'
    when 'monto_restante'  then 'Monto restante'
    when 'telefono'        then 'Teléfono'
    when 'instagram'       then 'Instagram'
    when 'email'           then 'Email'
    when 'contexto_setter' then 'Contexto setter'
    when 'contexto_closer' then 'Contexto closer'
  end
$$;


-- =====================================================================
-- 2. CONFIGURACION DE COLUMNAS
-- =====================================================================
create table if not exists public.fin_data_columnas (
  id          bigint generated always as identity primary key,
  cliente_id  text    not null references public.crm_clients(id),
  clave       text    not null check (clave ~ '^[a-z][a-z0-9_]{0,62}$'),
  sistema     boolean not null,
  etiqueta    text    check (etiqueta is null or (btrim(etiqueta) <> '' and char_length(etiqueta) <= 60)),
  orden       int,
  visible     boolean not null default true,
  tipo        text    check (tipo is null or tipo in ('texto','numero','fecha','casilla','opcion','link')),
  opciones    jsonb   not null default '[]'::jsonb check (jsonb_typeof(opciones) = 'array'),
  archivada   boolean not null default false,
  creado_en   timestamptz not null default now(),
  creado_por  uuid,
  updated_at  timestamptz not null default now(),
  constraint fin_data_columnas_uq unique (cliente_id, clave),
  constraint fin_data_columnas_sistema_ck check (
    (sistema and tipo is null and not archivada and clave = any (public.fin_data_claves_sistema()))
    or (not sistema and tipo is not null and clave like 'x\_%' and etiqueta is not null)),
  constraint fin_data_columnas_fijas_ck check (clave not in ('nombre', 'fecha_llamada') or visible),
  constraint fin_data_columnas_opciones_ck check (tipo = 'opcion' or opciones = '[]'::jsonb)
);

comment on table public.fin_data_columnas is
  '073: columnas de la grilla Data (Ventas) por cliente. Del sistema: etiqueta/orden/visible. Nuevas: con tipo. Escribe solo fundador, por funciones.';

alter table public.fin_data_columnas enable row level security;
revoke all on table public.fin_data_columnas from anon;
revoke insert, update, delete on table public.fin_data_columnas from authenticated;
grant select on table public.fin_data_columnas to authenticated;

-- Lectura: los mismos que ven las llamadas del cliente.
drop policy if exists fin_data_columnas_lectura on public.fin_data_columnas;
create policy fin_data_columnas_lectura on public.fin_data_columnas
  for select using (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id))
    or exists (select 1 from public.fin_personas p
               where p.user_id = auth.uid() and p.cliente_id = fin_data_columnas.cliente_id)
  );


-- =====================================================================
-- 3. VALORES DE LAS COLUMNAS NUEVAS
-- =====================================================================
alter table public.fin_llamadas
  add column if not exists campos_extra jsonb not null default '{}'::jsonb;

alter table public.fin_llamadas drop constraint if exists fin_llamadas_campos_extra_ck;
alter table public.fin_llamadas add constraint fin_llamadas_campos_extra_ck
  check (jsonb_typeof(campos_extra) = 'object');

comment on column public.fin_llamadas.campos_extra is
  '073: valores de las columnas nuevas de la grilla Data, {clave: valor}. En filas sheet de fuentes activas se pierde en la sync siguiente: por eso no se editan.';

-- El trigger de defaults de la 059, ahora tambien con campos_extra.
create or replace function public.fin_llamadas_defaults()
returns trigger language plpgsql as $$
begin
  new.origen         := coalesce(new.origen, 'sheet');
  new.formulario     := coalesce(new.formulario, '{}'::jsonb);
  new.campos_extra   := coalesce(new.campos_extra, '{}'::jsonb);
  new.actualizado_en := coalesce(new.actualizado_en, now());
  return new;
end $$;


-- =====================================================================
-- 4. REGLAS (quien, donde)
-- =====================================================================
-- Clientes con hoja Data: los unicos que tienen grilla.
create or replace function public.fin_data_cliente_ok(p_cliente text)
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if p_cliente is null or not exists (
       select 1 from public.fin_fuentes where cliente_id = p_cliente and tipo = 'data') then
    raise exception 'ventas: % no tiene hoja Data', coalesce(p_cliente, '(vacio)') using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.fin_data_exigir_fundador()
returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'ventas: solo un fundador cambia las columnas' using errcode = '42501';
  end if;
end;
$$;

-- Clientes que aceptan columnas nuevas (decision 03/10: mauro no).
create or replace function public.fin_data_admite_nuevas(p_cliente text)
returns boolean
language sql immutable parallel safe set search_path = public
as $$ select p_cliente in ('liam', 'lucas', 'teo') $$;

-- Una fila se puede editar si no la va a pisar la sync.
create or replace function public.fin_data_fila_editable(p_origen text, p_fuente_id bigint)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(p_origen, 'sheet') <> 'sheet'
      or exists (select 1 from public.fin_fuentes f
                 where f.id = p_fuente_id and f.cortada_en is not null)
$$;

-- Es el closer de esa llamada (misma regla que la RLS de lectura, 029).
create or replace function public.fin_data_es_su_llamada(p_cliente text, p_closer text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.rol_actual() = 'closer' and exists (
    select 1 from public.fin_personas p
    where p.user_id = auth.uid()
      and p.campo in ('closer', 'ambos')
      and p.cliente_id = p_cliente
      and lower(btrim(p.alias)) = lower(btrim(p_closer)))
$$;

-- Opciones de columnas nuevas: lista de textos, sin vacios ni repetidos.
create or replace function public.fin_data_opciones_limpias(p jsonb)
returns jsonb
language plpgsql immutable set search_path = public
as $$
declare
  v jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    raise exception 'ventas: las opciones van como lista' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(o order by n), '[]'::jsonb) into v
  from (select btrim(e) as o, min(ord) as n
          from jsonb_array_elements_text(p) with ordinality as t(e, ord)
         where btrim(e) <> '' group by btrim(e)) x;
  if jsonb_array_length(v) > 50 then
    raise exception 'ventas: hasta 50 opciones por columna' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements_text(v) e where char_length(e) > 60) then
    raise exception 'ventas: cada opcion tiene hasta 60 caracteres' using errcode = '22023';
  end if;
  return v;
end;
$$;


-- =====================================================================
-- 5. LECTURA (lo que pinta la app)
-- =====================================================================
-- Sistema sin fila guardada: orden = posicion de hoy x 10. Las nuevas sin
-- orden van al final. Las archivadas solo las ve el fundador.
create or replace function public.fin_data_columnas_de(p_cliente text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with sis as (
    select s.clave, s.pos
    from unnest(public.fin_data_claves_sistema()) with ordinality as s(clave, pos)
  ),
  guardadas as (
    select * from public.fin_data_columnas where cliente_id = p_cliente
  ),
  todas as (
    select s.clave, true as sistema,
           coalesce(g.etiqueta, public.fin_data_etiqueta_defecto(s.clave)) as etiqueta,
           public.fin_data_etiqueta_defecto(s.clave) as etiqueta_defecto,
           coalesce(g.orden, (s.pos * 10)::int) as orden,
           coalesce(g.visible, true) as visible,
           null::text as tipo, '[]'::jsonb as opciones, false as archivada
    from sis s left join guardadas g on g.clave = s.clave and g.sistema
    union all
    select g.clave, false, g.etiqueta, null, coalesce(g.orden, 100000), g.visible,
           g.tipo, g.opciones, g.archivada
    from guardadas g
    where not g.sistema and (not g.archivada or public.es_fundador())
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'clave', clave, 'sistema', sistema, 'etiqueta', etiqueta,
           'etiqueta_defecto', etiqueta_defecto, 'orden', orden, 'visible', visible,
           'tipo', tipo, 'opciones', opciones, 'archivada', archivada)
         order by orden, clave), '[]'::jsonb)
  from todas
  where public.es_fundador()
     or (public.rol_actual() = 'cliente' and public.tiene_acceso(p_cliente))
     or exists (select 1 from public.fin_personas p
                where p.user_id = auth.uid() and p.cliente_id = p_cliente);
$$;

-- Lo que puede hacer el usuario actual en la grilla de ese cliente.
-- filas_bloqueadas = la fuente no esta cortada: las filas sheet no se
-- editan (las ghl/app si). La app lo usa para mostrar el candado.
create or replace function public.fin_data_permisos(p_cliente text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'estructura',        coalesce(public.es_fundador(), false),
    'columnas_nuevas',   coalesce(public.es_fundador(), false) and public.fin_data_admite_nuevas(p_cliente),
    'editar_valores',    coalesce(public.es_fundador(), false) or public.rol_actual() = 'closer',
    'fuente_cortada',    exists (select 1 from public.fin_fuentes
                                 where cliente_id = p_cliente and tipo = 'data' and cortada_en is not null)
  )
$$;


-- =====================================================================
-- 6. ESTRUCTURA (solo fundador)
-- =====================================================================
-- Renombrar / mostrar u ocultar / opciones (solo nuevas de tipo opcion).
-- etiqueta null = nombre por defecto (solo sistema).
create or replace function public.fin_data_columna_guardar(
  p_cliente  text,
  p_clave    text,
  p_etiqueta text,
  p_visible  boolean default true,
  p_opciones jsonb default null
)
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col public.fin_data_columnas%rowtype;
  v_et  text := nullif(btrim(coalesce(p_etiqueta, '')), '');
begin
  perform public.fin_data_exigir_fundador();
  perform public.fin_data_cliente_ok(p_cliente);

  select * into v_col from public.fin_data_columnas
  where cliente_id = p_cliente and clave = p_clave;

  if p_opciones is not null and p_clave = any (public.fin_data_claves_sistema()) then
    raise exception 'ventas: las opciones de % salen del catalogo, no se cambian aca', p_clave using errcode = '22023';
  end if;

  if v_col.id is null then
    if not (p_clave = any (public.fin_data_claves_sistema())) then
      raise exception 'ventas: la columna % no existe en %', p_clave, p_cliente using errcode = 'P0002';
    end if;
    insert into public.fin_data_columnas (cliente_id, clave, sistema, etiqueta, visible, creado_por)
    values (p_cliente, p_clave, true, v_et, coalesce(p_visible, true), auth.uid());
    return;
  end if;

  if not v_col.sistema and v_et is null then
    raise exception 'ventas: una columna nueva necesita nombre' using errcode = '22023';
  end if;
  update public.fin_data_columnas
     set etiqueta   = v_et,
         visible    = coalesce(p_visible, visible),
         opciones   = case when tipo = 'opcion' and p_opciones is not null
                           then public.fin_data_opciones_limpias(p_opciones) else opciones end,
         updated_at = now()
   where id = v_col.id;
end;
$fn$;

-- Columna nueva. Devuelve la clave (x_<nombre>_<4 hex>). Queda al final.
create or replace function public.fin_data_columna_crear(
  p_cliente  text,
  p_etiqueta text,
  p_tipo     text,
  p_opciones jsonb default '[]'::jsonb
)
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_et    text := nullif(btrim(coalesce(p_etiqueta, '')), '');
  v_slug  text;
  v_clave text;
  v_orden int;
begin
  perform public.fin_data_exigir_fundador();
  perform public.fin_data_cliente_ok(p_cliente);
  if not public.fin_data_admite_nuevas(p_cliente) then
    raise exception 'ventas: % no admite columnas nuevas', p_cliente using errcode = '22023';
  end if;
  if v_et is null then
    raise exception 'ventas: la columna necesita nombre' using errcode = '22023';
  end if;
  if p_tipo is null or p_tipo not in ('texto','numero','fecha','casilla','opcion','link') then
    raise exception 'ventas: tipo de columna invalido (%)', p_tipo using errcode = '22023';
  end if;

  v_slug := left(trim(both '_' from regexp_replace(
              translate(lower(v_et), 'áéíóúñü', 'aeiounu'), '[^a-z0-9]+', '_', 'g')), 40);
  if v_slug = '' then v_slug := 'col'; end if;
  v_clave := 'x_' || v_slug || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);

  -- Al final: despues de la ultima guardada y de la ultima del sistema
  -- (posicion x 10), aunque nada se haya guardado todavia.
  select greatest(coalesce(max(orden), 0),
                  cardinality(public.fin_data_claves_sistema()) * 10) + 10
    into v_orden
  from public.fin_data_columnas where cliente_id = p_cliente;

  insert into public.fin_data_columnas (cliente_id, clave, sistema, etiqueta, orden, tipo, opciones, creado_por)
  values (p_cliente, v_clave, false, v_et, v_orden, p_tipo,
          case when p_tipo = 'opcion' then public.fin_data_opciones_limpias(coalesce(p_opciones, '[]'::jsonb))
               else '[]'::jsonb end,
          auth.uid());
  return v_clave;
end;
$fn$;

-- Orden completo: la app manda todas las claves en el orden nuevo.
create or replace function public.fin_data_columnas_ordenar(p_cliente text, p_claves text[])
returns void
language plpgsql security definer set search_path = public
as $fn$
declare
  v_mal text;
begin
  perform public.fin_data_exigir_fundador();
  perform public.fin_data_cliente_ok(p_cliente);
  if p_claves is null or cardinality(p_claves) = 0 then
    raise exception 'ventas: falta el orden de las columnas' using errcode = '22023';
  end if;
  if cardinality(p_claves) <> (select count(distinct x) from unnest(p_claves) x) then
    raise exception 'ventas: hay columnas repetidas en el orden' using errcode = '22023';
  end if;

  select x into v_mal from unnest(p_claves) x
  where not (x = any (public.fin_data_claves_sistema()))
    and not exists (select 1 from public.fin_data_columnas c
                    where c.cliente_id = p_cliente and c.clave = x and not c.sistema)
  limit 1;
  if v_mal is not null then
    raise exception 'ventas: la columna % no existe en %', v_mal, p_cliente using errcode = 'P0002';
  end if;

  insert into public.fin_data_columnas (cliente_id, clave, sistema, orden, creado_por)
  select p_cliente, x, true, (o * 10)::int, auth.uid()
  from unnest(p_claves) with ordinality as t(x, o)
  where x = any (public.fin_data_claves_sistema())
  on conflict (cliente_id, clave) do update
    set orden = excluded.orden, updated_at = now();

  update public.fin_data_columnas c
     set orden = (t.o * 10)::int, updated_at = now()
  from unnest(p_claves) with ordinality as t(x, o)
  where c.cliente_id = p_cliente and c.clave = t.x and not c.sistema;
end;
$fn$;

-- Archivar (borrar sin perder datos) o recuperar una columna nueva.
create or replace function public.fin_data_columna_archivar(p_cliente text, p_clave text, p_archivar boolean default true)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  perform public.fin_data_exigir_fundador();
  update public.fin_data_columnas
     set archivada = coalesce(p_archivar, true), updated_at = now()
   where cliente_id = p_cliente and clave = p_clave and not sistema;
  if not found then
    raise exception 'ventas: solo se archivan columnas nuevas (las del sistema se ocultan)' using errcode = '22023';
  end if;
end;
$fn$;

-- Renombrar una opcion de una columna NUEVA y los valores ya cargados.
-- Las del sistema (estado, show up, calificacion...) no pasan por aca.
create or replace function public.fin_data_opcion_renombrar(
  p_cliente text, p_clave text, p_viejo text, p_nuevo text)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col   public.fin_data_columnas%rowtype;
  v_nuevo text := btrim(coalesce(p_nuevo, ''));
  v_n     int;
begin
  perform public.fin_data_exigir_fundador();
  select * into v_col from public.fin_data_columnas
  where cliente_id = p_cliente and clave = p_clave and not sistema and tipo = 'opcion';
  if v_col.id is null then
    raise exception 'ventas: % no es una columna nueva de opciones', p_clave using errcode = 'P0002';
  end if;
  if v_nuevo = '' then
    raise exception 'ventas: la opcion necesita nombre' using errcode = '22023';
  end if;
  if not (v_col.opciones ? p_viejo) then
    raise exception 'ventas: la opcion "%" no existe', p_viejo using errcode = 'P0002';
  end if;

  update public.fin_data_columnas
     set opciones = public.fin_data_opciones_limpias(
                      (select jsonb_agg(case when e = p_viejo then v_nuevo else e end order by o)
                       from jsonb_array_elements_text(opciones) with ordinality as t(e, o))),
         updated_at = now()
   where id = v_col.id;

  update public.fin_llamadas
     set campos_extra = jsonb_set(campos_extra, array[p_clave], to_jsonb(v_nuevo))
   where cliente_id = p_cliente and campos_extra->>p_clave = p_viejo;
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;


-- =====================================================================
-- 7. GUARDAR UN VALOR
-- =====================================================================
-- Comun a las dos: trae la fila y valida quien y donde.
create or replace function public.fin_data_fila_para_editar(p_llamada bigint, p_clave text)
returns public.fin_llamadas
language plpgsql stable security definer set search_path = public
as $fn$
declare
  l public.fin_llamadas%rowtype;
begin
  select * into l from public.fin_llamadas where id = p_llamada;
  if l.id is null then
    raise exception 'ventas: la llamada no existe (la sync la pudo haber recreado: recarga)' using errcode = 'P0002';
  end if;
  if not (coalesce(public.es_fundador(), false) or public.fin_data_es_su_llamada(l.cliente_id, l.closer)) then
    raise exception 'ventas: no podes editar esta llamada' using errcode = '42501';
  end if;
  if p_clave = 'closer' and not coalesce(public.es_fundador(), false) then
    raise exception 'ventas: el closer lo cambia un fundador' using errcode = '42501';
  end if;
  if not public.fin_data_fila_editable(l.origen, l.fuente_id) then
    raise exception 'ventas: esta fila viene del Sheet y se edita alla hasta el corte' using errcode = '55000';
  end if;
  return l;
end;
$fn$;

-- Columnas del sistema. valor null o '' borra (salvo las obligatorias).
-- Devuelve el valor como quedo guardado (texto) para que la app lo pinte.
create or replace function public.fin_data_guardar(p_llamada bigint, p_clave text, p_valor text)
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  l    public.fin_llamadas%rowtype;
  v    text := nullif(btrim(coalesce(p_valor, '')), '');
  vn   numeric;
  vcat text;
  dim  text;
begin
  if not (p_clave = any (public.fin_data_claves_sistema())) then
    raise exception 'ventas: % no es una columna del sistema', p_clave using errcode = 'P0002';
  end if;
  l := public.fin_data_fila_para_editar(p_llamada, p_clave);

  case p_clave
    when 'nombre' then
      if v is null or char_length(v) > 200 then
        raise exception 'ventas: el nombre es obligatorio (hasta 200)' using errcode = '22023';
      end if;
      update public.fin_llamadas set nombre = v where id = l.id;

    when 'fecha_llamada' then
      if v is null or v !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'ventas: la fecha es obligatoria (AAAA-MM-DD)' using errcode = '22023';
      end if;
      update public.fin_llamadas set fecha_llamada = v::date where id = l.id;

    when 'hora_llamada' then
      if v is not null and v !~ '^\d{1,2}:\d{2}(:\d{2})?$' then
        raise exception 'ventas: la hora va como HH:MM' using errcode = '22023';
      end if;
      update public.fin_llamadas set hora_llamada = v::time where id = l.id;

    when 'closer' then
      select p.alias into vcat from public.fin_personas p
      where p.cliente_id = l.cliente_id
        and (p.campo is null or p.campo in ('closer', 'ambos'))
        and lower(btrim(p.alias)) = lower(v)
      order by p.id limit 1;
      if vcat is null then
        raise exception 'ventas: "%" no es un closer de %', coalesce(v, ''), l.cliente_id using errcode = '22023';
      end if;
      update public.fin_llamadas set closer = btrim(vcat) where id = l.id;
      v := btrim(vcat);

    when 'show_up', 'calificacion' then
      v := lower(v);
      if v is not null and not exists (
           select 1 from public.fin_catalogos c
           where c.cliente_id = l.cliente_id and c.dimension = p_clave and c.activo and c.valor = v) then
        raise exception 'ventas: "%" no es una opcion de %', v, p_clave using errcode = '22023';
      end if;
      if p_clave = 'show_up' then
        update public.fin_llamadas set show_up = v where id = l.id;
      else
        update public.fin_llamadas set calificacion = v where id = l.id;
      end if;

    when 'estado_llamada', 'programa', 'tipo_booking' then
      dim := case p_clave when 'estado_llamada' then 'estado' when 'tipo_booking' then 'fuente' else 'programa' end;
      if p_clave = 'estado_llamada' then v := upper(v); end if;
      -- Si el cliente tiene catalogo para esa columna, solo valores del
      -- catalogo (sin importar mayusculas; se guarda como en el catalogo).
      -- Sin catalogo (ej. fuente, hoy vacio a proposito): texto libre.
      if v is not null and exists (
           select 1 from public.fin_catalogos c
           where c.cliente_id = l.cliente_id and c.dimension = dim and c.activo) then
        select c.valor into vcat from public.fin_catalogos c
        where c.cliente_id = l.cliente_id and c.dimension = dim and c.activo
          and lower(c.valor) = lower(v)
        limit 1;
        if vcat is null then
          raise exception 'ventas: "%" no es una opcion de %', v, p_clave using errcode = '22023';
        end if;
        v := vcat;
      end if;
      if v is not null and char_length(v) > 120 then
        raise exception 'ventas: hasta 120 caracteres' using errcode = '22023';
      end if;
      if p_clave = 'estado_llamada' then
        update public.fin_llamadas set estado_llamada = v where id = l.id;
      elsif p_clave = 'programa' then
        update public.fin_llamadas set programa = v where id = l.id;
      else
        update public.fin_llamadas set tipo_booking = v where id = l.id;
      end if;

    when 'cc_dia1', 'cc_cerrado', 'cc_seguimiento', 'monto_restante' then
      if v is not null then
        v := replace(replace(v, '$', ''), ' ', '');
        if v !~ '^\d+([.,]\d{1,2})?$' then
          raise exception 'ventas: % espera un monto en USD (ej. 1500 o 1500,50)', p_clave using errcode = '22023';
        end if;
        vn := replace(v, ',', '.')::numeric;
        v := vn::text;
      end if;
      execute format('update public.fin_llamadas set %I = $1 where id = $2', p_clave) using vn, l.id;

    when 'email' then
      if v is not null and (v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v) > 200) then
        raise exception 'ventas: el email no es valido' using errcode = '22023';
      end if;
      update public.fin_llamadas set email = lower(v) where id = l.id;
      v := lower(v);

    when 'telefono', 'instagram', 'contexto_setter', 'contexto_closer' then
      if v is not null and char_length(v) > 5000 then
        raise exception 'ventas: hasta 5000 caracteres' using errcode = '22023';
      end if;
      execute format('update public.fin_llamadas set %I = $1 where id = $2', p_clave) using v, l.id;
  end case;

  return v;
end;
$fn$;

-- Columnas nuevas. valor null o "" borra el dato de esa columna.
-- Escribe una sola clave del jsonb: dos personas en columnas distintas
-- de la misma fila no se pisan.
create or replace function public.fin_data_guardar_extra(p_llamada bigint, p_clave text, p_valor jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  l     public.fin_llamadas%rowtype;
  v_col public.fin_data_columnas%rowtype;
  v     jsonb := p_valor;
begin
  l := public.fin_data_fila_para_editar(p_llamada, p_clave);

  select * into v_col from public.fin_data_columnas
  where cliente_id = l.cliente_id and clave = p_clave and not sistema and not archivada;
  if v_col.id is null then
    raise exception 'ventas: la columna % no existe en este cliente', p_clave using errcode = 'P0002';
  end if;

  if v is not null and (jsonb_typeof(v) = 'null'
                        or (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '')) then
    v := null;
  end if;

  if v is not null then
    case v_col.tipo
      when 'texto' then
        if jsonb_typeof(v) <> 'string' or char_length(v #>> '{}') > 2000 then
          raise exception 'ventas: % espera texto (hasta 2000)', v_col.etiqueta using errcode = '22023';
        end if;
        v := to_jsonb(btrim(v #>> '{}'));
      when 'numero' then
        if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^\s*-?\d+([.,]\d+)?\s*$' then
          v := to_jsonb(replace(btrim(v #>> '{}'), ',', '.')::numeric);
        end if;
        if jsonb_typeof(v) <> 'number' then
          raise exception 'ventas: % espera un numero', v_col.etiqueta using errcode = '22023';
        end if;
      when 'fecha' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception 'ventas: % espera una fecha (AAAA-MM-DD)', v_col.etiqueta using errcode = '22023';
        end if;
        perform (v #>> '{}')::date;   -- falla si la fecha no existe (ej. 31/02)
      when 'casilla' then
        if jsonb_typeof(v) <> 'boolean' then
          raise exception 'ventas: % espera si o no', v_col.etiqueta using errcode = '22023';
        end if;
      when 'opcion' then
        if jsonb_typeof(v) <> 'string' or not (v_col.opciones ? (v #>> '{}')) then
          raise exception 'ventas: "%" no es una opcion de %', v #>> '{}', v_col.etiqueta using errcode = '22023';
        end if;
      when 'link' then
        if jsonb_typeof(v) <> 'string' or (v #>> '{}') !~* '^https?://\S+$' or char_length(v #>> '{}') > 1000 then
          raise exception 'ventas: % espera un link que empiece con http', v_col.etiqueta using errcode = '22023';
        end if;
    end case;
  end if;

  update public.fin_llamadas
     set campos_extra = case when v is null then campos_extra - p_clave
                             else jsonb_set(campos_extra, array[p_clave], v) end
   where id = l.id;

  return v;
end;
$fn$;


-- =====================================================================
-- 8. PERMISOS
-- =====================================================================
revoke all on function public.fin_data_claves_sistema() from public, anon;
revoke all on function public.fin_data_etiqueta_defecto(text) from public, anon;
revoke all on function public.fin_data_cliente_ok(text) from public, anon, authenticated;
revoke all on function public.fin_data_exigir_fundador() from public, anon, authenticated;
revoke all on function public.fin_data_admite_nuevas(text) from public, anon;
revoke all on function public.fin_data_fila_editable(text, bigint) from public, anon;
revoke all on function public.fin_data_es_su_llamada(text, text) from public, anon, authenticated;
revoke all on function public.fin_data_opciones_limpias(jsonb) from public, anon, authenticated;
revoke all on function public.fin_data_fila_para_editar(bigint, text) from public, anon, authenticated;
revoke all on function public.fin_data_columnas_de(text) from public, anon;
revoke all on function public.fin_data_permisos(text) from public, anon;
revoke all on function public.fin_data_columna_guardar(text, text, text, boolean, jsonb) from public, anon;
revoke all on function public.fin_data_columna_crear(text, text, text, jsonb) from public, anon;
revoke all on function public.fin_data_columnas_ordenar(text, text[]) from public, anon;
revoke all on function public.fin_data_columna_archivar(text, text, boolean) from public, anon;
revoke all on function public.fin_data_opcion_renombrar(text, text, text, text) from public, anon;
revoke all on function public.fin_data_guardar(bigint, text, text) from public, anon;
revoke all on function public.fin_data_guardar_extra(bigint, text, jsonb) from public, anon;

grant execute on function public.fin_data_claves_sistema() to authenticated;
grant execute on function public.fin_data_etiqueta_defecto(text) to authenticated;
grant execute on function public.fin_data_admite_nuevas(text) to authenticated;
grant execute on function public.fin_data_fila_editable(text, bigint) to authenticated;
grant execute on function public.fin_data_columnas_de(text) to authenticated;
grant execute on function public.fin_data_permisos(text) to authenticated;
grant execute on function public.fin_data_columna_guardar(text, text, text, boolean, jsonb) to authenticated;
grant execute on function public.fin_data_columna_crear(text, text, text, jsonb) to authenticated;
grant execute on function public.fin_data_columnas_ordenar(text, text[]) to authenticated;
grant execute on function public.fin_data_columna_archivar(text, text, boolean) to authenticated;
grant execute on function public.fin_data_opcion_renombrar(text, text, text, text) to authenticated;
grant execute on function public.fin_data_guardar(bigint, text, text) to authenticated;
grant execute on function public.fin_data_guardar_extra(bigint, text, jsonb) to authenticated;


-- =====================================================================
-- 9. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
-- Usa una llamada de liam que ya existe, la pasa a origen 'app' DENTRO
-- de la prueba y al final todo se deshace (raise + exception).
do $humo$
declare
  v_fund  text := (select user_id::text from public.crm_members where rol = 'fundador' limit 1);
  v_id    bigint;
  v_k     text;
  v_n     int;
  v_j     jsonb;
  v_t     text;
  v_err   text;
  v_extra jsonb;
begin
  begin
    perform set_config('request.jwt.claim.sub', v_fund, true);

    select id into v_id from public.fin_llamadas where cliente_id = 'liam' order by id desc limit 1;
    if v_id is null then raise exception 'humo 0: liam no tiene llamadas'; end if;

    -- 1. lectura: 18 del sistema, orden de hoy x 10
    v_j := public.fin_data_columnas_de('liam');
    if jsonb_array_length(v_j) <> 18 or (v_j->0->>'clave') <> 'fecha_llamada'
       or (v_j->0->>'orden')::int <> 10 or (v_j->17->>'orden')::int <> 180 then
      raise exception 'humo 1: lectura inicial %', v_j;
    end if;

    -- 2. renombrar y ocultar una del sistema; nombre no se oculta
    perform public.fin_data_columna_guardar('liam', 'tipo_booking', 'Origen', true);
    perform public.fin_data_columna_guardar('liam', 'instagram', null, false);
    v_j := public.fin_data_columnas_de('liam');
    if not exists (select 1 from jsonb_array_elements(v_j) e
                   where e->>'clave' = 'tipo_booking' and e->>'etiqueta' = 'Origen')
       or not exists (select 1 from jsonb_array_elements(v_j) e
                      where e->>'clave' = 'instagram' and not (e->>'visible')::boolean) then
      raise exception 'humo 2: renombrar/ocultar';
    end if;
    begin
      perform public.fin_data_columna_guardar('liam', 'nombre', null, false);
      raise exception 'humo 3: dejo ocultar nombre';
    exception when check_violation then null;
    end;
    begin
      perform public.fin_data_columna_guardar('liam', 'estado_llamada', null, true, '["X"]');
      raise exception 'humo 4: dejo cambiar opciones de estado';
    exception when invalid_parameter_value then null;
    end;

    -- 3. columna nueva: queda al final aunque no haya nada guardado
    v_k := public.fin_data_columna_crear('liam', 'Canal de ingreso', 'opcion', '["Instagram"," YouTube ","Instagram",""]');
    if v_k !~ '^x_canal_de_ingreso_[0-9a-f]{4}$' then raise exception 'humo 5: clave %', v_k; end if;
    v_j := public.fin_data_columnas_de('liam');
    if (v_j->-1->>'clave') <> v_k or (v_j->-1->>'opciones')::jsonb <> '["Instagram","YouTube"]'::jsonb then
      raise exception 'humo 6: la nueva no quedo al final o las opciones mal: %', v_j->-1;
    end if;
    begin
      perform public.fin_data_columna_crear('mauro', 'Algo', 'texto');
      raise exception 'humo 7: mauro acepto columnas nuevas';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_columna_crear('agus', 'Algo', 'texto');
      raise exception 'humo 8: agus (sin Data) acepto columnas';
    exception when no_data_found then null;
    end;

    -- 4. fila sheet de fuente activa: no se edita
    begin
      perform public.fin_data_guardar(v_id, 'nombre', 'Otro');
      raise exception 'humo 9: edito una fila del Sheet';
    exception when object_not_in_prerequisite_state then null;
    end;
    begin
      perform public.fin_data_guardar_extra(v_id, v_k, '"YouTube"');
      raise exception 'humo 10: edito extra en una fila del Sheet';
    exception when object_not_in_prerequisite_state then null;
    end;

    -- 5. la misma fila como 'app' (solo dentro de la prueba)
    update public.fin_llamadas set origen = 'app' where id = v_id;
    perform public.fin_data_guardar_extra(v_id, v_k, '"YouTube"');
    begin
      perform public.fin_data_guardar_extra(v_id, v_k, '"TikTok"');
      raise exception 'humo 11: acepto una opcion inexistente';
    exception when invalid_parameter_value then null;
    end;
    v_n := public.fin_data_opcion_renombrar('liam', v_k, 'YouTube', 'YT');
    if v_n < 1 or (select campos_extra->>v_k from public.fin_llamadas where id = v_id) <> 'YT' then
      raise exception 'humo 12: renombrar opcion (n=%)', v_n;
    end if;

    -- 6. sistema: catalogos, montos, closer
    v_t := public.fin_data_guardar(v_id, 'estado_llamada', 'adentro en llamada');
    if v_t <> 'ADENTRO EN LLAMADA' then raise exception 'humo 13: estado %', v_t; end if;
    begin
      perform public.fin_data_guardar(v_id, 'estado_llamada', 'CERRADISIMO');
      raise exception 'humo 14: acepto un estado fuera del catalogo';
    exception when invalid_parameter_value then null;
    end;
    v_t := public.fin_data_guardar(v_id, 'show_up', 'SI');
    if v_t <> 'si' then raise exception 'humo 15: show_up %', v_t; end if;
    v_t := public.fin_data_guardar(v_id, 'cc_dia1', '1500,50');
    if (select cc_dia1 from public.fin_llamadas where id = v_id) <> 1500.50 then
      raise exception 'humo 16: monto %', v_t;
    end if;
    begin
      perform public.fin_data_guardar(v_id, 'cc_dia1', '-5');
      raise exception 'humo 17: acepto monto negativo';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_guardar(v_id, 'closer', 'Alguien Inventado');
      raise exception 'humo 18: acepto un closer que no existe';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_guardar(v_id, 'nombre', '   ');
      raise exception 'humo 19: dejo el nombre vacio';
    exception when invalid_parameter_value then null;
    end;

    -- 7. la vista de metricas ve el cambio (es la misma fila)
    if not (select es_cerrada or fecha_llamada > current_date
            from public.fin_v_llamadas_clasificadas where id = v_id) then
      raise exception 'humo 20: la vista no tomo el estado nuevo';
    end if;

    -- 8. orden: repetidas no; las del sistema se guardan x 10
    perform public.fin_data_columnas_ordenar('liam', array['nombre', v_k, 'fecha_llamada']);
    select count(*) into v_n from public.fin_data_columnas
    where cliente_id = 'liam' and ((clave = 'nombre' and orden = 10) or (clave = v_k and orden = 20)
                                 or (clave = 'fecha_llamada' and orden = 30));
    if v_n <> 3 then raise exception 'humo 21: orden (n=%)', v_n; end if;
    begin
      perform public.fin_data_columnas_ordenar('liam', array['nombre', 'nombre']);
      raise exception 'humo 22: acepto repetidas';
    exception when invalid_parameter_value then null;
    end;

    -- 9. archivar: el dato queda, no se escribe mas
    perform public.fin_data_columna_archivar('liam', v_k, true);
    begin
      perform public.fin_data_guardar_extra(v_id, v_k, '"Instagram"');
      raise exception 'humo 23: escribio en una archivada';
    exception when no_data_found then null;
    end;
    if (select campos_extra->>v_k from public.fin_llamadas where id = v_id) <> 'YT' then
      raise exception 'humo 24: archivar borro el dato';
    end if;

    -- 10. un no fundador no cambia estructura ni edita filas ajenas
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000dead', true);
    begin
      perform public.fin_data_columna_crear('liam', 'Intruso', 'texto');
      raise exception 'humo 25: un no fundador creo una columna';
    exception when insufficient_privilege then null;
    end;
    begin
      perform public.fin_data_guardar(v_id, 'nombre', 'Intruso');
      raise exception 'humo 26: un desconocido edito una llamada';
    exception when insufficient_privilege then null;
    end;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '073 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 10. CONTROLES (correr de a uno, despues del Success)
-- =====================================================================
-- C1. Lo nuevo existe. Tiene que dar 1 | 1 | 9 | 18.
-- select (select count(*) from information_schema.tables where table_name = 'fin_data_columnas') as tabla,
--        (select count(*) from information_schema.columns where table_name = 'fin_llamadas' and column_name = 'campos_extra') as columna,
--        (select count(*) from pg_proc where proname in ('fin_data_columnas_de','fin_data_permisos',
--           'fin_data_columna_guardar','fin_data_columna_crear','fin_data_columnas_ordenar',
--           'fin_data_columna_archivar','fin_data_opcion_renombrar','fin_data_guardar',
--           'fin_data_guardar_extra')) as funciones,
--        cardinality(public.fin_data_claves_sistema()) as claves_sistema;

-- C2. La prueba de humo no dejo nada. Tiene que dar 0 | 0 | 0.
-- select (select count(*) from public.fin_data_columnas) as configuradas,
--        (select count(*) from public.fin_llamadas where campos_extra <> '{}'::jsonb) as con_extras,
--        (select count(*) from public.fin_llamadas where origen <> 'sheet') as no_sheet;

-- C3. Las llamadas siguen todas (520 | 541 | 984 | 363, o las que haya
--     hoy si entraron nuevas). Compará con lo de antes de correrla.
-- select cliente_id, count(*) from public.fin_llamadas group by 1 order by 1;

-- C4. Las metricas siguen vivas: un numero, sin error.
-- select count(*) from public.fin_v_metricas_ventas;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================
-- C5. La sync sigue escribiendo: las 4 fuentes de Data con una corrida
--     'ok' posterior a la migracion.
-- select f.cliente_id, c.estado, c.fin
--   from public.fin_fuentes f
--   join lateral (select * from public.fin_sync_corridas x
--                 where x.fuente_id = f.id order by x.id desc limit 1) c on true
--  where f.tipo = 'data' order by 1;
