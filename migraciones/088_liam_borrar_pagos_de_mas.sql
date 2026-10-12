-- =====================================================================
-- 088_liam_borrar_pagos_de_mas.sql
-- FINANZAS: borra de Liam los 3 pagos que no estan en el xlsx (3.500,00 USD),
-- con respaldo previo. Decision de Joaquin (12/10/2026): los pagos de mas o
-- repetidos se borran.
--
-- Pagos a borrar (ids de fin_pagos, salieron de la Q2 de la 076c):
--   2505043, 2505056, 2505062   (suma 3.500,00 USD)
--
-- COMO CORRERLA (SQL Editor):
--   1. Correr SOLO el bloque DIAGNOSTICO (primer select). No modifica nada.
--      Esperado: estado = LISTA PARA CORRER.
--   2. Correr el bloque MIGRACION (do $liam088$ ... $liam088$). Es UNA sola
--      sentencia: se aplica completa o no se aplica nada. Sin begin/commit
--      ni temporales (el SQL Editor pasa por un pooler).
--   3. Controles: migraciones/088b_liam_borrar_pagos_control.sql, de a uno.
--   Para deshacer: migraciones/088c_liam_restaurar_pagos.sql (solo si Joaquin lo pide).
--
-- Re-ejecutable: si ya corrio (los 3 pagos no estan y estan en el respaldo)
-- no borra nada y no falla.
--
-- Criterio del conjunto a borrar: el MISMO de la Q2 de la 076c. Un pago de
-- liam sobra si, entre los pagos con su misma huella ordenados por ocurrencia,
-- su posicion es mayor que la cantidad de filas de la foto del xlsx
-- (public.fin_import_liam_076) con esa huella. La huella de la foto se
-- calcula con public.fin_pago_huella('liam', fecha, alumno, monto, concepto).
--
-- ABORTA SIN BORRAR si:
--   - falta la foto fin_import_liam_076 o fin_pagos de liam no tiene los 3 ids;
--   - el conjunto calculado no es exactamente esos 3 ids (se comparan conjuntos);
--   - la suma de monto_usd no es 3.500,00;
--   - alguno tiene creado_por o editado_por (cargado o editado en la app);
--   - alguno figura en una liquidacion (fin_liquidacion_items, por clave o id);
--   - alguno es el pago original de una devolucion (pago_original_clave);
--   - alguno tiene valores en fin_pagos_extra;
--   - queda activa una fuente de pagos de liam (la sync podria volver a traerlos).
-- Nunca borra en cascada: si hay algo dependiente, avisa y no toca nada.
--
-- Respaldo: tabla normal public.fin_respaldo_088_liam_pagos (filas completas
-- de fin_pagos + respaldado_en). Contiene alumnos: solo la lee el rol postgres
-- (RLS activada, sin permisos para anon ni authenticated).
--
-- NO correr a las :00/:15/:30/:45 (corre la sync).
-- =====================================================================

-- =====================================================================
-- DIAGNOSTICO (solo lectura)
-- =====================================================================

