-- 013_llamadas.sql — Dystopia Finanzas: hoja Data (CRM de ventas) -> fin_llamadas.
-- Ver CONTRATO-DATA.md secciones 1 y 9 (pasos 1 y 2).
--
-- 1. fin_llamadas: una fila por llamada de la hoja Data, con los campos
--    canonicos de CONTRATO-DATA.md §1 + cliente_id, fuente_id, sync_id y
--    fila_planilla, igual que fin_pagos. Reemplazo completo por fuente.
-- 2. RLS igual a fin_pagos_lectura: fundador todo, cliente por
--    tiene_acceso(), closer por alias en fin_personas. Sin rama setter:
--    Data no tiene columna de setter (CONTRATO-DATA.md §5).
-- 3. fin_sync_escribir acepta la clave "llamadas" en p_datos. Misma firma
--    que 005, asi que create or replace no rompe los grants ni a la Edge
--    Function deployada (que no manda la clave: coalesce a '[]').
-- 4. fin_alias_columnas: columna "posicion" (mapeo por posicion, gana sobre
--    alias) y CHECK de campo_canonico ampliado con los campos de Data.
--    Motivo: liam tiene dos columnas "Encargado de la llamada" y la fecha
--    es la segunda (CONTRATO-DATA.md §4.1).
--
-- La politica de lectura solo deja pasar alias de fin_personas con campo
-- 'closer' o 'ambos' (a diferencia de fin_pagos_lectura, que no filtra).
--
-- show_up y calificacion llegan YA normalizados por el parser (minusculas,
-- sin tildes, 'se desconoce' -> 'no se sabe', 'por closer' ->
-- 'cancelado por closer'). Un valor fuera del dominio hace fallar la
-- escritura entera de la fuente y quedan los datos de la corrida anterior:
-- el parser tiene que rechazar la celda antes (CONTRATO-DATA.md §4.4).
--
-- Idempotente. Requiere 001, 005, 006 y 009.

begin;

-- ---------------------------------------------------------------------------
-- 0. fin_alias_columnas: posicion + campos canonicos de Data
-- ---------------------------------------------------------------------------
alter table public.fin_alias_columnas
  add column if not exists posicion int;

alter table public.fin_alias_columnas drop constraint if exists fin_alias_columnas_posicion_ck;
alter table public.fin_alias_columnas
  add constraint fin_alias_columnas_posicion_ck check (posicion is null or posicion >= 1);

comment on column public.fin_alias_columnas.posicion is
  'Columna de la planilla, 1-based (A = 1). Si esta cargada GANA sobre alias: el campo se lee de esa posicion '
  'sin mirar el encabezado. NULL = se mapea por nombre (alias), como hasta ahora. '
  'Existe por liam, que tiene dos columnas "Encargado de la llamada" y la fecha es la segunda (CONTRATO-DATA.md §4.1).';

-- El check de campo_canonico de 001 no tiene nombre propio: se busca por su
-- definicion (mismo patron que 006) y se reemplaza por uno con nombre.
do $$
declare v_nombre text;
begin
  for v_nombre in
    select conname from pg_constraint
    where conrelid = 'public.fin_alias_columnas'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%campo_canonico%'
  loop
    execute format('alter table public.fin_alias_columnas drop constraint %I', v_nombre);
  end loop;
end $$;

alter table public.fin_alias_columnas
  add constraint fin_alias_columnas_campo_ck check (campo_canonico in (
    -- Pagos, Opps, Cuotas (001)
    'fecha', 'programa', 'alumno', 'telefono', 'concepto', 'monto', 'monto_pesos',
    'closer', 'setter', 'comprobante', 'quien_recibe', 'metodo_pago',
    'monto_restante', 'estado',
    -- Data (CONTRATO-DATA.md §1). programa, telefono, closer y monto_restante ya estaban.
    'fecha_llamada', 'nombre', 'show_up', 'calificacion', 'estado_llamada',
    'tipo_booking', 'cc_dia1', 'cc_cerrado', 'cc_seguimiento', 'instagram',
    'contexto_closer', 'contexto_setter'));

