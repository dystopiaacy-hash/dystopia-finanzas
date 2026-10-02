-- =====================================================================
-- 059_ventas_esquema_grilla.sql
-- Ventas, fase 2: esquema para que la hoja Data viva en la app.
--
-- 1. fin_llamadas: columnas para filas que no vienen del Sheet
--    (origen, ghl_cita_id, hora, email, formulario, auditoria).
-- 2. fin_fuentes.cortada_en: fecha de corte por fuente. Una fuente
--    cortada no puede volver a activarse (la sync solo corre activas).
-- 3. fin_catalogos: desplegables por cliente (mismo formato que
--    crm_catalogos de Marketing). Semilla: estado, show_up,
--    calificacion y programa de liam, lucas y teo, sacados de los
--    desplegables de los Sheets. Fuente queda vacia a proposito.
-- 4. fin_formulario_preguntas: preguntas del formulario de cada cliente.
-- 5. fin_alias_columnas: admite 'formulario' y 'email' (con clave).
--    Los alias en si van en la 060, DESPUES de deployar el parser.
--
-- No toca datos existentes ni la vista. No da permisos de escritura
-- sobre fin_llamadas (eso es la fase 6).
-- Idempotente. Sin begin/commit. Controles abajo, de a uno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. fin_llamadas
-- ---------------------------------------------------------------------
alter table fin_llamadas alter column fila_planilla drop not null;

alter table fin_llamadas add column if not exists origen          text        not null default 'sheet';
alter table fin_llamadas add column if not exists ghl_cita_id     text;
alter table fin_llamadas add column if not exists hora_llamada    time;
alter table fin_llamadas add column if not exists email           text;
alter table fin_llamadas add column if not exists formulario      jsonb       not null default '{}'::jsonb;
alter table fin_llamadas add column if not exists actualizado_en  timestamptz not null default now();
alter table fin_llamadas add column if not exists actualizado_por uuid;

comment on column fin_llamadas.origen is 'sheet = sincronizada desde la hoja Data; ghl = webhook de agenda; app = cargada en la grilla';
comment on column fin_llamadas.ghl_cita_id is 'ID de la cita en GHL. Un reagendamiento actualiza la fila en vez de crear otra';
comment on column fin_llamadas.hora_llamada is 'Hora local de la llamada tal como la muestra GHL, sin zona horaria';
comment on column fin_llamadas.formulario is 'Respuestas del formulario de agenda. Claves = fin_formulario_preguntas.clave';

alter table fin_llamadas drop constraint if exists fin_llamadas_origen_ck;
alter table fin_llamadas add constraint fin_llamadas_origen_ck
  check (origen in ('sheet', 'ghl', 'app'));

alter table fin_llamadas drop constraint if exists fin_llamadas_fila_sheet_ck;
alter table fin_llamadas add constraint fin_llamadas_fila_sheet_ck
  check (origen <> 'sheet' or fila_planilla is not null);

alter table fin_llamadas drop constraint if exists fin_llamadas_formulario_ck;
alter table fin_llamadas add constraint fin_llamadas_formulario_ck
  check (jsonb_typeof(formulario) = 'object');

create unique index if not exists fin_llamadas_ghl_cita_uq
  on fin_llamadas (cliente_id, ghl_cita_id)
  where ghl_cita_id is not null;

-- defaults blindados: si fin_sync_escribir arma la fila completa desde
-- jsonb (populate_record), las columnas nuevas llegan NULL aunque tengan
-- default. Este trigger las completa antes de los NOT NULL.
create or replace function fin_llamadas_defaults()
returns trigger language plpgsql as $$
begin
  new.origen         := coalesce(new.origen, 'sheet');
  new.formulario     := coalesce(new.formulario, '{}'::jsonb);
  new.actualizado_en := coalesce(new.actualizado_en, now());
  return new;
end $$;

drop trigger if exists fin_llamadas_defaults_tg on fin_llamadas;
create trigger fin_llamadas_defaults_tg
  before insert on fin_llamadas
  for each row execute function fin_llamadas_defaults();

-- auditoria: solo en UPDATE (la sync hace delete + insert, no la toca)
create or replace function fin_llamadas_tocar()
returns trigger language plpgsql as $$
begin
  new.actualizado_en  := now();
  new.actualizado_por := auth.uid();
  return new;
end $$;

drop trigger if exists fin_llamadas_tocar_tg on fin_llamadas;
create trigger fin_llamadas_tocar_tg
  before update on fin_llamadas
  for each row execute function fin_llamadas_tocar();

-- ---------------------------------------------------------------------
-- 2. Corte por fuente
-- ---------------------------------------------------------------------
alter table fin_fuentes add column if not exists cortada_en timestamptz;

comment on column fin_fuentes.cortada_en is 'Fecha de corte: desde aca la carga es en la app. Una fuente cortada queda inactiva para siempre';

alter table fin_fuentes drop constraint if exists fin_fuentes_cortada_ck;
alter table fin_fuentes add constraint fin_fuentes_cortada_ck
  check (cortada_en is null or activo = false);

