-- =====================================================================
-- 077_ventas_liam_equipo.sql  -  VENTAS: Liam listo para que el equipo lo use
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), DESPUES
-- de la 075_finanzas_areas_liam.sql (Finanzas). La 075 es la unica que define
-- los roles de crm_members y da de alta a los 6 usuarios; esta migracion
-- aborta con mensaje claro si la 075 no se corrio. Es idempotente.
--
-- Archivo 100% ASCII (acentos como U&'...\00F3...'). Si se copia al
-- portapapeles: Get-Content archivo.sql -Raw -Encoding UTF8 | Set-Clipboard
-- Evitar :00, :15, :30 y :45 (la sync escribe fin_llamadas).
-- Sin probar contra un Postgres local: la prueba de humo del final es la
-- unica red. Si aborta, no queda nada (todo es una transaccion).
--
-- Decisiones de Nacho (03/10) que aplica:
--   - "ADENTRO EN CHAT" no existe y "SEGUIMIENTO CUOTAS" deja de ser opcion:
--     las dos pasan a "ADENTRO EN SEGUIMIENTO" (solo liam).
--     OJO: SEGUIMIENTO CUOTAS hoy NO cuenta como cerrada en las metricas;
--     "ADENTRO EN SEGUIMIENTO" si. Las cerradas en seguimiento de liam suben.
--   - "Ghosteado" queda (= cancelado por closer).
--   - Closers de liam: solo Ivan Binsztein y Lucas Deza (mas BPF = sin
--     closer). Matias Ortuno y el resto siguen existiendo como alias para las
--     comisiones, pero no salen en la lista de closers.
--   - Programa de liam: BLUEPRINT, GESTION DE CAPITAL, 1 a 1 Blueprint Financiero.
--   - La sync de Sheets de liam (solo la hoja Data) se corta: desde aca la
--     carga es en la app.
--
-- Que hace:
--   0. Guarda: aborta si falta la 075.
--   1. fin_personas.lista_closers + alta de Ivan Binsztein + alias de
--      Matias Ortuno. NO toca fin_personas.campo (la vista de metricas y las
--      comisiones la usan para atribuir cierres).
--   2. Corte de la fuente Data de liam (activo=false, cortada_en=now()).
--   3. Catalogos de liam: estado (sin SEGUIMIENTO CUOTAS, con GHOSTEADO) y
--      programa. Normaliza los estados que ya estan cargados.
--   4. Reglas y lectura para el rol 'ventas' (politicas ADITIVAS: no
--      reemplazan las de otros; las de Finanzas 075/076 no se pisan).
--   5. Funciones: fin_data_permisos, fin_data_columnas_de,
--      fin_data_fila_para_editar y fin_data_guardar (misma firma que la 073,
--      con el rol ventas), fin_data_closers_de, fin_data_llamada_crear.
--
-- Matriz de permisos EN VENTAS (crm_members.rol = area; la RLS manda, la
-- app solo esconde):
--   fundador   todo, todos los clientes
--   ventas     Data de su cliente: ve, edita celdas (incl. closer) y agrega
--              llamadas. No ve Dashboard, Closers, Setters ni Comisiones
--              (dependen de pagos, que es de Finanzas).
--   finanzas   Data de su cliente, SOLO LECTURA
--   cliente    Data de su cliente, SOLO LECTURA (y lo que ya veia)
--   producto   no entra a Ventas
--   contenido  no entra a Ventas
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- 0. GUARDA: la 075 (Finanzas) define los roles por area (CHECK de
--    crm_members.rol) y da de alta los usuarios. Esta migracion no toca ni
--    crm_members ni crm_asignaciones: solo decide que puede hacer cada rol
--    EN VENTAS.
do $guarda$
declare
  v_def text;
begin
  if to_regclass('public.fin_clientes_areas') is null
     or to_regprocedure('public.fin_asignado(text)') is null
     or to_regprocedure('public.fin_ve_plata(text)') is null then
    raise exception '077 ABORTADA: falta correr la 075_finanzas_areas_liam.sql (Finanzas). Correr la 075 primero y despues esta.';
  end if;
  select string_agg(pg_get_constraintdef(oid), ' ') into v_def
  from pg_constraint
  where conrelid = 'public.crm_members'::regclass and contype = 'c'
    and pg_get_constraintdef(oid) ~* '\mrol\M\s*=\s*ANY';
  if v_def is null
     or v_def !~ '''finanzas''' or v_def !~ '''ventas''' or v_def !~ '''producto''' or v_def !~ '''contenido''' then
    raise exception '077 ABORTADA: crm_members.rol todavia no admite finanzas/ventas/producto/contenido (la 075 no se corrio completa). CHECK actual: %', coalesce(v_def, '(sin CHECK)');
  end if;
