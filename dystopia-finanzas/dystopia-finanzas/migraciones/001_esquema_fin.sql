-- 001_esquema_fin.sql — Dystopia Finanzas: tablas, indices, RLS y politicas.
-- Una transaccion. DDL idempotente (se puede correr dos veces).
-- Requiere: crm_clients, crm_members, es_fundador(), rol_actual(),
-- tiene_acceso(text) (verificados en DATOS-CONFIRMADOS.md).
-- La Edge Function escribe con service_role, que saltea RLS. Ningun rol de
-- usuario escribe datos sincronizados.

begin;

-- ---------------------------------------------------------------------------
-- 0. crm_members.rol: admitir 'closer' y 'setter'.
--    Si hay un CHECK sobre rol, se extiende con los valores nuevos y se
--    conservan los que ya tenia. Si no hay, no se hace nada. Si el CHECK
--    tiene una forma que no se puede extender con seguridad, se aborta todo.
--    Solo se miran los CHECK del tipo rol = ANY (...) / rol IN (...): otro
--    CHECK sobre rol (ej. no vacio) no limita valores y no se toca.
-- ---------------------------------------------------------------------------
do $$
declare
  r      record;
  v_vals text[];
begin
  for r in
    select conname, pg_get_constraintdef(oid) as def
    from pg_constraint
    where conrelid = 'public.crm_members'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ~* '\mrol\M\s*=\s*ANY'
  loop
    if r.def ~ '''closer''' and r.def ~ '''setter''' then
      continue;
    end if;
    if r.def !~* '^CHECK \(+rol\s*=\s*ANY\s*\(+ARRAY\[[^]]*\]\)*\)*$' then
      raise exception 'crm_members tiene un CHECK sobre rol con forma no esperada (%: %). Revisar a mano antes de correr 001.', r.conname, r.def;
    end if;
    select array_agg(distinct m[1] order by m[1]) into v_vals
    from regexp_matches(r.def, '''([^'']+)''', 'g') as m;
    v_vals := array(select distinct x from unnest(v_vals || array['closer', 'setter']) as x order by 1);
    execute format('alter table public.crm_members drop constraint %I', r.conname);
    execute format('alter table public.crm_members add constraint %I check (rol = any (%L::text[]))', r.conname, v_vals);
    raise notice 'CHECK % extendido: %', r.conname, v_vals;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Configuracion
-- ---------------------------------------------------------------------------
create table if not exists public.fin_fuentes (
  id                   bigint generated always as identity primary key,
  cliente_id           text    not null references public.crm_clients(id),
  spreadsheet_id       text    not null,
  gid                  bigint  not null,
  nombre_hoja_esperado text    not null,
  tipo                 text    not null check (tipo in ('pagos', 'opps', 'cuotas', 'data', 'trazabilidad', 'pagos_historico')),
  forma                text    check (forma in ('cuotas_ancho', 'cuotas_plano', 'desde_pagos')),
  fila_encabezado      int     not null default 1 check (fila_encabezado >= 1),
  anio                 int     check (anio between 2024 and 2027),
  tope_monto           numeric default 10000 check (tope_monto is null or tope_monto > 0),
  activo               boolean not null default true,
  creado               timestamptz not null default now(),
  constraint fin_fuentes_hoja_uq unique (spreadsheet_id, gid, tipo),
  constraint fin_fuentes_forma_ck check ((tipo = 'cuotas') = (forma is not null)),
  constraint fin_fuentes_anio_ck check (tipo <> 'opps' or anio is not null)
);
comment on column public.fin_fuentes.gid is 'Se identifica la hoja por gid: renombrarla no lo cambia.';
comment on column public.fin_fuentes.tope_monto is 'abs(monto) mayor a esto se rechaza como probable moneda local sin convertir. NULL = sin control.';
comment on column public.fin_fuentes.fila_encabezado is '1-based. En cuotas_ancho es la segunda fila del encabezado doble.';

create table if not exists public.fin_alias_columnas (
  id             bigint generated always as identity primary key,
  fuente_id      bigint  not null references public.fin_fuentes(id) on delete cascade,
  campo_canonico text    not null check (campo_canonico in (
                   'fecha', 'programa', 'alumno', 'telefono', 'concepto', 'monto', 'monto_pesos',
                   'closer', 'setter', 'comprobante', 'quien_recibe', 'metodo_pago',
                   'monto_restante', 'estado')),
  alias          text    not null,
  obligatorio    boolean not null default false,
  constraint fin_alias_uq unique (fuente_id, campo_canonico, alias)
);

