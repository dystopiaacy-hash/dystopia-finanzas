-- =====================================================================
-- 142_ventas_ia_analisis_llamadas.sql
-- Ventas, IA fase 3: analisis de las llamadas de venta grabadas con Fathom.
--
-- QUE HACE
--   1. fin_cliente_config: texto "estructura de venta" por cliente (lo carga
--      la agencia; si esta, la IA evalua contra esa estructura, si no contra
--      la estandar). Se guarda con fin_estructura_venta_guardar (solo fundador).
--   2. fin_llamadas_fathom: VINCULO reunion de Fathom <-> llamada de venta de
--      fin_llamadas, por mail del invitado + hora de la agenda (tolerancia
--      90 min; sin hora, mismo dia). Lo llena fin_ia_vincular_fathom().
--      OJO: la sync de Sheets borra y recrea las filas origen 'sheet' de
--      fin_llamadas (ids nuevos cada vez), por eso NO hay FK a fin_llamadas.id:
--      el vinculo guarda cliente + fecha + mail de la llamada y la vista
--      fin_v_llamada_analisis la vuelve a encontrar sola.
--   3. fin_llamadas_analisis: el analisis de cada reunion vinculada (lo escribe
--      la Edge Function ventas-ia-llamadas con claude-sonnet-5-5): objeciones,
--      como se respondio cada una, puntaje 1-10 por etapa (apertura,
--      diagnostico, presentacion, manejo de objeciones, cierre), resultado
--      probable y mejoras. NO guarda la transcripcion.
--   4. fin_devoluciones_closer: devolucion semanal por closer (lunes 8:22 ART).
--   5. Vistas fin_v_llamada_analisis (una fila por llamada, para el detalle) y
--      fin_v_analisis_llamadas (una fila por analisis, para la pantalla).
--      Las dos con security_invoker: valen las politicas de las tablas.
--   6. Cron: ventas_ia_procesar (minutos 24, 38, 52: vincula y analiza lo
--      pendiente) y ventas_ia_devolucion (lunes 11:22 UTC = 8:22 ART). La URL
--      de la funcion va a Vault (ventas_ia_url); la clave es la misma de la sync
--      (fin_sync_service_key).
--
-- QUIEN VE QUE (RLS): fundador todo; ventas los clientes que tiene asignados
--   (fin_asignado); closer solo lo suyo (alias o mismo vendedor_id en
--   fin_personas). Escribe solo service_role (la Edge Function). El rol
--   cliente NO lo ve (decision de la tarea).
--
-- NO TOCA fin_llamadas, vistas de metricas ni la sync de Fathom (Producto).
--
-- ORDEN: correr los BLOQUES de a uno, fuera de :00/:15/:30/:45. El 4 (cron)
-- solo DESPUES de desplegar la Edge Function ventas-ia-llamadas.
-- Sin begin/commit (SQL Editor). Idempotente.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (si algo falta, corta con un mensaje claro)
-- ---------------------------------------------------------------------
do $g$
declare v_falta text;
begin
  select string_agg(t, ', ') into v_falta
  from unnest(array['crm_clients', 'fin_llamadas', 'fin_personas', 'fin_fuentes',
                    'cs_fathom_sin_asignar', 'cs_llamadas', 'cs_llamada_transcripciones']) t
  where to_regclass('public.' || t) is null;
  if v_falta is not null then
    raise exception '142: faltan tablas: % (Producto: migraciones 122 a 127; Ventas: 131)', v_falta;
  end if;
  if to_regprocedure('public.es_fundador()') is null or to_regprocedure('public.rol_actual()') is null
     or to_regprocedure('public.fin_asignado(text)') is null
     or to_regprocedure('public.fin_data_closer_canonico(text,text)') is null then
    raise exception '142: faltan funciones es_fundador / rol_actual / fin_asignado / fin_data_closer_canonico';
  end if;
  select string_agg(c, ', ') into v_falta
  from unnest(array['fin_llamadas.estado_agenda', 'fin_llamadas.email', 'fin_llamadas.hora_llamada',
                    'cs_fathom_sin_asignar.consultor', 'cs_fathom_sin_asignar.invitados', 'cs_fathom_sin_asignar.transcripcion',
                    'cs_llamadas.consultor', 'cs_llamadas.invitados', 'cs_llamadas.inicio_at']) c
  where not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = split_part(c, '.', 1)
                       and column_name = split_part(c, '.', 2));
  if v_falta is not null then
    raise exception '142: faltan columnas: %', v_falta;
  end if;
  if to_regclass('public.ia_uso') is null then
    raise exception '142: falta ia_uso (migracion 137)';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Tablas, permisos y vistas
