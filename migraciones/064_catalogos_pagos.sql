-- =====================================================================
-- 064_catalogos_pagos.sql
-- FINANZAS, fase 3 (estructura). Ver ESQUEMA-FINANZAS.md, secciones 2 y 3.
--
-- 1. fin_catalogos: nuevas dimensiones metodo_pago, quien_recibe,
--    concepto e item_gasto. programa ya existia y se comparte con Ventas.
-- 2. fin_catalogo_alias (nueva): traduce el texto del Sheet (normalizado)
--    al valor del catalogo. Un mismo texto de "metodo de pago" puede dar
--    metodo Y quien recibe ("TRANSFER EN PESOS-Calypso Soluciones").
-- 3. fin_pagos: programa_id, concepto_id, metodo_pago_id, quien_recibe_id.
--    El texto crudo del Sheet NO se toca: los *_id van al lado.
-- 4. Trigger: completa los *_id en cada insert de la sync usando los
--    alias. Si se agrega un alias, la proxima sync (15 min) lo aplica.
-- 5. fin_v_alias_pendientes: textos sin mapear, por cliente y columna,
--    con cantidad de pagos y USD. Es lo que la agencia tiene que resolver.
-- 6. Semilla PROVISIONAL (aprobado = false) sacada del historico al
--    2026-10-02. Lo dudoso queda sin mapear a proposito.
--
-- Mauro queda afuera (decision V3): sin catalogo ni alias.
-- No toca fin_sync_escribir, la Edge Function ni ningun dato existente
-- salvo completar los *_id nuevos. Idempotente. Probada dos veces contra
-- Postgres local con el esquema real y los pagos del 2026-10-02.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. fin_catalogos: dimensiones nuevas
-- ---------------------------------------------------------------------
alter table public.fin_catalogos drop constraint if exists fin_catalogos_dimension_ck;
alter table public.fin_catalogos add constraint fin_catalogos_dimension_ck
  check (dimension in ('estado', 'show_up', 'calificacion', 'programa', 'fuente',
                       'metodo_pago', 'quien_recibe', 'concepto', 'item_gasto'));

-- Para que los alias solo puedan apuntar a un valor del MISMO cliente y
-- la MISMA dimension (FK compuesta).
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fin_catalogos_id_cli_dim_uq') then
    alter table public.fin_catalogos
      add constraint fin_catalogos_id_cli_dim_uq unique (id, cliente_id, dimension);
  end if;
end $$;

comment on table public.fin_catalogos is
  'Opciones de los desplegables por cliente. Ventas: estado, show_up, calificacion, programa, fuente. Finanzas (064): programa (compartido), metodo_pago, quien_recibe, concepto, item_gasto.';

