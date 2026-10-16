-- 143_finanzas_comprobantes.sql  (IA Fase 3: lectura de comprobantes de pago)
--
-- Que crea (todo nuevo, no cambia ninguna tabla ni funcion existente):
--   * Bucket PRIVADO de Storage `comprobantes` (10 MB, jpg/png/webp/pdf), con policies por cliente:
--       subir:  fundador, o finanzas / closer / setter / cliente asignado al cliente (crm_asignaciones, fin_asignado).
--       ver:    quien lo subio, o fundador / finanzas asignado al cliente.
--       Nadie puede pisar ni borrar desde la app (solo service_role).
--   * Tabla fin_comprobantes: el archivo, lo extraido por la IA, la propuesta (alumno / cuota), posibles
--     duplicados, quien subio y quien confirmo, y el pago al que quedo vinculado cuando se confirma.
--     Lectura directa solo para fundador / finanzas asignado (bandeja). Quien sube ve lo suyo por RPC, sin detalle de otros pagos.
--   * Funciones de permiso: fin_comp_puede_subir(cliente), fin_comp_puede_confirmar(cliente).
--   * RPC de la app: fin_comp_clientes, fin_comp_registrar, fin_comp_mios, fin_comp_bandeja, fin_comp_obtener,
--     fin_comp_confirmar, fin_comp_descartar.
--   * RPC solo service_role (las usa la Edge Function comprobante-leer): fin_comp_tomar, fin_comp_buscar, fin_comp_guardar_lectura.
--
-- Nada se guarda como PAGO desde aca: la persona revisa el formulario de Cargar pago (fin_pago_cargar, 066) y,
-- recien despues de guardar, el front llama a fin_comp_confirmar para vincular el comprobante con el pago.
-- Confirmar (cargar el pago) = fundador y finanzas. Un closer, setter o cliente solo sube: queda pendiente en la bandeja.
--
-- Depende de: 066/075 (fin_pagos con nota y clave, fin_asignado, es_fundador, rol_actual), 129 (fin_cs_*),
-- 137 (ia_uso, la usa la Edge Function), crm_clients / crm_members / crm_asignaciones y el esquema storage.
-- No usa begin/commit (el SQL Editor pasa por un pooler): todo es re-ejecutable.
-- Correr (no a :00/:15/:30/:45 ni a las 9:00). Despues, controles C1 a C7 de a uno (al final) y deploy de la funcion:
--   supabase functions deploy comprobante-leer --no-verify-jwt

-- ---------------------------------------------------------------------
-- 0. Guarda: si falta algo, no se aplica nada
-- ---------------------------------------------------------------------
do $guarda$
declare
  v_falta text := '';
begin
  if to_regprocedure('public.fin_asignado(text)') is null then v_falta := v_falta || ' fin_asignado(text) [075]'; end if;
  if to_regprocedure('public.es_fundador()') is null then v_falta := v_falta || ' es_fundador()'; end if;
  if to_regprocedure('public.rol_actual()') is null then v_falta := v_falta || ' rol_actual()'; end if;
  if to_regprocedure('public.fin_cs_alumnos(text)') is null then v_falta := v_falta || ' fin_cs_alumnos(text) [129]'; end if;
  if to_regprocedure('public.fin_cs_nombres(text)') is null then v_falta := v_falta || ' fin_cs_nombres(text) [129]'; end if;
  if to_regprocedure('public.fin_cs_norm_nombre(text)') is null then v_falta := v_falta || ' fin_cs_norm_nombre(text) [129]'; end if;
  if to_regprocedure('public.fin_cs_tokens(text)') is null then v_falta := v_falta || ' fin_cs_tokens(text) [129]'; end if;
  if to_regclass('public.fin_cs_vinculo') is null then v_falta := v_falta || ' fin_cs_vinculo [129]'; end if;
  if to_regclass('public.ia_uso') is null then v_falta := v_falta || ' ia_uso [137]'; end if;
  if to_regclass('public.crm_members') is null then v_falta := v_falta || ' crm_members'; end if;
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then v_falta := v_falta || ' storage.buckets/objects'; end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'nota') then
    v_falta := v_falta || ' fin_pagos.nota [066]';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_pagos' and column_name = 'clave') then
    v_falta := v_falta || ' fin_pagos.clave [062]';
  end if;
  if v_falta <> '' then
    raise exception 'GUARDA 143: faltan:%. No se aplica nada.', v_falta;
  end if;
end $guarda$;

