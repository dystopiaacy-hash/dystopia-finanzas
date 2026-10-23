-- =====================================================================
-- 209_agus_pagos_mail_nota.sql
-- Agus (De CERO a CEO): la hoja Pagos trae columnas nuevas. Esta migracion hace que la
-- sync las lea y que la grilla de Pagos las muestre. SIN CORRER, NO PROBADA contra Postgres.
--
-- Hoja Pagos de Agus (xlsx 23/10), columnas nuevas respecto del fixture del 21/09:
--   O  MAIL                  -> fin_pagos.email          (14 filas con dato, todas de octubre)
--   P  FUENTE DEL MAIL       -> fin_pagos.fuente_email   (19 filas)
--   Q  NOTA (carga 19/10)    -> fin_pagos.nota           (22 filas; la columna `nota` ya existia: la usa la app)
--   L  (SIN TITULO)          -> fin_pagos.fuente_lead, se muestra como "Fuente" (origen del lead: instagram,
--      webinar, resell...; ~123 filas desde el 01/09). Decidido por Joaquin 23/10. Se mapea por titulo
--      (FUENTE, FUENTE DEL LEAD, ORIGEN DEL LEAD, por si Agus le pone uno) y, mientras la columna L siga SIN
--      titulo, por posicion (alias en blanco + posicion 12; el parser lo usa solo si esa columna esta en blanco).
--      La clave se llama fuente_lead y no `fuente` para no confundirla con fuente_id / fin_fuentes (la fuente de sync).
--
-- Que hace:
--   1. fin_pagos.email, fuente_email y fuente_lead (text, null). Las filas existentes quedan en null hasta la
--      proxima sync de Agus (la sync borra y reinserta los pagos 'sheet').
--   2. fin_alias_columnas: el CHECK de campo_canonico suma 'nota', 'fuente_email' y 'fuente_lead' (la lista de la 059 + 3).
--   3. fin_sync_escribir: copia EXACTA de la 196 con un cambio: el insert de pagos copia nota, email,
--      fuente_email y fuente_lead. No cambia nada para Liam (fuente cortada) ni Teo (sin esos alias, llegan en null).
--   4. fin_columnas_sistema('pagos') suma 'email', 'fuente_email' y 'fuente_lead' AL FINAL (no mueve ninguna
--      columna existente) y fin_columnas_ocultas_por_defecto('pagos') las deja ocultas: otros clientes no ven cambios.
--   5. Alias de la fuente de Pagos de Agus: NOTA (carga 19/10) y NOTA -> nota; MAIL -> email;
--      FUENTE DEL MAIL -> fuente_email; FUENTE / FUENTE DEL LEAD / ORIGEN DEL LEAD y ('' + posicion 12) -> fuente_lead.
--      Ninguno obligatorio.
--   6. Config de columnas de Agus (vista pagos): Mail, Fuente del mail, Fuente y Nota visibles, para todos los que
--      ven Pagos de Agus (fin_columnas_de no filtra por rol; la RLS de fin_pagos decide que filas ve cada uno).
--      Si Agus NO tiene orden guardado, se deja en el orden de la hoja; si ya tiene (alguien lo configuro), no se
--      pisa nada: las columnas nuevas van al final y la Nota queda como estaba.
--
-- No toca: datos de pagos, Opps, Liam, Teo, fin_pago_cargar, fin_pago_editar. El formulario Cargar pago (Mail,
-- Fuente del mail y Fuente) lo resuelve la 211, que se corre DESPUES de esta.
-- Depende de la 196 (guarda). Orden: correr esta migracion -> redeploy de `sincronizar` -> publicar el front
-- (el front pide email/fuente_email/fuente_lead: sin la migracion la grilla de Pagos da error de columna).
-- DESPUES: aceptar el encabezado nuevo de la fuente de Pagos de Agus (ver C6 y el informe) y esperar la sync.
-- No correr a las :00/:15/:30/:45 ni a las 9:00 (corre la sync). Re-ejecutable.
-- Controles C1 a C8 y vuelta atras al final (de a uno).
-- =====================================================================

begin;
set local lock_timeout = '10s';
lock table public.fin_pagos, public.fin_alias_columnas, public.fin_columnas in access exclusive mode;