-- ---------------------------------------------------------------------

-- Quien puede ver un analisis de (cliente, closer).
create or replace function public.fin_ia_puede_ver(p_cliente text, p_closer text)
returns boolean
language sql stable security definer set search_path = public
as $fn$
  select coalesce(public.es_fundador(), false)
      or (public.rol_actual() = 'ventas' and public.fin_asignado(p_cliente))
      or (public.rol_actual() = 'closer' and p_closer is not null and exists (
            select 1 from public.fin_personas p
             where p.user_id = auth.uid() and p.cliente_id = p_cliente
               and p.campo in ('closer', 'ambos')
               and (lower(btrim(p.alias)) = lower(btrim(p_closer))
                    or (p.vendedor_id is not null and exists (
                          select 1 from public.fin_personas q
                           where q.cliente_id = p_cliente and q.vendedor_id = p.vendedor_id
                             and lower(btrim(q.alias)) = lower(btrim(p_closer)))))))
$fn$;
revoke all on function public.fin_ia_puede_ver(text, text) from public, anon;
grant execute on function public.fin_ia_puede_ver(text, text) to authenticated, service_role;

-- 1. Config por cliente
create table if not exists public.fin_cliente_config (
  cliente_id       text primary key references public.crm_clients(id) on delete cascade,
  estructura_venta text check (estructura_venta is null or char_length(estructura_venta) <= 20000),
  actualizado_en   timestamptz not null default now(),
  actualizado_por  uuid
);
comment on table public.fin_cliente_config is
  'Config de Ventas por cliente (142). estructura_venta: guion o estructura de venta del cliente; la IA evalua las llamadas contra ella. Vacio = estructura estandar.';

-- 2. Vinculo reunion de Fathom <-> llamada de venta
create table if not exists public.fin_llamadas_fathom (
  externo_id      text primary key,                  -- 'fathom:<recording_id>' (el mismo de Producto)
  cliente_id      text not null references public.crm_clients(id) on delete cascade,
  llamada_id      bigint,                            -- puntero blando: la sync de Sheets recrea las filas
  fecha_llamada   date not null,
  hora_llamada    time,
  email           text not null check (email = lower(btrim(email)) and position('@' in email) > 1),
  nombre          text,
  closer          text,                              -- alias canonico del closer de la agenda
  origen          text not null check (origen in ('sin_asignar', 'cs_llamadas')),
  reunion_inicio  timestamptz,
  titulo          text,
  grabacion_url   text,
  consultor       text,                              -- de que cuenta de Fathom salio
  duracion_min    int,
  diferencia_min  int,                               -- reunion - agenda, en minutos (null si la agenda no tenia hora)
  vinculado_en    timestamptz not null default now(),
  actualizado_en  timestamptz not null default now()
);
create index if not exists fin_llamadas_fathom_llamada_idx on public.fin_llamadas_fathom (cliente_id, fecha_llamada, email);
create index if not exists fin_llamadas_fathom_closer_idx  on public.fin_llamadas_fathom (cliente_id, closer);
comment on table public.fin_llamadas_fathom is
  'Vinculo entre una reunion de Fathom (Producto) y una llamada de venta de fin_llamadas (142). Sin FK a fin_llamadas.id: la sync de Sheets recrea esas filas.';