end
$guarda$;

lock table public.fin_llamadas, public.fin_fuentes, public.fin_personas
  in access exclusive mode;


-- =====================================================================
-- 1. CLOSERS DE LIAM (fin_personas)
-- =====================================================================
alter table public.fin_personas
  add column if not exists lista_closers boolean not null default true;

comment on column public.fin_personas.lista_closers is
  '077: false = el alias no sale en la lista de closers de Data (sigue atribuyendo comisiones). Solo se usa en la grilla Data.';

-- Ivan Binsztein: closer real de liam.
insert into public.fin_vendedores (nombre, es_persona, notas)
values ('Ivan Binsztein', true, 'closer de liam (077)')
on conflict (nombre_norm) do nothing;

insert into public.fin_vendedor_asignaciones (vendedor_id, cliente_id, es_setter, es_closer, comisiona)
select v.id, 'liam', false, true, true
from public.fin_vendedores v
where v.nombre_norm = public.fin_normalizar_nombre('Ivan Binsztein')
  and exists (select 1 from public.crm_clients where id = 'liam')
on conflict (vendedor_id, cliente_id) do nothing;

-- Alias (la RLS y la vista comparan lower(btrim()) SIN quitar tildes: con y
-- sin tilde son filas distintas). cliente_id nunca va en null.
insert into public.fin_personas (user_id, cliente_id, alias, vendedor_id, campo)
select null, 'liam', x.alias, v.id, 'closer'
from (values
  ('Ivan Binsztein',               'Ivan Binsztein'),
  (U&'Iv\00E1n Binsztein',         'Ivan Binsztein'),
  ('IVAN BINSZTEIN',              'Ivan Binsztein'),
  ('Ivan',                        'Ivan Binsztein'),
  ('IVAN',                        'Ivan Binsztein'),
  (U&'Iv\00E1n',                   'Ivan Binsztein'),
  ('Lucas Deza',                  'Lucas Deza'),
  ('Matias Ortuno',               'Matias Ortuno'),
  (U&'Mat\00EDas Ortu\00F1o',      'Matias Ortuno'),
  (U&'Matias Ortu\00F1o',          'Matias Ortuno'),
  (U&'MATIAS ORTU\00D1O',          'Matias Ortuno'),
  ('MATIAS ORTUNO',               'Matias Ortuno')
) as x(alias, vendedor)
join public.fin_vendedores v on v.nombre_norm = public.fin_normalizar_nombre(x.vendedor)
where exists (select 1 from public.crm_clients where id = 'liam')
on conflict do nothing;

-- Lista de closers de liam: Ivan, Lucas Deza y BPF (venta sin closer).
update public.fin_personas set lista_closers = false where cliente_id = 'liam';
update public.fin_personas p set lista_closers = true
from public.fin_vendedores v
where p.cliente_id = 'liam'
  and v.id = p.vendedor_id
  and v.nombre_norm in (public.fin_normalizar_nombre('Ivan Binsztein'),
                        public.fin_normalizar_nombre('Lucas Deza'),
                        public.fin_normalizar_nombre('BPF'));


-- =====================================================================
-- 2. CORTE DE LA SYNC DE LIAM (solo la hoja Data)
-- =====================================================================
update public.fin_fuentes
   set activo = false, cortada_en = now()
 where cliente_id = 'liam' and tipo = 'data' and cortada_en is null;


-- =====================================================================
-- 3. CATALOGOS Y ESTADOS DE LIAM
-- =====================================================================
update public.fin_catalogos set activo = false, updated_at = now()
 where cliente_id = 'liam' and dimension = 'estado'
   and valor in ('SEGUIMIENTO CUOTAS', 'ADENTRO EN CHAT') and activo;

insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
select 'liam', x.d, x.v, x.o
from (values
  ('estado',   'GHOSTEADO',                   9),
  ('programa', 'BLUEPRINT',                   1),
  ('programa', 'GESTION DE CAPITAL',          2),
  ('programa', '1 a 1 Blueprint Financiero',  3)
) as x(d, v, o)
where exists (select 1 from public.crm_clients where id = 'liam')
on conflict (cliente_id, dimension, valor) do update set activo = true, updated_at = now();