-- ---------------------------------------------------------------------
-- Guardas
-- ---------------------------------------------------------------------
do $g$
declare v text; n int;
begin
  v := pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure);
  if v not like '%196: comprobantes_extra%' then
    raise exception 'GUARDA 209: fin_sync_escribir no es la de la 196 (falta correr la 196, o algo la cambio despues). No se toca nada.';
  end if;
  if v not like '%esta cortada desde%' or v not like '%065: no toca pagos cargados en la app%'
     or v not like '%060: no toca filas de ghl ni de la app%' then
    raise exception 'GUARDA 209: fin_sync_escribir perdio una de sus marcas (corte, 065 o 060). No se toca nada.';
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.fin_alias_columnas'::regclass and conname = 'fin_alias_columnas_campo_ck'
                    and pg_get_constraintdef(oid) like '%formulario%') then
    raise exception 'GUARDA 209: el CHECK de campo_canonico no es el de la 059 (falta ''formulario''). No se toca nada.';
  end if;

  if public.fin_columnas_sistema('pagos') is distinct from array['fecha', 'alumno', 'telefono', 'programa', 'concepto',
       'monto_usd', 'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante', 'nota', 'origen', 'fila_planilla'] then
    raise exception 'GUARDA 209: fin_columnas_sistema(''pagos'') no es la de la 072 (14 claves). No se toca nada.';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_alias_columnas' and column_name = 'posicion') then
    raise exception 'GUARDA 209: fin_alias_columnas no tiene la columna posicion (013). No se toca nada.';
  end if;

  select count(*) into n from public.fin_fuentes where cliente_id = 'agus' and tipo = 'pagos';
  if n <> 1 then
    raise exception 'GUARDA 209: se esperaba 1 fuente de pagos de agus y hay %. No se toca nada.', n;
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- 1. Columnas de fin_pagos
-- ---------------------------------------------------------------------
alter table public.fin_pagos
  add column if not exists email        text,
  add column if not exists fuente_email text,
  add column if not exists fuente_lead  text;

comment on column public.fin_pagos.email is
  '209: mail del alumno, columna MAIL de la planilla de Pagos de Agus. Lo escribe la sync (origen sheet) y, desde la 211, Cargar pago.';
comment on column public.fin_pagos.fuente_email is
  '209: de donde salio el mail (columna FUENTE DEL MAIL de la planilla de Pagos de Agus). Sync y, desde la 211, Cargar pago.';
comment on column public.fin_pagos.fuente_lead is
  '209: origen del lead (instagram, webinar...), columna L sin titulo de la planilla de Pagos de Agus; se muestra como "Fuente". Sync y, desde la 211, Cargar pago.';

-- ---------------------------------------------------------------------
-- 2. CHECK de campo_canonico: lista de la 059 + nota + fuente_email + fuente_lead
-- ---------------------------------------------------------------------
alter table public.fin_alias_columnas drop constraint if exists fin_alias_columnas_campo_ck;
alter table public.fin_alias_columnas add constraint fin_alias_columnas_campo_ck
  check (campo_canonico in (
    'fecha','programa','alumno','telefono','concepto','monto','monto_pesos',
    'closer','setter','comprobante','quien_recibe','metodo_pago',
    'monto_restante','estado','fecha_llamada','nombre','show_up',
    'calificacion','estado_llamada','tipo_booking','cc_dia1','cc_cerrado',
    'cc_seguimiento','instagram','contexto_closer','contexto_setter',
    'email','formulario',
    'nota','fuente_email','fuente_lead'));

