-- =====================================================================
-- 088b. Controles de la 088 (borrar los 3 pagos de mas de Liam).
-- Solo lectura. Cada consulta es UN select y se corre SOLA en el SQL Editor
-- (el editor muestra solo el ultimo resultado). Dependen de la foto
-- public.fin_import_liam_076 (no borrarla antes de controlar).
-- No traen datos personales en el archivo; los resultados no incluyen alumnos.
-- =====================================================================


-- ---------------------------------------------------------------------
-- C1. Pagos de liam despues. Esperado: pagos 231, usd 231600.80.
-- ---------------------------------------------------------------------
select count(*) as pagos, round(sum(monto_usd), 2) as usd
  from public.fin_pagos
 where cliente_id = 'liam';


-- ---------------------------------------------------------------------
-- C2. Sobrantes despues (misma logica que la Q2 de la 076c). Esperado: 0 filas.
-- ---------------------------------------------------------------------
select p.id, p.fecha, p.concepto, p.monto_usd, p.fila_planilla
  from (
    select x.*,
           row_number() over (partition by x.huella order by x.ocurrencia, x.id) as pos
      from public.fin_pagos x
     where x.cliente_id = 'liam'
  ) p
  left join (
    select public.fin_pago_huella('liam', d.fecha, d.alumno, d.monto, d.concepto) as huella,
           count(*)::int as n
      from public.fin_import_liam_076 d
     group by 1
  ) f on f.huella = p.huella
 where p.pos > coalesce(f.n, 0)
 order by p.fecha, p.id;


-- ---------------------------------------------------------------------
-- C3. Respaldo. Esperado: filas 3, usd 3500.00, ids 2505043, 2505056, 2505062.
-- ---------------------------------------------------------------------
select count(*) as filas, round(sum(monto_usd), 2) as usd,
       string_agg(id::text, ', ' order by id) as ids
  from public.fin_respaldo_088_liam_pagos;


-- ---------------------------------------------------------------------
-- C4. Inverso: filas del xlsx sin pago en la app. Esperado: 0 filas.
-- ---------------------------------------------------------------------
select d.fila, d.fecha, d.concepto, d.monto
  from (
    select d0.fila, d0.fecha, d0.concepto, d0.monto,
           public.fin_pago_huella('liam', d0.fecha, d0.alumno, d0.monto, d0.concepto) as huella,
           row_number() over (
             partition by public.fin_pago_huella('liam', d0.fecha, d0.alumno, d0.monto, d0.concepto)
             order by d0.fila) as pos
      from public.fin_import_liam_076 d0
  ) d
  left join (
    select huella, count(*)::int as n
      from public.fin_pagos
     where cliente_id = 'liam'
     group by huella
  ) b on b.huella = d.huella
 where d.pos > coalesce(b.n, 0)
 order by d.fila;


-- ---------------------------------------------------------------------
-- C5. Los 3 ids ya no estan en fin_pagos. Esperado: 0.
-- ---------------------------------------------------------------------
select count(*) as siguen_en_fin_pagos
  from public.fin_pagos
 where id in (2505043, 2505056, 2505062);


-- ---------------------------------------------------------------------
-- C6. Fuentes de pagos de liam (la sync no puede traerlos de vuelta).
--     Esperado: tipo pagos con activo = false y cortada_en con fecha;
--     pagos_historico con activo = false.
-- ---------------------------------------------------------------------
select id, tipo, activo, cortada_en
  from public.fin_fuentes
 where cliente_id = 'liam' and tipo in ('pagos', 'pagos_historico')
 order by tipo, id;