-- ---------------------------------------------------------------------
-- 3. fin_catalogos
-- ---------------------------------------------------------------------
create table if not exists fin_catalogos (
  id          bigint generated by default as identity primary key,
  cliente_id  text        not null references crm_clients(id),
  dimension   text        not null,
  valor       text        not null,
  orden       integer     not null default 0,
  activo      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint fin_catalogos_dimension_ck
    check (dimension in ('estado', 'show_up', 'calificacion', 'programa', 'fuente')),
  constraint fin_catalogos_valor_ck check (btrim(valor) <> ''),
  constraint fin_catalogos_uq unique (cliente_id, dimension, valor)
);

comment on table fin_catalogos is 'Opciones de los desplegables de la grilla de Ventas, por cliente. show_up y calificacion en minuscula (los CHECK de fin_llamadas)';

alter table fin_catalogos enable row level security;

drop policy if exists fin_catalogos_lectura on fin_catalogos;
create policy fin_catalogos_lectura on fin_catalogos for select using (
  es_fundador()
  or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
  or exists (select 1 from fin_personas p
              where p.user_id = auth.uid()
                and p.cliente_id = fin_catalogos.cliente_id)
);

drop policy if exists fin_catalogos_alta on fin_catalogos;
create policy fin_catalogos_alta on fin_catalogos for insert with check (es_fundador());

drop policy if exists fin_catalogos_edicion on fin_catalogos;
create policy fin_catalogos_edicion on fin_catalogos for update using (es_fundador()) with check (es_fundador());

drop policy if exists fin_catalogos_baja on fin_catalogos;
create policy fin_catalogos_baja on fin_catalogos for delete using (es_fundador());

-- Semilla. Orden = de mas usado a menos usado en el Sheet.
insert into fin_catalogos (cliente_id, dimension, valor, orden)
select c, d, v, o from (values
  -- estado: liam
  ('liam','estado','NO CIERRE',1), ('liam','estado','EN SEGUIMIENTO',2),
  ('liam','estado','NO SHOW',3), ('liam','estado','NO CALIFICADO',4),
  ('liam','estado','ADENTRO EN LLAMADA',5), ('liam','estado','ADENTRO EN SEGUIMIENTO',6),
  ('liam','estado','FEE',7), ('liam','estado','SEGUIMIENTO CUOTAS',8),
  -- estado: lucas
  ('lucas','estado','NO SHOW',1), ('lucas','estado','NO CIERRE',2),
  ('lucas','estado','EN SEGUIMIENTO',3), ('lucas','estado','FEE',4),
  ('lucas','estado','PODRIDO',5), ('lucas','estado','ADENTRO EN SEGUIMIENTO',6),
  ('lucas','estado','ADENTRO EN LLAMADA',7), ('lucas','estado','SEGUIMIENTO CUOTAS',8),
  ('lucas','estado','ADENTRO EN CHAT',9),
  -- estado: teo
  ('teo','estado','NO CIERRE',1), ('teo','estado','NO SHOW',2),
  ('teo','estado','NO CALIFICADO',3), ('teo','estado','EN SEGUIMIENTO',4),
  ('teo','estado','ADENTRO EN SEGUIMIENTO',5), ('teo','estado','FEE',6),
  ('teo','estado','ADENTRO EN LLAMADA',7),
  -- show_up y calificacion: los mismos para los tres
  ('liam','show_up','si',1), ('liam','show_up','no',2), ('liam','show_up','regenda',3), ('liam','show_up','cancelado por closer',4),
  ('lucas','show_up','si',1), ('lucas','show_up','no',2), ('lucas','show_up','regenda',3), ('lucas','show_up','cancelado por closer',4),
  ('teo','show_up','si',1), ('teo','show_up','no',2), ('teo','show_up','regenda',3), ('teo','show_up','cancelado por closer',4),
  ('liam','calificacion','calificado',1), ('liam','calificacion','no calificado',2), ('liam','calificacion','no se sabe',3),
  ('lucas','calificacion','calificado',1), ('lucas','calificacion','no calificado',2), ('lucas','calificacion','no se sabe',3),
  ('teo','calificacion','calificado',1), ('teo','calificacion','no calificado',2), ('teo','calificacion','no se sabe',3),
  -- programa: liam queda pendiente (decision 8)
  ('lucas','programa','GRUPAL',1), ('lucas','programa','1 A 1',2),
  ('teo','programa','GRUPAL',1), ('teo','programa','1 A 1',2)
) s(c, d, v, o)
where exists (select 1 from crm_clients k where k.id = s.c)
on conflict (cliente_id, dimension, valor) do nothing;

-- ---------------------------------------------------------------------
-- 4. fin_formulario_preguntas
-- ---------------------------------------------------------------------
create table if not exists fin_formulario_preguntas (
  id          bigint generated by default as identity primary key,
  cliente_id  text        not null references crm_clients(id),
  clave       text        not null,
  etiqueta    text        not null,
  orden       integer     not null default 0,
  ghl_campo   text,
  activo      boolean     not null default true,
  created_at  timestamptz not null default now(),
  constraint fin_formulario_clave_ck check (clave ~ '^[a-z][a-z0-9_]*$'),
  constraint fin_formulario_uq unique (cliente_id, clave)
);