-- Vinculo usuario -> nombres tal como aparecen en las planillas (sucios).
create table if not exists public.fin_personas (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  cliente_id text references public.crm_clients(id),
  alias      text not null check (btrim(alias) <> '')
);
comment on column public.fin_personas.cliente_id is 'NULL = el alias vale para todos los clientes. Conviene acotarlo: "Lucas" es closer en liam y tambien un cliente.';
create unique index if not exists fin_personas_uq
  on public.fin_personas (user_id, coalesce(cliente_id, ''), lower(btrim(alias)));
create index if not exists fin_personas_alias_idx on public.fin_personas (lower(btrim(alias)));

create table if not exists public.fin_comision_agencia (
  id         bigint generated always as identity primary key,
  cliente_id text    not null references public.crm_clients(id),
  desde      date    not null,
  hasta      date,
  porcentaje numeric not null check (porcentaje >= 0 and porcentaje <= 100),
  nota       text,
  constraint fin_comision_periodo_ck check (hasta is null or hasta >= desde)
);

-- ---------------------------------------------------------------------------
-- 2. Operacion
-- ---------------------------------------------------------------------------
create table if not exists public.fin_sync_corridas (
  id                bigint generated always as identity primary key,
  fuente_id         bigint not null references public.fin_fuentes(id) on delete cascade,
  inicio            timestamptz not null default now(),
  fin               timestamptz,
  estado            text not null default 'en_curso' check (estado in ('en_curso', 'ok', 'error', 'parcial')),
  filas_leidas      int,
  filas_cargadas    int,
  filas_rechazadas  int,
  filas_descartadas int,
  mensaje           text,
  hash_encabezado   text
);
create index if not exists fin_sync_corridas_fuente_idx on public.fin_sync_corridas (fuente_id, inicio desc);

create table if not exists public.fin_filas_rechazadas (
  id              bigint generated always as identity primary key,
  corrida_id      bigint not null references public.fin_sync_corridas(id) on delete cascade,
  fila_planilla   int    not null,
  motivo          text   not null,
  valor_crudo     text,
  comprobante     text,
  metodo_pago     text,
  contenido_crudo jsonb  not null
);
create index if not exists fin_filas_rechazadas_corrida_idx on public.fin_filas_rechazadas (corrida_id);

create table if not exists public.fin_tipo_cambio (
  fecha     date    not null,
  moneda    text    not null,
  valor_usd numeric not null check (valor_usd > 0),
  fuente    text    not null,
  primary key (fecha, moneda, fuente)
);
comment on table public.fin_tipo_cambio is 'Vacia a proposito hasta que la agencia defina que cotizacion usar. No inventar valores.';

-- ---------------------------------------------------------------------------
-- 3. Datos sincronizados (reemplazo completo por fuente en cada corrida)
-- ---------------------------------------------------------------------------
create table if not exists public.fin_pagos (
  id             bigint generated always as identity primary key,
  cliente_id     text    not null references public.crm_clients(id),
  fuente_id      bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id        bigint  references public.fin_sync_corridas(id) on delete set null,
  fila_planilla  int     not null,
  fecha          date    not null,
  programa       text,
  alumno         text    not null,
  telefono       text,
  concepto       text,
  monto_usd      numeric not null,
  monto_origen   numeric not null,
  moneda_origen  text    not null,
  tc_usado       numeric,
  tc_fuente      text,
  moneda_cobro   text,
  closer         text,
  setter         text,
  comprobante    text,
  quien_recibe   text,
  metodo_pago    text,
  monto_restante numeric,
  estado         text
);
create index if not exists fin_pagos_cliente_fecha_idx on public.fin_pagos (cliente_id, fecha);
create index if not exists fin_pagos_fuente_idx on public.fin_pagos (fuente_id);
create index if not exists fin_pagos_closer_idx on public.fin_pagos (cliente_id, lower(btrim(closer)));
create index if not exists fin_pagos_setter_idx on public.fin_pagos (cliente_id, lower(btrim(setter)));

create table if not exists public.fin_pnl (
  id               bigint generated always as identity primary key,
  cliente_id       text    not null references public.crm_clients(id),
  fuente_id        bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id          bigint  references public.fin_sync_corridas(id) on delete set null,
  anio             int     not null,
  mes              int     not null check (mes between 1 and 12),
  categoria        text    not null check (categoria in ('revenue', 'staff', 'softwares', 'others')),
  item             text,
  monto_usd        numeric not null,
  fila_planilla    int     not null,
  columna_planilla int     not null
);
create index if not exists fin_pnl_cliente_mes_idx on public.fin_pnl (cliente_id, anio, mes);
create index if not exists fin_pnl_fuente_idx on public.fin_pnl (fuente_id);