-- ---------------------------------------------------------------------
-- 1. Permisos
-- ---------------------------------------------------------------------
-- Subir: fundador, o finanzas / closer / setter / cliente con ese cliente en crm_asignaciones.
create or replace function public.fin_comp_puede_subir(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null
     and exists (select 1 from public.crm_clients c where c.id = p_cliente and c.id <> 'mauro')
     and (coalesce(public.es_fundador(), false)
          or (public.rol_actual() in ('finanzas', 'closer', 'setter', 'cliente') and public.fin_asignado(p_cliente)));
$$;

-- Confirmar / ver la bandeja: fundador, o finanzas asignado al cliente.
create or replace function public.fin_comp_puede_confirmar(p_cliente text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null
     and exists (select 1 from public.crm_clients c where c.id = p_cliente and c.id <> 'mauro')
     and (coalesce(public.es_fundador(), false)
          or (public.rol_actual() = 'finanzas' and public.fin_asignado(p_cliente)));
$$;

-- ---------------------------------------------------------------------
-- 2. Tabla
-- ---------------------------------------------------------------------
create table if not exists public.fin_comprobantes (
  id               uuid        primary key default gen_random_uuid(),
  cliente_id       text        not null references public.crm_clients(id),
  archivo_path     text        not null unique,
  archivo_nombre   text,
  mime             text,
  bytes            bigint,
  subido_por       uuid        not null,
  subido_rol       text,
  subido_en        timestamptz not null default now(),
  estado           text        not null default 'subido'
                   check (estado in ('subido', 'leyendo', 'leido', 'error', 'confirmado', 'descartado')),
  leyendo_desde    timestamptz,
  leido_en         timestamptz,
  extraido         jsonb,
  propuesta        jsonb,
  duplicados       jsonb       not null default '[]'::jsonb,
  confianza        text        check (confianza in ('alta', 'media', 'baja')),
  -- Copias de lo extraido para buscar duplicados sin parsear el jsonb (las escribe fin_comp_guardar_lectura).
  monto            numeric,
  moneda           text,
  fecha_comp       date,
  pagador_norm     text,
  pagador_doc      text,
  op_norm          text,
  error            text,
  ia_modelo        text,
  ia_costo_usd     numeric,
  pago_clave       text,
  pago_id          bigint,
  confirmado_por   uuid,
  confirmado_en    timestamptz,
  descartado_por   uuid,
  descartado_en    timestamptz,
  descartado_motivo text,
  constraint fin_comp_confirmado_ck check ((estado = 'confirmado') = (pago_clave is not null))
);
comment on table public.fin_comprobantes is
  '143: comprobantes de pago subidos (bucket privado comprobantes), lo que leyo la IA y el pago al que quedaron vinculados al confirmarse. Nada de aca es un pago hasta que fundador/finanzas lo cargan.';
comment on column public.fin_comprobantes.pago_clave is 'fin_pagos.clave del pago creado al confirmar (sin FK: la sync reescribe fin_pagos de origen sheet).';
create index if not exists fin_comp_cliente_estado_idx on public.fin_comprobantes (cliente_id, estado, subido_en desc);
create index if not exists fin_comp_subido_por_idx on public.fin_comprobantes (subido_por, subido_en desc);
create index if not exists fin_comp_op_idx on public.fin_comprobantes (cliente_id, op_norm) where op_norm is not null;

alter table public.fin_comprobantes enable row level security;
revoke all on public.fin_comprobantes from anon, public, authenticated;
grant select on public.fin_comprobantes to authenticated;
grant all on public.fin_comprobantes to service_role;
drop policy if exists fin_comprobantes_lectura on public.fin_comprobantes;
create policy fin_comprobantes_lectura on public.fin_comprobantes for select to authenticated
  using (public.fin_comp_puede_confirmar(cliente_id));
-- Sin policies de escritura: se escribe solo por las RPC (security definer) y por service_role.

-- ---------------------------------------------------------------------
-- 3. Bucket privado y policies de Storage
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprobantes', 'comprobantes', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
   set public = false, file_size_limit = 10485760,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

-- Quien puede abrir un archivo: quien lo subio, o quien confirma pagos de ese cliente.
create or replace function public.fin_comp_puede_ver_archivo(p_path text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.fin_comprobantes c
     where c.archivo_path = p_path
       and (c.subido_por = auth.uid() or public.fin_comp_puede_confirmar(c.cliente_id)));
$$;

drop policy if exists fin_comprobantes_subir on storage.objects;
create policy fin_comprobantes_subir on storage.objects for insert to authenticated
  with check (
    bucket_id = 'comprobantes'
    and name ~ '^[a-z0-9_-]+/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|pdf)$'
    and public.fin_comp_puede_subir((storage.foldername(name))[1]));

drop policy if exists fin_comprobantes_ver on storage.objects;
create policy fin_comprobantes_ver on storage.objects for select to authenticated
  using (bucket_id = 'comprobantes' and public.fin_comp_puede_ver_archivo(name));
-- Sin policies de update ni delete: los archivos no se pisan ni se borran desde la app.

-- ---------------------------------------------------------------------
-- 4. RPC de la app
-- ---------------------------------------------------------------------
-- Clientes para los que el usuario puede subir, y si ademas confirma.
create or replace function public.fin_comp_clientes()
returns table (cliente_id text, nombre text, puede_confirmar boolean)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.nombre, public.fin_comp_puede_confirmar(c.id)
    from public.crm_clients c
   where c.id <> 'mauro' and public.fin_comp_puede_subir(c.id)
   order by c.orden;
$$;

-- Registra un archivo ya subido al bucket. Devuelve el id del comprobante.
create or replace function public.fin_comp_registrar(
  p_cliente text, p_path text, p_nombre text, p_mime text, p_bytes bigint)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id  uuid;
  v_rol text;
begin
  if auth.uid() is null then raise exception 'fin: sesion requerida' using errcode = '42501'; end if;
  if p_cliente is null or not public.fin_comp_puede_subir(p_cliente) then
    raise exception 'No tenes permiso para subir comprobantes de %', coalesce(p_cliente, '?') using errcode = '42501';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_cliente
     or p_path !~ '^[a-z0-9_-]+/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|pdf)$' then
    raise exception 'Ruta de archivo invalida';
  end if;
  if p_mime is null or p_mime not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    raise exception 'Tipo de archivo no admitido (jpg, png, webp o pdf)';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'comprobantes' and o.name = p_path) then
    raise exception 'El archivo no esta en el almacenamiento';
  end if;
  select m.rol into v_rol from public.crm_members m where m.user_id = auth.uid();
  insert into public.fin_comprobantes (cliente_id, archivo_path, archivo_nombre, mime, bytes, subido_por, subido_rol)
  values (p_cliente, p_path, left(nullif(btrim(p_nombre), ''), 200), p_mime, p_bytes, auth.uid(), v_rol)
  returning id into v_id;
  return v_id;
end $$;

-- Lo que subio el propio usuario (sin detalle de otros pagos ni de duplicados).
create or replace function public.fin_comp_mios()
returns table (id uuid, cliente_id text, archivo_nombre text, subido_en timestamptz,
               estado text, monto numeric, moneda text, motivo text)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.cliente_id, c.archivo_nombre, c.subido_en,
         case c.estado when 'confirmado' then 'confirmado' when 'descartado' then 'descartado' else 'en_revision' end,
         c.monto, c.moneda, c.descartado_motivo
    from public.fin_comprobantes c
   where auth.uid() is not null and c.subido_por = auth.uid()
   order by c.subido_en desc
   limit 50;
$$;

-- Bandeja de fundador / finanzas. p_filtro: 'pendientes' | 'confirmados' | 'descartados'.
create or replace function public.fin_comp_bandeja(p_filtro text default 'pendientes')
returns setof jsonb
language sql stable security definer set search_path = ''
as $$
  select to_jsonb(c) || jsonb_build_object('subido_por_nombre', m.nombre)
    from public.fin_comprobantes c
    left join public.crm_members m on m.user_id = c.subido_por
   where public.fin_comp_puede_confirmar(c.cliente_id)
     and case coalesce(p_filtro, 'pendientes')
           when 'confirmados' then c.estado = 'confirmado'
           when 'descartados' then c.estado = 'descartado'
           else c.estado in ('subido', 'leyendo', 'leido', 'error') end
   order by c.subido_en desc
   limit 200;
$$;

-- Un comprobante (para precargar Cargar pago). Solo quien confirma.
create or replace function public.fin_comp_obtener(p_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select to_jsonb(c) || jsonb_build_object('subido_por_nombre', m.nombre)
    from public.fin_comprobantes c
    left join public.crm_members m on m.user_id = c.subido_por
   where c.id = p_id and public.fin_comp_puede_confirmar(c.cliente_id);
$$;

-- Vincula el comprobante con el pago recien cargado (fin_pago_cargar devuelve la clave).
create or replace function public.fin_comp_confirmar(p_id uuid, p_pago_clave text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_c   public.fin_comprobantes%rowtype;
  v_pid bigint;
begin
  select * into v_c from public.fin_comprobantes where id = p_id for update;
  if not found then raise exception 'Comprobante inexistente'; end if;
  if not public.fin_comp_puede_confirmar(v_c.cliente_id) then
    raise exception 'No tenes permiso para confirmar comprobantes de %', v_c.cliente_id using errcode = '42501';
  end if;
  if v_c.estado = 'confirmado' then raise exception 'El comprobante ya esta confirmado'; end if;
  if v_c.estado = 'descartado' then raise exception 'El comprobante fue descartado'; end if;
  select p.id into v_pid from public.fin_pagos p
   where p.clave = p_pago_clave and p.cliente_id = v_c.cliente_id limit 1;
  if v_pid is null then raise exception 'No existe ese pago en %', v_c.cliente_id; end if;
  update public.fin_comprobantes
     set estado = 'confirmado', pago_clave = p_pago_clave, pago_id = v_pid,
         confirmado_por = auth.uid(), confirmado_en = now()
   where id = p_id;
end $$;

create or replace function public.fin_comp_descartar(p_id uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_c public.fin_comprobantes%rowtype;
begin
  select * into v_c from public.fin_comprobantes where id = p_id for update;
  if not found then raise exception 'Comprobante inexistente'; end if;
  if not public.fin_comp_puede_confirmar(v_c.cliente_id) then
    raise exception 'No tenes permiso sobre comprobantes de %', v_c.cliente_id using errcode = '42501';
  end if;
  if v_c.estado = 'confirmado' then raise exception 'El comprobante ya esta vinculado a un pago'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribi el motivo (al menos 3 letras)'; end if;
  update public.fin_comprobantes
     set estado = 'descartado', descartado_por = auth.uid(), descartado_en = now(),
         descartado_motivo = left(btrim(p_motivo), 300)
   where id = p_id;
end $$;

-- ---------------------------------------------------------------------
-- 5. Funciones de la Edge Function (solo service_role)
-- ---------------------------------------------------------------------
-- Toma el comprobante para leerlo (atomico: evita dos lecturas = dos cobros de IA).
-- Se puede tomar si esta 'subido' o 'error'; 'leyendo' hace mas de 3 minutos (la funcion murio);
-- o 'leido' si p_reintentar. Devuelve el comprobante o null.
create or replace function public.fin_comp_tomar(p_id uuid, p_reintentar boolean default false)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  update public.fin_comprobantes c
     set estado = 'leyendo', leyendo_desde = now(), error = null
   where c.id = p_id
     and (c.estado in ('subido', 'error')
          or (c.estado = 'leyendo' and c.leyendo_desde < now() - interval '3 minutes')
          or (c.estado = 'leido' and coalesce(p_reintentar, false)))
  returning c.id into v_id;
  if v_id is null then return null; end if;
  return (select to_jsonb(c) from public.fin_comprobantes c where c.id = v_id);
end $$;

-- Guarda el resultado de la lectura. Solo si sigue en 'leyendo'.
create or replace function public.fin_comp_guardar_lectura(
  p_id uuid, p_ok boolean, p_extraido jsonb, p_propuesta jsonb, p_duplicados jsonb,
  p_confianza text, p_error text, p_modelo text, p_costo numeric)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_monto numeric;
  v_fecha date;
  v_doc   text := nullif(regexp_replace(coalesce(p_extraido ->> 'pagador_documento', ''), '\D', '', 'g'), '');
  v_op    text := nullif(lower(regexp_replace(coalesce(p_extraido ->> 'numero_operacion', ''), '[^A-Za-z0-9]', '', 'g')), '');
begin
  if (p_extraido ->> 'monto') ~ '^[0-9]+(\.[0-9]+)?$' then v_monto := (p_extraido ->> 'monto')::numeric; end if;
  if (p_extraido ->> 'fecha') ~ '^\d{4}-\d{2}-\d{2}$' then
    begin v_fecha := (p_extraido ->> 'fecha')::date; exception when others then v_fecha := null; end;
  end if;
  if v_doc is not null and length(v_doc) < 7 then v_doc := null; end if;
  if v_op is not null and length(v_op) < 6 then v_op := null; end if;
  update public.fin_comprobantes c
     set estado = case when p_ok then 'leido' else 'error' end,
         leido_en = now(), leyendo_desde = null,
         extraido = p_extraido, propuesta = p_propuesta,
         duplicados = coalesce(p_duplicados, '[]'::jsonb),
         confianza = p_confianza,
         monto = v_monto, moneda = nullif(upper(btrim(p_extraido ->> 'moneda')), ''), fecha_comp = v_fecha,
         pagador_norm = public.fin_cs_norm_nombre(p_extraido ->> 'pagador_nombre'),
         pagador_doc = v_doc, op_norm = v_op,
         error = left(p_error, 300), ia_modelo = p_modelo, ia_costo_usd = p_costo
   where c.id = p_id and c.estado = 'leyendo';
end $$;

-- Busca a que alumno / cuota corresponde lo leido y si ya hay algo igual.
-- Alumnos: nombre normalizado igual (100), pagador ya confirmado antes en otro comprobante (90), nombre de la ficha o
-- alias de Producto vinculada por fin_cs_vinculo (85), 2 o mas palabras en comun (70), 1 palabra de 4+ letras (40).
-- Cuotas: pendientes del alumno (mismo criterio que fin_v_cobranzas), la de monto mas parecido primero.
-- Duplicados: mismo numero de operacion (en comprobantes y en la nota de los pagos) o mismo monto + fecha (+-1 dia) + pagador.
create or replace function public.fin_comp_buscar(
  p_comp uuid, p_cliente text, p_nombre text, p_documento text, p_monto numeric, p_moneda text,
  p_fecha date, p_operacion text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_norm text := public.fin_cs_norm_nombre(p_nombre);
  v_tok  text[] := public.fin_cs_tokens(public.fin_cs_norm_nombre(p_nombre));
  v_doc  text := nullif(regexp_replace(coalesce(p_documento, ''), '\D', '', 'g'), '');
  v_op   text := nullif(lower(regexp_replace(coalesce(p_operacion, ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_mon  text := coalesce(nullif(upper(btrim(p_moneda)), ''), 'USD');
  v_cero uuid := '00000000-0000-0000-0000-000000000000';
  v_cand jsonb;
  v_dup  jsonb;
begin
  if v_doc is not null and length(v_doc) < 7 then v_doc := null; end if;
  if v_op is not null and length(v_op) < 6 then v_op := null; end if;

  with al as (select * from public.fin_cs_alumnos(p_cliente)),
  prod as (
    select v.alumno_norm, n.nom
      from public.fin_cs_vinculo v
      join public.fin_cs_nombres(p_cliente) n on n.cs_id = v.cs_cliente_id
     where v.cliente_id = p_cliente and v.estado = 'vinculado' and n.nom is not null),
  aprendido as (
    select distinct public.fin_cs_norm_nombre(p.alumno) as alumno_norm
      from public.fin_comprobantes k
      join public.fin_pagos p on p.clave = k.pago_clave and p.cliente_id = k.cliente_id
     where k.cliente_id = p_cliente and k.estado = 'confirmado' and k.id <> coalesce(p_comp, v_cero)
       and ((v_doc is not null and k.pagador_doc = v_doc) or (v_norm is not null and k.pagador_norm = v_norm))),
  sc as (
    select al.alumno_norm, al.alumno, al.ultimo_pago,
           (v_norm is not null and al.alumno_norm = v_norm) as s_exacto,
           exists (select 1 from aprendido x where x.alumno_norm = al.alumno_norm) as s_aprendido,
           (v_norm is not null and exists (select 1 from prod pr where pr.alumno_norm = al.alumno_norm and pr.nom = v_norm)) as s_producto,
           (select count(*) from unnest(v_tok) t where t = any(public.fin_cs_tokens(al.alumno_norm)))::int as n_comun,
           (select count(*) from unnest(v_tok) t where length(t) >= 4 and t = any(public.fin_cs_tokens(al.alumno_norm)))::int as n_comun4
      from al),
  pt as (
    select sc.*,
           case when s_exacto then 100 when s_aprendido then 90 when s_producto then 85
                when n_comun >= 2 then 70 when n_comun4 >= 1 then 40 else 0 end as puntaje,
           case when s_exacto then 'nombre igual al del alumno'
                when s_aprendido then 'mismo pagador que un comprobante ya confirmado'
                when s_producto then 'nombre igual al de su ficha en Producto'
                when n_comun >= 2 then 'comparten ' || n_comun || ' palabras del nombre'
                when n_comun4 >= 1 then 'comparten una palabra del nombre'
           end as motivo
      from sc),
  top as (select * from pt where puntaje > 0 order by puntaje desc, ultimo_pago desc nulls last, alumno limit 3)
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'alumno', t.alumno, 'alumno_norm', t.alumno_norm, 'puntaje', t.puntaje, 'motivo', t.motivo,
             'ultimo_pago', t.ultimo_pago,
             'vinculo', (select v.estado from public.fin_cs_vinculo v where v.cliente_id = p_cliente and v.alumno_norm = t.alumno_norm),
             'telefono', (select p.telefono from public.fin_pagos p
                           where p.cliente_id = p_cliente and public.fin_cs_norm_nombre(p.alumno) = t.alumno_norm
                             and nullif(btrim(p.telefono), '') is not null
                           order by p.fecha desc limit 1),
             'programa', coalesce(
                (select q.programa from public.fin_cuotas q
                  where q.cliente_id = p_cliente and public.fin_cs_norm_nombre(q.alumno) = t.alumno_norm
                    and nullif(btrim(q.programa), '') is not null
                  order by q.fecha_pago desc nulls last limit 1),
                (select p.programa from public.fin_pagos p
                  where p.cliente_id = p_cliente and public.fin_cs_norm_nombre(p.alumno) = t.alumno_norm
                    and nullif(btrim(p.programa), '') is not null
                  order by p.fecha desc limit 1)),
             'cuotas', coalesce((
                select jsonb_agg(jsonb_build_object(
                         'cuota_id', x.id, 'numero', x.numero_cuota, 'programa', x.programa, 'monto', x.monto,
                         'vence', x.fecha_pago, 'estado', x.estado, 'closer', x.closer,
                         'coincide_monto', (v_mon = 'USD' and p_monto is not null and x.monto is not null
                                            and abs(x.monto - p_monto) <= greatest(1, x.monto * 0.01)))
                         order by x.dif nulls last, x.fecha_pago nulls last)
                  from (select q.*, case when v_mon = 'USD' and p_monto is not null and q.monto is not null
                                         then abs(q.monto - p_monto) end as dif
                          from public.fin_cuotas q
                         where q.cliente_id = p_cliente and public.fin_cs_norm_nombre(q.alumno) = t.alumno_norm
                           and lower(btrim(coalesce(q.estado, ''))) not in ('pagado', 'churn', 'pausado', 'cancelado')
                         order by dif nulls last, q.fecha_pago nulls last limit 3) x), '[]'::jsonb))
           order by t.puntaje desc, t.ultimo_pago desc nulls last, t.alumno), '[]'::jsonb)
    into v_cand
    from top t;

  select coalesce(jsonb_agg(d), '[]'::jsonb) into v_dup from (
    select jsonb_build_object('tipo', 'operacion', 'donde', 'pago', 'pago_clave', p.clave, 'fecha', p.fecha,
                              'alumno', p.alumno, 'monto', p.monto_origen, 'moneda', p.moneda_origen) as d
      from public.fin_pagos p
     where v_op is not null and p.cliente_id = p_cliente and p.nota is not null
       and position(v_op in lower(regexp_replace(p.nota, '[^A-Za-z0-9]', '', 'g'))) > 0
    union all
    select jsonb_build_object('tipo', 'operacion', 'donde', 'comprobante', 'comprobante_id', k.id,
                              'estado', k.estado, 'subido_en', k.subido_en, 'monto', k.monto, 'moneda', k.moneda)
      from public.fin_comprobantes k
     where v_op is not null and k.cliente_id = p_cliente and k.op_norm = v_op
       and k.estado <> 'descartado' and k.id <> coalesce(p_comp, v_cero)
    union all
    select jsonb_build_object('tipo', 'monto_fecha_pagador', 'donde', 'pago', 'pago_clave', p.clave, 'fecha', p.fecha,
                              'alumno', p.alumno, 'monto', p.monto_origen, 'moneda', p.moneda_origen)
      from public.fin_pagos p
     where p_monto is not null and p_fecha is not null and cardinality(v_tok) > 0
       and p.cliente_id = p_cliente and p.moneda_origen = v_mon and p.monto_origen = p_monto
       and p.fecha between p_fecha - 1 and p_fecha + 1
       and exists (select 1 from unnest(v_tok) t
                    where t = any(public.fin_cs_tokens(public.fin_cs_norm_nombre(p.alumno))))
    union all
    select jsonb_build_object('tipo', 'monto_fecha_pagador', 'donde', 'comprobante', 'comprobante_id', k.id,
                              'estado', k.estado, 'subido_en', k.subido_en, 'monto', k.monto, 'moneda', k.moneda)
      from public.fin_comprobantes k
     where p_monto is not null and p_fecha is not null and v_norm is not null
       and k.cliente_id = p_cliente and k.estado <> 'descartado' and k.id <> coalesce(p_comp, v_cero)
       and k.monto = p_monto and coalesce(k.moneda, 'USD') = v_mon
       and k.fecha_comp between p_fecha - 1 and p_fecha + 1 and k.pagador_norm = v_norm
    limit 10) u;

  return jsonb_build_object('candidatos', v_cand, 'duplicados', v_dup);
end $$;

-- ---------------------------------------------------------------------
-- 6. Grants de funciones
-- ---------------------------------------------------------------------
do $grants$
declare
  v_app text[] := array[
    'fin_comp_puede_subir(text)', 'fin_comp_puede_confirmar(text)', 'fin_comp_puede_ver_archivo(text)',
    'fin_comp_clientes()', 'fin_comp_registrar(text,text,text,text,bigint)', 'fin_comp_mios()',
    'fin_comp_bandeja(text)', 'fin_comp_obtener(uuid)', 'fin_comp_confirmar(uuid,text)', 'fin_comp_descartar(uuid,text)'];
  v_srv text[] := array[
    'fin_comp_tomar(uuid,boolean)',
    'fin_comp_guardar_lectura(uuid,boolean,jsonb,jsonb,jsonb,text,text,text,numeric)',
    'fin_comp_buscar(uuid,text,text,text,numeric,text,date,text)'];
  f text;
begin
  foreach f in array v_app loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  foreach f in array v_srv loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $grants$;

-- ---------------------------------------------------------------------
-- 7. Prueba de humo (se revierte sola: termina con una excepcion capturada)
--    Mira el NOTICE: tiene que decir "HUMO 143 OK".
-- ---------------------------------------------------------------------
do $humo$
declare
  v_user uuid;
  v_cli  text;
  v_id   uuid := gen_random_uuid();
  v_path text;
  v_r    jsonb;
  v_n    int;
  v_est  text;
begin
  select m.user_id into v_user from public.crm_members m where m.rol = 'fundador' limit 1;
  select c.id into v_cli from public.crm_clients c where c.id <> 'mauro' order by c.orden limit 1;
  if v_user is null or v_cli is null then
    raise notice 'HUMO 143: sin fundador o sin cliente, se omite';
    return;
  end if;
  v_path := v_cli || '/' || v_id::text || '.png';
  begin
    perform set_config('request.jwt.claim.sub', v_user::text, true);
    if not public.fin_comp_puede_subir(v_cli) or not public.fin_comp_puede_confirmar(v_cli) then
      raise exception 'HUMO 143 FALLA: el fundador deberia poder subir y confirmar';
    end if;
    insert into public.fin_comprobantes (id, cliente_id, archivo_path, archivo_nombre, mime, bytes, subido_por, subido_rol)
    values (v_id, v_cli, v_path, 'humo.png', 'image/png', 10, v_user, 'fundador');
    if public.fin_comp_tomar(v_id, false) is null then raise exception 'HUMO 143 FALLA: tomar'; end if;
    if public.fin_comp_tomar(v_id, false) is not null then raise exception 'HUMO 143 FALLA: tomar dos veces'; end if;
    v_r := public.fin_comp_buscar(v_id, v_cli, 'Persona De Prueba Humo', '20123456786', 123.45, 'USD', current_date, 'OP123456789');
    if jsonb_typeof(v_r -> 'candidatos') <> 'array' or jsonb_typeof(v_r -> 'duplicados') <> 'array' then
      raise exception 'HUMO 143 FALLA: buscar no devolvio arrays';
    end if;
    perform public.fin_comp_guardar_lectura(v_id, true,
      '{"monto": 123.45, "moneda": "USD", "fecha": "2026-10-01", "pagador_nombre": "Persona De Prueba Humo", "pagador_documento": "20-12345678-6", "numero_operacion": "OP-123456789"}'::jsonb,
      '{}'::jsonb, '[]'::jsonb, 'media', null, 'humo', 0.01);
    select estado, (op_norm = 'op123456789')::int into v_est, v_n from public.fin_comprobantes where id = v_id;
    if v_est <> 'leido' or v_n <> 1 then raise exception 'HUMO 143 FALLA: guardar_lectura (% / %)', v_est, v_n; end if;
    -- el mismo numero de operacion en otro comprobante se detecta como duplicado
    v_r := public.fin_comp_buscar(gen_random_uuid(), v_cli, 'Otra Persona', null, 1, 'USD', current_date, 'OP-123456789');
    if jsonb_array_length(v_r -> 'duplicados') < 1 then raise exception 'HUMO 143 FALLA: no detecto el duplicado por operacion'; end if;
    select count(*) into v_n from public.fin_comp_bandeja('pendientes') b where (b ->> 'id')::uuid = v_id;
    if v_n <> 1 then raise exception 'HUMO 143 FALLA: la bandeja no lo muestra'; end if;
    perform public.fin_comp_descartar(v_id, 'prueba de humo');
    select estado into v_est from public.fin_comprobantes where id = v_id;
    if v_est <> 'descartado' then raise exception 'HUMO 143 FALLA: descartar'; end if;
    raise exception 'HUMO_143_OK';
  exception when others then
    if sqlerrm = 'HUMO_143_OK' then
      raise notice 'HUMO 143 OK (revertido)';
    else
      raise;
    end if;
  end;
end $humo$;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno; el editor muestra solo el ultimo resultado)
-- ---------------------------------------------------------------------
-- C1. Bucket privado con limite y tipos. Esperado: public = false, 10485760, 4 tipos.
--   select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'comprobantes';
--
-- C2. Tabla vacia y con RLS. Esperado: filas = 0, rls = true.
--   select (select count(*) from public.fin_comprobantes) as filas,
--          (select relrowsecurity from pg_class where oid = 'public.fin_comprobantes'::regclass) as rls;
--
-- C3. Policies de Storage de este bucket. Esperado: 2 filas (insert y select), ninguna de update/delete.
--   select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'fin_comprobantes%';
--
-- C4. Permisos de las funciones. Esperado: las 3 de service_role dicen anon = false y authenticated = false.
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'execute') as anon,
--          has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--          has_function_privilege('service_role', p.oid, 'execute') as service_role
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.proname like 'fin_comp_%' order by 1;
--
-- C5. Quien puede subir y quien confirmar, por usuario y cliente (como postgres; cambia el uuid del usuario).
--   Esperado: fundador sube y confirma todo; finanzas asignado, closer, setter y cliente asignados suben, solo finanzas confirma;
--   un usuario sin asignacion al cliente: nada.
--   select m.nombre, m.rol, c.id as cliente,
--          (select set_config('request.jwt.claim.sub', m.user_id::text, true)) as _,
--          public.fin_comp_puede_subir(c.id) as sube, public.fin_comp_puede_confirmar(c.id) as confirma
--     from public.crm_members m cross join public.crm_clients c
--    where c.id <> 'mauro' and m.rol in ('fundador', 'finanzas', 'closer', 'setter', 'cliente')
--    order by m.rol, m.nombre, c.id;
--
-- C6. Clientes por usuario (un cliente = solo el suyo). Reemplazar el uuid de un usuario con rol cliente.
--   select set_config('request.jwt.claim.sub', '<uuid de un usuario cliente>', true);   -- ejecutar junto con la de abajo
--   select * from public.fin_comp_clientes();
--
-- C7. Despues de probar en la app: costo de IA de Finanzas en comprobantes (ia_uso, migracion 137).
--   select date_trunc('month', creado_en) as mes, count(*) as llamadas, sum(costo_usd) as usd, avg(costo_usd) as usd_promedio
--     from public.ia_uso where app = 'finanzas' and funcion = 'leer_comprobante' group by 1 order by 1;
--   -- (si la columna de fecha de ia_uso no se llama creado_en, mirar select * from public.ia_uso limit 1)
--
-- ---------------------------------------------------------------------
-- VUELTA ATRAS (no se corre salvo pedido). Los archivos subidos se pierden: si ya hay comprobantes reales, exportar antes.
--   drop policy if exists fin_comprobantes_subir on storage.objects;
--   drop policy if exists fin_comprobantes_ver on storage.objects;
--   drop function if exists public.fin_comp_buscar(uuid,text,text,text,numeric,text,date,text);
--   drop function if exists public.fin_comp_guardar_lectura(uuid,boolean,jsonb,jsonb,jsonb,text,text,text,numeric);
--   drop function if exists public.fin_comp_tomar(uuid,boolean);
--   drop function if exists public.fin_comp_descartar(uuid,text);
--   drop function if exists public.fin_comp_confirmar(uuid,text);
--   drop function if exists public.fin_comp_obtener(uuid);
--   drop function if exists public.fin_comp_bandeja(text);
--   drop function if exists public.fin_comp_mios();
--   drop function if exists public.fin_comp_registrar(text,text,text,text,bigint);
--   drop function if exists public.fin_comp_clientes();
--   drop table if exists public.fin_comprobantes;
--   drop function if exists public.fin_comp_puede_ver_archivo(text);
--   drop function if exists public.fin_comp_puede_confirmar(text);
--   drop function if exists public.fin_comp_puede_subir(text);
--   -- El bucket se vacia y borra desde el panel de Storage (Supabase no deja borrar un bucket con archivos por SQL).