with foto as (
  select public.fin_pago_huella('liam', d.fecha, d.alumno, d.monto, d.concepto) as huella,
         count(*)::int as n
    from public.fin_import_liam_076 d
   group by 1
), sob as (
  select p.id, p.clave, p.cliente_id, p.monto_usd, p.creado_por, p.editado_por
    from (
      select x.*,
             row_number() over (partition by x.huella order by x.ocurrencia, x.id) as pos
        from public.fin_pagos x
       where x.cliente_id = 'liam'
    ) p
    left join foto f on f.huella = p.huella
   where p.pos > coalesce(f.n, 0)
), esperados as (
  select unnest(array[2505043, 2505056, 2505062]::bigint[]) as id
), r as (
  select
    (select count(*) from sob)::int as sobrantes,
    (select coalesce(round(sum(monto_usd), 2), 0) from sob) as usd,
    (select count(*) from sob where id in (select id from esperados))::int as sobrantes_esperados,
    (select count(*) from esperados e where not exists (select 1 from sob s where s.id = e.id))::int as esperados_que_no_sobran,
    (select count(*) from sob where creado_por is not null or editado_por is not null)::int as cargados_o_editados,
    (select count(*) from public.fin_liquidacion_items i join sob s on i.pago_clave = s.clave or i.pago_id = s.id)::int as en_liquidaciones,
    (select count(*) from public.fin_pagos d join sob s on d.cliente_id = s.cliente_id and d.pago_original_clave = s.clave)::int as devoluciones_dependientes,
    (select count(*) from public.fin_pagos_extra e join sob s on e.cliente_id = s.cliente_id and e.clave = s.clave)::int as con_extras,
    (select count(*) from public.fin_pagos_anulados a join sob s on a.cliente_id = s.cliente_id and a.clave = s.clave)::int as anulados_misma_clave_info,
    (select count(*) from public.fin_fuentes
      where cliente_id = 'liam' and tipo in ('pagos', 'pagos_historico') and activo)::int as fuentes_pagos_activas,
    (select count(*) from public.fin_fuentes
      where cliente_id = 'liam' and tipo = 'pagos' and cortada_en is not null and not activo)::int as fuentes_pagos_cortadas,
    (select count(*) from public.fin_import_liam_076)::int as foto_filas,
    (select count(*) from public.fin_pagos where cliente_id = 'liam')::int as pagos_liam,
    to_regclass('public.fin_respaldo_088_liam_pagos') is not null as hay_respaldo
)
select
  case
    when sobrantes = 0 and hay_respaldo then 'YA APLICADA: no hay sobrantes y existe el respaldo (volver a correr no cambia nada)'
    when sobrantes = 3 and sobrantes_esperados = 3 and esperados_que_no_sobran = 0 and usd = 3500.00
         and cargados_o_editados = 0 and en_liquidaciones = 0 and devoluciones_dependientes = 0
         and con_extras = 0 and fuentes_pagos_activas = 0 and fuentes_pagos_cortadas >= 1
      then 'LISTA PARA CORRER'
    else 'NO CORRER: mirar las columnas (la migracion va a abortar sin borrar)'
  end as estado,
  sobrantes, sobrantes_esperados, esperados_que_no_sobran, usd,
  cargados_o_editados, en_liquidaciones, devoluciones_dependientes, con_extras,
  anulados_misma_clave_info, fuentes_pagos_activas, fuentes_pagos_cortadas,
  foto_filas, pagos_liam, hay_respaldo
from r;

-- =====================================================================
-- MIGRACION (una sola sentencia atomica)
-- =====================================================================

do $liam088$
declare
  v_esp       constant bigint[] := array[2505043, 2505056, 2505062]::bigint[];
  v_ids       bigint[];
  v_n         int;
  v_suma      numeric;
  v_tocados   int;
  v_cuenta    int;
  v_borrados  int;