-- ---------------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------------
create table if not exists public.fin_llamadas (
  id              bigint generated always as identity primary key,
  cliente_id      text    not null references public.crm_clients(id),
  fuente_id       bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id         bigint  references public.fin_sync_corridas(id) on delete set null,
  fila_planilla   int     not null,
  fecha_llamada   date    not null,
  closer          text    not null,
  nombre          text    not null,
  show_up         text    check (show_up in ('si', 'no', 'regenda', 'cancelado por closer')),
  calificacion    text    check (calificacion in ('calificado', 'no calificado', 'no se sabe')),
  estado_llamada  text,
  tipo_booking    text,
  programa        text,
  cc_dia1         numeric,
  cc_cerrado      numeric,
  cc_seguimiento  numeric,
  monto_restante  numeric,
  telefono        text,
  instagram       text,
  contexto_closer text,
  contexto_setter text
);
create index if not exists fin_llamadas_cliente_fecha_idx on public.fin_llamadas (cliente_id, fecha_llamada);
create index if not exists fin_llamadas_fuente_idx on public.fin_llamadas (fuente_id);
create index if not exists fin_llamadas_closer_idx on public.fin_llamadas (cliente_id, lower(btrim(closer)));

comment on table public.fin_llamadas is 'Hoja Data (CRM de ventas). Reemplazo completo por fuente en cada corrida. Ver CONTRATO-DATA.md.';
comment on column public.fin_llamadas.closer is '"Encargado de la llamada". Alias de Data: set distinto al de Pagos (CONTRATO-DATA.md §6).';
comment on column public.fin_llamadas.estado_llamada is 'Solo teo y mauro. Lista abierta: se guarda el texto, sin validar.';
comment on column public.fin_llamadas.contexto_setter is 'Texto libre, NO es un nombre de setter. Data no tiene columna de setter.';

-- ---------------------------------------------------------------------------
-- 2. Permisos de tabla (mismo bloque que 001 §4 para las tablas sincronizadas)
-- ---------------------------------------------------------------------------
alter table public.fin_llamadas enable row level security;
revoke all on table public.fin_llamadas from anon, public;
revoke all on table public.fin_llamadas from authenticated;
grant select on table public.fin_llamadas to authenticated;
grant all on table public.fin_llamadas to service_role;

-- ---------------------------------------------------------------------------
-- 3. Politica: fundador; cliente lo suyo; closer donde figura como closer,
--    y solo con alias marcados 'closer' o 'ambos' en fin_personas.campo.
-- ---------------------------------------------------------------------------
drop policy if exists fin_llamadas_lectura on public.fin_llamadas;
create policy fin_llamadas_lectura on public.fin_llamadas
  for select to authenticated
  using (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id))
    or (public.rol_actual() = 'closer' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and (p.cliente_id is null or p.cliente_id = fin_llamadas.cliente_id)
            and lower(btrim(p.alias)) = lower(btrim(fin_llamadas.closer))))
  );