-- ---------------------------------------------------------------------
-- 2. Normalizacion y tabla de alias
-- ---------------------------------------------------------------------
create or replace function public.fin_normalizar_alias(p text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select nullif(translate(lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')),
                          'áéíóúüñ', 'aeiouun'), '');
$$;

create table if not exists public.fin_catalogo_alias (
  id           bigint generated always as identity primary key,
  cliente_id   text    not null references public.crm_clients(id),
  columna      text    not null,
  crudo_norm   text    not null,
  dimension    text    not null,
  catalogo_id  bigint  not null,
  aprobado     boolean not null default false,
  creado_en    timestamptz not null default now(),
  constraint fin_cat_alias_columna_ck
    check (columna in ('programa', 'concepto', 'metodo_pago', 'quien_recibe')),
  constraint fin_cat_alias_dimension_ck
    check (dimension in ('programa', 'concepto', 'metodo_pago', 'quien_recibe')),
  constraint fin_cat_alias_norm_ck
    check (crudo_norm = public.fin_normalizar_alias(crudo_norm)),
  constraint fin_cat_alias_catalogo_fk
    foreign key (catalogo_id, cliente_id, dimension)
    references public.fin_catalogos (id, cliente_id, dimension) on delete cascade,
  constraint fin_cat_alias_uq unique (cliente_id, columna, crudo_norm, dimension)
);

comment on table public.fin_catalogo_alias is
  '064: texto del Sheet (normalizado) -> valor del catalogo. aprobado = false es semilla provisional sin confirmar por la agencia.';

alter table public.fin_catalogo_alias enable row level security;
drop policy if exists fin_cat_alias_lectura on public.fin_catalogo_alias;
create policy fin_cat_alias_lectura on public.fin_catalogo_alias for select using (public.es_fundador());
drop policy if exists fin_cat_alias_escritura on public.fin_catalogo_alias;
create policy fin_cat_alias_escritura on public.fin_catalogo_alias for all
  using (public.es_fundador()) with check (public.es_fundador());
revoke all on public.fin_catalogo_alias from anon;
grant select, insert, update, delete on public.fin_catalogo_alias to authenticated;
grant all on public.fin_catalogo_alias to service_role;

-- Resolucion: texto crudo de una columna -> id del catalogo de una dimension.
create or replace function public.fin_resolver_alias(
  p_cliente text, p_columna text, p_dimension text, p_crudo text)
returns bigint
language sql
stable
set search_path = ''
as $$
  select a.catalogo_id
  from public.fin_catalogo_alias a
  where a.cliente_id = p_cliente
    and a.columna    = p_columna
    and a.dimension  = p_dimension
    and a.crudo_norm = public.fin_normalizar_alias(p_crudo);
$$;

-- ---------------------------------------------------------------------
-- 3. fin_pagos: columnas *_id al lado del texto crudo
-- ---------------------------------------------------------------------
alter table public.fin_pagos
  add column if not exists programa_id     bigint references public.fin_catalogos(id) on delete set null,
  add column if not exists concepto_id     bigint references public.fin_catalogos(id) on delete set null,
  add column if not exists metodo_pago_id  bigint references public.fin_catalogos(id) on delete set null,
  add column if not exists quien_recibe_id bigint references public.fin_catalogos(id) on delete set null;

comment on column public.fin_pagos.metodo_pago_id is
  '064: valor del catalogo. Lo completa el trigger desde fin_catalogo_alias; el texto crudo queda en metodo_pago.';
comment on column public.fin_pagos.quien_recibe_id is
  '064: sale de la columna quien_recibe o, si esta vacia, de lo que implica el metodo de pago.';

-- ---------------------------------------------------------------------
-- 4. Trigger de resolucion (solo completa lo que viene vacio)
-- ---------------------------------------------------------------------
create or replace function public.fin_pagos_resolver()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.cliente_id = 'mauro' then
    return new;
  end if;
  new.programa_id    := coalesce(new.programa_id,
                          public.fin_resolver_alias(new.cliente_id, 'programa', 'programa', new.programa));
  new.concepto_id    := coalesce(new.concepto_id,
                          public.fin_resolver_alias(new.cliente_id, 'concepto', 'concepto', new.concepto));
  new.metodo_pago_id := coalesce(new.metodo_pago_id,
                          public.fin_resolver_alias(new.cliente_id, 'metodo_pago', 'metodo_pago', new.metodo_pago));
  new.quien_recibe_id := coalesce(new.quien_recibe_id,
                          public.fin_resolver_alias(new.cliente_id, 'quien_recibe', 'quien_recibe', new.quien_recibe),
                          public.fin_resolver_alias(new.cliente_id, 'metodo_pago', 'quien_recibe', new.metodo_pago));
  return new;
end $$;

drop trigger if exists fin_pagos_resolver_trg on public.fin_pagos;
create trigger fin_pagos_resolver_trg
  before insert on public.fin_pagos
  for each row execute function public.fin_pagos_resolver();

-- ---------------------------------------------------------------------
-- 6. Semilla provisional (antes del relleno, para que el relleno la use)
-- ---------------------------------------------------------------------
insert into public.fin_catalogos (cliente_id, dimension, valor, orden)
select s.cliente_id, s.dimension, s.valor, s.orden
from (values
  ('agus', 'concepto', 'FEE', 1),
  ('agus', 'concepto', 'PIF', 2),
  ('agus', 'concepto', 'COMPLETA PIF', 3),
  ('agus', 'concepto', '1RA CUOTA', 4),
  ('agus', 'concepto', '2DA CUOTA', 5),
  ('agus', 'concepto', 'REFUERZA FEE', 6),
  ('agus', 'concepto', 'COMPLETA FEE', 7),
  ('agus', 'concepto', 'FEE DE PIF', 8),
  ('agus', 'concepto', 'CUOTA RENOVACION', 9),
  ('agus', 'concepto', 'RESELL', 10),
  ('agus', 'concepto', 'UPSELL', 11),
  ('agus', 'metodo_pago', 'Dolar App', 1),
  ('agus', 'metodo_pago', 'Efectivo', 2),
  ('agus', 'metodo_pago', 'Mercado Pago', 3),
  ('agus', 'metodo_pago', 'Stripe Dystopia', 4),
  ('agus', 'metodo_pago', 'Stripe del cliente', 5),
  ('agus', 'metodo_pago', 'Transferencia ACH', 6),
  ('agus', 'metodo_pago', 'Transferencia ARS', 7),
  ('agus', 'metodo_pago', 'Transferencia USD Argentina', 8),
  ('agus', 'metodo_pago', 'USDT', 9),
  ('agus', 'programa', '1 A 1', 1),
  ('agus', 'programa', '1 MES', 2),
  ('agus', 'programa', '3 MESES', 3),
  ('agus', 'programa', 'GRUPAL', 4),
  ('agus', 'programa', 'SKOOL', 5),
  ('agus', 'quien_recibe', 'Agus SaaS', 1),
  ('agus', 'quien_recibe', 'Agus personal', 2),
  ('agus', 'quien_recibe', 'Blas', 3),
  ('agus', 'quien_recibe', 'Dystopia', 4),
  ('agus', 'quien_recibe', 'Fran Lagrega', 5),
  ('agus', 'quien_recibe', 'Lucas Financiera', 6),
  ('agus', 'quien_recibe', 'Male', 7),
  ('agus', 'quien_recibe', 'Sofi Financiera', 8),
  ('liam', 'concepto', 'FEE', 1),
  ('liam', 'concepto', 'PIF', 2),
  ('liam', 'concepto', 'COMPLETA PIF', 3),
  ('liam', 'concepto', '1RA CUOTA', 4),
  ('liam', 'concepto', '2DA CUOTA', 5),
  ('liam', 'concepto', 'REFUERZA FEE', 6),
  ('liam', 'concepto', 'COMPLETA FEE', 7),
  ('liam', 'concepto', 'FEE DE PIF', 8),
  ('liam', 'concepto', 'CUOTA RENOVACION', 9),
  ('liam', 'concepto', 'RESELL', 10),
  ('liam', 'concepto', 'UPSELL', 11),
  ('liam', 'metodo_pago', 'Efectivo', 1),
  ('liam', 'metodo_pago', 'Otro', 2),
  ('liam', 'metodo_pago', 'PayPal', 3),
  ('liam', 'metodo_pago', 'Stripe Dystopia', 4),
  ('liam', 'metodo_pago', 'Stripe del cliente', 5),
  ('liam', 'metodo_pago', 'Transferencia ARS', 6),
  ('liam', 'metodo_pago', 'Transferencia USD Argentina', 7),
  ('liam', 'metodo_pago', 'Transferencia USD Uruguay', 8),
  ('liam', 'metodo_pago', 'USDT', 9),
  ('liam', 'programa', 'BPF 1 A 1 1 AÑO', 1),
  ('liam', 'programa', 'BPF 1 A 1 4 MESES', 2),
  ('liam', 'programa', 'BPF 1 A 1 6 MESES', 3),
  ('liam', 'programa', 'BPF 1 A 1 RESELL 9 MESES', 4),
  ('liam', 'programa', 'BPF DOWNSELL', 5),
  ('liam', 'programa', 'BPF GRUPAL 4 MESES', 6),
  ('liam', 'programa', 'DOWNSELL GRUPAL 4 MESES', 7),
  ('liam', 'programa', 'GESTION DE CAPITAL', 8),
  ('liam', 'quien_recibe', 'Dystopia', 1),
  ('liam', 'quien_recibe', 'Liam', 2),
  ('liam', 'quien_recibe', 'Lucas Financiera', 3),
  ('liam', 'quien_recibe', 'Nacho', 4),
  ('liam', 'quien_recibe', 'Sofi Financiera', 5),
  ('liam', 'quien_recibe', 'Valen', 6),
  ('lucas', 'concepto', 'FEE', 1),
  ('lucas', 'concepto', 'PIF', 2),
  ('lucas', 'concepto', 'COMPLETA PIF', 3),
  ('lucas', 'concepto', '1RA CUOTA', 4),
  ('lucas', 'concepto', '2DA CUOTA', 5),
  ('lucas', 'concepto', 'REFUERZA FEE', 6),
  ('lucas', 'concepto', 'COMPLETA FEE', 7),
  ('lucas', 'concepto', 'FEE DE PIF', 8),
  ('lucas', 'concepto', 'CUOTA RENOVACION', 9),
  ('lucas', 'concepto', 'RESELL', 10),
  ('lucas', 'concepto', 'UPSELL', 11),
  ('lucas', 'metodo_pago', 'Efectivo', 1),
  ('lucas', 'metodo_pago', 'Otro', 2),
  ('lucas', 'metodo_pago', 'Stripe Dystopia', 3),
  ('lucas', 'metodo_pago', 'Transferencia ARS', 4),
  ('lucas', 'metodo_pago', 'Transferencia USD Argentina', 5),
  ('lucas', 'metodo_pago', 'USDT', 6),
  ('lucas', 'programa', '1 A 1', 1),
  ('lucas', 'programa', 'GRUPAL', 2),
  ('lucas', 'quien_recibe', 'Blas', 1),
  ('lucas', 'quien_recibe', 'Calypso Soluciones', 2),
  ('lucas', 'quien_recibe', 'Dystopia', 3),
  ('lucas', 'quien_recibe', 'Lucas', 4),
  ('lucas', 'quien_recibe', 'Lucas Financiera', 5),
  ('lucas', 'quien_recibe', 'Nacho', 6),
  ('lucas', 'quien_recibe', 'Sofi Financiera', 7),
  ('teo', 'concepto', 'FEE', 1),
  ('teo', 'concepto', 'PIF', 2),
  ('teo', 'concepto', 'COMPLETA PIF', 3),
  ('teo', 'concepto', '1RA CUOTA', 4),
  ('teo', 'concepto', '2DA CUOTA', 5),
  ('teo', 'concepto', 'REFUERZA FEE', 6),
  ('teo', 'concepto', 'COMPLETA FEE', 7),
  ('teo', 'concepto', 'FEE DE PIF', 8),
  ('teo', 'concepto', 'CUOTA RENOVACION', 9),
  ('teo', 'concepto', 'RESELL', 10),
  ('teo', 'concepto', 'UPSELL', 11),
  ('teo', 'metodo_pago', 'Efectivo', 1),
  ('teo', 'metodo_pago', 'Otro', 2),
  ('teo', 'metodo_pago', 'Stripe Dystopia', 3),
  ('teo', 'metodo_pago', 'Transferencia ARS', 4),
  ('teo', 'metodo_pago', 'Transferencia USD Argentina', 5),
  ('teo', 'metodo_pago', 'Transferencia USD Mercury', 6),
  ('teo', 'metodo_pago', 'USDT', 7),
  ('teo', 'programa', '1 A 1', 1),
  ('teo', 'programa', 'GRUPAL', 2),
  ('teo', 'quien_recibe', 'Blas', 1),
  ('teo', 'quien_recibe', 'Dystopia', 2),
  ('teo', 'quien_recibe', 'Joaco Fernandez', 3),
  ('teo', 'quien_recibe', 'Martu Chimienti', 4),
  ('teo', 'quien_recibe', 'Nacho', 5),
  ('teo', 'quien_recibe', 'Sofi Financiera', 6),
  ('teo', 'quien_recibe', 'Teo', 7)
) s(cliente_id, dimension, valor, orden)
on conflict (cliente_id, dimension, valor) do nothing;

insert into public.fin_catalogo_alias (cliente_id, columna, crudo_norm, dimension, catalogo_id)
select s.cliente_id, s.columna, s.crudo_norm, s.dimension, c.id
from (values
  ('liam', 'metodo_pago', 'efectivo', 'metodo_pago', 'Efectivo'),
  ('liam', 'metodo_pago', 'otro', 'metodo_pago', 'Otro'),
  ('liam', 'metodo_pago', 'paypal', 'metodo_pago', 'PayPal'),
  ('liam', 'metodo_pago', 'stripe', 'metodo_pago', 'Stripe del cliente'),
  ('liam', 'metodo_pago', 'stripe dystopia', 'metodo_pago', 'Stripe Dystopia'),
  ('liam', 'metodo_pago', 'stripe dystopia', 'quien_recibe', 'Dystopia'),
  ('liam', 'metodo_pago', 'tranfer pesos', 'metodo_pago', 'Transferencia ARS'),
  ('liam', 'metodo_pago', 'tranfer usd - arg', 'metodo_pago', 'Transferencia USD Argentina'),
  ('liam', 'metodo_pago', 'transfer en usd- uru', 'metodo_pago', 'Transferencia USD Uruguay'),
  ('liam', 'metodo_pago', 'usdt', 'metodo_pago', 'USDT'),
  ('liam', 'quien_recibe', 'dystopia', 'quien_recibe', 'Dystopia'),
  ('liam', 'quien_recibe', 'liam', 'quien_recibe', 'Liam'),
  ('liam', 'quien_recibe', 'lucas financiera', 'quien_recibe', 'Lucas Financiera'),
  ('liam', 'quien_recibe', 'nacho', 'quien_recibe', 'Nacho'),
  ('liam', 'quien_recibe', 'sofi financiera', 'quien_recibe', 'Sofi Financiera'),
  ('liam', 'quien_recibe', 'valen', 'quien_recibe', 'Valen'),
  ('liam', 'programa', 'bpf 1 a 1 - 4 meses', 'programa', 'BPF 1 A 1 4 MESES'),
  ('liam', 'programa', 'bpf 1 a 1 4 meses', 'programa', 'BPF 1 A 1 4 MESES'),
  ('liam', 'programa', 'bpf 1 a 1 resell 9 meses', 'programa', 'BPF 1 A 1 RESELL 9 MESES'),
  ('liam', 'programa', 'bpf downsell', 'programa', 'BPF DOWNSELL'),
  ('liam', 'programa', 'bpf grupal 4 meses', 'programa', 'BPF GRUPAL 4 MESES'),
  ('liam', 'programa', 'downsell grupal 4 meses', 'programa', 'DOWNSELL GRUPAL 4 MESES'),
  ('liam', 'programa', 'gestion de capital', 'programa', 'GESTION DE CAPITAL'),
  ('liam', 'concepto', '1ra cuota', 'concepto', '1RA CUOTA'),
  ('liam', 'concepto', '2da cuota', 'concepto', '2DA CUOTA'),
  ('liam', 'concepto', 'completa pif', 'concepto', 'COMPLETA PIF'),
  ('liam', 'concepto', 'cuota renovacion', 'concepto', 'CUOTA RENOVACION'),
  ('liam', 'concepto', 'fee', 'concepto', 'FEE'),
  ('liam', 'concepto', 'pif', 'concepto', 'PIF'),
  ('liam', 'concepto', 'refuerza fee', 'concepto', 'REFUERZA FEE'),
  ('liam', 'concepto', 'resell', 'concepto', 'RESELL'),
  ('liam', 'concepto', 'upsell', 'concepto', 'UPSELL'),
  ('agus', 'metodo_pago', 'dolar app', 'metodo_pago', 'Dolar App'),
  ('agus', 'metodo_pago', 'efectivo', 'metodo_pago', 'Efectivo'),
  ('agus', 'metodo_pago', 'link de mercado pago', 'metodo_pago', 'Mercado Pago'),
  ('agus', 'metodo_pago', 'link para tarjeta de mp', 'metodo_pago', 'Mercado Pago'),
  ('agus', 'metodo_pago', 'stripe', 'metodo_pago', 'Stripe del cliente'),
  ('agus', 'metodo_pago', 'stripe dystopia', 'metodo_pago', 'Stripe Dystopia'),
  ('agus', 'metodo_pago', 'stripe dystopia', 'quien_recibe', 'Dystopia'),
  ('agus', 'metodo_pago', 'tranfer pesos', 'metodo_pago', 'Transferencia ARS'),
  ('agus', 'metodo_pago', 'tranfer usd - arg', 'metodo_pago', 'Transferencia USD Argentina'),
  ('agus', 'metodo_pago', 'transfer ach', 'metodo_pago', 'Transferencia ACH'),
  ('agus', 'metodo_pago', 'usdt', 'metodo_pago', 'USDT'),
  ('agus', 'quien_recibe', 'agus personal', 'quien_recibe', 'Agus personal'),
  ('agus', 'quien_recibe', 'agus saas', 'quien_recibe', 'Agus SaaS'),
  ('agus', 'quien_recibe', 'blas', 'quien_recibe', 'Blas'),
  ('agus', 'quien_recibe', 'fran lagrega', 'quien_recibe', 'Fran Lagrega'),
  ('agus', 'quien_recibe', 'lucas financiera', 'quien_recibe', 'Lucas Financiera'),
  ('agus', 'quien_recibe', 'male', 'quien_recibe', 'Male'),
  ('agus', 'quien_recibe', 'sofi', 'quien_recibe', 'Sofi Financiera'),
  ('agus', 'quien_recibe', 'sofi financiera', 'quien_recibe', 'Sofi Financiera'),
  ('agus', 'programa', '1 a 1', 'programa', '1 A 1'),
  ('agus', 'programa', '1 mes', 'programa', '1 MES'),
  ('agus', 'programa', '3 meses', 'programa', '3 MESES'),
  ('agus', 'programa', 'grupal', 'programa', 'GRUPAL'),
  ('agus', 'programa', 'skool', 'programa', 'SKOOL'),
  ('agus', 'concepto', '1ra cuota', 'concepto', '1RA CUOTA'),
  ('agus', 'concepto', '2da cuota', 'concepto', '2DA CUOTA'),
  ('agus', 'concepto', 'completa pif', 'concepto', 'COMPLETA PIF'),
  ('agus', 'concepto', 'cuota renovacion', 'concepto', 'CUOTA RENOVACION'),
  ('agus', 'concepto', 'fee', 'concepto', 'FEE'),
  ('agus', 'concepto', 'pif', 'concepto', 'PIF'),
  ('agus', 'concepto', 'refuerza fee', 'concepto', 'REFUERZA FEE'),
  ('agus', 'concepto', 'resell', 'concepto', 'RESELL'),
  ('agus', 'concepto', 'upsell', 'concepto', 'UPSELL'),
  ('teo', 'metodo_pago', 'efectivo', 'metodo_pago', 'Efectivo'),
  ('teo', 'metodo_pago', 'otro', 'metodo_pago', 'Otro'),
  ('teo', 'metodo_pago', 'stripe dystopia', 'metodo_pago', 'Stripe Dystopia'),
  ('teo', 'metodo_pago', 'stripe dystopia', 'quien_recibe', 'Dystopia'),
  ('teo', 'metodo_pago', 'transfer en pesos', 'metodo_pago', 'Transferencia ARS'),
  ('teo', 'metodo_pago', 'transfer en pesos a blas', 'metodo_pago', 'Transferencia ARS'),
  ('teo', 'metodo_pago', 'transfer en pesos a blas', 'quien_recibe', 'Blas'),
  ('teo', 'metodo_pago', 'transfer en usd - arg', 'metodo_pago', 'Transferencia USD Argentina'),
  ('teo', 'metodo_pago', 'transfer usd mercury', 'metodo_pago', 'Transferencia USD Mercury'),
  ('teo', 'metodo_pago', 'usdt', 'metodo_pago', 'USDT'),
  ('teo', 'quien_recibe', 'blas', 'quien_recibe', 'Blas'),
  ('teo', 'quien_recibe', 'dystopia', 'quien_recibe', 'Dystopia'),
  ('teo', 'quien_recibe', 'joaco feranandez', 'quien_recibe', 'Joaco Fernandez'),
  ('teo', 'quien_recibe', 'joaco fernandez', 'quien_recibe', 'Joaco Fernandez'),
  ('teo', 'quien_recibe', 'martu chimienti', 'quien_recibe', 'Martu Chimienti'),
  ('teo', 'quien_recibe', 'nacho', 'quien_recibe', 'Nacho'),
  ('teo', 'quien_recibe', 'sofi', 'quien_recibe', 'Sofi Financiera'),
  ('teo', 'quien_recibe', 'stripe dystopia', 'quien_recibe', 'Dystopia'),
  ('teo', 'quien_recibe', 'teo', 'quien_recibe', 'Teo'),
  ('teo', 'programa', '1 a 1', 'programa', '1 A 1'),
  ('teo', 'programa', 'grupal', 'programa', 'GRUPAL'),
  ('teo', 'concepto', '1ra cuota', 'concepto', '1RA CUOTA'),
  ('teo', 'concepto', '2da cuota', 'concepto', '2DA CUOTA'),
  ('teo', 'concepto', 'completa pif', 'concepto', 'COMPLETA PIF'),
  ('teo', 'concepto', 'fee', 'concepto', 'FEE'),
  ('teo', 'concepto', 'fee de pif', 'concepto', 'FEE DE PIF'),
  ('teo', 'concepto', 'pif', 'concepto', 'PIF'),
  ('teo', 'concepto', 'refuerza fee', 'concepto', 'REFUERZA FEE'),
  ('teo', 'concepto', 'resell', 'concepto', 'RESELL'),
  ('teo', 'concepto', 'upsell', 'concepto', 'UPSELL'),
  ('lucas', 'metodo_pago', 'efectivo', 'metodo_pago', 'Efectivo'),
  ('lucas', 'metodo_pago', 'efectivo lucas', 'metodo_pago', 'Efectivo'),
  ('lucas', 'metodo_pago', 'efectivo lucas', 'quien_recibe', 'Lucas'),
  ('lucas', 'metodo_pago', 'lbfinanzas - blas', 'quien_recibe', 'Blas'),
  ('lucas', 'metodo_pago', 'otro', 'metodo_pago', 'Otro'),
  ('lucas', 'metodo_pago', 'recibio nachito', 'quien_recibe', 'Nacho'),
  ('lucas', 'metodo_pago', 'red tron trc20 (nacho)', 'metodo_pago', 'USDT'),
  ('lucas', 'metodo_pago', 'red tron trc20 (nacho)', 'quien_recibe', 'Nacho'),
  ('lucas', 'metodo_pago', 'stripe dystopia', 'metodo_pago', 'Stripe Dystopia'),
  ('lucas', 'metodo_pago', 'stripe dystopia', 'quien_recibe', 'Dystopia'),
  ('lucas', 'metodo_pago', 'transfer en pesos-calypso soluciones', 'metodo_pago', 'Transferencia ARS'),
  ('lucas', 'metodo_pago', 'transfer en pesos-calypso soluciones', 'quien_recibe', 'Calypso Soluciones'),
  ('lucas', 'metodo_pago', 'transfer en usd - arg', 'metodo_pago', 'Transferencia USD Argentina'),
  ('lucas', 'metodo_pago', 'transferencia en dolares - juan kaiser ferreiro', 'metodo_pago', 'Transferencia USD Argentina'),
  ('lucas', 'metodo_pago', 'transferencia en pesos - recibe sofi', 'metodo_pago', 'Transferencia ARS'),
  ('lucas', 'metodo_pago', 'transferencia en pesos - recibe sofi', 'quien_recibe', 'Sofi Financiera'),
  ('lucas', 'metodo_pago', 'usdt', 'metodo_pago', 'USDT'),
  ('lucas', 'quien_recibe', 'dystopia', 'quien_recibe', 'Dystopia'),
  ('lucas', 'quien_recibe', 'lucas', 'quien_recibe', 'Lucas'),
  ('lucas', 'quien_recibe', 'lucas financiera', 'quien_recibe', 'Lucas Financiera'),
  ('lucas', 'quien_recibe', 'sofi financiera', 'quien_recibe', 'Sofi Financiera'),
  ('lucas', 'programa', '1 a 1', 'programa', '1 A 1'),
  ('lucas', 'programa', 'grupal', 'programa', 'GRUPAL'),
  ('lucas', 'concepto', '1ra cuota', 'concepto', '1RA CUOTA'),
  ('lucas', 'concepto', '2da cuota', 'concepto', '2DA CUOTA'),
  ('lucas', 'concepto', 'completa fee', 'concepto', 'COMPLETA FEE'),
  ('lucas', 'concepto', 'completa pif', 'concepto', 'COMPLETA PIF'),
  ('lucas', 'concepto', 'completo fee (acceso al programa)', 'concepto', 'COMPLETA FEE'),
  ('lucas', 'concepto', 'fee', 'concepto', 'FEE'),
  ('lucas', 'concepto', 'pif', 'concepto', 'PIF'),
  ('lucas', 'concepto', 'refuerza fee', 'concepto', 'REFUERZA FEE')
) s(cliente_id, columna, crudo_norm, dimension, valor)
join public.fin_catalogos c
  on c.cliente_id = s.cliente_id and c.dimension = s.dimension and c.valor = s.valor
on conflict (cliente_id, columna, crudo_norm, dimension) do nothing;

-- Relleno de lo que ya esta cargado (la sync lo rehace sola cada 15 min).
update public.fin_pagos p set
  programa_id     = coalesce(p.programa_id,
                      public.fin_resolver_alias(p.cliente_id, 'programa', 'programa', p.programa)),
  concepto_id     = coalesce(p.concepto_id,
                      public.fin_resolver_alias(p.cliente_id, 'concepto', 'concepto', p.concepto)),
  metodo_pago_id  = coalesce(p.metodo_pago_id,
                      public.fin_resolver_alias(p.cliente_id, 'metodo_pago', 'metodo_pago', p.metodo_pago)),
  quien_recibe_id = coalesce(p.quien_recibe_id,
                      public.fin_resolver_alias(p.cliente_id, 'quien_recibe', 'quien_recibe', p.quien_recibe),
                      public.fin_resolver_alias(p.cliente_id, 'metodo_pago', 'quien_recibe', p.metodo_pago))
where p.cliente_id <> 'mauro';

-- ---------------------------------------------------------------------
-- 5. Pendientes: textos del Sheet sin valor de catalogo
-- ---------------------------------------------------------------------
create or replace view public.fin_v_alias_pendientes
with (security_invoker = true) as
select cliente_id, columna, crudo, count(*) as pagos, round(sum(monto_usd), 2) as usd
from (
  select cliente_id, 'programa' as columna, btrim(programa) as crudo, monto_usd
    from public.fin_pagos where programa_id is null and public.fin_normalizar_alias(programa) is not null
  union all
  select cliente_id, 'concepto', btrim(concepto), monto_usd
    from public.fin_pagos where concepto_id is null and public.fin_normalizar_alias(concepto) is not null
  union all
  select cliente_id, 'metodo_pago', btrim(metodo_pago), monto_usd
    from public.fin_pagos where metodo_pago_id is null and public.fin_normalizar_alias(metodo_pago) is not null
  union all
  select cliente_id, 'quien_recibe', btrim(quien_recibe), monto_usd
    from public.fin_pagos where quien_recibe_id is null and public.fin_normalizar_alias(quien_recibe) is not null
) x
where cliente_id <> 'mauro'
group by cliente_id, columna, crudo;

comment on view public.fin_v_alias_pendientes is
  '064: textos del Sheet que todavia no tienen valor de catalogo. Se resuelven agregando un alias.';

revoke all on public.fin_v_alias_pendientes from anon;
grant select on public.fin_v_alias_pendientes to authenticated;
grant all on public.fin_v_alias_pendientes to service_role;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- C1. Catalogos y alias cargados. Esperado: 120 valores nuevos de Finanzas
--     (programa incluye los 4 que ya tenian lucas y teo) y 126 alias.
-- select (select count(*) from public.fin_catalogos
--          where dimension in ('metodo_pago', 'quien_recibe', 'concepto', 'programa')) as valores,
--        (select count(*) from public.fin_catalogo_alias) as alias;

-- C2. Cobertura por cliente y columna (sin mauro). Esperado: concepto y
--     metodo cerca del 95% o mas; programa de liam ~72% (bpf 1 a 1 sin
--     duracion queda pendiente); quien_recibe alto donde la columna se usa.
-- select cliente_id,
--        round(100.0 * count(programa_id)     / nullif(count(*) filter (where public.fin_normalizar_alias(programa) is not null), 0)) as pct_programa,
--        round(100.0 * count(concepto_id)     / nullif(count(*) filter (where public.fin_normalizar_alias(concepto) is not null), 0)) as pct_concepto,
--        round(100.0 * count(metodo_pago_id)  / nullif(count(*) filter (where public.fin_normalizar_alias(metodo_pago) is not null), 0)) as pct_metodo,
--        count(quien_recibe_id) as con_quien_recibe
--   from public.fin_pagos where cliente_id <> 'mauro'
--  group by 1 order by 1;

-- C3. Lo que queda para la agencia, de mayor a menor USD.
-- select * from public.fin_v_alias_pendientes order by usd desc;

-- =====================================================================
-- DESPUES DE LA PROXIMA SINCRONIZACION (15 min)
-- =====================================================================

-- C4. La sync sigue en ok/revisar como antes y vuelve a completar los *_id:
--     repeti C2 y tiene que dar lo mismo.