-- 3. Analisis de cada reunion
create table if not exists public.fin_llamadas_analisis (
  externo_id         text primary key references public.fin_llamadas_fathom(externo_id) on delete cascade,
  cliente_id         text not null references public.crm_clients(id) on delete cascade,
  closer             text,
  estado             text not null check (estado in ('ok', 'error', 'omitida')),
  motivo             text check (motivo is null or char_length(motivo) <= 300),
  intentos           int not null default 0,
  estructura_usada   text check (estructura_usada is null or estructura_usada in ('estandar', 'cliente')),
  resultado_probable text check (resultado_probable is null or resultado_probable in ('cerrada', 'seguimiento', 'perdida', 'indeterminado')),
  resumen            text,
  p_apertura         smallint check (p_apertura between 1 and 10),
  p_diagnostico      smallint check (p_diagnostico between 1 and 10),
  p_presentacion     smallint check (p_presentacion between 1 and 10),
  p_objeciones       smallint check (p_objeciones between 1 and 10),
  p_cierre           smallint check (p_cierre between 1 and 10),
  puntaje_total      numeric(3,1) generated always as (
    case when p_apertura is not null and p_diagnostico is not null and p_presentacion is not null
              and p_objeciones is not null and p_cierre is not null
         then round((p_apertura + p_diagnostico + p_presentacion + p_objeciones + p_cierre)::numeric / 5, 1) end) stored,
  detalle_etapas     jsonb not null default '{}'::jsonb check (jsonb_typeof(detalle_etapas) = 'object'),
  objeciones         jsonb not null default '[]'::jsonb check (jsonb_typeof(objeciones) = 'array'),
  mejoras            jsonb not null default '[]'::jsonb check (jsonb_typeof(mejoras) = 'array'),
  modelo             text,
  tokens_entrada     int,
  tokens_salida      int,
  costo_usd          numeric(10,6),
  analizado_en       timestamptz not null default now(),
  analizado_por      uuid                              -- null = cron
);
create index if not exists fin_llamadas_analisis_cliente_idx on public.fin_llamadas_analisis (cliente_id, analizado_en desc);
create index if not exists fin_llamadas_analisis_closer_idx  on public.fin_llamadas_analisis (cliente_id, closer);
comment on table public.fin_llamadas_analisis is
  'Analisis de IA de una llamada de venta (142). No guarda la transcripcion. objeciones: [{objecion, categoria, respuesta, efectiva}]; mejoras: [{titulo, detalle}].';

-- 4. Devolucion semanal por closer
create table if not exists public.fin_devoluciones_closer (
  id                bigint generated always as identity primary key,
  cliente_id        text not null references public.crm_clients(id) on delete cascade,
  closer            text not null,
  semana_inicio     date not null check (extract(isodow from semana_inicio) = 1),   -- lunes
  n_llamadas        int not null check (n_llamadas >= 0),
  promedio          numeric(3,1),
  promedios_etapas  jsonb not null default '{}'::jsonb check (jsonb_typeof(promedios_etapas) = 'object'),
  resumen           text,
  objeciones        jsonb not null default '[]'::jsonb check (jsonb_typeof(objeciones) = 'array'),
  mejoras           jsonb not null default '[]'::jsonb check (jsonb_typeof(mejoras) = 'array'),
  modelo            text,
  costo_usd         numeric(10,6),
  generada_en       timestamptz not null default now(),
  unique (cliente_id, closer, semana_inicio)
);
comment on table public.fin_devoluciones_closer is
  'Devolucion semanal por closer (142): resumen de la semana, objeciones mas frecuentes y 2 o 3 mejoras. Semana = lunes a domingo (hora de Buenos Aires).';