-- ---------------------------------------------------------------------------
-- 4. fin_sync_escribir: 005 + clave "llamadas". Lo demas queda identico.
-- ---------------------------------------------------------------------------
create or replace function public.fin_sync_escribir(
  p_corrida     bigint,
  p_estado      text,
  p_mensaje     text,
  p_hash        text,
  p_controles   jsonb,
  p_leidas      int,
  p_descartadas int,
  p_datos       jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
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

  -- Dos corridas de la misma fuente a la vez (cron + boton manual) se hacen en fila.
  perform pg_advisory_xact_lock(hashtext('fin_sync_escribir'), v_fuente.id::int);

  -- Reemplazo completo: se borra todo lo de la fuente y se inserta lo nuevo.
  delete from public.fin_pagos      where fuente_id = v_fuente.id;
  delete from public.fin_pnl        where fuente_id = v_fuente.id;
  delete from public.fin_pnl_saldos where fuente_id = v_fuente.id;
  delete from public.fin_reparto    where fuente_id = v_fuente.id;
  delete from public.fin_cuotas     where fuente_id = v_fuente.id;
  delete from public.fin_llamadas   where fuente_id = v_fuente.id;

  -- cliente_id, fuente_id y sync_id salen de la fuente y la corrida, nunca del payload.
  insert into public.fin_pagos (cliente_id, fuente_id, sync_id, fila_planilla, fecha, programa, alumno, telefono,
    concepto, monto_usd, monto_origen, moneda_origen, tc_usado, tc_fuente, moneda_cobro, closer, setter,
    comprobante, quien_recibe, metodo_pago, monto_restante, estado)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha, x.programa, x.alumno, x.telefono,
         x.concepto, x.monto_usd, x.monto_origen, x.moneda_origen, x.tc_usado, x.tc_fuente, x.moneda_cobro, x.closer, x.setter,
         x.comprobante, x.quien_recibe, x.metodo_pago, x.monto_restante, x.estado
  from jsonb_to_recordset(coalesce(p_datos -> 'pagos', '[]'::jsonb)) as x(
    fila_planilla int, fecha date, programa text, alumno text, telefono text, concepto text, monto_usd numeric,
    monto_origen numeric, moneda_origen text, tc_usado numeric, tc_fuente text, moneda_cobro text, closer text,
    setter text, comprobante text, quien_recibe text, metodo_pago text, monto_restante numeric, estado text);
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
    monto_restante, telefono, instagram, contexto_closer, contexto_setter)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha_llamada, x.closer, x.nombre,
         x.show_up, x.calificacion, x.estado_llamada, x.tipo_booking, x.programa, x.cc_dia1, x.cc_cerrado, x.cc_seguimiento,
         x.monto_restante, x.telefono, x.instagram, x.contexto_closer, x.contexto_setter
  from jsonb_to_recordset(coalesce(p_datos -> 'llamadas', '[]'::jsonb)) as x(
    fila_planilla int, fecha_llamada date, closer text, nombre text, show_up text, calificacion text,
    estado_llamada text, tipo_booking text, programa text, cc_dia1 numeric, cc_cerrado numeric,
    cc_seguimiento numeric, monto_restante numeric, telefono text, instagram text, contexto_closer text,
    contexto_setter text);
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
end $$;

