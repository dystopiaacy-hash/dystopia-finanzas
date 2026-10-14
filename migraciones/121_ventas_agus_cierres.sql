-- =====================================================================
-- 121_ventas_agus_cierres.sql
-- Ventas. Cierres de Agus desde su planilla de ventas real
-- ("Ventas De Cero a CEO", pestania "Clientes"): una fila por trato
-- cerrado, con fecha de cierre, producto, fuente, estado, cash dia 1 y
-- valor del trato. Mientras Agus no tenga CRM de llamadas (la 120 queda
-- para cuando exista la pestania DATA) Ventas muestra con esto cerradas,
-- cash dia 1 y valor de tratos por mes. NO hay agendadas ni show up.
--
-- Que crea:
--   1. fin_fuentes.tipo admite 'cierres'.
--   2. Tabla fin_cierres (reemplazo completo por fuente, RLS de lectura
--      como fin_llamadas para fundador, cliente, ventas y finanzas).
--   3. fin_cierres_escribir: la escritura de la sync para este tipo. NO se
--      toca fin_sync_escribir (la usan pagos, opps, cuotas y data).
--   4. Alta de la fuente de Agus (INACTIVA hasta completar <GID_CLIENTES>).
--
-- ORDEN: correr BLOQUE 1 y BLOQUE 1b ya. Despues redesplegar la funcion
-- `sincronizar` (trae el parser nuevo). Recien con el gid, BLOQUE 2 y 3.
-- Sin el redeploy, una fuente 'cierres' activa daria error en la sync
-- ("el tipo 'cierres' no se sincroniza todavia"): por eso nace inactiva.
--
-- Sin tocar datos de Liam ni de Teo ni la 120. Idempotente.
-- Correr cada bloque entero y fuera de :00/:15/:30/:45 (la sync lee
-- fin_fuentes). Requiere 001, 005, 006, 059 (cortada_en) y 077
-- (fin_data_puede_ver).
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Tipo, tabla, permisos y funcion de escritura
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';
lock table public.fin_fuentes in share row exclusive mode;

do $$
begin
  if not exists (select 1 from public.crm_clients where id = 'agus') then
    raise exception '121: no existe el cliente agus en crm_clients';
  end if;
  if to_regprocedure('public.fin_data_puede_ver(text)') is null then
    raise exception '121: falta fin_data_puede_ver (migracion 077)';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'fin_fuentes' and column_name = 'cortada_en') then
    raise exception '121: falta fin_fuentes.cortada_en (migracion 059)';
  end if;
end $$;

-- El check de tipo de 001 no tiene nombre propio: se busca por definicion.
do $$
declare v_nombre text;
begin
  for v_nombre in
    select conname from pg_constraint
    where conrelid = 'public.fin_fuentes'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%pagos_historico%'
  loop
    execute format('alter table public.fin_fuentes drop constraint %I', v_nombre);
  end loop;
end $$;

alter table public.fin_fuentes drop constraint if exists fin_fuentes_tipo_ck;
alter table public.fin_fuentes add constraint fin_fuentes_tipo_ck
  check (tipo in ('pagos', 'opps', 'cuotas', 'data', 'trazabilidad', 'pagos_historico', 'cierres'));

create table if not exists public.fin_cierres (
  id              bigint generated always as identity primary key,
  cliente_id      text    not null references public.crm_clients(id),
  fuente_id       bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id         bigint  references public.fin_sync_corridas(id) on delete set null,
  fila_planilla   int     not null,
  fecha_cierre    date    not null,
  nombre          text    not null,
  producto        text,
  fuente          text,
  estructura_pago text,
  estado          text,
  cash_dia1       numeric,
  trato_cerrado   numeric
);
create index if not exists fin_cierres_cliente_fecha_idx on public.fin_cierres (cliente_id, fecha_cierre);
create index if not exists fin_cierres_fuente_idx on public.fin_cierres (fuente_id);

comment on table public.fin_cierres is
  '121: tratos cerrados de la pestania Clientes de la planilla de ventas (hoy solo agus). Reemplazo completo por fuente en cada corrida. Sin llamadas: no hay agendadas ni show up.';