-- Permisos: lectura segun fin_ia_puede_ver, escritura solo service_role.
do $p$
declare t text;
begin
  foreach t in array array['fin_cliente_config', 'fin_llamadas_fathom', 'fin_llamadas_analisis', 'fin_devoluciones_closer'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
    execute format('grant select, insert, update, delete on table public.%I to service_role', t);
  end loop;
end
$p$;

drop policy if exists fin_cliente_config_lectura on public.fin_cliente_config;
create policy fin_cliente_config_lectura on public.fin_cliente_config for select to authenticated
  using (public.es_fundador() or (public.rol_actual() = 'ventas' and public.fin_asignado(cliente_id)));

drop policy if exists fin_llamadas_fathom_lectura on public.fin_llamadas_fathom;
create policy fin_llamadas_fathom_lectura on public.fin_llamadas_fathom for select to authenticated
  using (public.fin_ia_puede_ver(cliente_id, closer));

drop policy if exists fin_llamadas_analisis_lectura on public.fin_llamadas_analisis;
create policy fin_llamadas_analisis_lectura on public.fin_llamadas_analisis for select to authenticated
  using (public.fin_ia_puede_ver(cliente_id, closer));

drop policy if exists fin_devoluciones_closer_lectura on public.fin_devoluciones_closer;
create policy fin_devoluciones_closer_lectura on public.fin_devoluciones_closer for select to authenticated
  using (public.fin_ia_puede_ver(cliente_id, closer));

-- Guardar la estructura de venta (solo fundador).
create or replace function public.fin_estructura_venta_guardar(p_cliente text, p_texto text)
returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  if not coalesce(public.es_fundador(), false) then
    raise exception 'sin permiso' using errcode = '42501';
  end if;
  if not exists (select 1 from public.crm_clients where id = p_cliente) then
    raise exception 'cliente inexistente: %', p_cliente using errcode = '22023';
  end if;
  if char_length(coalesce(p_texto, '')) > 20000 then
    raise exception 'la estructura de venta no puede pasar de 20000 caracteres' using errcode = '22023';
  end if;
  insert into public.fin_cliente_config (cliente_id, estructura_venta, actualizado_en, actualizado_por)
  values (p_cliente, nullif(btrim(coalesce(p_texto, '')), ''), now(), auth.uid())
  on conflict (cliente_id) do update
    set estructura_venta = excluded.estructura_venta, actualizado_en = now(), actualizado_por = auth.uid();
end
$fn$;
revoke all on function public.fin_estructura_venta_guardar(text, text) from public, anon;
grant execute on function public.fin_estructura_venta_guardar(text, text) to authenticated;

-- Vistas (security_invoker: rigen las politicas de las tablas de abajo).
create or replace view public.fin_v_llamada_analisis with (security_invoker = true) as
select l.id as llamada_id, f.externo_id, f.grabacion_url, f.reunion_inicio, f.duracion_min,
       a.estado, a.motivo, a.estructura_usada, a.resultado_probable, a.resumen,
       a.p_apertura, a.p_diagnostico, a.p_presentacion, a.p_objeciones, a.p_cierre, a.puntaje_total,
       a.detalle_etapas, a.objeciones, a.mejoras, a.analizado_en
  from public.fin_llamadas_fathom f
  join public.fin_llamadas l
    on l.cliente_id = f.cliente_id and l.fecha_llamada = f.fecha_llamada
   and lower(btrim(coalesce(l.email, ''))) = f.email
   and coalesce(l.estado_agenda, '') <> 'cancelada'
  left join public.fin_llamadas_analisis a on a.externo_id = f.externo_id;

create or replace view public.fin_v_analisis_llamadas with (security_invoker = true) as
select a.externo_id, a.cliente_id, f.closer, f.nombre, f.fecha_llamada, f.reunion_inicio, f.grabacion_url, f.duracion_min,
       a.estado, a.motivo, a.estructura_usada, a.resultado_probable, a.resumen,
       a.p_apertura, a.p_diagnostico, a.p_presentacion, a.p_objeciones, a.p_cierre, a.puntaje_total,
       a.detalle_etapas, a.objeciones, a.mejoras, a.analizado_en
  from public.fin_llamadas_analisis a
  join public.fin_llamadas_fathom f on f.externo_id = a.externo_id;

revoke all on public.fin_v_llamada_analisis, public.fin_v_analisis_llamadas from anon;
grant select on public.fin_v_llamada_analisis, public.fin_v_analisis_llamadas to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Funciones de la Edge Function (solo service_role)
-- ---------------------------------------------------------------------

-- Vincula reuniones de Fathom con llamadas de venta: mismo mail de invitado y
-- hora de la agenda dentro de la tolerancia (sin hora en la agenda: mismo dia).
-- Cada reunion queda con la llamada mas cercana. Idempotente: refresca los datos
-- de la agenda si la llamada se reprogramo.
create or replace function public.fin_ia_vincular_fathom(p_dias integer default 21, p_tolerancia_min integer default 90)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_nuevas integer;
  v_total  integer;
begin
  with reu as (
    select 'sin_asignar'::text as origen, s.externo_id, s.inicio_at, s.titulo, s.grabacion_url,
           s.consultor::text as consultor, s.duracion_min, s.invitados
      from public.cs_fathom_sin_asignar s
     where s.inicio_at >= now() - make_interval(days => p_dias + 1)
    union all
    select 'cs_llamadas'::text, c.externo_id, c.inicio_at, c.titulo, c.grabacion_url,
           c.consultor::text, c.duracion_min, c.invitados
      from public.cs_llamadas c
     where c.externo_id like 'fathom:%' and c.inicio_at >= now() - make_interval(days => p_dias + 1)
  ), reu1 as (
    select distinct on (externo_id) * from reu order by externo_id, (origen = 'cs_llamadas') desc
  ), mails as (
    select r.*, lower(btrim(case when jsonb_typeof(e) = 'string' then e #>> '{}' else e ->> 'email' end)) as email
      from reu1 r
      cross join lateral jsonb_array_elements(case when jsonb_typeof(r.invitados) = 'array' then r.invitados else '[]'::jsonb end) e
  ), ll as (
    select l.id, l.cliente_id, l.fecha_llamada, l.hora_llamada, lower(btrim(l.email)) as email, l.nombre, l.closer,
           case when l.hora_llamada is not null
                then (l.fecha_llamada + l.hora_llamada) at time zone 'America/Argentina/Buenos_Aires' end as ini
      from public.fin_llamadas l
     where l.fecha_llamada >= current_date - p_dias and l.fecha_llamada <= current_date + 1
       and position('@' in coalesce(l.email, '')) > 1
       and coalesce(l.estado_agenda, '') <> 'cancelada'
  ), par as (
    select distinct on (m.externo_id)
           m.externo_id, m.origen, m.inicio_at, m.titulo, m.grabacion_url, m.consultor, m.duracion_min, m.email,
           ll.id as llamada_id, ll.cliente_id, ll.fecha_llamada, ll.hora_llamada, ll.nombre as nombre_ll, ll.closer as closer_ll,
           case when ll.ini is not null then round(extract(epoch from (m.inicio_at - ll.ini)) / 60)::int end as dif
      from mails m
      join ll on ll.email = m.email
     where m.inicio_at is not null and m.email is not null and position('@' in m.email) > 1
       and ((ll.ini is not null and abs(extract(epoch from (m.inicio_at - ll.ini))) <= p_tolerancia_min * 60)
         or (ll.ini is null and (m.inicio_at at time zone 'America/Argentina/Buenos_Aires')::date = ll.fecha_llamada))
     order by m.externo_id, abs(coalesce(extract(epoch from (m.inicio_at - ll.ini)), 0)), ll.id
  ), ins as (
    insert into public.fin_llamadas_fathom as f
      (externo_id, cliente_id, llamada_id, fecha_llamada, hora_llamada, email, nombre, closer, origen,
       reunion_inicio, titulo, grabacion_url, consultor, duracion_min, diferencia_min)
    select p.externo_id, p.cliente_id, p.llamada_id, p.fecha_llamada, p.hora_llamada, p.email, p.nombre_ll,
           coalesce(public.fin_data_closer_canonico(p.cliente_id, p.closer_ll), p.closer_ll), p.origen,
           p.inicio_at, left(p.titulo, 200), p.grabacion_url, p.consultor, p.duracion_min, p.dif
      from par p
    on conflict (externo_id) do update set
      cliente_id = excluded.cliente_id, llamada_id = excluded.llamada_id, fecha_llamada = excluded.fecha_llamada,
      hora_llamada = excluded.hora_llamada, email = excluded.email, nombre = excluded.nombre, closer = excluded.closer,
      origen = excluded.origen, reunion_inicio = excluded.reunion_inicio, titulo = excluded.titulo,
      grabacion_url = excluded.grabacion_url, consultor = excluded.consultor, duracion_min = excluded.duracion_min,
      diferencia_min = excluded.diferencia_min, actualizado_en = now()
    returning (xmax = 0) as nueva
  )
  select count(*) filter (where nueva), count(*) into v_nuevas, v_total from ins;

  return jsonb_build_object('vinculos_nuevos', v_nuevas, 'vinculos_revisados', v_total);
end
$fn$;

-- Transcripcion y resumen de una reunion (pueden estar en cualquiera de las dos tablas de Producto).
create or replace function public.fin_ia_reunion(p_externo_id text)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  v_t  text;
  v_r  text;
  v_t2 text;
  v_r2 text;
begin
  select s.transcripcion, s.resumen into v_t, v_r from public.cs_fathom_sin_asignar s where s.externo_id = p_externo_id;
  if v_t is null then
    select t.texto, l.resumen into v_t2, v_r2
      from public.cs_llamadas l left join public.cs_llamada_transcripciones t on t.llamada_id = l.id
     where l.externo_id = p_externo_id;
    v_t := v_t2;
    v_r := coalesce(v_r, v_r2);
  end if;
  return jsonb_build_object('transcripcion', v_t, 'resumen', v_r);
end
$fn$;

-- Reuniones de una llamada de venta (para el boton "Analizar").
create or replace function public.fin_ia_externos_de_llamada(p_llamada bigint)
returns text[]
language sql stable security definer set search_path = public
as $fn$
  select coalesce(array_agg(f.externo_id order by f.reunion_inicio), '{}'::text[])
    from public.fin_llamadas l
    join public.fin_llamadas_fathom f
      on f.cliente_id = l.cliente_id and f.fecha_llamada = l.fecha_llamada
     and f.email = lower(btrim(coalesce(l.email, '')))
   where l.id = p_llamada
$fn$;

-- Pendientes de analizar: vinculadas, ya terminadas (25 min), sin analisis o con
-- error reciente reintentable (menos de 3 intentos, 1 hora entre intentos).
-- Las mas nuevas primero.
create or replace function public.fin_ia_pendientes(p_max integer default 5)
returns table (externo_id text, cliente_id text, closer text, nombre text, fecha_llamada date, reunion_inicio timestamptz)
language sql stable security definer set search_path = public
as $fn$
  select f.externo_id, f.cliente_id, f.closer, f.nombre, f.fecha_llamada, f.reunion_inicio
    from public.fin_llamadas_fathom f
    left join public.fin_llamadas_analisis a on a.externo_id = f.externo_id
   where f.reunion_inicio < now() - interval '25 minutes'
     and f.reunion_inicio > now() - interval '30 days'
     and (a.externo_id is null
          or (a.estado = 'error' and a.intentos < 3 and a.analizado_en < now() - interval '1 hour'))
   order by f.reunion_inicio desc
   limit greatest(coalesce(p_max, 5), 1)
$fn$;

do $perm$
declare f text;
begin
  foreach f in array array['fin_ia_vincular_fathom(integer,integer)', 'fin_ia_reunion(text)',
                           'fin_ia_externos_de_llamada(bigint)', 'fin_ia_pendientes(integer)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end
$perm$;

-- ---------------------------------------------------------------------
-- BLOQUE 3. PRUEBA DE HUMO (se revierte sola: termina en una excepcion
--           "HUMO OK ..."; si algo falla dice "HUMO FALLO ..." y tambien
--           revierte). Usa el cliente liam y mails @example.com.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_fuente bigint;
  v_ini    timestamptz := date_trunc('minute', now()) - interval '3 hours';
  v_f      date := ((date_trunc('minute', now()) - interval '3 hours') at time zone 'America/Argentina/Buenos_Aires')::date;
  v_h      time := ((date_trunc('minute', now()) - interval '3 hours') at time zone 'America/Argentina/Buenos_Aires')::time;
  v_r      jsonb;
  v_n      integer;
  v_dif    integer;
  v_tot    numeric;
begin
  select id into v_fuente from public.fin_fuentes where cliente_id = 'liam' and tipo = 'data' limit 1;
  if v_fuente is null then raise exception 'HUMO FALLO: liam no tiene fuente data'; end if;

  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, hora_llamada, closer, nombre, email, origen)
  values ('liam', v_fuente, null, v_f, v_h, 'PRUEBA CLOSER', 'PRUEBA 142', 'humo142@example.com', 'app');

  -- A: a los 20 min de la agenda, con el mail -> vincula
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, inicio_at, titulo, invitados, transcripcion)
  values ('fathom:HUMO142A', v_f, v_ini + interval '20 minutes', 'Llamada humo A', '["humo142@example.com"]'::jsonb, 'Closer: hola. Lead: hola.');
  -- B: mismo mail pero 4 horas despues -> fuera de tolerancia
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, inicio_at, titulo, invitados)
  values ('fathom:HUMO142B', v_f, v_ini + interval '4 hours', 'Llamada humo B', '["humo142@example.com"]'::jsonb);
  -- C: a la hora pero otro mail -> no vincula
  insert into public.cs_fathom_sin_asignar (externo_id, fecha, inicio_at, titulo, invitados)
  values ('fathom:HUMO142C', v_f, v_ini, 'Llamada humo C', '["otro142@example.com"]'::jsonb);

  v_r := public.fin_ia_vincular_fathom();
  select count(*) into v_n from public.fin_llamadas_fathom where externo_id in ('fathom:HUMO142A', 'fathom:HUMO142B', 'fathom:HUMO142C');
  if v_n <> 1 then raise exception 'HUMO FALLO 1: se esperaba 1 vinculo (solo A) y hay % (%)', v_n, v_r; end if;
  select diferencia_min into v_dif from public.fin_llamadas_fathom where externo_id = 'fathom:HUMO142A';
  if v_dif is distinct from 20 then raise exception 'HUMO FALLO 2: diferencia_min esperada 20 y es %', v_dif; end if;

  -- idempotente: otra pasada no duplica
  v_r := public.fin_ia_vincular_fathom();
  select count(*) into v_n from public.fin_llamadas_fathom where externo_id like 'fathom:HUMO142%';
  if v_n <> 1 then raise exception 'HUMO FALLO 3: la segunda pasada dejo % vinculos', v_n; end if;

  -- la vista encuentra la llamada y las funciones de apoyo responden
  select count(*) into v_n from public.fin_v_llamada_analisis where externo_id = 'fathom:HUMO142A';
  if v_n <> 1 then raise exception 'HUMO FALLO 4: fin_v_llamada_analisis devolvio % filas', v_n; end if;
  if (public.fin_ia_reunion('fathom:HUMO142A') ->> 'transcripcion') is distinct from 'Closer: hola. Lead: hola.' then
    raise exception 'HUMO FALLO 5: fin_ia_reunion no trajo la transcripcion';
  end if;
  select count(*) into v_n from public.fin_ia_pendientes(50) where externo_id = 'fathom:HUMO142A';
  if v_n <> 1 then raise exception 'HUMO FALLO 6: fin_ia_pendientes no lista la reunion (%)', v_n; end if;
  if cardinality(public.fin_ia_externos_de_llamada((select id from public.fin_llamadas where nombre = 'PRUEBA 142' limit 1))) <> 1 then
    raise exception 'HUMO FALLO 7: fin_ia_externos_de_llamada';
  end if;

  -- analisis: el total sale solo y el puntaje fuera de 1-10 se rechaza
  insert into public.fin_llamadas_analisis (externo_id, cliente_id, closer, estado, resultado_probable,
                                            p_apertura, p_diagnostico, p_presentacion, p_objeciones, p_cierre)
  values ('fathom:HUMO142A', 'liam', 'PRUEBA CLOSER', 'ok', 'cerrada', 8, 7, 6, 7, 7);
  select puntaje_total into v_tot from public.fin_llamadas_analisis where externo_id = 'fathom:HUMO142A';
  if v_tot is distinct from 7.0 then raise exception 'HUMO FALLO 8: puntaje_total esperado 7.0 y es %', v_tot; end if;
  begin
    update public.fin_llamadas_analisis set p_cierre = 11 where externo_id = 'fathom:HUMO142A';
    raise exception 'HUMO FALLO 9: acepto un puntaje de 11';
  exception when check_violation then null;
  end;
  select count(*) into v_n from public.fin_ia_pendientes(50) where externo_id = 'fathom:HUMO142A';
  if v_n <> 0 then raise exception 'HUMO FALLO 10: una reunion ya analizada sigue pendiente'; end if;

  -- sin sesion nadie ve nada
  if public.fin_ia_puede_ver('liam', 'PRUEBA CLOSER') then raise exception 'HUMO FALLO 11: fin_ia_puede_ver da true sin sesion'; end if;

  raise exception 'HUMO OK: 11 pruebas pasaron (vinculo por mail y hora, fuera de tolerancia, otro mail, idempotente, vista, apoyo, analisis, permisos). Se revirtio todo.';
end
$humo$;
-- Resultado esperado: ERROR "HUMO OK: ...". Cualquier "HUMO FALLO" = avisar.

-- ---------------------------------------------------------------------
-- BLOQUE 4. Cron. Correr DESPUES de desplegar ventas-ia-llamadas
--           (supabase functions deploy ventas-ia-llamadas --no-verify-jwt)
--           y de mirar los controles C1 a C5.
--   ventas_ia_procesar   : minutos 24, 38 y 52 de cada hora (vincula y analiza lo pendiente)
--   ventas_ia_devolucion : lunes 11:22 UTC = 8:22 ART (devolucion semanal)
-- ---------------------------------------------------------------------
do $v$
begin
  if not exists (select 1 from vault.decrypted_secrets where name = 'fin_sync_service_key') then
    raise exception '142: falta el secreto fin_sync_service_key en Vault (ver 004_cron.sql, paso 0)';
  end if;
  if not exists (select 1 from vault.decrypted_secrets where name = 'ventas_ia_url') then
    perform vault.create_secret('https://alxdjcdfpdayucassfub.supabase.co/functions/v1/ventas-ia-llamadas', 'ventas_ia_url');
  end if;
end
$v$;

select cron.unschedule(jobid) from cron.job where jobname in ('ventas_ia_procesar', 'ventas_ia_devolucion');

select cron.schedule('ventas_ia_procesar', '24,38,52 * * * *',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'ventas_ia_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_service_key')),
      body    := '{"accion":"procesar"}'::jsonb,
      timeout_milliseconds := 150000
    );
  $cron$);