-- ---------------------------------------------------------------------
-- 3. fin_sync_escribir = 196 + nota, email, fuente_email, fuente_lead
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fin_sync_escribir(p_corrida bigint, p_estado text, p_mensaje text, p_hash text, p_controles jsonb, p_leidas integer, p_descartadas integer, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_corrida  public.fin_sync_corridas%rowtype;
  v_fuente   public.fin_fuentes%rowtype;
  n_pagos    int := 0;
  n_pnl      int := 0;
  n_saldos   int := 0;
  n_reparto  int := 0;
  n_cuotas   int := 0;
  n_llamadas int := 0;
  n_rech     int := 0;
begin
  if p_estado is null or p_estado not in ('ok', 'revisar', 'parcial') then
    raise exception 'fin_sync_escribir: el estado % no escribe datos', p_estado;
  end if;

  select * into v_corrida from public.fin_sync_corridas where id = p_corrida for update;
  if not found then raise exception 'fin_sync_escribir: no existe la corrida %', p_corrida; end if;
  if v_corrida.estado <> 'en_curso' then
    raise exception 'fin_sync_escribir: la corrida % ya esta cerrada (%)', p_corrida, v_corrida.estado;
  end if;
  select * into v_fuente from public.fin_fuentes where id = v_corrida.fuente_id;

  -- 060: una fuente cortada ya no se escribe nunca (la carga es en la app).
  if v_fuente.cortada_en is not null then
    raise exception 'fin_sync_escribir: la fuente % esta cortada desde %', v_fuente.id, v_fuente.cortada_en;
  end if;

  -- Dos corridas de la misma fuente a la vez (cron + boton manual) se hacen en fila.
  perform pg_advisory_xact_lock(hashtext('fin_sync_escribir'), v_fuente.id::int);

  -- Reemplazo completo: se borra todo lo de la fuente y se inserta lo nuevo.
  delete from public.fin_pagos      where fuente_id = v_fuente.id and origen = 'sheet';  -- 065: no toca pagos cargados en la app
  delete from public.fin_pnl        where fuente_id = v_fuente.id;
  delete from public.fin_pnl_saldos where fuente_id = v_fuente.id;
  delete from public.fin_reparto    where fuente_id = v_fuente.id;
  delete from public.fin_cuotas     where fuente_id = v_fuente.id;
  delete from public.fin_llamadas   where fuente_id = v_fuente.id and origen = 'sheet';  -- 060: no toca filas de ghl ni de la app

  -- cliente_id, fuente_id y sync_id salen de la fuente y la corrida, nunca del payload.
  insert into public.fin_pagos (cliente_id, fuente_id, sync_id, fila_planilla, fecha, programa, alumno, telefono,
    concepto, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente, moneda_cobro, closer, setter,
    comprobante, quien_recibe, metodo_pago, monto_restante, estado, comprobantes_extra,  -- 196: comprobantes_extra
    nota, email, fuente_email, fuente_lead)  -- 209: nota, email, fuente_email (planilla de Agus)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha, x.programa, x.alumno, x.telefono,
         x.concepto, x.monto_usd, x.monto_origen, x.moneda_origen, x.tc_usado, x.tc_fuente, x.moneda_cobro, x.closer, x.setter,
         x.comprobante, x.quien_recibe, x.metodo_pago, x.monto_restante, x.estado,
         case when jsonb_typeof(x.comprobantes_extra) = 'array' then x.comprobantes_extra else '[]'::jsonb end,  -- 196
         x.nota, x.email, x.fuente_email, x.fuente_lead  -- 209
  from jsonb_to_recordset(coalesce(p_datos -> 'pagos', '[]'::jsonb)) as x(
    fila_planilla int, fecha date, programa text, alumno text, telefono text, concepto text, monto_usd numeric,
    monto_origen numeric, moneda_origen text, tc_usado numeric, tc_fuente text, moneda_cobro text, closer text,
    setter text, comprobante text, quien_recibe text, metodo_pago text, monto_restante numeric, estado text,
    comprobantes_extra jsonb, nota text, email text, fuente_email text, fuente_lead text);
  get diagnostics n_pagos = row_count;

  insert into public.fin_pnl (cliente_id, fuente_id, sync_id, anio, mes, categoria, item, monto_usd, fila_planilla, columna_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.categoria, x.item, x.monto_usd, x.fila_planilla, x.columna_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'pnl', '[]'::jsonb)) as x(
    anio int, mes int, categoria text, item text, monto_usd numeric, fila_planilla int, columna_planilla int);
  get diagnostics n_pnl = row_count;

  insert into public.fin_pnl_saldos (cliente_id, fuente_id, sync_id, anio, mes, opening_balance, closing_balance, dividends_released)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.opening_balance, x.closing_balance, x.dividends_released
  from jsonb_to_recordset(coalesce(p_datos -> 'saldos', '[]'::jsonb)) as x(
    anio int, mes int, opening_balance numeric, closing_balance numeric, dividends_released numeric);
  get diagnostics n_saldos = row_count;

  insert into public.fin_reparto (cliente_id, fuente_id, sync_id, anio, mes, beneficiario, monto, fila_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.anio, x.mes, x.beneficiario, x.monto, x.fila_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'reparto', '[]'::jsonb)) as x(
    anio int, mes int, beneficiario text, monto numeric, fila_planilla int);
  get diagnostics n_reparto = row_count;

  insert into public.fin_cuotas (cliente_id, fuente_id, sync_id, alumno, telefono, programa, numero_cuota, tipo_cuota,
    monto, monto_cobrado, fecha_pago, estado, closer, contexto, fila_planilla)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.alumno, x.telefono, x.programa, x.numero_cuota, x.tipo_cuota,
         x.monto, x.monto_cobrado, x.fecha_pago, x.estado, x.closer, x.contexto, x.fila_planilla
  from jsonb_to_recordset(coalesce(p_datos -> 'cuotas', '[]'::jsonb)) as x(
    alumno text, telefono text, programa text, numero_cuota int, tipo_cuota text, monto numeric, monto_cobrado numeric,
    fecha_pago date, estado text, closer text, contexto text, fila_planilla int);
  get diagnostics n_cuotas = row_count;

  insert into public.fin_llamadas (cliente_id, fuente_id, sync_id, fila_planilla, fecha_llamada, closer, nombre,
    show_up, calificacion, estado_llamada, tipo_booking, programa, cc_dia1, cc_cerrado, cc_seguimiento,
    monto_restante, telefono, instagram, contexto_closer, contexto_setter,
    email, hora_llamada, formulario, origen)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha_llamada, x.closer, x.nombre,
         x.show_up, x.calificacion, x.estado_llamada, x.tipo_booking, x.programa, x.cc_dia1, x.cc_cerrado, x.cc_seguimiento,
         x.monto_restante, x.telefono, x.instagram, x.contexto_closer, x.contexto_setter,
         x.email, x.hora_llamada, coalesce(x.formulario, '{}'::jsonb), 'sheet'
  from jsonb_to_recordset(coalesce(p_datos -> 'llamadas', '[]'::jsonb)) as x(
    fila_planilla int, fecha_llamada date, closer text, nombre text, show_up text, calificacion text,
    estado_llamada text, tipo_booking text, programa text, cc_dia1 numeric, cc_cerrado numeric,
    cc_seguimiento numeric, monto_restante numeric, telefono text, instagram text, contexto_closer text,
    contexto_setter text, email text, hora_llamada time, formulario jsonb);
  get diagnostics n_llamadas = row_count;

  insert into public.fin_filas_rechazadas (corrida_id, fila_planilla, motivo, valor_crudo, comprobante, metodo_pago, contenido_crudo)
  select p_corrida, x.fila_planilla, x.motivo, x.valor_crudo, x.comprobante, x.metodo_pago, coalesce(x.contenido_crudo, '[]'::jsonb)
  from jsonb_to_recordset(coalesce(p_datos -> 'rechazadas', '[]'::jsonb)) as x(
    fila_planilla int, motivo text, valor_crudo text, comprobante text, metodo_pago text, contenido_crudo jsonb);
  get diagnostics n_rech = row_count;

  update public.fin_sync_corridas set
    fin               = now(),
    estado            = p_estado,
    filas_leidas      = p_leidas,
    filas_cargadas    = n_pagos + n_pnl + n_cuotas + n_llamadas,
    filas_rechazadas  = n_rech,
    filas_descartadas = p_descartadas,
    mensaje           = p_mensaje,
    hash_encabezado   = p_hash,
    controles         = coalesce(p_controles, '[]'::jsonb)
  where id = p_corrida;

  return jsonb_build_object('pagos', n_pagos, 'pnl', n_pnl, 'saldos', n_saldos, 'reparto', n_reparto,
                            'cuotas', n_cuotas, 'llamadas', n_llamadas, 'rechazadas', n_rech);