create table if not exists public.fin_pnl_saldos (
  cliente_id         text    not null references public.crm_clients(id),
  fuente_id          bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id            bigint  references public.fin_sync_corridas(id) on delete set null,
  anio               int     not null,
  mes                int     not null check (mes between 1 and 12),
  opening_balance    numeric,
  closing_balance    numeric,
  dividends_released numeric,
  primary key (cliente_id, anio, mes)
);

-- Reparto de la ganancia del mes entre agencia y cliente (= comision).
-- SOLO fundador. Tabla propia y no jsonb: la RLS no puede ocultar un campo.
create table if not exists public.fin_reparto (
  id            bigint generated always as identity primary key,
  cliente_id    text    not null references public.crm_clients(id),
  fuente_id     bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id       bigint  references public.fin_sync_corridas(id) on delete set null,
  anio          int     not null,
  mes           int     not null check (mes between 1 and 12),
  beneficiario  text    not null,
  monto         numeric not null,
  fila_planilla int     not null
);
create index if not exists fin_reparto_cliente_mes_idx on public.fin_reparto (cliente_id, anio, mes);

create table if not exists public.fin_cuotas (
  id            bigint generated always as identity primary key,
  cliente_id    text    not null references public.crm_clients(id),
  fuente_id     bigint  not null references public.fin_fuentes(id) on delete cascade,
  sync_id       bigint  references public.fin_sync_corridas(id) on delete set null,
  alumno        text    not null,
  telefono      text,
  programa      text,
  numero_cuota  int,
  tipo_cuota    text,
  monto         numeric,
  monto_cobrado numeric,
  fecha_pago    date,
  estado        text,
  closer        text,
  contexto      text,
  fila_planilla int     not null
);
create index if not exists fin_cuotas_cliente_idx on public.fin_cuotas (cliente_id, fecha_pago);
create index if not exists fin_cuotas_fuente_idx on public.fin_cuotas (fuente_id);

-- ---------------------------------------------------------------------------
-- 4. Permisos de tabla. anon: nada, en ninguna tabla fin_*.
--    authenticated: SELECT en todas (la RLS filtra); escritura solo en las
--    tablas de configuracion, y la RLS la limita a fundador.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'fin_fuentes', 'fin_alias_columnas', 'fin_personas', 'fin_comision_agencia',
    'fin_sync_corridas', 'fin_filas_rechazadas', 'fin_tipo_cambio',
    'fin_pagos', 'fin_pnl', 'fin_pnl_saldos', 'fin_reparto', 'fin_cuotas']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, public', t);
    execute format('revoke all on table public.%I from authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
  end loop;
  foreach t in array array['fin_fuentes', 'fin_alias_columnas', 'fin_personas', 'fin_comision_agencia', 'fin_tipo_cambio']
  loop
    execute format('grant insert, update, delete on table public.%I to authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Politicas
-- ---------------------------------------------------------------------------
-- Solo fundador, lectura y escritura: configuracion y operacion.
do $$
declare t text;
begin
  foreach t in array array['fin_fuentes', 'fin_alias_columnas', 'fin_comision_agencia', 'fin_tipo_cambio']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_fundador', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.es_fundador()) with check (public.es_fundador())', t || '_fundador', t);
  end loop;
  foreach t in array array['fin_sync_corridas', 'fin_filas_rechazadas', 'fin_reparto']
  loop
    execute format('drop policy if exists %I on public.%I', t || '_fundador', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.es_fundador())', t || '_fundador', t);
  end loop;
end $$;

-- fin_personas: fundador administra; cada usuario ve sus propios alias
-- (lo necesitan las politicas de closer/setter, que corren como el usuario).
drop policy if exists fin_personas_fundador on public.fin_personas;
create policy fin_personas_fundador on public.fin_personas
  for all to authenticated using (public.es_fundador()) with check (public.es_fundador());
drop policy if exists fin_personas_propias on public.fin_personas;
create policy fin_personas_propias on public.fin_personas
  for select to authenticated using (user_id = auth.uid());

-- P&L y saldos: fundador, o cliente sobre lo suyo. Closer y setter NUNCA
-- (el bloque Staff son los sueldos del equipo).
drop policy if exists fin_pnl_lectura on public.fin_pnl;
create policy fin_pnl_lectura on public.fin_pnl
  for select to authenticated
  using (public.es_fundador() or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id)));

