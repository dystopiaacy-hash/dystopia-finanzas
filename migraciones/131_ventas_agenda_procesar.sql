-- =====================================================================
-- 131_ventas_agenda_procesar.sql
-- Ventas, fase 3 de la agenda de GHL: de fin_agendas_entrantes a fin_llamadas.
--
-- QUE HACE
--   1. fin_agendas_entrantes: evento (agendada / reprogramada / cancelada /
--      desconocido), de donde salieron la cita y el evento (rutas), vinculo
--      con el Sheet, datos extraidos, intentos.
--   2. fin_llamadas: estado_agenda (agendada / reprogramada / cancelada) y
--      agenda_en. No toca ninguna fila existente.
--   3. fin_procesar_agenda(id): idempotente por (cliente, cita). Crea o
--      actualiza la llamada origen 'ghl'. Si el lead ya esta en el Sheet
--      (mismo cliente, fecha y telefono / email / nombre) NO crea otra:
--      la vincula y manda el Sheet.
--   4. fin_agendas_procesar_pendientes(): respaldo por cron.
--
-- REGLA ANTI-DUPLICADO CON LA SYNC DE SHEETS
--   - La sync solo borra y recrea filas origen 'sheet' (060): las filas
--     'ghl' sobreviven.
--   - Si al llegar la agenda ya hay una fila 'sheet' o 'app' del mismo lead
--     y fecha: no se crea fila. La agenda queda con vinculo='sheet'/'app'
--     y el detalle de la fila encontrada. MANDA EL SHEET (o lo cargado a
--     mano): estado, show up y cash son suyos.
--   - Si la agenda llego ANTES que la fila del Sheet (lo normal: el
--     webhook sale antes de la sync de 15 min), la fila 'ghl' existe. Al
--     aparecer la del Sheet, el respaldo (o el proximo evento de la cita)
--     la reconcilia: si la fila 'ghl' no tiene datos cargados (estado,
--     show up, cash) se borra y la agenda queda vinculada al Sheet; si
--     ya tiene datos se deja y la vista de duplicadas (115) decide cual
--     cuenta (gana la que tiene estado / show up / cash).
--   - Una cita sin ID no se procesa (error sin_cita_id): sin ID no hay
--     forma de no duplicar reprogramaciones.
--
-- NO TOCA vistas ni metricas. Ojo: una cita cancelada en una fila 'ghl'
-- sigue contando como agendada en fin_v_llamadas_clasificadas (la vista no
-- mira estado_agenda). Ver "decisiones" en el resumen de la tarea.
--
-- Orden: correr los BLOQUES en orden, uno por vez, fuera de :00/:15/:30/:45
-- (la sync lee fin_llamadas). Sin begin/commit (SQL Editor). Idempotente.
-- Correr ANTES de desplegar la Edge Function nueva (la funcion llama a
-- fin_procesar_agenda; si no existe, guarda el crudo igual y el cron
-- procesa despues).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Columnas
-- ---------------------------------------------------------------------
alter table public.fin_agendas_entrantes add column if not exists evento      text;
alter table public.fin_agendas_entrantes add column if not exists evento_ruta text;
alter table public.fin_agendas_entrantes add column if not exists cita_ruta   text;
alter table public.fin_agendas_entrantes add column if not exists vinculo     text;
alter table public.fin_agendas_entrantes add column if not exists vinculo_ref text;
alter table public.fin_agendas_entrantes add column if not exists datos       jsonb;
alter table public.fin_agendas_entrantes add column if not exists intentos    integer not null default 0;

alter table public.fin_agendas_entrantes drop constraint if exists fin_agendas_evento_ck;
alter table public.fin_agendas_entrantes add constraint fin_agendas_evento_ck
  check (evento is null or evento in ('agendada', 'reprogramada', 'cancelada', 'desconocido'));

alter table public.fin_agendas_entrantes drop constraint if exists fin_agendas_vinculo_ck;
alter table public.fin_agendas_entrantes add constraint fin_agendas_vinculo_ck
  check (vinculo is null or vinculo in ('ghl', 'sheet', 'app'));

comment on column public.fin_agendas_entrantes.evento is 'agendada / reprogramada / cancelada / desconocido. De customData.evento o del status de la cita';
comment on column public.fin_agendas_entrantes.evento_ruta is 'Ruta del payload de la que salio el evento (para ajustar con el primer payload real)';
comment on column public.fin_agendas_entrantes.cita_ruta is 'Ruta del payload de la que salio ghl_cita_id';
comment on column public.fin_agendas_entrantes.vinculo is 'ghl = fila propia en fin_llamadas; sheet / app = el lead ya estaba cargado, no se crea otra (manda esa fila)';
comment on column public.fin_agendas_entrantes.vinculo_ref is 'Detalle del vinculo: fila de fin_llamadas encontrada (id, fuente, fila de planilla)';
comment on column public.fin_agendas_entrantes.datos is 'Campos extraidos al procesar (nombre, telefono, inicio, closer, fuente...) y la ruta de cada uno';
comment on column public.fin_agendas_entrantes.intentos is 'Cuantas veces fallo el procesamiento. El respaldo reintenta hasta 3';