end $function$;

-- ---------------------------------------------------------------------
-- 4. Columnas del sistema de Pagos: tres nuevas AL FINAL, ocultas por defecto
-- ---------------------------------------------------------------------
create or replace function public.fin_columnas_sistema(p_vista text)
returns text[]
language sql immutable set search_path = public
as $$
  select case p_vista
    when 'pagos' then array['fecha', 'alumno', 'telefono', 'programa', 'concepto', 'monto_usd',
                            'metodo_pago', 'quien_recibe', 'closer', 'setter', 'comprobante',
                            'nota', 'origen', 'fila_planilla', 'email', 'fuente_email', 'fuente_lead']
    when 'pnl' then array['revenue_declarado', 'ingreso_real', 'staff', 'softwares', 'others',
                          'sin_categoria', 'gastos_total', 'net_cash_flow', 'dividends_released',
                          'opening_balance', 'closing_balance']
    when 'resumen' then array['ingreso_real', 'revenue_declarado', 'diferencia', 'gastos_total',
                              'net_cash_flow', 'cantidad_pagos', 'sincronizacion']
    when 'conciliacion' then array['mes', 'revenue_opps', 'revenue_pagos', 'cantidad_pagos',
                                   'diferencia', 'diferencia_pct']
  end;
$$;

create or replace function public.fin_columnas_ocultas_por_defecto(p_vista text)
returns text[]
language sql immutable set search_path = public
as $$
  select case p_vista when 'pagos' then array['telefono', 'nota', 'email', 'fuente_email', 'fuente_lead'] else array[]::text[] end;