revoke all on function public.fin_sync_escribir(bigint, text, text, text, jsonb, int, int, jsonb) from public, anon, authenticated;
grant execute on function public.fin_sync_escribir(bigint, text, text, text, jsonb, int, int, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Prueba de humo (se autorrevierte): dos corridas seguidas de una fuente
-- 'data'. La segunda reemplaza a la primera (no suma). show_up fuera del
-- dominio o closer faltante hacen fallar la escritura sin dejar nada a
-- medias. filas_cargadas cuenta las llamadas.
-- REGRESION de Pagos: una fuente 'pagos' carga y reemplaza como en 005, y
-- escribir una fuente no toca los datos de la otra.
-- fin_alias_columnas: acepta campos de Data con posicion; rechazan
-- posicion 0 y un campo_canonico inventado.
-- ---------------------------------------------------------------------------
do $$
declare
  v_fuente  bigint;
  v_fpagos  bigint;
  v_c1      bigint;
  v_c2      bigint;
  v_c3      bigint;
  v_p1      bigint;
  v_p2      bigint;
  v_n       int;
  v_r       jsonb;
  v_pago    jsonb := '{"fila_planilla":2,"fecha":"2026-02-10","alumno":"Smoke","monto_usd":900,"monto_origen":900,"moneda_origen":"USD","closer":"Smoke Closer"}';
  v_llamada jsonb := '{"fila_planilla":2,"fecha_llamada":"2026-09-05","closer":"Smoke Closer ","nombre":"Smoke",'
                     '"show_up":"si","calificacion":"calificado","tipo_booking":"instagram","cc_dia1":500}';
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo)
    values ('liam', 'SMOKE_013', 1, 'Data', 'data') returning id into v_fuente;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c1;
    v_r := public.fin_sync_escribir(v_c1, 'ok', null, 'h1', '[]', 3, 0,
      jsonb_build_object('llamadas', jsonb_build_array(v_llamada, v_llamada || '{"fila_planilla":3,"show_up":null}'),
                         'rechazadas', '[{"fila_planilla":4,"motivo":"fecha en texto no reconocida","contenido_crudo":["x"]}]'::jsonb));
    if (v_r ->> 'llamadas')::int <> 2 then raise exception 'smoke 013: la funcion informo % llamadas, se esperaban 2', v_r ->> 'llamadas'; end if;
    select count(*) into v_n from public.fin_llamadas where fuente_id = v_fuente and cliente_id = 'liam' and sync_id = v_c1;
    if v_n <> 2 then raise exception 'smoke 013: primera corrida dejo % llamadas, se esperaban 2', v_n; end if;
    select filas_cargadas into v_n from public.fin_sync_corridas where id = v_c1;
    if v_n <> 2 then raise exception 'smoke 013: filas_cargadas = %, se esperaba 2', v_n; end if;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c2;
    perform public.fin_sync_escribir(v_c2, 'ok', null, 'h1', '[]', 1, 0,
      jsonb_build_object('llamadas', jsonb_build_array(v_llamada)));
    select count(*) into v_n from public.fin_llamadas where fuente_id = v_fuente;
    if v_n <> 1 then raise exception 'smoke 013: la segunda corrida no reemplazo (quedan % llamadas)', v_n; end if;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c3;
    -- show_up sin normalizar: viola el CHECK, nada a medias.
    begin
      perform public.fin_sync_escribir(v_c3, 'ok', null, 'h1', '[]', 2, 0,
        jsonb_build_object('llamadas', jsonb_build_array(v_llamada, v_llamada || '{"show_up":"SI"}')));
      raise exception 'smoke 013: un show_up fuera del dominio no hizo fallar la escritura';
    exception when check_violation then null;
    end;
    -- Sin closer: viola not null, nada a medias.
    begin
      perform public.fin_sync_escribir(v_c3, 'ok', null, 'h1', '[]', 2, 0,
        jsonb_build_object('llamadas', jsonb_build_array(v_llamada, v_llamada - 'closer')));
      raise exception 'smoke 013: una llamada sin closer no hizo fallar la escritura';
    exception when not_null_violation then null;
    end;
    select count(*) into v_n from public.fin_llamadas where fuente_id = v_fuente and sync_id = v_c2;
    if v_n <> 1 then raise exception 'smoke 013: un fallo a mitad borro los datos anteriores'; end if;

    -- REGRESION Pagos: carga, reemplazo por fuente y aislamiento entre fuentes.
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('liam', 'SMOKE_013', 2, 'Pagos', 'pagos', 10000) returning id into v_fpagos;

    insert into public.fin_sync_corridas (fuente_id) values (v_fpagos) returning id into v_p1;
    v_r := public.fin_sync_escribir(v_p1, 'ok', null, 'h1', '[]', 3, 0,
      jsonb_build_object('pagos', jsonb_build_array(v_pago, v_pago || '{"fila_planilla":3}', v_pago || '{"fila_planilla":4}')));
    if (v_r ->> 'pagos')::int <> 3 or (v_r ->> 'llamadas')::int <> 0 then
      raise exception 'smoke 013 (pagos): la funcion informo %, se esperaban 3 pagos y 0 llamadas', v_r;
    end if;
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fpagos and cliente_id = 'liam' and sync_id = v_p1;
    if v_n <> 3 then raise exception 'smoke 013 (pagos): primera corrida dejo % pagos, se esperaban 3', v_n; end if;
    select filas_cargadas into v_n from public.fin_sync_corridas where id = v_p1;
    if v_n <> 3 then raise exception 'smoke 013 (pagos): filas_cargadas = %, se esperaba 3', v_n; end if;
    select count(*) into v_n from public.fin_llamadas where fuente_id = v_fuente and sync_id = v_c2;
    if v_n <> 1 then raise exception 'smoke 013 (pagos): escribir la fuente de pagos toco las llamadas de otra fuente'; end if;

    insert into public.fin_sync_corridas (fuente_id) values (v_fpagos) returning id into v_p2;
    perform public.fin_sync_escribir(v_p2, 'revisar', null, 'h1', '[]', 1, 0,
      jsonb_build_object('pagos', jsonb_build_array(v_pago)));
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fpagos;
    if v_n <> 1 then raise exception 'smoke 013 (pagos): la segunda corrida no reemplazo (quedan % pagos)', v_n; end if;
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fpagos and sync_id = v_p2;
    if v_n <> 1 then raise exception 'smoke 013 (pagos): el pago que quedo no es de la segunda corrida'; end if;

    -- Y al reves: una corrida de la fuente data no toca los pagos.
    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c3;
    perform public.fin_sync_escribir(v_c3, 'ok', null, 'h1', '[]', 1, 0,
      jsonb_build_object('llamadas', jsonb_build_array(v_llamada)));
    select count(*) into v_n from public.fin_pagos where fuente_id = v_fpagos and sync_id = v_p2;
    if v_n <> 1 then raise exception 'smoke 013 (pagos): escribir la fuente data toco los pagos de otra fuente'; end if;

    -- fin_alias_columnas: el caso de liam (dos "Encargado de la llamada").
    insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, posicion)
    values (v_fuente, 'closer',        'Encargado de la llamada', true, 1),
           (v_fuente, 'fecha_llamada', 'Encargado de la llamada', true, 2);
    begin
      insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, posicion)
      values (v_fuente, 'nombre', 'Nombre', 0);
      raise exception 'smoke 013: fin_alias_columnas acepto posicion 0';
    exception when check_violation then null;
    end;
    begin
      insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias)
      values (v_fuente, 'campo_inventado', 'X');
      raise exception 'smoke 013: fin_alias_columnas acepto un campo_canonico inventado';
    exception when check_violation then null;
    end;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 013: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Query de control: la columna "ok" tiene que dar true en todas las filas.
