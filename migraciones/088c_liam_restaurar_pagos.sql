-- =====================================================================
-- 088c_liam_restaurar_pagos.sql
-- Restaura los 3 pagos borrados por la 088 desde public.fin_respaldo_088_liam_pagos.
-- NO SE CORRE salvo que Joaquin lo pida.
--
-- Una sola sentencia (do $liam088c$ ... $liam088c$): atomica.
-- Re-ejecutable: si los 3 ya estan en fin_pagos no hace nada.
-- Aborta sin insertar si: falta el respaldo o no tiene exactamente los 3 ids,
-- o si solo algunos de los 3 estan en fin_pagos.
--
-- Mantiene los mismos id y valores (insert con overriding system value). El
-- trigger fin_pagos_clave_trg recalcula huella/ocurrencia/clave al insertar:
-- la migracion compara que la clave restaurada sea la misma del respaldo y, si
-- no, revierte todo.
-- Despues de restaurar, la foto sigue marcando estos 3 como "sobrantes".
-- El respaldo no se borra.
--
-- NO correr a las :00/:15/:30/:45 (corre la sync).
-- =====================================================================

do $liam088c$
declare
  v_esp      constant bigint[] := array[2505043, 2505056, 2505062]::bigint[];
  v_resp     int;
  v_vivos    int;
  v_ins      int;
  v_difieren int;
begin
  perform set_config('lock_timeout', '10s', true);
  lock table public.fin_pagos in access exclusive mode;

  if to_regclass('public.fin_respaldo_088_liam_pagos') is null then
    raise exception 'GUARDA 088c: no existe public.fin_respaldo_088_liam_pagos. No se restaura nada.';
  end if;

  select count(*)::int into v_resp
    from public.fin_respaldo_088_liam_pagos r
   where r.id = any (v_esp) and r.cliente_id = 'liam';
  if v_resp <> 3 then
    raise exception 'GUARDA 088c: el respaldo tiene % de los 3 pagos. No se restaura nada.', v_resp;
  end if;

  select count(*)::int into v_vivos from public.fin_pagos p where p.id = any (v_esp);
  if v_vivos = 3 then
    raise notice '088c: los 3 pagos ya estan en fin_pagos. No se cambio nada.';
    return;
  end if;
  if v_vivos <> 0 then
    raise exception 'GUARDA 088c: % de los 3 pagos ya estan en fin_pagos (estado mixto). No se restaura nada.', v_vivos;
  end if;

  insert into public.fin_pagos overriding system value
    select x.*
      from public.fin_respaldo_088_liam_pagos r
      cross join lateral jsonb_populate_record(null::public.fin_pagos, to_jsonb(r) - 'respaldado_en') x
     where r.id = any (v_esp) and r.cliente_id = 'liam'
     order by r.ocurrencia, r.id;
  get diagnostics v_ins = row_count;
  if v_ins <> 3 then
    raise exception 'GUARDA 088c: se insertaron % filas y no 3. Se revierte todo.', v_ins;
  end if;

  select count(*)::int into v_difieren
    from public.fin_respaldo_088_liam_pagos r
    join public.fin_pagos p on p.id = r.id
   where r.id = any (v_esp) and p.clave is distinct from r.clave;
  if v_difieren > 0 then
    raise exception 'GUARDA 088c: % pago(s) restaurados quedaron con otra clave que en el respaldo. Se revierte todo.', v_difieren;
  end if;

  raise notice '088c: 3 pagos restaurados (3500.00 USD).';
end
$liam088c$;

-- Resultado. Esperado: pagos 234, usd 235100.80 (231 + los 3 restaurados).
select count(*) as pagos_liam, round(sum(monto_usd), 2) as usd
  from public.fin_pagos
 where cliente_id = 'liam';