begin
  perform set_config('lock_timeout', '10s', true);
  lock table public.fin_pagos, public.fin_pagos_extra, public.fin_liquidacion_items in access exclusive mode;

  if to_regclass('public.fin_import_liam_076') is null then
    raise exception 'GUARDA 088: falta la foto public.fin_import_liam_076. No se borra nada.';
  end if;

  -- Conjunto a borrar: misma logica que la Q2 de la 076c.
  with foto as (
    select public.fin_pago_huella('liam', d.fecha, d.alumno, d.monto, d.concepto) as huella,
           count(*)::int as n
      from public.fin_import_liam_076 d
     group by 1
  ), sob as (
    select p.id, p.monto_usd, p.creado_por, p.editado_por
      from (
        select x.*,
               row_number() over (partition by x.huella order by x.ocurrencia, x.id) as pos
          from public.fin_pagos x
         where x.cliente_id = 'liam'
      ) p
      left join foto f on f.huella = p.huella
     where p.pos > coalesce(f.n, 0)
  )
  select coalesce(array_agg(s.id order by s.id), array[]::bigint[]),
         coalesce(round(sum(s.monto_usd), 2), 0),
         (count(*) filter (where s.creado_por is not null or s.editado_por is not null))::int
    into v_ids, v_suma, v_tocados
    from sob s;

  v_n := coalesce(array_length(v_ids, 1), 0);

  -- Ya aplicada: no hay sobrantes y los 3 estan en el respaldo y no en fin_pagos.
  if v_n = 0 and to_regclass('public.fin_respaldo_088_liam_pagos') is not null then
    select count(*)::int into v_cuenta
      from public.fin_respaldo_088_liam_pagos r
     where r.id = any (v_esp) and r.cliente_id = 'liam';
    if v_cuenta = 3
       and not exists (select 1 from public.fin_pagos p where p.id = any (v_esp)) then
      raise notice '088: ya estaba aplicada (los 3 pagos estan en el respaldo y no en fin_pagos). No se cambio nada.';
      return;
    end if;
  end if;

  -- Guarda: el conjunto calculado es EXACTAMENTE los 3 ids (comparacion de conjuntos).
  if v_n <> 3
     or exists (select unnest(v_ids) except select unnest(v_esp))
     or exists (select unnest(v_esp) except select unnest(v_ids)) then
    raise exception 'GUARDA 088: el conjunto calculado (% pagos) no es exactamente 2505043, 2505056 y 2505062. No se borra nada.', v_n;
  end if;

  if v_suma <> 3500.00 then
    raise exception 'GUARDA 088: la suma de los 3 pagos es % y no 3500.00. No se borra nada.', v_suma;
  end if;

  if v_tocados > 0 then
    raise exception 'GUARDA 088: % de los 3 pagos tiene creado_por o editado_por (cargado o editado en la app). No se borra nada.', v_tocados;
  end if;

  -- Sync: ninguna fuente de pagos de liam activa y la de pagos cortada.
  if exists (select 1 from public.fin_fuentes
              where cliente_id = 'liam' and tipo in ('pagos', 'pagos_historico') and activo) then
    raise exception 'GUARDA 088: hay una fuente de pagos de liam activa; la sync podria volver a traer los pagos. No se borra nada.';
  end if;
  if not exists (select 1 from public.fin_fuentes
                  where cliente_id = 'liam' and tipo = 'pagos' and cortada_en is not null and not activo) then
    raise exception 'GUARDA 088: la fuente de pagos de liam no esta cortada (falta la 076). No se borra nada.';
  end if;

  -- Dependientes: si hay alguno, se aborta (no se borra en cascada).
  select count(*)::int into v_cuenta
    from public.fin_liquidacion_items i
    join public.fin_pagos p on p.id = any (v_esp) and (i.pago_clave = p.clave or i.pago_id = p.id);
  if v_cuenta > 0 then
    raise exception 'GUARDA 088: % linea(s) de liquidaciones (fin_liquidacion_items) referencian estos pagos. No se borra nada.', v_cuenta;
  end if;

  select count(*)::int into v_cuenta
    from public.fin_pagos d
    join public.fin_pagos p on p.id = any (v_esp) and d.cliente_id = p.cliente_id and d.pago_original_clave = p.clave;
  if v_cuenta > 0 then
    raise exception 'GUARDA 088: % devolucion(es) apuntan a estos pagos por pago_original_clave. No se borra nada.', v_cuenta;
  end if;

  select count(*)::int into v_cuenta
    from public.fin_pagos_extra e
    join public.fin_pagos p on p.id = any (v_esp) and e.cliente_id = p.cliente_id and e.clave = p.clave;
  if v_cuenta > 0 then
    raise exception 'GUARDA 088: % fila(s) de fin_pagos_extra tienen valores de estos pagos. No se borra nada.', v_cuenta;
  end if;

  -- Respaldo: filas completas (la tabla se crea con las mismas columnas de fin_pagos + respaldado_en).
  create table if not exists public.fin_respaldo_088_liam_pagos as
    select p.*, now() as respaldado_en
      from public.fin_pagos p
     where false;
  alter table public.fin_respaldo_088_liam_pagos enable row level security;
  revoke all on public.fin_respaldo_088_liam_pagos from anon, authenticated;
  grant all on public.fin_respaldo_088_liam_pagos to service_role;

  delete from public.fin_respaldo_088_liam_pagos where id = any (v_esp);
  insert into public.fin_respaldo_088_liam_pagos
    select p.*, now()
      from public.fin_pagos p
     where p.id = any (v_esp) and p.cliente_id = 'liam';

  select count(*)::int into v_cuenta
    from public.fin_respaldo_088_liam_pagos r
   where r.id = any (v_esp) and r.cliente_id = 'liam';
  if v_cuenta <> 3 then
    raise exception 'GUARDA 088: el respaldo quedo con % filas y no 3. No se borra nada.', v_cuenta;
  end if;

  -- Borrado.
  delete from public.fin_pagos where id = any (v_esp) and cliente_id = 'liam';
  get diagnostics v_borrados = row_count;
  if v_borrados <> 3 then
    raise exception 'GUARDA 088: el delete afecto % filas y no 3. Se revierte todo.', v_borrados;
  end if;

  raise notice '088: aplicada. 3 pagos borrados (3500.00 USD) y respaldados en fin_respaldo_088_liam_pagos.';
end
$liam088$;

-- Resultado. Esperado: pagos 231, usd 231600.80.
select count(*) as pagos_liam, round(sum(monto_usd), 2) as usd
  from public.fin_pagos
 where cliente_id = 'liam';
