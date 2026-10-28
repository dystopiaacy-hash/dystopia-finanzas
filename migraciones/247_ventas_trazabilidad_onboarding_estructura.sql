-- =====================================================================
-- 247_ventas_trazabilidad_onboarding_estructura.sql
-- Ventas. Estructura (SIN datos) para tres pestanias de los sheets del 28/10:
--   * "Trazabilidad - Data" del CRM de BPF (liam)        -> fin_trazabilidad
--   * "DATA ONBOARDING" del CRM de NEC (teo)             -> fin_onboarding_respuestas
--   * tablas pegadas a mano (foto) del "Dashoboard - Onboarding" de BPF
--     y las secciones 6 y 7 del "Dashboard Trazabilidad" -> fin_hoja_resumen
-- Los datos van en la 248 (se corre DESPUES de esta).
--
-- Por que fin_hoja_resumen: esos dashboards de BPF no tienen fuente (sin
-- formulas, solo valores pegados: "Septiembre (n=44)" y "Snapshot al 18-09").
-- Se guardan tal cual como filas (seccion, categoria, cantidad, porcentaje)
-- para mostrarlos igual que el sheet, sin inventar el calculo.
--
-- Permisos (misma regla que fin_cierres y Data, 121/077): leen fundador,
-- cliente con acceso y ventas/finanzas asignados. Closer y setter NO.
-- Escribe solo service_role / SQL Editor (no hay politicas de escritura).
--
-- No toca fin_fuentes ni la sync: estas tablas se cargan a mano (248).
-- Idempotente (create ... if not exists). Requiere 001 (crm_clients) y
-- las funciones es_fundador, rol_actual, tiene_acceso, fin_asignado.
-- Correr el BLOQUE 1 entero y fuera de :00/:15/:30/:45.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Tablas, permisos y prueba de humo
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';

do $$
begin
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception '247: no existe el cliente liam en crm_clients';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'teo') then
    raise exception '247: no existe el cliente teo en crm_clients';
  end if;
  if to_regprocedure('public.es_fundador()') is null
     or to_regprocedure('public.rol_actual()') is null
     or to_regprocedure('public.tiene_acceso(text)') is null
     or to_regprocedure('public.fin_asignado(text)') is null then
    raise exception '247: faltan funciones de permisos (es_fundador / rol_actual / tiene_acceso / fin_asignado)';
  end if;
end $$;

-- 1. Trazabilidad (BPF): una fila por cierre con el recorrido del lead
create table if not exists public.fin_trazabilidad (
  id                     bigint generated always as identity primary key,
  cliente_id             text   not null references public.crm_clients(id),
  fila_planilla          int    not null,
  fecha                  date,
  cc                     numeric(14,2),
  nombre                 text   not null,
  formato_primer_contacto text,
  angulo_primer_contacto  text,
  otros_contactos        text,
  analisis_chat          text,
  tipo_cliente           text,
  formato_ultimo_contacto text,
  angulo_ultimo_contacto  text,
  fuente                 text,
  ig                     text,
  manychat               text,
  creado_en              timestamptz not null default now(),
  constraint fin_trazabilidad_fila_key unique (cliente_id, fila_planilla)
);
create index if not exists fin_trazabilidad_cliente_fecha_idx on public.fin_trazabilidad (cliente_id, fecha);
comment on table public.fin_trazabilidad is
  '247: pestania "Trazabilidad - Data" del CRM de BPF (hoy solo liam). CC = cash collected del cierre en USD. Carga manual (248); sin sync.';
comment on column public.fin_trazabilidad.angulo_ultimo_contacto is
  'La planilla repite el encabezado ANGULO PRIMER CONTACTO en la columna del ultimo contacto; aca se guarda como angulo del ultimo contacto.';