drop policy if exists fin_pnl_saldos_lectura on public.fin_pnl_saldos;
create policy fin_pnl_saldos_lectura on public.fin_pnl_saldos
  for select to authenticated
  using (public.es_fundador() or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id)));

-- Pagos: fundador; cliente lo suyo; closer donde figura como closer; setter
-- donde figura como setter.
drop policy if exists fin_pagos_lectura on public.fin_pagos;
create policy fin_pagos_lectura on public.fin_pagos
  for select to authenticated
  using (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id))
    or (public.rol_actual() = 'closer' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and (p.cliente_id is null or p.cliente_id = fin_pagos.cliente_id)
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.closer))))
    or (public.rol_actual() = 'setter' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and (p.cliente_id is null or p.cliente_id = fin_pagos.cliente_id)
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.setter))))
  );

-- Cuotas: fundador; cliente lo suyo; closer las suyas; setter NO.
drop policy if exists fin_cuotas_lectura on public.fin_cuotas;
create policy fin_cuotas_lectura on public.fin_cuotas
  for select to authenticated
  using (
    public.es_fundador()
    or (public.rol_actual() = 'cliente' and public.tiene_acceso(cliente_id))
    or (public.rol_actual() = 'closer' and exists (
          select 1 from public.fin_personas p
          where p.user_id = auth.uid()
            and (p.cliente_id is null or p.cliente_id = fin_cuotas.cliente_id)
            and lower(btrim(p.alias)) = lower(btrim(fin_cuotas.closer))))
  );

-- ---------------------------------------------------------------------------
-- 6. Prueba de humo (se autorrevierte: termina con SMOKE_OK y el bloque
--    de excepcion deshace todo lo que inserto).
-- ---------------------------------------------------------------------------
do $$
declare
  v_fuente bigint;
  v_n      int;
  v_anon   boolean := false;
begin
  begin
    insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo)
    values ('liam', 'SMOKE_TEST', 1, 'Smoke', 'pagos')
    returning id into v_fuente;

    insert into public.fin_pagos (cliente_id, fuente_id, fila_planilla, fecha, alumno, monto_usd, monto_origen, moneda_origen)
    values ('liam', v_fuente, 2, date '2026-01-15', 'Alumno Smoke', 100, 100, 'USD');

    insert into public.fin_reparto (cliente_id, fuente_id, anio, mes, beneficiario, monto, fila_planilla)
    values ('liam', v_fuente, 2026, 1, 'Dystopia', 10, 67);

    select count(*) into v_n from public.fin_pagos where fuente_id = v_fuente;
    if v_n <> 1 then raise exception 'smoke: fin_pagos no inserto'; end if;

    begin
      insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo)
      values ('liam', 'SMOKE_TEST', 2, 'Smoke', 'tipo_invalido');
      raise exception 'smoke: el CHECK de tipo no rechazo un valor invalido';
    exception when check_violation then null;
    end;

    begin
      insert into public.fin_fuentes (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo)
      values ('liam', 'SMOKE_TEST', 3, 'Smoke', 'cuotas');
      raise exception 'smoke: se acepto una fuente de cuotas sin forma';
    exception when check_violation then null;
    end;

    -- anon no puede leer ninguna tabla fin_* (se prueba si el rol lo permite).
    begin
      perform set_config('role', 'anon', true);
      v_anon := true;
    exception when others then
      raise notice 'smoke: no se pudo cambiar a anon (%), se omite esa prueba', sqlerrm;
    end;
    if v_anon then
      begin
        perform 1 from public.fin_pagos limit 1;
        raise exception 'smoke: anon pudo leer fin_pagos';
      exception when insufficient_privilege then null;
      end;
      begin
        perform 1 from public.fin_reparto limit 1;
        raise exception 'smoke: anon pudo leer fin_reparto';
      exception when insufficient_privilege then null;
      end;
    end if;

    raise exception 'SMOKE_OK';
  exception when others then
    if sqlerrm = 'SMOKE_OK' then
      raise notice 'prueba de humo 001: OK (revertida)';
    else
      raise;
    end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Query de control: 12 tablas, todas con RLS y ninguna legible por anon.
-- ---------------------------------------------------------------------------
select c.relname                                          as tabla,
       c.relrowsecurity                                   as rls,
       has_table_privilege('anon', c.oid, 'select')       as anon_lee,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as politicas
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'fin\_%'
order by c.relname;

commit;