-- Los ya cargados (la carga completa viene en la 078).
update public.fin_llamadas set estado_llamada = 'ADENTRO EN SEGUIMIENTO'
 where cliente_id = 'liam'
   and upper(btrim(estado_llamada)) in ('SEGUIMIENTO CUOTAS', 'ADENTRO EN CHAT');
update public.fin_llamadas set estado_llamada = 'ADENTRO EN LLAMADA'
 where cliente_id = 'liam' and upper(btrim(estado_llamada)) = 'ADENTRO LLAMADA';
update public.fin_llamadas set estado_llamada = 'GHOSTEADO'
 where cliente_id = 'liam' and upper(btrim(estado_llamada)) = 'GHOSTEADO'
   and estado_llamada <> 'GHOSTEADO';


-- =====================================================================
-- 4. ROL 'ventas': REGLAS Y LECTURA
-- =====================================================================
-- Es del rol ventas Y tiene asignado ese cliente (crm_asignaciones, via
-- fin_asignado de la 075). Es el unico rol que EDITA Data (ademas del
-- fundador y del closer de su propia llamada).
create or replace function public.fin_data_es_ventas(p_cliente text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.rol_actual() = 'ventas' and public.fin_asignado(p_cliente), false)
$$;

-- Quien VE Data de un cliente (solo lectura salvo ventas/fundador):
-- fundador, cliente (como siempre), finanzas y ventas asignados.
-- producto y contenido no entran.
create or replace function public.fin_data_puede_ver(p_cliente text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(public.es_fundador(), false)
      or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(p_cliente), false))
      or (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(p_cliente))
$$;

-- Lectura ADITIVA (las politicas se suman con OR): no se tocan las de los
-- otros roles. 'cliente' ya tiene la suya de antes.
drop policy if exists fin_llamadas_lectura_ventas on public.fin_llamadas;
drop policy if exists fin_llamadas_lectura_areas on public.fin_llamadas;
create policy fin_llamadas_lectura_areas on public.fin_llamadas
  for select to authenticated
  using (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id));

drop policy if exists fin_catalogos_lectura_ventas on public.fin_catalogos;
drop policy if exists fin_catalogos_lectura_areas on public.fin_catalogos;
create policy fin_catalogos_lectura_areas on public.fin_catalogos
  for select to authenticated
  using (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id));

drop policy if exists fin_formulario_lectura_ventas on public.fin_formulario_preguntas;
drop policy if exists fin_formulario_lectura_areas on public.fin_formulario_preguntas;
create policy fin_formulario_lectura_areas on public.fin_formulario_preguntas
  for select to authenticated
  using (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id));


-- =====================================================================
-- 5. FUNCIONES DE DATA (073 + ventas)
-- =====================================================================
-- Alias canonico de un closer de la lista: una persona, un solo texto (el
-- alias que coincide con el nombre del vendedor; si no, el mas largo).
-- null = no es un closer de la lista de ese cliente.
create or replace function public.fin_data_closer_canonico(p_cliente text, p_texto text)
returns text
language sql stable security definer set search_path = public
as $$
  select (
    select btrim(c.alias)
    from public.fin_personas c
    left join public.fin_vendedores cv on cv.id = c.vendedor_id
    where c.cliente_id = p_cliente
      and (c.campo is null or c.campo in ('closer', 'ambos'))
      and c.lista_closers
      and (c.id = p.id or (p.vendedor_id is not null and c.vendedor_id = p.vendedor_id))
    order by (public.fin_normalizar_nombre(c.alias) = cv.nombre_norm) desc,
             char_length(btrim(c.alias)) desc, c.id
    limit 1)
  from public.fin_personas p
  where p.cliente_id = p_cliente
    and (p.campo is null or p.campo in ('closer', 'ambos'))
    and p.lista_closers
    and lower(btrim(p.alias)) = lower(btrim(coalesce(p_texto, '')))
  order by p.id
  limit 1
$$;

-- Lo que pinta la app (igual que la 073, con la rama ventas).
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
  where public.fin_data_puede_ver(p_cliente)
     or exists (select 1 from public.fin_personas p
                where p.user_id = auth.uid() and p.cliente_id = p_cliente);
$$;