comment on column public.fin_cierres.nombre is 'Columna "Cliente" de la planilla: la persona que compro (no es crm_clients).';
comment on column public.fin_cierres.cash_dia1 is 'Cash del dia 1 en USD, declarado en la planilla.';
comment on column public.fin_cierres.trato_cerrado is 'Valor del trato cerrado en USD, declarado en la planilla.';

alter table public.fin_cierres enable row level security;
revoke all on table public.fin_cierres from anon, public;
revoke all on table public.fin_cierres from authenticated;
grant select on table public.fin_cierres to authenticated;
grant all on table public.fin_cierres to service_role;

-- Lectura: fundador, cliente con acceso y ventas/finanzas asignados (misma
-- regla que Data, helper de la 077). Closers y setters no ven cierres.
drop policy if exists fin_cierres_lectura on public.fin_cierres;
create policy fin_cierres_lectura on public.fin_cierres
  for select to authenticated
  using (public.fin_data_puede_ver(cliente_id));

create or replace function public.fin_cierres_escribir(
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
  n_cierres  int := 0;
begin
  if p_estado is null or p_estado not in ('ok', 'revisar', 'parcial') then
    raise exception 'fin_cierres_escribir: el estado % no escribe datos', p_estado;
  end if;

  select * into v_corrida from public.fin_sync_corridas where id = p_corrida for update;
  if not found then raise exception 'fin_cierres_escribir: no existe la corrida %', p_corrida; end if;
  if v_corrida.estado <> 'en_curso' then
    raise exception 'fin_cierres_escribir: la corrida % ya esta cerrada (%)', p_corrida, v_corrida.estado;
  end if;
  select * into v_fuente from public.fin_fuentes where id = v_corrida.fuente_id;
  if v_fuente.tipo <> 'cierres' then
    raise exception 'fin_cierres_escribir: la fuente % es de tipo %, no cierres', v_fuente.id, v_fuente.tipo;
  end if;
  if v_fuente.cortada_en is not null then
    raise exception 'fin_cierres_escribir: la fuente % esta cortada desde %', v_fuente.id, v_fuente.cortada_en;
  end if;

  perform pg_advisory_xact_lock(hashtext('fin_sync_escribir'), v_fuente.id::int);

  -- Reemplazo completo de la fuente. cliente_id, fuente_id y sync_id salen
  -- de la fuente y la corrida, nunca del payload.
  delete from public.fin_cierres where fuente_id = v_fuente.id;

  insert into public.fin_cierres (cliente_id, fuente_id, sync_id, fila_planilla, fecha_cierre, nombre,
    producto, fuente, estructura_pago, estado, cash_dia1, trato_cerrado)
  select v_fuente.cliente_id, v_fuente.id, p_corrida, x.fila_planilla, x.fecha_cierre, x.nombre,
         x.producto, x.fuente, x.estructura_pago, x.estado, x.cash_dia1, x.trato_cerrado
  from jsonb_to_recordset(coalesce(p_datos -> 'cierres', '[]'::jsonb)) as x(
    fila_planilla int, fecha_cierre date, nombre text, producto text, fuente text,
    estructura_pago text, estado text, cash_dia1 numeric, trato_cerrado numeric);
  get diagnostics n_cierres = row_count;

  update public.fin_sync_corridas set
    fin               = now(),
    estado            = p_estado,
    filas_leidas      = p_leidas,
    filas_cargadas    = n_cierres,
    filas_rechazadas  = 0,   -- los rechazos los escribe fin_rechazos_escribir (033)
    filas_descartadas = p_descartadas,
    mensaje           = p_mensaje,
    hash_encabezado   = p_hash,
    controles         = coalesce(p_controles, '[]'::jsonb)
  where id = p_corrida;

  return jsonb_build_object('cierres', n_cierres);
end $$;

revoke all on function public.fin_cierres_escribir(bigint, text, text, text, jsonb, int, int, jsonb) from public, anon, authenticated;
grant execute on function public.fin_cierres_escribir(bigint, text, text, text, jsonb, int, int, jsonb) to service_role;

commit;

-- ---------------------------------------------------------------------
-- BLOQUE 1b. Prueba de humo (se revierte sola; correr entero)
-- ---------------------------------------------------------------------
do $$
declare
  v_fuente bigint;
  v_otra   bigint;
  v_c1 bigint; v_c2 bigint; v_c3 bigint; v_c4 bigint;
  v_n int;
  v_r jsonb;
  v_fila jsonb := '{"fila_planilla":2,"fecha_cierre":"2026-10-06","nombre":"Smoke","producto":"P","fuente":"IG","estructura_pago":"Contado","estado":"Activo","cash_dia1":500,"trato_cerrado":2000}';
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('agus', 'SMOKE_121', 1, 'Clientes', 'cierres', null) returning id into v_fuente;

    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c1;
    v_r := public.fin_cierres_escribir(v_c1, 'ok', null, 'h1', '[]', 3, 1,
      jsonb_build_object('cierres', jsonb_build_array(v_fila, v_fila || '{"fila_planilla":3,"cash_dia1":null}')));
    if (v_r ->> 'cierres')::int <> 2 then raise exception 'smoke 121: informo % cierres, se esperaban 2', v_r; end if;
    select count(*) into v_n from public.fin_cierres where fuente_id = v_fuente and cliente_id = 'agus' and sync_id = v_c1;
    if v_n <> 2 then raise exception 'smoke 121: primera corrida dejo % filas', v_n; end if;
    select filas_cargadas into v_n from public.fin_sync_corridas where id = v_c1;
    if v_n <> 2 then raise exception 'smoke 121: filas_cargadas = %', v_n; end if;

    -- La segunda corrida reemplaza (no suma).
    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c2;
    perform public.fin_cierres_escribir(v_c2, 'ok', null, 'h1', '[]', 1, 0,
      jsonb_build_object('cierres', jsonb_build_array(v_fila)));
    select count(*) into v_n from public.fin_cierres where fuente_id = v_fuente;
    if v_n <> 1 then raise exception 'smoke 121: la segunda corrida no reemplazo (quedan %)', v_n; end if;

    -- Sin fecha: viola not null y no deja nada a medias.
    insert into public.fin_sync_corridas (fuente_id) values (v_fuente) returning id into v_c3;
    begin
      perform public.fin_cierres_escribir(v_c3, 'ok', null, 'h1', '[]', 2, 0,
        jsonb_build_object('cierres', jsonb_build_array(v_fila, v_fila - 'fecha_cierre')));
      raise exception 'smoke 121: una fila sin fecha no hizo fallar la escritura';
    exception when not_null_violation then null;
    end;
    select count(*) into v_n from public.fin_cierres where fuente_id = v_fuente and sync_id = v_c2;
    if v_n <> 1 then raise exception 'smoke 121: un fallo a mitad borro los datos anteriores'; end if;

    -- Una fuente de otro tipo no puede usar esta funcion.
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, tope_monto)
    values ('agus', 'SMOKE_121', 2, 'Pagos', 'pagos', 10000) returning id into v_otra;
    insert into public.fin_sync_corridas (fuente_id) values (v_otra) returning id into v_c4;
    begin
      perform public.fin_cierres_escribir(v_c4, 'ok', null, 'h1', '[]', 0, 0, '{}'::jsonb);
      raise exception 'smoke 121: acepto una fuente que no es de cierres';
    exception when raise_exception then
      if sqlerrm like 'smoke 121%' then raise; end if;
    end;

    -- El tipo nuevo pasa el check y uno inventado no.
    begin
      insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo)
      values ('agus', 'SMOKE_121', 3, 'X', 'inventado');
      raise exception 'smoke 121: el check de tipo acepto un valor inventado';
    exception when check_violation then null;
    end;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 121: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Alta de la fuente de Agus, INACTIVA.