select cron.schedule('ventas_ia_devolucion', '22 11 * * 1',
  $cron$
    select net.http_post(
      url     := (select decrypted_secret from vault.decrypted_secrets where name = 'ventas_ia_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'fin_sync_service_key')),
      body    := '{"accion":"devolucion"}'::jsonb,
      timeout_milliseconds := 150000
    );
  $cron$);

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. Las 4 tablas y las 2 vistas existen, con RLS en las tablas: 6 filas.
-- select c.relname, c.relkind::text as tipo, c.relrowsecurity as rls
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public'
--    and c.relname in ('fin_cliente_config','fin_llamadas_fathom','fin_llamadas_analisis','fin_devoluciones_closer',
--                      'fin_v_llamada_analisis','fin_v_analisis_llamadas')
--  order by 1;

-- C2. Las funciones: las de la Edge Function solo para service_role (authenticated = false);
--     fin_ia_puede_ver y fin_estructura_venta_guardar para authenticated. 6 filas.
-- select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('fin_ia_vincular_fathom','fin_ia_reunion','fin_ia_externos_de_llamada','fin_ia_pendientes',
--                      'fin_ia_puede_ver','fin_estructura_venta_guardar')
--  order by 1;

-- C3. El humo no dejo nada: 0 | 0 | 0.
-- select (select count(*) from fin_llamadas_fathom where externo_id like 'fathom:HUMO142%') as vinculos_prueba,
--        (select count(*) from cs_fathom_sin_asignar where externo_id like 'fathom:HUMO142%') as reuniones_prueba,
--        (select count(*) from fin_llamadas where nombre = 'PRUEBA 142') as llamadas_prueba;

-- C4. Primera pasada A MANO del vinculo (ver cuantas llamadas de venta ya tienen reunion en Fathom):
-- select public.fin_ia_vincular_fathom();
-- select cliente_id, count(*) as vinculos, min(diferencia_min) as dif_min, max(diferencia_min) as dif_max
--   from fin_llamadas_fathom group by 1 order by 1;
--   (si salen vinculos con diferencia rara, mirar los extremos antes de analizar:)
-- select externo_id, cliente_id, nombre, closer, fecha_llamada, hora_llamada, reunion_inicio, diferencia_min, consultor
--   from fin_llamadas_fathom order by abs(coalesce(diferencia_min, 0)) desc limit 20;

-- C5. Llamadas de venta de los ultimos 21 dias SIN reunion de Fathom (para saber cuanto falta cubrir:
--     closers que graban con cuentas propias no entran hasta cargar su key en cs_fathom_consultores):
-- select l.cliente_id, count(*) as con_mail, count(f.externo_id) as con_reunion
--   from fin_llamadas l
--   left join fin_llamadas_fathom f on f.cliente_id = l.cliente_id and f.fecha_llamada = l.fecha_llamada
--                                  and f.email = lower(btrim(coalesce(l.email, '')))
--  where l.fecha_llamada >= current_date - 21 and position('@' in coalesce(l.email, '')) > 1
--    and coalesce(l.estado_agenda, '') <> 'cancelada'
--  group by 1 order by 1;

-- C6. Cron programado: 2 filas, activo = true.
-- select jobname, schedule, active from cron.job where jobname in ('ventas_ia_procesar','ventas_ia_devolucion') order by 1;
-- select name from vault.decrypted_secrets where name = 'ventas_ia_url';

-- C7. Despues de unas horas: estado de los analisis y gasto (ia_uso).
-- select estado, count(*) from fin_llamadas_analisis group by 1;
-- select funcion, count(*) as llamadas, round(sum(costo_usd), 4) as usd, count(*) filter (where not ok) as con_error
--   from ia_uso where app = 'ventas' and creado_en > now() - interval '7 days' group by 1;
-- select status::text, return_message, start_time from cron.job_run_details
--  where jobid in (select jobid from cron.job where jobname like 'ventas_ia_%') order by start_time desc limit 6;

-- =====================================================================
-- VUELTA ATRAS (en este orden; borra analisis y vinculos, no toca fin_llamadas ni Fathom)
-- =====================================================================
-- select cron.unschedule(jobid) from cron.job where jobname in ('ventas_ia_procesar', 'ventas_ia_devolucion');
-- delete from vault.secrets where name = 'ventas_ia_url';
-- drop view if exists public.fin_v_analisis_llamadas;
-- drop view if exists public.fin_v_llamada_analisis;
-- drop function if exists public.fin_ia_pendientes(integer);
-- drop function if exists public.fin_ia_externos_de_llamada(bigint);
-- drop function if exists public.fin_ia_reunion(text);
-- drop function if exists public.fin_ia_vincular_fathom(integer, integer);
-- drop function if exists public.fin_estructura_venta_guardar(text, text);
-- drop table if exists public.fin_devoluciones_closer;
-- drop table if exists public.fin_llamadas_analisis;
-- drop table if exists public.fin_llamadas_fathom;
-- drop table if exists public.fin_cliente_config;
-- drop function if exists public.fin_ia_puede_ver(text, text);