-- Que puede hacer el usuario actual. Nuevas claves: editar_closer y
-- agregar_llamadas (solo con la fuente cortada: las filas 'app' no las pisa
-- la sync).
create or replace function public.fin_data_permisos(p_cliente text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'estructura',        coalesce(public.es_fundador(), false),
    'columnas_nuevas',   coalesce(public.es_fundador(), false) and public.fin_data_admite_nuevas(p_cliente),
    'editar_valores',    coalesce(public.es_fundador(), false)
                         or coalesce(public.rol_actual() = 'closer', false)
                         or public.fin_data_es_ventas(p_cliente),
    'editar_closer',     coalesce(public.es_fundador(), false) or public.fin_data_es_ventas(p_cliente),
    'agregar_llamadas',  (coalesce(public.es_fundador(), false) or public.fin_data_es_ventas(p_cliente))
                         and exists (select 1 from public.fin_fuentes
                                     where cliente_id = p_cliente and tipo = 'data' and cortada_en is not null),
    'fuente_cortada',    exists (select 1 from public.fin_fuentes
                                 where cliente_id = p_cliente and tipo = 'data' and cortada_en is not null)
  )
$$;

-- Quien puede tocar una fila: fundador, el closer de esa llamada, o ventas.
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
  if not (coalesce(public.es_fundador(), false)
          or public.fin_data_es_ventas(l.cliente_id)
          or public.fin_data_es_su_llamada(l.cliente_id, l.closer)) then
    raise exception 'ventas: no podes editar esta llamada' using errcode = '42501';
  end if;
  if p_clave = 'closer' and not (coalesce(public.es_fundador(), false)
                                 or public.fin_data_es_ventas(l.cliente_id)) then
    raise exception 'ventas: el closer lo cambia un fundador o el equipo de ventas' using errcode = '42501';
  end if;
  if not public.fin_data_fila_editable(l.origen, l.fuente_id) then
    raise exception 'ventas: esta fila viene del Sheet y se edita alla hasta el corte' using errcode = '55000';
  end if;
  return l;
end;
$fn$;

-- Columnas del sistema. Igual que la 073; unico cambio: el closer tiene que
-- estar en la lista de closers (fin_personas.lista_closers).
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
      vcat := public.fin_data_closer_canonico(l.cliente_id, v);
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

-- Lista de closers para el desplegable: una entrada por persona (el alias
-- que coincide con el nombre del vendedor; si no, el mas largo).
create or replace function public.fin_data_closers_de(p_cliente text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(a order by a), '[]'::jsonb)
  from (
    select distinct on (coalesce(p.vendedor_id::text, lower(btrim(p.alias))))
           btrim(p.alias) as a
    from public.fin_personas p
    left join public.fin_vendedores v on v.id = p.vendedor_id
    where p.cliente_id = p_cliente
      and (p.campo is null or p.campo in ('closer', 'ambos'))
      and p.lista_closers
      and (public.es_fundador() or public.fin_data_es_ventas(p_cliente))
    order by coalesce(p.vendedor_id::text, lower(btrim(p.alias))),
             (public.fin_normalizar_nombre(p.alias) = v.nombre_norm) desc,
             char_length(btrim(p.alias)) desc, p.id
  ) x
$$;

-- Agregar una llamada a mano (agenda diferida o en persona). Queda con
-- origen 'app': la sync no la toca. Valida cada campo con fin_data_guardar,
-- asi que las reglas son las mismas que al editar en celda. Atomica: si un
-- campo es invalido no queda nada.
-- p_campos admite: hora_llamada, tipo_booking, programa, estado_llamada,
-- show_up, calificacion, cc_dia1, cc_cerrado, cc_seguimiento, monto_restante,
-- telefono, instagram, email, contexto_setter, contexto_closer.
create or replace function public.fin_data_llamada_crear(
  p_cliente text,
  p_fecha   date,
  p_nombre  text,
  p_closer  text,
  p_campos  jsonb default '{}'::jsonb
)
returns bigint
language plpgsql security definer set search_path = public
as $fn$
declare
  v_fuente bigint;
  v_nombre text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_closer text;
  v_id     bigint;
  k        text;
  v        jsonb;