create index if not exists fin_agendas_pendientes_idx
  on public.fin_agendas_entrantes (recibido_en)
  where procesado_en is null;

alter table public.fin_llamadas add column if not exists estado_agenda text;
alter table public.fin_llamadas add column if not exists agenda_en     timestamptz;

alter table public.fin_llamadas drop constraint if exists fin_llamadas_estado_agenda_ck;
alter table public.fin_llamadas add constraint fin_llamadas_estado_agenda_ck
  check (estado_agenda is null or estado_agenda in ('agendada', 'reprogramada', 'cancelada'));

comment on column public.fin_llamadas.estado_agenda is 'Solo filas origen ghl: ultimo evento de agenda de la cita. null en filas del Sheet y de la app';
comment on column public.fin_llamadas.agenda_en is 'Cuando llego el ultimo evento de agenda de la cita';

-- ---------------------------------------------------------------------
-- BLOQUE 2. Funciones
-- ---------------------------------------------------------------------

-- Primer valor no vacio entre varias rutas ("a.b.c") de un jsonb.
-- Devuelve {valor, ruta}. Ignora objetos/arrays y merge fields sin resolver
-- ("{{appointment.id}}").
create or replace function public.fin_agenda_buscar(p jsonb, p_rutas text[])
returns jsonb
language plpgsql immutable set search_path = public
as $fn$
declare
  r text;
  v text;