-- ---------------------------------------------------------------------------
select 'fin_llamadas: columnas' as control,
       count(*)::text as valor, count(*) = 21 as ok
from information_schema.columns
where table_schema = 'public' and table_name = 'fin_llamadas'
union all
select 'fin_llamadas: RLS activa',
       c.relrowsecurity::text, c.relrowsecurity
from pg_class c where c.oid = 'public.fin_llamadas'::regclass
union all
select 'fin_llamadas: politica fin_llamadas_lectura',
       count(*)::text, count(*) = 1
from pg_policies where schemaname = 'public' and tablename = 'fin_llamadas' and policyname = 'fin_llamadas_lectura'
union all
select 'fin_llamadas_lectura: filtra por fin_personas.campo',
       (qual like '%campo%')::text, qual like '%campo%' and qual like '%ambos%'
from pg_policies where schemaname = 'public' and tablename = 'fin_llamadas' and policyname = 'fin_llamadas_lectura'
union all
select 'fin_alias_columnas: columna posicion',
       count(*)::text, count(*) = 1
from information_schema.columns
where table_schema = 'public' and table_name = 'fin_alias_columnas' and column_name = 'posicion'
union all
select 'fin_alias_columnas: un solo CHECK de campo_canonico y admite fecha_llamada',
       count(*)::text,
       count(*) = 1 and bool_and(pg_get_constraintdef(oid) like '%fecha_llamada%')
from pg_constraint
where conrelid = 'public.fin_alias_columnas'::regclass and contype = 'c'
  and pg_get_constraintdef(oid) like '%campo_canonico%'
union all
select 'fin_llamadas: anon sin select',
       has_table_privilege('anon', 'public.fin_llamadas', 'select')::text,
       not has_table_privilege('anon', 'public.fin_llamadas', 'select')
union all
select 'fin_llamadas: authenticated solo select',
       has_table_privilege('authenticated', 'public.fin_llamadas', 'insert')::text,
       has_table_privilege('authenticated', 'public.fin_llamadas', 'select')
       and not has_table_privilege('authenticated', 'public.fin_llamadas', 'insert,update,delete')
union all
select 'fin_llamadas: service_role escribe',
       has_table_privilege('service_role', 'public.fin_llamadas', 'insert')::text,
       has_table_privilege('service_role', 'public.fin_llamadas', 'insert,delete')
union all
select 'fin_sync_escribir: no es security definer',
       p.prosecdef::text, not p.prosecdef
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fin_sync_escribir'
union all
select 'fin_sync_escribir: escribe fin_llamadas',
       (pg_get_functiondef(p.oid) like '%delete from public.fin_llamadas%')::text,
       pg_get_functiondef(p.oid) like '%delete from public.fin_llamadas%'
         and pg_get_functiondef(p.oid) like '%p_datos -> ''llamadas''%'
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fin_sync_escribir'
union all
select 'fin_sync_escribir: service_role si, anon/authenticated no',
       has_function_privilege('service_role', p.oid, 'execute')::text,
       has_function_privilege('service_role', p.oid, 'execute')
         and not has_function_privilege('anon', p.oid, 'execute')
         and not has_function_privilege('authenticated', p.oid, 'execute')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fin_sync_escribir';

commit;