begin
  if not (coalesce(public.es_fundador(), false) or public.fin_data_es_ventas(p_cliente)) then
    raise exception 'ventas: no podes agregar llamadas en %', coalesce(p_cliente, '(vacio)') using errcode = '42501';
  end if;
  perform public.fin_data_cliente_ok(p_cliente);

  select id into v_fuente from public.fin_fuentes
  where cliente_id = p_cliente and tipo = 'data' and cortada_en is not null
  order by id limit 1;
  if v_fuente is null then
    raise exception 'ventas: la hoja de % todavia se carga en el Sheet (sin corte no se agregan llamadas)', p_cliente
      using errcode = '55000';
  end if;

  if v_nombre is null or char_length(v_nombre) > 200 then
    raise exception 'ventas: el nombre es obligatorio (hasta 200)' using errcode = '22023';
  end if;
  if p_fecha is null or p_fecha < date '2024-01-01' or p_fecha > date '2027-12-31' then
    raise exception 'ventas: la fecha es obligatoria (entre 2024 y 2027)' using errcode = '22023';
  end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then
    raise exception 'ventas: los campos van como objeto' using errcode = '22023';
  end if;

  v_closer := public.fin_data_closer_canonico(p_cliente, p_closer);
  if v_closer is null then
    raise exception 'ventas: "%" no es un closer de %', coalesce(p_closer, ''), p_cliente using errcode = '22023';
  end if;

  insert into public.fin_llamadas
    (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, origen, actualizado_por)
  values (p_cliente, v_fuente, null, p_fecha, v_closer, v_nombre, 'app', auth.uid())
  returning id into v_id;

  for k, v in select key, value from jsonb_each(p_campos) loop
    if k not in ('hora_llamada', 'tipo_booking', 'programa', 'estado_llamada', 'show_up',
                 'calificacion', 'cc_dia1', 'cc_cerrado', 'cc_seguimiento', 'monto_restante',
                 'telefono', 'instagram', 'email', 'contexto_setter', 'contexto_closer') then
      raise exception 'ventas: el campo % no se puede cargar al agregar una llamada', k using errcode = '22023';
    end if;
    if jsonb_typeof(v) = 'null' or (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '') then
      continue;
    end if;
    perform public.fin_data_guardar(v_id, k, v #>> '{}');
  end loop;

  return v_id;
end;
$fn$;

revoke all on function public.fin_data_es_ventas(text) from public, anon, authenticated;
revoke all on function public.fin_data_puede_ver(text) from public, anon, authenticated;
revoke all on function public.fin_data_closer_canonico(text, text) from public, anon, authenticated;
revoke all on function public.fin_data_columnas_de(text) from public, anon;
revoke all on function public.fin_data_permisos(text) from public, anon;
revoke all on function public.fin_data_fila_para_editar(bigint, text) from public, anon, authenticated;
revoke all on function public.fin_data_guardar(bigint, text, text) from public, anon;
revoke all on function public.fin_data_closers_de(text) from public, anon;
revoke all on function public.fin_data_llamada_crear(text, date, text, text, jsonb) from public, anon;

grant execute on function public.fin_data_columnas_de(text) to authenticated;
grant execute on function public.fin_data_permisos(text) to authenticated;
grant execute on function public.fin_data_guardar(bigint, text, text) to authenticated;
grant execute on function public.fin_data_closers_de(text) to authenticated;
grant execute on function public.fin_data_llamada_crear(text, date, text, text, jsonb) to authenticated;


-- (Los usuarios, sus roles y sus clientes los da de alta la 075 de Finanzas:
-- esta migracion no escribe en crm_members ni en crm_asignaciones.)


-- =====================================================================
-- 6. PRUEBA DE HUMO (se revierte sola; corre como fundador)
-- =====================================================================
do $humo$
declare
  v_fund  text := (select user_id::text from public.crm_members where rol = 'fundador' limit 1);
  v_id    bigint;
  v_j     jsonb;
  v_t     text;
  v_err   text;
begin
  begin
    if v_fund is null then raise exception 'humo 0: no hay fundador'; end if;
    perform set_config('request.jwt.claim.sub', v_fund, true);

    if not (public.fin_data_permisos('liam')->>'agregar_llamadas')::boolean then
      raise exception 'humo 1: liam no puede agregar llamadas (permisos %)', public.fin_data_permisos('liam');
    end if;

    v_j := public.fin_data_closers_de('liam');
    if not exists (select 1 from jsonb_array_elements_text(v_j) e
                   where public.fin_normalizar_nombre(e) = 'ivan binsztein')
       or not exists (select 1 from jsonb_array_elements_text(v_j) e
                      where public.fin_normalizar_nombre(e) = 'lucas deza') then
      raise exception 'humo 2: faltan closers en %', v_j;
    end if;
    if exists (select 1 from jsonb_array_elements_text(v_j) e where lower(e) like '%ortu%') then
      raise exception 'humo 3: Matias Ortuno sigue en la lista %', v_j;
    end if;

    v_id := public.fin_data_llamada_crear('liam', current_date, '  Prueba Humo  ', 'ivan',
      '{"estado_llamada":"ghosteado","programa":"gestion de capital","show_up":"si","cc_dia1":"1500,50"}'::jsonb);
    if (select origen || '|' || nombre || '|' || public.fin_normalizar_nombre(closer) || '|'
               || estado_llamada || '|' || programa
          from public.fin_llamadas where id = v_id)
       <> 'app|Prueba Humo|ivan binsztein|GHOSTEADO|GESTION DE CAPITAL' then
      raise exception 'humo 4: la llamada quedo mal';
    end if;

    begin
      perform public.fin_data_guardar(v_id, 'estado_llamada', 'SEGUIMIENTO CUOTAS');
      raise exception 'humo 5: acepto SEGUIMIENTO CUOTAS';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_guardar(v_id, 'closer', U&'Matias Ortu\00F1o');
      raise exception 'humo 6: acepto a Matias como closer';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_llamada_crear('liam', current_date, 'X', 'ivan', '{"programa":"inventado"}'::jsonb);
      raise exception 'humo 7: acepto un programa inventado';
    exception when invalid_parameter_value then null;
    end;
    begin
      perform public.fin_data_llamada_crear('teo', current_date, 'X', 'teo', '{}'::jsonb);
      raise exception 'humo 8: agrego una llamada en teo (sin corte)';
    exception when object_not_in_prerequisite_state then null;
    end;

    -- sheet cortada: una fila vieja de liam ya se edita
    select id into v_id from public.fin_llamadas
     where cliente_id = 'liam' and origen = 'sheet' order by id desc limit 1;
    if v_id is not null then
      v_t := public.fin_data_guardar(v_id, 'show_up', 'SI');
      if v_t <> 'si' then raise exception 'humo 9: show_up %', v_t; end if;
    end if;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '077 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 8. CONTROLES (correr de a uno, despues del Success)
-- =====================================================================
-- C1. Esta migracion no toca usuarios: solo se verifica que la 075 los dejo
--     (esperado: 6 filas; roles fundador, cliente, finanzas, ventas, producto,
--     contenido).
-- select u.email, m.rol,
--        (select string_agg(a.cliente_id, ',' order by a.cliente_id)
--           from public.crm_asignaciones a where a.user_id = u.id) as clientes
--   from auth.users u join public.crm_members m on m.user_id = u.id
--  where lower(u.email) like '%@liam.dystopia' or lower(u.email) = 'fundador@agencia.dystopia'
--  order by 1;

-- C2. Corte de liam: 1 fila, activo=false, cortada_en con fecha. Los otros
--     clientes siguen activos y sin corte.
-- select cliente_id, tipo, activo, cortada_en from public.fin_fuentes
--  where tipo = 'data' order by 1;

-- C3. Closers de liam en la lista (esperado lista_closers = true solo para
--     BPF, Ivan Binsztein y Lucas Deza). En el SQL Editor no hay usuario, asi
--     que fin_data_closers_de() daria []: se mira la tabla.
-- select p.alias, p.campo, v.nombre, p.lista_closers
--   from public.fin_personas p left join public.fin_vendedores v on v.id = p.vendedor_id
--  where p.cliente_id = 'liam' order by p.lista_closers desc, v.nombre, p.alias;

-- C4. Estados de liam: no tiene que haber SEGUIMIENTO CUOTAS ni ADENTRO EN
--     CHAT ni ADENTRO LLAMADA. Tiene que dar 0.
-- select count(*) from public.fin_llamadas
--  where cliente_id = 'liam'
--    and upper(btrim(estado_llamada)) in ('SEGUIMIENTO CUOTAS','ADENTRO EN CHAT','ADENTRO LLAMADA');

-- C5. Catalogo de liam: estado 7 activos + GHOSTEADO, programa 3.
-- select dimension, valor, activo from public.fin_catalogos
--  where cliente_id = 'liam' and dimension in ('estado','programa') order by 1, orden;

-- C6. Las politicas aditivas existen: 3 filas (fin_llamadas, fin_catalogos,
--     fin_formulario_preguntas) y ninguna *_lectura_ventas vieja.
-- select tablename, policyname from pg_policies
--  where policyname like '%_lectura_areas' or policyname like '%_lectura_ventas' order by 1;

-- C7. Nada cambio en otros clientes: conteos iguales a antes de correrla.
-- select cliente_id, count(*), count(*) filter (where origen <> 'sheet') as no_sheet
--   from public.fin_llamadas group by 1 order by 1;

-- C8. Prueba de verdad: entrar con cada usuario (ver LEEME de la tarea).