-- Completar <GID_CLIENTES>: el numero tras #gid= en la URL de la pestania
-- "Clientes". fila_encabezado = 1: si el encabezado de esa pestania no esta
-- en la fila 1, cambiar el 1 por el numero de fila (1-based).
-- ---------------------------------------------------------------------
do $$
begin
  if '<GID_CLIENTES>' like '<%' then
    raise exception '121: completar <GID_CLIENTES> antes de correr el bloque 2';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'agus') then
    raise exception '121: no existe el cliente agus en crm_clients';
  end if;
end $$;

insert into public.fin_fuentes
  (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, fila_encabezado, anio, tope_monto, activo)
select 'agus', '1BdMWa7mYmPLquDOGvpoPU-PuwoUinHF47OCdP-t3U3s', <GID_CLIENTES>, 'Clientes', 'cierres', null, 1, null, null, false
where not exists (
  select 1 from public.fin_fuentes
  where spreadsheet_id = '1BdMWa7mYmPLquDOGvpoPU-PuwoUinHF47OCdP-t3U3s' and tipo = 'cierres');

-- ---------------------------------------------------------------------
-- BLOQUE 3. Activar (solo con `sincronizar` ya redesplegada y la hoja
-- compartida con la cuenta de servicio de la sync)
-- ---------------------------------------------------------------------
-- update public.fin_fuentes set activo = true
--  where cliente_id = 'agus' and tipo = 'cierres';

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno, comentados)
-- ---------------------------------------------------------------------
-- C1 tipo admitido y tabla con RLS (esperado: 1 fila, ok = true):
-- select (pg_get_constraintdef(oid) like '%cierres%') as tipo_ok,
--        (select relrowsecurity from pg_class where oid = 'public.fin_cierres'::regclass) as rls
--   from pg_constraint where conrelid = 'public.fin_fuentes'::regclass and conname = 'fin_fuentes_tipo_ck';
-- C2 funcion con permisos solo para service_role (esperado: true, false, false):
-- select has_function_privilege('service_role', 'public.fin_cierres_escribir(bigint,text,text,text,jsonb,int,int,jsonb)', 'execute'),
--        has_function_privilege('authenticated', 'public.fin_cierres_escribir(bigint,text,text,text,jsonb,int,int,jsonb)', 'execute'),
--        has_function_privilege('anon', 'public.fin_cierres_escribir(bigint,text,text,text,jsonb,int,int,jsonb)', 'execute');
-- C3 fuente creada (1 fila; activo = false hasta el bloque 3):
-- select id, spreadsheet_id, gid, nombre_hoja_esperado, fila_encabezado, activo from public.fin_fuentes where cliente_id = 'agus' and tipo = 'cierres';
-- C4 tras activar y esperar una corrida (15 min), o con sincronizar de la fuente a mano:
-- select estado, filas_leidas, filas_cargadas, filas_rechazadas, mensaje from public.fin_sync_corridas
--  where fuente_id = (select id from public.fin_fuentes where cliente_id = 'agus' and tipo = 'cierres') order by inicio desc limit 3;
-- C5 cierres por mes (cantidad, cash dia 1, valor de tratos):
-- select date_trunc('month', fecha_cierre)::date as mes, count(*) as cerradas, sum(cash_dia1) as cash_dia1, sum(trato_cerrado) as tratos
--   from public.fin_cierres where cliente_id = 'agus' group by 1 order by 1;
-- C6 estados y fuentes que trae la planilla (para decidir si algun estado no cuenta como cierre):
-- select estado, count(*) from public.fin_cierres where cliente_id = 'agus' group by 1 order by 2 desc;
-- C7 filas con monto vacio (celdas rechazadas o sin cargar):
-- select count(*) filter (where cash_dia1 is null) sin_cash_dia1, count(*) filter (where trato_cerrado is null) sin_trato from public.fin_cierres where cliente_id = 'agus';

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (comentada). Antes de la primera corrida:
--   delete from public.fin_fuentes where cliente_id = 'agus' and tipo = 'cierres';
--   drop function if exists public.fin_cierres_escribir(bigint, text, text, text, jsonb, int, int, jsonb);
--   drop table if exists public.fin_cierres;
--   -- el check de tipo puede quedar con 'cierres' (inofensivo); para volver al de 001:
--   alter table public.fin_fuentes drop constraint fin_fuentes_tipo_ck;
--   alter table public.fin_fuentes add constraint fin_fuentes_tipo_ck
--     check (tipo in ('pagos', 'opps', 'cuotas', 'data', 'trazabilidad', 'pagos_historico'));
-- Con corridas ya hechas: solo apagar (no borrar):
--   update public.fin_fuentes set activo = false where cliente_id = 'agus' and tipo = 'cierres';
-- ---------------------------------------------------------------------