-- 2. Onboarding (NEC): una fila por respuesta del formulario
create table if not exists public.fin_onboarding_respuestas (
  id             bigint generated always as identity primary key,
  cliente_id     text   not null references public.crm_clients(id),
  fila_planilla  int    not null,
  marca_temporal timestamptz,
  nombre         text,
  apellido       text,
  telefono       text,
  email          text,
  respuestas     jsonb  not null default '{}'::jsonb check (jsonb_typeof(respuestas) = 'object'),
  creado_en      timestamptz not null default now(),
  constraint fin_onboarding_respuestas_fila_key unique (cliente_id, fila_planilla)
);
create index if not exists fin_onboarding_respuestas_cliente_idx on public.fin_onboarding_respuestas (cliente_id, marca_temporal);
comment on table public.fin_onboarding_respuestas is
  '247: pestania "DATA ONBOARDING" del CRM de NEC (hoy solo teo): formulario que completa el cliente que compro. NO es cs_onboarding_respuestas de Producto (ese es el diagnostico del alumno). Datos personales: misma regla de lectura que fin_cierres.';
comment on column public.fin_onboarding_respuestas.respuestas is
  'Clave = tema de la pregunta (perfil, facturacion, nicho, conocio, formato, por_que_formato, temas, dijo_si, motivo_accion, expectativas, tiempo_decidir, mejor_antes, mejora, problemas, ultimo_convencio, impedia, mentoria_previa, top3_problemas, objetivo); valor = texto tal como lo respondio. Las de seleccion multiple vienen separadas por coma.';

-- 3. Tablas pegadas a mano en los dashboards de BPF (foto, sin formulas)
create table if not exists public.fin_hoja_resumen (
  id            bigint generated always as identity primary key,
  cliente_id    text   not null references public.crm_clients(id),
  hoja          text   not null check (hoja in ('onboarding', 'trazabilidad')),
  titulo        text,
  n_respuestas  int,
  seccion_orden int    not null,
  seccion       text   not null,
  orden         int    not null,
  categoria     text   not null,
  cantidad      numeric,
  porcentaje    numeric check (porcentaje is null or porcentaje between 0 and 1),
  creado_en     timestamptz not null default now(),
  constraint fin_hoja_resumen_key unique (cliente_id, hoja, seccion_orden, orden)
);
comment on table public.fin_hoja_resumen is
  '247: valores pegados a mano en dashboards de BPF (Dashoboard - Onboarding: Septiembre n=44; Dashboard Trazabilidad secciones 6 y 7: snapshot 18-09). Foto: no se recalcula. porcentaje es fraccion (0.48 = 48 %). Filas de texto: categoria = el texto, cantidad y porcentaje null.';

alter table public.fin_trazabilidad          enable row level security;
alter table public.fin_onboarding_respuestas enable row level security;
alter table public.fin_hoja_resumen          enable row level security;

revoke all on table public.fin_trazabilidad          from anon, public, authenticated;
revoke all on table public.fin_onboarding_respuestas from anon, public, authenticated;
revoke all on table public.fin_hoja_resumen          from anon, public, authenticated;
grant select on table public.fin_trazabilidad          to authenticated;
grant select on table public.fin_onboarding_respuestas to authenticated;
grant select on table public.fin_hoja_resumen          to authenticated;
grant all on table public.fin_trazabilidad          to service_role;
grant all on table public.fin_onboarding_respuestas to service_role;
grant all on table public.fin_hoja_resumen          to service_role;

-- Lectura: regla en linea de fin_cierres (121) = fin_data_puede_ver (077).
drop policy if exists fin_trazabilidad_lectura on public.fin_trazabilidad;
create policy fin_trazabilidad_lectura on public.fin_trazabilidad
  for select to authenticated
  using (coalesce(public.es_fundador(), false)
         or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(cliente_id), false))
         or (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id)));

drop policy if exists fin_onboarding_respuestas_lectura on public.fin_onboarding_respuestas;
create policy fin_onboarding_respuestas_lectura on public.fin_onboarding_respuestas
  for select to authenticated
  using (coalesce(public.es_fundador(), false)
         or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(cliente_id), false))
         or (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id)));