$$;

-- ---------------------------------------------------------------------
-- 5. Alias de la fuente de Pagos de Agus
-- ---------------------------------------------------------------------
-- Fuente (columna L, hoy sin titulo): alias en blanco + posicion 12. El parser lo usa solo mientras la
-- columna L siga en blanco; si Agus le pone titulo, lo toman los alias por nombre (FUENTE, etc.).
insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, posicion)
select f.id, a.campo, a.alias, false, a.posicion
from public.fin_fuentes f
cross join (values
  ('nota',         'NOTA (carga 19/10)',  null::int),
  ('nota',         'NOTA',                null::int),
  ('email',        'MAIL',                null::int),
  ('fuente_email', 'FUENTE DEL MAIL',     null::int),
  ('fuente_lead',  'FUENTE',              null::int),
  ('fuente_lead',  'FUENTE DEL LEAD',     null::int),
  ('fuente_lead',  'ORIGEN DEL LEAD',     null::int),
  ('fuente_lead',  '',                    12)
) as a(campo, alias, posicion)
where f.cliente_id = 'agus' and f.tipo = 'pagos'
on conflict (fuente_id, campo_canonico, alias) do nothing;

-- ---------------------------------------------------------------------
-- 6. Columnas de Agus en la grilla de Pagos
-- ---------------------------------------------------------------------
do $c$
declare v_hay boolean; v_max int;
begin
  select exists (select 1 from public.fin_columnas where cliente_id = 'agus' and vista = 'pagos' and sistema)
    into v_hay;
  if not v_hay then
    -- Sin configuracion guardada: orden de la hoja (Fecha, Programa, Alumno, Numero, Concepto, Pago, Closer, Setter,
    -- Comprobante, Quien recibe, Metodo, Fuente, Mail, Fuente del mail, Nota) y despues las columnas propias de la app.
    -- Telefono sigue oculto (es el default de la app; la hoja lo muestra: ver informe).
    insert into public.fin_columnas (cliente_id, vista, clave, sistema, orden, visible)
    values ('agus','pagos','fecha',        true,  10, true),
           ('agus','pagos','programa',     true,  20, true),
           ('agus','pagos','alumno',       true,  30, true),
           ('agus','pagos','telefono',     true,  40, false),
           ('agus','pagos','concepto',     true,  50, true),
           ('agus','pagos','monto_usd',    true,  60, true),
           ('agus','pagos','closer',       true,  70, true),
           ('agus','pagos','setter',       true,  80, true),
           ('agus','pagos','comprobante',  true,  90, true),
           ('agus','pagos','quien_recibe', true, 100, true),
           ('agus','pagos','metodo_pago',  true, 110, true),
           ('agus','pagos','fuente_lead',  true, 115, true),
           ('agus','pagos','email',        true, 120, true),
           ('agus','pagos','fuente_email', true, 130, true),
           ('agus','pagos','nota',         true, 140, true),
           ('agus','pagos','origen',       true, 150, true),
           ('agus','pagos','fila_planilla',true, 160, true)
    on conflict (coalesce(cliente_id, '*'), vista, clave) do nothing;
  else
    -- Ya hay configuracion: no se pisa el orden ni la visibilidad de lo existente.
    -- Mail, Fuente del mail y Fuente se agregan al final (visibles); Nota no se toca.
    select coalesce(max(orden), 0) into v_max from public.fin_columnas where cliente_id = 'agus' and vista = 'pagos';
    insert into public.fin_columnas (cliente_id, vista, clave, sistema, orden, visible)
    values ('agus','pagos','email',        true, v_max + 10, true),
           ('agus','pagos','fuente_email', true, v_max + 20, true),
           ('agus','pagos','fuente_lead',  true, v_max + 30, true)
    on conflict (coalesce(cliente_id, '*'), vista, clave) do nothing;
    raise notice '209: Agus ya tenia columnas configuradas en Pagos: se agregaron Mail, Fuente del mail y Fuente al final; la Nota queda como estaba (ver C5).';
  end if;