comment on table fin_formulario_preguntas is 'Preguntas del formulario de agenda por cliente. Las respuestas van en fin_llamadas.formulario bajo esta clave';
comment on column fin_formulario_preguntas.ghl_campo is 'Nombre del campo personalizado de GHL. Se completa en la fase de ingesta directa';

alter table fin_formulario_preguntas enable row level security;

drop policy if exists fin_formulario_lectura on fin_formulario_preguntas;
create policy fin_formulario_lectura on fin_formulario_preguntas for select using (
  es_fundador()
  or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
  or exists (select 1 from fin_personas p
              where p.user_id = auth.uid()
                and p.cliente_id = fin_formulario_preguntas.cliente_id)
);

drop policy if exists fin_formulario_escritura on fin_formulario_preguntas;
create policy fin_formulario_escritura on fin_formulario_preguntas for all
  using (es_fundador()) with check (es_fundador());

insert into fin_formulario_preguntas (cliente_id, clave, etiqueta, orden)
select c, k, e, o from (values
  ('liam','edad','Edad',1),
  ('liam','profesion','Profesión',2),
  ('liam','contexto_ig','Contexto + IG',3),
  ('liam','situacion_inversiones','Situación actual de inversiones',4),
  ('liam','objetivo_consultoria','Objetivo de la consultoría',5),
  ('liam','ingreso_mensual','Ingreso mensual actual',6),
  ('liam','capital_inicial','Capital inicial para invertir',7),
  ('liam','objetivo_invertir','Objetivo al invertir',8),
  ('liam','inversion_mensual','Inversión mensual',9),
  ('lucas','ocupacion','Ocupación actual',1),
  ('lucas','bloqueo','Bloqueo principal',2),
  ('lucas','inversion_disponible','Inversión disponible',3),
  ('teo','punto_ecommerce','En qué punto estás en E-Commerce',1),
  ('teo','ingreso_mensual','Ingreso mensual actual',2),
  ('teo','objetivo','Objetivo con el E-Commerce',3),
  ('teo','bloqueo','Bloqueo principal',4),
  ('teo','inversion_disponible','Inversión disponible',5)
) s(c, k, e, o)
where exists (select 1 from crm_clients x where x.id = s.c)
on conflict (cliente_id, clave) do nothing;

-- ---------------------------------------------------------------------
-- 5. fin_alias_columnas: admitir 'formulario' y 'email'
-- ---------------------------------------------------------------------
alter table fin_alias_columnas add column if not exists clave text;

comment on column fin_alias_columnas.clave is 'Solo para campo_canonico = formulario: clave de fin_formulario_preguntas';

alter table fin_alias_columnas drop constraint if exists fin_alias_columnas_campo_ck;
alter table fin_alias_columnas add constraint fin_alias_columnas_campo_ck
  check (campo_canonico in (
    'fecha','programa','alumno','telefono','concepto','monto','monto_pesos',
    'closer','setter','comprobante','quien_recibe','metodo_pago',
    'monto_restante','estado','fecha_llamada','nombre','show_up',
    'calificacion','estado_llamada','tipo_booking','cc_dia1','cc_cerrado',
    'cc_seguimiento','instagram','contexto_closer','contexto_setter',
    'email','formulario'));

alter table fin_alias_columnas drop constraint if exists fin_alias_columnas_clave_ck;
alter table fin_alias_columnas add constraint fin_alias_columnas_clave_ck
  check ((campo_canonico = 'formulario') = (clave is not null));

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Columnas nuevas de fin_llamadas: 7 filas.
-- select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--  where table_name = 'fin_llamadas'
--    and column_name in ('origen','ghl_cita_id','hora_llamada','email',
--                        'formulario','actualizado_en','actualizado_por')
--  order by 1;

-- C2. Todas las filas actuales quedaron como origen sheet: una sola fila, sheet con el total.
-- select origen, count(*) from fin_llamadas group by 1;

-- C3. Catalogos: liam 15 (sin programa), lucas 18, teo 16.
-- select cliente_id, count(*) as opciones,
--        string_agg(distinct dimension, ', ') as dimensiones
--   from fin_catalogos group by 1 order by 1;

-- C4. Preguntas: liam 9, lucas 3, teo 5.
-- select cliente_id, count(*) from fin_formulario_preguntas group by 1 order by 1;

-- C5. Corte: no hay ninguna fuente cortada todavia. Tiene que dar 0.
-- select count(*) from fin_fuentes where cortada_en is not null;

-- C6. RLS prendida en las dos tablas nuevas: 2 filas en true.
-- select relname, relrowsecurity from pg_class
--  where relname in ('fin_catalogos','fin_formulario_preguntas');

-- C7. La vista y la sincronizacion siguen vivas (esperar 15 min):
--     las 4 ultimas corridas de data en ok o revisar, como antes.
-- select f.cliente_id, c.estado, c.filas_cargadas, c.inicio
--   from fin_sync_corridas c join fin_fuentes f on f.id = c.fuente_id
--  where f.tipo = 'data' order by c.id desc limit 4;