begin
  foreach r in array p_rutas loop
    if jsonb_typeof(p #> string_to_array(r, '.')) in ('string', 'number', 'boolean') then
      v := nullif(btrim(p #>> string_to_array(r, '.')), '');
      if v is not null and v !~ '^\{\{.*\}\}$' and lower(v) not in ('null', 'undefined') then
        return jsonb_build_object('valor', v, 'ruta', r);
      end if;
    end if;
  end loop;
  return jsonb_build_object('valor', null, 'ruta', null);
end;
$fn$;

-- Texto de evento o de status de GHL -> agendada / reprogramada / cancelada.
-- null si no hay texto; desconocido si no lo entiende (showed, noshow...).
create or replace function public.fin_agenda_evento(p_texto text)
returns text
language sql immutable set search_path = public
as $fn$
  select case
    when t is null then null
    when t ~ '(reprogram|reagend|resched|rescheduled)' then 'reprogramada'
    when t ~ '(cancel|anulad)' then 'cancelada'
    when t ~ '^(agendad|agenda|nuev|new|book|confirm|creat|schedul|reservad)' then 'agendada'
    else 'desconocido'
  end
  from (select nullif(lower(btrim(translate(coalesce(p_texto, ''),
          U&'\00C1\00C9\00CD\00D3\00DA\00E1\00E9\00ED\00F3\00FA', 'AEIOUaeiou'))), '') as t) x
$fn$;

-- Procesa UNA agenda entrante. Idempotente: procesar dos veces la misma
-- fila, o dos eventos de la misma cita, deja una sola llamada.
create or replace function public.fin_procesar_agenda(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  a           public.fin_agendas_entrantes%rowtype;
  j           jsonb;
  v_cita      text;
  v_cita_ruta text;
  v_ev        text;
  v_ev_ruta   text;
  v_nombre    text;
  v_nom_ruta  text;
  v_tel       text;
  v_mail      text;
  v_ini       text;
  v_ini_ruta  text;
  v_closer_r  text;
  v_closer    text;
  v_fuente_t  text;
  v_fecha     date;
  v_hora      time;
  v_ts        timestamp;
  v_fuente_id bigint;
  v_ll        public.fin_llamadas%rowtype;
  v_twin      record;
  v_estado    text;
  v_id        bigint;
  v_accion    text;
  k_tel       text;
  k_mail      text;
  k_nom       text;
  v_datos     jsonb;
begin
  select * into a from public.fin_agendas_entrantes where id = p_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no existe la agenda ' || p_id);
  end if;
  if a.procesado_en is not null then
    return jsonb_build_object('ok', true, 'accion', 'ya_procesada', 'llamada_id', a.llamada_id);
  end if;

  begin
    -- 1. ID de la cita. Nunca calendar.id (es el ID del CALENDARIO, no de la cita).
    if a.ghl_cita_id is not null then
      v_cita := a.ghl_cita_id;
      v_cita_ruta := coalesce(a.cita_ruta, 'columna');
    else
      j := public.fin_agenda_buscar(a.payload, array[
        'appointment.id', 'calendar.appointmentId', 'calendar.appointment_id', 'appointmentId',
        'appointment_id', 'customData.cita_id', 'id']);
      v_cita := j ->> 'valor';
      v_cita_ruta := j ->> 'ruta';
      -- el "id" de primer nivel en GHL suele ser el del contacto: no sirve de cita
      if v_cita_ruta = 'id' and v_cita = coalesce(a.payload ->> 'contact_id', a.payload ->> 'contactId') then
        v_cita := null; v_cita_ruta := null;
      end if;
    end if;
    if v_cita is null then
      raise exception 'sin_cita_id: el payload no trae ID de cita (rutas probadas: appointment.id, calendar.appointmentId, appointmentId, appointment_id, customData.cita_id, id)';
    end if;

    -- 2. Evento
    if a.evento is not null then
      v_ev := a.evento;
      v_ev_ruta := coalesce(a.evento_ruta, 'columna');
    else
      j := public.fin_agenda_buscar(a.payload, array['customData.evento', 'customData.event', 'evento']);
      v_ev := public.fin_agenda_evento(j ->> 'valor');
      v_ev_ruta := j ->> 'ruta';
      if v_ev is null then
        j := public.fin_agenda_buscar(a.payload, array[
          'calendar.status', 'calendar.appoinmentStatus', 'calendar.appointmentStatus',
          'appointment.status', 'appointment.appointmentStatus', 'appointmentStatus', 'status']);
        v_ev := coalesce(public.fin_agenda_evento(j ->> 'valor'), 'desconocido');
        v_ev_ruta := j ->> 'ruta';
      end if;
    end if;
    if v_ev = 'desconocido' then
      raise exception 'evento_desconocido: no se pudo saber si es agendada, reprogramada o cancelada (ruta %). Mandar customData.evento', coalesce(v_ev_ruta, 'ninguna');
    end if;

    -- 3. Datos del lead y de la cita
    j := public.fin_agenda_buscar(a.payload, array['customData.nombre', 'full_name', 'contact.full_name', 'contact.name', 'name']);
    v_nombre := j ->> 'valor'; v_nom_ruta := j ->> 'ruta';
    if v_nombre is null then
      v_nombre := nullif(btrim(coalesce(a.payload ->> 'first_name', a.payload #>> '{contact,first_name}', '') || ' '
                            || coalesce(a.payload ->> 'last_name',  a.payload #>> '{contact,last_name}',  '')), '');
      v_nom_ruta := case when v_nombre is not null then 'first_name+last_name' end;
    end if;
    if v_nombre is null then
      j := public.fin_agenda_buscar(a.payload, array['calendar.title', 'appointment.title']);
      v_nombre := j ->> 'valor'; v_nom_ruta := j ->> 'ruta';
    end if;
    v_nombre := left(coalesce(v_nombre, '(sin nombre)'), 200);

    v_tel  := public.fin_agenda_buscar(a.payload, array['customData.telefono', 'phone', 'contact.phone', 'phone_number']) ->> 'valor';
    v_mail := public.fin_agenda_buscar(a.payload, array['customData.email', 'email', 'contact.email']) ->> 'valor';
    j := public.fin_agenda_buscar(a.payload, array[
      'customData.inicio', 'calendar.startTime', 'calendar.start_time', 'appointment.startTime',
      'appointment.start_time', 'startTime', 'start_time']);
    v_ini := j ->> 'valor'; v_ini_ruta := j ->> 'ruta';
    v_closer_r  := public.fin_agenda_buscar(a.payload, array['customData.closer', 'calendar.assignedUser', 'appointment.assigned_user', 'user.name', 'assigned_user']) ->> 'valor';
    v_fuente_t  := public.fin_agenda_buscar(a.payload, array['customData.fuente', 'customData.source']) ->> 'valor';

    -- 4. Fecha y hora: tal cual las muestra GHL (sin zona). Un horario en UTC
    --    ("...Z" o +00:00) se rechaza: la fecha local podria correrse un dia.
    if v_ini is null then
      raise exception 'sin_inicio: el payload no trae hora de la cita (customData.inicio, calendar.startTime...)';
    end if;
    if v_ini ~ '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}' then
      if v_ini ~ '(Z|[+-]00:?00)$' then
        raise exception 'inicio_utc: la hora viene en UTC (%). Mandar la hora local con su offset, ej. 2026-10-20T15:00:00-03:00', v_ini;
      end if;
      v_fecha := substr(v_ini, 1, 10)::date;
      v_hora  := substr(v_ini, 12, 5)::time;
    else
      begin
        v_ts := v_ini::timestamp;
      exception when others then
        raise exception 'inicio_ilegible: no se pudo leer la hora "%"', left(v_ini, 60);
      end;
      v_fecha := v_ts::date;
      v_hora  := v_ts::time;
    end if;
    if v_fecha < date '2024-01-01' or v_fecha > date '2027-12-31' then
      raise exception 'inicio_fuera_de_rango: % (entre 2024 y 2027)', v_fecha;
    end if;

    -- 5. Fuente de datos del cliente (la fila de fin_llamadas la necesita)
    select id into v_fuente_id from public.fin_fuentes
     where cliente_id = a.cliente_id and tipo = 'data'
     order by (cortada_en is not null) desc, activo desc, id
     limit 1;
    if v_fuente_id is null then
      raise exception 'sin_fuente_data: % no tiene una fuente tipo data en fin_fuentes', a.cliente_id;
    end if;

    -- 6. Closer: el alias listado si existe; si no, el texto de GHL tal cual
    v_closer := nullif(btrim(coalesce(v_closer_r, '')), '');
    if v_closer is not null then
      v_closer := coalesce(public.fin_data_closer_canonico(a.cliente_id, v_closer), v_closer);
    end if;
    v_closer := coalesce(v_closer, '(sin asignar)');

    v_datos := jsonb_build_object(
      'nombre', v_nombre, 'nombre_ruta', v_nom_ruta, 'telefono', v_tel, 'email', v_mail,
      'inicio', v_ini, 'inicio_ruta', v_ini_ruta, 'fecha', v_fecha, 'hora', v_hora,
      'closer', v_closer, 'fuente', v_fuente_t, 'fuente_id', v_fuente_id);

    -- Un solo procesamiento a la vez por cita
    perform pg_advisory_xact_lock(hashtext('fin_procesar_agenda'), hashtext(a.cliente_id || ':' || v_cita));

    -- 7. Evento mas nuevo de la misma cita ya procesado: este quedo viejo
    if exists (select 1 from public.fin_agendas_entrantes x
                where x.cliente_id = a.cliente_id and x.ghl_cita_id = v_cita
                  and x.id > a.id and x.procesado_en is not null and x.error is null) then
      update public.fin_agendas_entrantes
         set ghl_cita_id = v_cita, cita_ruta = v_cita_ruta, evento = v_ev, evento_ruta = v_ev_ruta,
             datos = v_datos, procesado_en = now(), error = null,
             vinculo_ref = 'superada: ya se proceso un evento mas nuevo de la misma cita'
       where id = a.id;
      return jsonb_build_object('ok', true, 'accion', 'superada');
    end if;

    -- 8. Llamada propia de esta cita (si ya existe)
    select * into v_ll from public.fin_llamadas
     where cliente_id = a.cliente_id and ghl_cita_id = v_cita;

    -- Claves del lead para buscar el mismo lead en el Sheet / la app
    k_tel  := case when length(regexp_replace(coalesce(v_tel, ''), '\D', '', 'g')) >= 8
                   then right(regexp_replace(v_tel, '\D', '', 'g'), 10) end;
    k_mail := case when position('@' in coalesce(v_mail, '')) > 1 then lower(btrim(v_mail)) end;
    k_nom  := case when length(lower(regexp_replace(btrim(v_nombre), '\s+', ' ', 'g'))) >= 4
                    and v_nombre ~ '[[:alpha:]]' and v_nombre <> '(sin nombre)'
                   then lower(regexp_replace(btrim(v_nombre), '\s+', ' ', 'g')) end;

    select l.id, l.origen, l.fuente_id, l.fila_planilla into v_twin
      from public.fin_llamadas l
     where l.cliente_id = a.cliente_id
       and l.fecha_llamada = v_fecha
       and l.origen in ('sheet', 'app')
       and ((k_tel  is not null and right(regexp_replace(coalesce(l.telefono, ''), '\D', '', 'g'), 10) = k_tel
                                and length(regexp_replace(coalesce(l.telefono, ''), '\D', '', 'g')) >= 8)
         or (k_mail is not null and lower(btrim(coalesce(l.email, ''))) = k_mail)
         or (k_nom  is not null and lower(regexp_replace(btrim(coalesce(l.nombre, '')), '\s+', ' ', 'g')) = k_nom))
     order by (k_tel is not null and right(regexp_replace(coalesce(l.telefono, ''), '\D', '', 'g'), 10) = k_tel) desc,
              l.id
     limit 1;

    if v_twin.id is not null then
      -- El lead ya esta cargado: manda esa fila. Si la agenda habia creado
      -- una propia y no tiene datos cargados, se retira.
      if v_ll.id is not null
         and nullif(btrim(coalesce(v_ll.estado_llamada, '')), '') is null
         and v_ll.show_up is null
         and coalesce(v_ll.cc_dia1, 0) + coalesce(v_ll.cc_cerrado, 0) + coalesce(v_ll.cc_seguimiento, 0) = 0 then
        delete from public.fin_llamadas where id = v_ll.id;
        v_accion := 'vinculada_y_retirada_la_propia';
      elsif v_ll.id is not null then
        v_accion := 'vinculada_propia_con_datos';   -- queda; la 115 decide cual cuenta
      else
        v_accion := 'vinculada';
      end if;
      update public.fin_agendas_entrantes
         set ghl_cita_id = v_cita, cita_ruta = v_cita_ruta, evento = v_ev, evento_ruta = v_ev_ruta,
             datos = v_datos, vinculo = v_twin.origen,
             vinculo_ref = format('fin_llamadas %s (%s, fuente %s, fila %s)', v_twin.id, v_twin.origen, v_twin.fuente_id, coalesce(v_twin.fila_planilla::text, '-')),
             llamada_id = case when v_accion = 'vinculada_propia_con_datos' then v_ll.id else v_twin.id end,
             procesado_en = now(), error = null
       where id = a.id;
      return jsonb_build_object('ok', true, 'accion', v_accion, 'llamada_id', v_twin.id, 'manda', v_twin.origen);
    end if;

    -- 9. Estado de la agenda. "agendada" sobre una cita que ya existia con
    --    otra fecha u hora es una reprogramacion aunque GHL no lo diga.
    v_estado := v_ev;
    if v_ev = 'agendada' and v_ll.id is not null
       and (v_ll.fecha_llamada is distinct from v_fecha or v_ll.hora_llamada is distinct from v_hora) then
      v_estado := 'reprogramada';
    end if;

    if v_ll.id is null then
      insert into public.fin_llamadas
        (cliente_id, fuente_id, fila_planilla, fecha_llamada, hora_llamada, closer, nombre,
         telefono, email, tipo_booking, origen, ghl_cita_id, estado_agenda, agenda_en)
      values
        (a.cliente_id, v_fuente_id, null, v_fecha, v_hora, v_closer, v_nombre,
         v_tel, v_mail, v_fuente_t, 'ghl', v_cita, v_estado, a.recibido_en)
      returning id into v_id;
      v_accion := 'creada';
    else
      -- Una cancelacion no pisa fecha/hora/closer: solo marca el estado.
      -- Lo cargado a mano (estado, show up, cash, calificacion) no se toca.
      update public.fin_llamadas set
        estado_agenda = v_estado,
        agenda_en     = a.recibido_en,
        fecha_llamada = case when v_estado = 'cancelada' then fecha_llamada else v_fecha end,
        hora_llamada  = case when v_estado = 'cancelada' then hora_llamada  else v_hora  end,
        closer        = case when v_estado = 'cancelada' or v_closer = '(sin asignar)' then closer else v_closer end,
        telefono      = coalesce(telefono, v_tel),
        email         = coalesce(email, v_mail),
        tipo_booking  = coalesce(tipo_booking, v_fuente_t)
      where id = v_ll.id
      returning id into v_id;
      v_accion := 'actualizada';
    end if;

    update public.fin_agendas_entrantes
       set ghl_cita_id = v_cita, cita_ruta = v_cita_ruta, evento = v_ev, evento_ruta = v_ev_ruta,
           datos = v_datos, vinculo = 'ghl', vinculo_ref = null,
           llamada_id = v_id, procesado_en = now(), error = null
     where id = a.id;
    return jsonb_build_object('ok', true, 'accion', v_accion, 'llamada_id', v_id, 'estado_agenda', v_estado);

  exception when others then
    update public.fin_agendas_entrantes
       set error = left(sqlerrm, 500), intentos = intentos + 1
     where id = p_id;
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
end;
$fn$;

comment on function public.fin_procesar_agenda(bigint) is
  'Procesa una agenda entrante de GHL a fin_llamadas (origen ghl). Idempotente por cliente + cita. Si el lead ya esta en el Sheet, vincula y manda el Sheet (131)';

-- Respaldo: procesa lo pendiente y reconcilia filas 'ghl' recientes con el Sheet.
create or replace function public.fin_agendas_procesar_pendientes(p_max integer default 200)
returns jsonb
language plpgsql security definer set search_path = public
as $fn$
declare
  r       record;
  v_ok    integer := 0;
  v_mal   integer := 0;
  v_res   jsonb;
begin
  -- Pendientes (sin procesar y con menos de 3 intentos), las mas viejas primero.
  for r in
    select id from public.fin_agendas_entrantes
     where procesado_en is null and intentos < 3 and recibido_en > now() - interval '7 days'
     order by id
     limit p_max
  loop
    v_res := public.fin_procesar_agenda(r.id);
    if (v_res ->> 'ok')::boolean then v_ok := v_ok + 1; else v_mal := v_mal + 1; end if;
  end loop;

  -- Reconciliar: agendas con fila propia 'ghl' cuyo lead ya aparecio en el Sheet.
  -- Se reabre la ultima agenda de la cita para que el proceso decida.
  update public.fin_agendas_entrantes e
     set procesado_en = null
   where e.id in (
     select max(x.id)
       from public.fin_agendas_entrantes x
       join public.fin_llamadas g on g.cliente_id = x.cliente_id and g.ghl_cita_id = x.ghl_cita_id and g.origen = 'ghl'
      where x.procesado_en is not null and x.error is null and x.vinculo = 'ghl'
        and x.recibido_en > now() - interval '3 days'
        and g.fecha_llamada >= current_date - 3
        and exists (
          select 1 from public.fin_llamadas s
           where s.cliente_id = g.cliente_id and s.fecha_llamada = g.fecha_llamada and s.origen = 'sheet'
             and ((length(regexp_replace(coalesce(g.telefono, ''), '\D', '', 'g')) >= 8
                   and right(regexp_replace(coalesce(s.telefono, ''), '\D', '', 'g'), 10) = right(regexp_replace(g.telefono, '\D', '', 'g'), 10))
               or (position('@' in coalesce(g.email, '')) > 1 and lower(btrim(coalesce(s.email, ''))) = lower(btrim(g.email)))
               or (length(btrim(g.nombre)) >= 4 and lower(regexp_replace(btrim(s.nombre), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(g.nombre), '\s+', ' ', 'g')))))
      group by x.cliente_id, x.ghl_cita_id);
  for r in
    select id from public.fin_agendas_entrantes
     where procesado_en is null and intentos < 3 and error is null and vinculo = 'ghl'
       and recibido_en > now() - interval '3 days'
     order by id limit p_max
  loop
    v_res := public.fin_procesar_agenda(r.id);
  end loop;

  return jsonb_build_object('procesadas', v_ok, 'con_error', v_mal);
end;
$fn$;

revoke all on function public.fin_agenda_buscar(jsonb, text[])        from public, anon, authenticated;
revoke all on function public.fin_agenda_evento(text)                 from public, anon, authenticated;
revoke all on function public.fin_procesar_agenda(bigint)             from public, anon, authenticated;
revoke all on function public.fin_agendas_procesar_pendientes(integer) from public, anon, authenticated;
grant execute on function public.fin_procesar_agenda(bigint)              to service_role;
grant execute on function public.fin_agendas_procesar_pendientes(integer) to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 3. PRUEBA DE HUMO (se revierte sola: termina en una excepcion
--           "HUMO OK ..."; si algo falla dice "HUMO FALLO: ..." y tambien
--           revierte). Usa cliente liam y filas origen_wf='prueba-jefe'.
-- ---------------------------------------------------------------------
do $humo$
declare
  v_cita  text := 'PRUEBA-HUMO-' || extract(epoch from clock_timestamp())::bigint;
  v_a1    bigint; v_a2 bigint; v_a3 bigint; v_a4 bigint;
  v_r     jsonb;
  v_ll    public.fin_llamadas%rowtype;
  v_n     integer;
  v_f     date := current_date + 20;
  v_fs    text := to_char(current_date + 20, 'YYYY-MM-DD');
  v_fs2   text := to_char(current_date + 21, 'YYYY-MM-DD');
  v_fuente bigint;
begin
  select id into v_fuente from public.fin_fuentes where cliente_id = 'liam' and tipo = 'data' limit 1;
  if v_fuente is null then raise exception 'HUMO FALLO: liam no tiene fuente data'; end if;

  -- 1. agendada
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, ghl_cita_id, evento, payload)
  values ('liam', 'prueba-jefe', v_cita, 'agendada', jsonb_build_object(
    'full_name', 'PRUEBA JEFE', 'email', 'prueba.jefe@example.com', 'phone', '+5491100000000',
    'customData', jsonb_build_object('inicio', v_fs || 'T15:00:00-03:00', 'closer', 'PRUEBA CLOSER', 'fuente', 'PRUEBA', 'prueba', 'true')))
  returning id into v_a1;
  v_r := public.fin_procesar_agenda(v_a1);
  if not (v_r ->> 'ok')::boolean or v_r ->> 'accion' <> 'creada' then
    raise exception 'HUMO FALLO 1 (agendada): %', v_r;
  end if;
  select * into v_ll from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita;
  if v_ll.id is null or v_ll.origen <> 'ghl' or v_ll.estado_agenda <> 'agendada'
     or v_ll.fecha_llamada <> v_f or v_ll.hora_llamada <> time '15:00' then
    raise exception 'HUMO FALLO 1b: la fila no quedo como se esperaba: %', to_jsonb(v_ll);
  end if;

  -- 2. misma cita, otra hora y evento agendada -> reprogramada, UNA sola fila
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, ghl_cita_id, evento, payload)
  values ('liam', 'prueba-jefe', v_cita, 'agendada', jsonb_build_object(
    'full_name', 'PRUEBA JEFE', 'email', 'prueba.jefe@example.com', 'phone', '+5491100000000',
    'customData', jsonb_build_object('inicio', v_fs2 || 'T16:30:00-03:00', 'closer', 'PRUEBA CLOSER', 'prueba', 'true')))
  returning id into v_a2;
  v_r := public.fin_procesar_agenda(v_a2);
  select count(*) into v_n from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita;
  select * into v_ll from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita;
  if v_n <> 1 or v_ll.estado_agenda <> 'reprogramada' or v_ll.fecha_llamada <> v_f + 1 or v_ll.hora_llamada <> time '16:30' then
    raise exception 'HUMO FALLO 2 (reprogramada): filas=% fila=% r=%', v_n, to_jsonb(v_ll), v_r;
  end if;

  -- 3. cancelada: marca el estado, no mueve la fecha
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, evento, payload)
  values ('liam', 'prueba-jefe', null, jsonb_build_object(
    'full_name', 'PRUEBA JEFE', 'calendar', jsonb_build_object('appointmentId', v_cita, 'status', 'cancelled', 'startTime', v_fs2 || 'T16:30:00-03:00'),
    'customData', jsonb_build_object('prueba', 'true')))
  returning id into v_a3;
  v_r := public.fin_procesar_agenda(v_a3);
  select count(*) into v_n from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita;
  select * into v_ll from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita;
  if v_n <> 1 or v_ll.estado_agenda <> 'cancelada' or v_ll.fecha_llamada <> v_f + 1 then
    raise exception 'HUMO FALLO 3 (cancelada): filas=% fila=% r=%', v_n, to_jsonb(v_ll), v_r;
  end if;
  if (select evento from public.fin_agendas_entrantes where id = v_a3) <> 'cancelada'
     or (select cita_ruta from public.fin_agendas_entrantes where id = v_a3) <> 'calendar.appointmentId' then
    raise exception 'HUMO FALLO 3b: evento o ruta de cita no quedaron guardados';
  end if;

  -- 4. reprocesar es idempotente
  v_r := public.fin_procesar_agenda(v_a3);
  if v_r ->> 'accion' <> 'ya_procesada' then raise exception 'HUMO FALLO 4: %', v_r; end if;

  -- 5. sin ID de cita -> error legible, nada en fin_llamadas
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, payload)
  values ('liam', 'prueba-jefe', jsonb_build_object('full_name', 'PRUEBA SIN ID', 'customData', jsonb_build_object('evento', 'agendada', 'inicio', v_fs || 'T10:00:00-03:00')))
  returning id into v_a4;
  v_r := public.fin_procesar_agenda(v_a4);
  if (v_r ->> 'ok')::boolean
     or (select error from public.fin_agendas_entrantes where id = v_a4) not like 'sin_cita_id%'
     or (select intentos from public.fin_agendas_entrantes where id = v_a4) <> 1 then
    raise exception 'HUMO FALLO 5 (sin cita): %', v_r;
  end if;

  -- 6. anti-duplicado: un lead que ya esta (origen app) en esa fecha se vincula
  insert into public.fin_llamadas (cliente_id, fuente_id, fila_planilla, fecha_llamada, closer, nombre, telefono, origen)
  values ('liam', v_fuente, null, v_f + 2, 'PRUEBA CLOSER', 'PRUEBA GEMELO', '+54 9 11 0000-1111', 'app');
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, ghl_cita_id, evento, payload)
  values ('liam', 'prueba-jefe', v_cita || '-B', 'agendada', jsonb_build_object(
    'full_name', 'OTRO NOMBRE', 'phone', '5491100001111',
    'customData', jsonb_build_object('inicio', to_char(v_f + 2, 'YYYY-MM-DD') || 'T11:00:00-03:00', 'prueba', 'true')))
  returning id into v_a4;
  v_r := public.fin_procesar_agenda(v_a4);
  select count(*) into v_n from public.fin_llamadas where cliente_id = 'liam' and ghl_cita_id = v_cita || '-B';
  if v_n <> 0 or v_r ->> 'accion' <> 'vinculada' or (select vinculo from public.fin_agendas_entrantes where id = v_a4) <> 'app' then
    raise exception 'HUMO FALLO 6 (vinculo): filas propias=% r=%', v_n, v_r;
  end if;

  -- 7. la hora en UTC se rechaza
  insert into public.fin_agendas_entrantes (cliente_id, origen_wf, ghl_cita_id, evento, payload)
  values ('liam', 'prueba-jefe', v_cita || '-C', 'agendada', jsonb_build_object(
    'full_name', 'PRUEBA UTC', 'customData', jsonb_build_object('inicio', v_fs || 'T23:00:00Z')))
  returning id into v_a4;
  v_r := public.fin_procesar_agenda(v_a4);
  if (v_r ->> 'ok')::boolean or (select error from public.fin_agendas_entrantes where id = v_a4) not like 'inicio_utc%' then
    raise exception 'HUMO FALLO 7 (utc): %', v_r;
  end if;

  raise exception 'HUMO OK: 7 pruebas pasaron (agendada, reprogramada, cancelada, idempotente, sin cita, vinculo, utc). Se revirtio todo.';
end
$humo$;
-- Resultado esperado: ERROR "HUMO OK: ...". Cualquier "HUMO FALLO" = avisar.

-- ---------------------------------------------------------------------
-- BLOQUE 4. Cron de respaldo (4 veces por hora; minutos 11, 26, 43, 56:
--           fuera de :00/:15/:30/:45 y de los de los otros jobs).
--           Correr DESPUES de mirar los controles C1 a C4.
-- ---------------------------------------------------------------------
select cron.unschedule(jobid) from cron.job where jobname = 'fin_agendas_procesar';
select cron.schedule('fin_agendas_procesar', '11,26,43,56 * * * *',
  $cron$ select public.fin_agendas_procesar_pendientes(); $cron$);

-- =====================================================================
-- CONTROLES (de a uno, descomentar cada uno)
-- =====================================================================

-- C1. Columnas nuevas: 7 en fin_agendas_entrantes + 2 en fin_llamadas = 9 filas.
-- select table_name, column_name from information_schema.columns
--  where (table_name = 'fin_agendas_entrantes' and column_name in
--         ('evento','evento_ruta','cita_ruta','vinculo','vinculo_ref','datos','intentos'))
--     or (table_name = 'fin_llamadas' and column_name in ('estado_agenda','agenda_en'))
--  order by 1, 2;

-- C2. Las funciones existen y solo las ve service_role: 4 filas, authenticated = false.
-- select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
--        has_function_privilege('service_role', p.oid, 'execute') as service_role
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.proname in ('fin_agenda_buscar','fin_agenda_evento','fin_procesar_agenda','fin_agendas_procesar_pendientes')
--  order by 1;

-- C3. El humo no dejo nada: 0 | 0.
-- select (select count(*) from fin_agendas_entrantes where origen_wf = 'prueba-jefe') as agendas_prueba,
--        (select count(*) from fin_llamadas where ghl_cita_id like 'PRUEBA-%') as llamadas_prueba;

-- C4. Nada de lo existente cambio: todas las filas de fin_llamadas siguen igual (estado_agenda null).
-- select origen, count(*) as filas, count(estado_agenda) as con_estado_agenda
--   from fin_llamadas group by 1 order by 1;

-- C5. El cron quedo programado: 1 fila, activo = true.
-- select jobname, schedule, active from cron.job where jobname = 'fin_agendas_procesar';

-- C6. Despues de probar de punta a punta (script con --enviar): las 3 agendas de prueba
--     procesadas, 1 sola llamada, estado cancelada, sin error.
-- select e.id, e.evento, e.evento_ruta, e.cita_ruta, e.vinculo, e.llamada_id, e.procesado_en is not null as procesada, e.error
--   from fin_agendas_entrantes e where e.origen_wf = 'prueba-jefe' order by e.id;
-- select id, origen, fecha_llamada, hora_llamada, nombre, closer, estado_agenda, ghl_cita_id
--   from fin_llamadas where ghl_cita_id like 'PRUEBA-%';

-- C7. Estado general de la cola (despues de unos dias reales): procesadas / con error / pendientes.
-- select cliente_id,
--        count(*) filter (where procesado_en is not null and error is null) as procesadas,
--        count(*) filter (where error is not null and procesado_en is null)  as con_error,
--        count(*) filter (where procesado_en is null and error is null)      as pendientes,
--        count(*) filter (where vinculo in ('sheet','app'))                  as vinculadas_al_sheet
--   from fin_agendas_entrantes group by 1 order by 1;

-- =====================================================================
-- BORRAR LAS FILAS DE PRUEBA (despues del test de punta a punta)
-- =====================================================================
-- delete from fin_llamadas where ghl_cita_id like 'PRUEBA-%';
-- delete from fin_agendas_entrantes where origen_wf = 'prueba-jefe';

-- =====================================================================
-- VUELTA ATRAS (en este orden; no borra datos de ventas)
-- =====================================================================
-- select cron.unschedule(jobid) from cron.job where jobname = 'fin_agendas_procesar';
-- drop function if exists public.fin_agendas_procesar_pendientes(integer);
-- drop function if exists public.fin_procesar_agenda(bigint);
-- drop function if exists public.fin_agenda_evento(text);
-- drop function if exists public.fin_agenda_buscar(jsonb, text[]);
-- -- Antes de quitar las columnas: borrar filas ghl si se quiere volver al estado anterior:
-- --   delete from fin_llamadas where origen = 'ghl';
-- alter table public.fin_llamadas drop constraint if exists fin_llamadas_estado_agenda_ck;
-- alter table public.fin_llamadas drop column if exists agenda_en;
-- alter table public.fin_llamadas drop column if exists estado_agenda;
-- drop index if exists public.fin_agendas_pendientes_idx;
-- alter table public.fin_agendas_entrantes drop constraint if exists fin_agendas_vinculo_ck;
-- alter table public.fin_agendas_entrantes drop constraint if exists fin_agendas_evento_ck;
-- alter table public.fin_agendas_entrantes drop column if exists intentos;
-- alter table public.fin_agendas_entrantes drop column if exists datos;
-- alter table public.fin_agendas_entrantes drop column if exists vinculo_ref;
-- alter table public.fin_agendas_entrantes drop column if exists vinculo;
-- alter table public.fin_agendas_entrantes drop column if exists cita_ruta;
-- alter table public.fin_agendas_entrantes drop column if exists evento_ruta;
-- alter table public.fin_agendas_entrantes drop column if exists evento;