end
$c$;

-- ---------------------------------------------------------------------
-- Verificacion dentro de la transaccion: si algo no quedo, no se confirma nada.
-- ---------------------------------------------------------------------
do $v$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema = 'public' and table_name = 'fin_pagos' and column_name in ('nota', 'email', 'fuente_email', 'fuente_lead');
  if n <> 4 then raise exception 'VERIFICACION 209: faltan columnas en fin_pagos (hay % de 4)', n; end if;

  select count(*) into n from public.fin_alias_columnas a join public.fin_fuentes f on f.id = a.fuente_id
   where f.cliente_id = 'agus' and f.tipo = 'pagos' and a.campo_canonico in ('nota', 'email', 'fuente_email', 'fuente_lead');
  if n < 8 then raise exception 'VERIFICACION 209: faltan alias de Agus (hay % de 8)', n; end if;

  if pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure)
       not like '%209: nota, email, fuente_email%' then
    raise exception 'VERIFICACION 209: fin_sync_escribir no quedo actualizada';
  end if;

  select count(*) into n from public.fin_columnas
   where cliente_id = 'agus' and vista = 'pagos' and clave in ('email', 'fuente_email', 'fuente_lead') and visible;
  if n <> 3 then raise exception 'VERIFICACION 209: Mail / Fuente del mail / Fuente de Agus no quedaron visibles'; end if;
end
$v$;

commit;

-- =====================================================================
-- CONTROLES (de a uno; el editor muestra solo el ultimo)
-- =====================================================================

-- C1. Columnas nuevas en fin_pagos. Esperado: 4 filas (email, fuente_email, fuente_lead, nota), todas text y nullable.
-- select column_name, data_type, is_nullable from information_schema.columns
--  where table_schema = 'public' and table_name = 'fin_pagos' and column_name in ('nota', 'email', 'fuente_email', 'fuente_lead')
--  order by 1;

-- C2. La funcion nueva conserva lo anterior. Esperado: las 5 en true.
-- select pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%209: nota, email, fuente_email%' as copia_nuevas,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%196: comprobantes_extra%' as extras_196,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%065: no toca pagos cargados en la app%' as solo_sheet,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%esta cortada desde%' as respeta_corte,
--        pg_get_functiondef('public.fin_sync_escribir(bigint,text,text,text,jsonb,integer,integer,jsonb)'::regprocedure) like '%060: no toca filas de ghl ni de la app%' as llamadas_igual;

-- C3. Alias de Agus. Esperado: 8 nuevas (NOTA (carga 19/10), NOTA, MAIL, FUENTE DEL MAIL, FUENTE, FUENTE DEL LEAD,
--     ORIGEN DEL LEAD y una de fuente_lead con alias en blanco y posicion 12) + las 11 de siempre.
-- select f.id as fuente_id, a.campo_canonico, a.alias, a.posicion, a.obligatorio
--   from public.fin_alias_columnas a join public.fin_fuentes f on f.id = a.fuente_id
--  where f.cliente_id = 'agus' and f.tipo = 'pagos' order by a.campo_canonico, a.alias;

-- C4. Otros clientes sin cambios: ningun alias nuevo fuera de Agus. Esperado: 0 filas.
-- select f.cliente_id, a.campo_canonico, a.alias
--   from public.fin_alias_columnas a join public.fin_fuentes f on f.id = a.fuente_id
--  where a.campo_canonico in ('nota', 'fuente_email', 'fuente_lead') and f.cliente_id <> 'agus';