drop policy if exists fin_hoja_resumen_lectura on public.fin_hoja_resumen;
create policy fin_hoja_resumen_lectura on public.fin_hoja_resumen
  for select to authenticated
  using (coalesce(public.es_fundador(), false)
         or (public.rol_actual() = 'cliente' and coalesce(public.tiene_acceso(cliente_id), false))
         or (public.rol_actual() in ('finanzas', 'ventas') and public.fin_asignado(cliente_id)));

-- Prueba de humo: inserta una fila por tabla, la cuenta y la borra (todo en la misma transaccion).
do $$
declare v_t int; v_o int; v_h int;
begin
  insert into public.fin_trazabilidad (cliente_id, fila_planilla, nombre) values ('liam', -1, '__humo_247__');
  insert into public.fin_onboarding_respuestas (cliente_id, fila_planilla, respuestas) values ('teo', -1, '{"perfil":"x"}');
  insert into public.fin_hoja_resumen (cliente_id, hoja, seccion_orden, seccion, orden, categoria) values ('liam', 'onboarding', -1, 'humo', 1, 'humo');
  select count(*) into v_t from public.fin_trazabilidad where fila_planilla = -1;
  select count(*) into v_o from public.fin_onboarding_respuestas where fila_planilla = -1;
  select count(*) into v_h from public.fin_hoja_resumen where seccion_orden = -1;
  if v_t <> 1 or v_o <> 1 or v_h <> 1 then
    raise exception '247 humo: se esperaban 1/1/1 filas y hay %/%/%', v_t, v_o, v_h;
  end if;
  delete from public.fin_trazabilidad where fila_planilla = -1;
  delete from public.fin_onboarding_respuestas where fila_planilla = -1;
  delete from public.fin_hoja_resumen where seccion_orden = -1;
end $$;

commit;

-- =====================================================================
-- CONTROLES (sueltos: seleccionar uno y Run)
-- =====================================================================
-- C1. Las tres tablas existen, con RLS y vacias (esperado: rls = true en las tres, filas = 0).
-- select c.relname, c.relrowsecurity as rls,
--        (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from public.%I', c.relname), false, true, '')))[1]::text::int as filas
--   from pg_class c
--  where c.oid in ('public.fin_trazabilidad'::regclass, 'public.fin_onboarding_respuestas'::regclass, 'public.fin_hoja_resumen'::regclass);

-- C2. Una politica de lectura por tabla (esperado: 3 filas, cmd = SELECT).
-- select tablename, policyname, cmd from pg_policies
--  where schemaname = 'public' and tablename in ('fin_trazabilidad', 'fin_onboarding_respuestas', 'fin_hoja_resumen') order by 1;

-- C3. El front (authenticated) solo lee; service_role escribe (esperado: select = true, insert = false).
-- select t,
--        has_table_privilege('authenticated', 'public.' || t, 'select') as select_auth,
--        has_table_privilege('authenticated', 'public.' || t, 'insert') as insert_auth,
--        has_table_privilege('anon', 'public.' || t, 'select') as select_anon,
--        has_table_privilege('service_role', 'public.' || t, 'insert') as insert_service
--   from unnest(array['fin_trazabilidad', 'fin_onboarding_respuestas', 'fin_hoja_resumen']) as t;

-- C4. La prueba de humo no dejo basura (esperado: 0, 0, 0).
-- select (select count(*) from public.fin_trazabilidad where fila_planilla < 0),
--        (select count(*) from public.fin_onboarding_respuestas where fila_planilla < 0),
--        (select count(*) from public.fin_hoja_resumen where seccion_orden < 0);

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (borra las tablas y lo que tengan; correr solo si todavia no se uso)
-- ---------------------------------------------------------------------
-- begin;
--   drop table if exists public.fin_hoja_resumen;
--   drop table if exists public.fin_onboarding_respuestas;
--   drop table if exists public.fin_trazabilidad;
-- commit;