-- C5. Configuracion de columnas de Agus (Pagos). Esperado sin config previa: 17 filas en el orden de la hoja,
--     telefono visible=false, todo lo demas true. Con config previa: las que habia + email, fuente_email y fuente_lead al final.
-- select clave, orden, visible, etiqueta from public.fin_columnas
--  where cliente_id = 'agus' and vista = 'pagos' order by orden, clave;

-- C6. Estado de la fuente de Pagos de Agus. Mirar: activo/cortada_en (si cortada_en NO es null, la 067 se
--     corrio: la sync ya no lee la hoja y nada de esto llega solo, ver informe) y la ultima corrida.
--     Anotar el id (fuente_id) para aceptar el encabezado nuevo.
-- select f.id as fuente_id, f.activo, f.cortada_en,
--        (select c.estado from public.fin_sync_corridas c where c.fuente_id = f.id order by c.id desc limit 1) as ultima_corrida,
--        (select c.mensaje from public.fin_sync_corridas c where c.fuente_id = f.id order by c.id desc limit 1) as mensaje
--   from public.fin_fuentes f where f.cliente_id = 'agus' and f.tipo = 'pagos';

-- C7. LUEGO del redeploy de `sincronizar`, de aceptar el encabezado y de una corrida buena de Agus Pagos:
--     Esperado segun el xlsx del 23/10: con_nota 22, con_mail 14, con_fuente_mail 19, con_fuente ~123 (puede variar si la hoja cambio).
--     Si con_fuente da 0 y la columna L sigue sin titulo, mirar el encabezado aceptado (posicion 12 en blanco).
-- select count(*) as pagos_sheet,
--        count(*) filter (where nota is not null)         as con_nota,
--        count(*) filter (where email is not null)        as con_mail,
--        count(*) filter (where fuente_email is not null) as con_fuente_mail,
--        count(*) filter (where fuente_lead is not null)  as con_fuente
--   from public.fin_pagos where cliente_id = 'agus' and origen = 'sheet';

-- C8. Otros clientes: ni mail, ni fuente de mail, ni fuente. Esperado: 0, 0 y 0 (hasta que alguien los cargue en la app con la 211).
-- select count(*) filter (where email is not null) as con_mail, count(*) filter (where fuente_email is not null) as con_fuente_mail,
--        count(*) filter (where fuente_lead is not null) as con_fuente
--   from public.fin_pagos where cliente_id <> 'agus';

-- =====================================================================
-- VUELTA ATRAS (no correr salvo marcha atras)
-- =====================================================================
-- 1) Redeploy de `sincronizar` con el parser anterior (git) y volver a correr el bloque create or replace de
--    fin_sync_escribir de la 196 (sin nota/email/fuente_email/fuente_lead). Si la 211 ya se corrio, volver antes su fin_pago_cargar (ver su vuelta atras).
-- 2) delete from public.fin_alias_columnas where campo_canonico in ('nota', 'fuente_email', 'fuente_lead')
--       or (campo_canonico = 'email' and fuente_id in (select id from public.fin_fuentes where cliente_id = 'agus' and tipo = 'pagos'));
--    alter table public.fin_alias_columnas drop constraint fin_alias_columnas_campo_ck;
--    alter table public.fin_alias_columnas add constraint fin_alias_columnas_campo_ck check (campo_canonico in (
--      'fecha','programa','alumno','telefono','concepto','monto','monto_pesos','closer','setter','comprobante','quien_recibe',
--      'metodo_pago','monto_restante','estado','fecha_llamada','nombre','show_up','calificacion','estado_llamada','tipo_booking',
--      'cc_dia1','cc_cerrado','cc_seguimiento','instagram','contexto_closer','contexto_setter','email','formulario'));
-- 3) delete from public.fin_columnas where vista = 'pagos' and clave in ('email', 'fuente_email', 'fuente_lead');
--    (el orden y la visibilidad que esta migracion le dio a las demas columnas de Agus, si no tenia config, se
--    revierte con: delete from public.fin_columnas where cliente_id = 'agus' and vista = 'pagos' and sistema;
--    SOLO si esa config la creo esta migracion y nadie la toco despues.)
-- 4) Restaurar fin_columnas_sistema('pagos') y fin_columnas_ocultas_por_defecto('pagos') a la 072 (14 claves; ocultas telefono y nota).
-- 5) alter table public.fin_pagos drop column if exists email, drop column if exists fuente_email, drop column if exists fuente_lead;
--    (publicar antes el front anterior: pide esas columnas).
