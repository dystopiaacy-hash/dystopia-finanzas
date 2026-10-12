-- =====================================================================
-- 089b_ventas_liam_closer_lectura_control.sql  -  CONTROLES de la 089
-- =====================================================================
-- Solo lectura. Correr DESPUES de la 089, UNA consulta por vez (el editor de
-- Supabase solo muestra el resultado de la ultima). Cada una esta separada
-- por una linea en blanco y se puede copiar y pegar sola.
-- =====================================================================

-- C1. El mapa de liam: texto guardado (en minuscula) -> como se muestra.
--     Esperado: lucas y lucas deza -> Lucas Deza; ivan y ivan binsztein -> Ivan
--     (y otros alias de esas dos personas si los hay). Sin BPF ni Valentin Morello.
select j.key as texto_guardado, j.value as se_muestra
  from jsonb_each_text(public.fin_data_closer_mapa_base('liam')) j
 order by j.value, j.key;

-- C2. Closers de liam que NO tienen canonico (se muestran tal cual y no se
--     pierden al abrir el editor). Esperado: solo historicos (Valentin/Valen
--     Morello, Liam Wickham, Ignacio Mazzei, Ignacio Colombetti, Fabian Silva,
--     BPF, Liam). Ninguna variante de Lucas ni de Ivan.
select l.closer, count(*) as filas
  from public.fin_llamadas l
 where l.cliente_id = 'liam' and btrim(coalesce(l.closer, '')) <> ''
   and public.fin_data_closer_mapa_base('liam') ->> lower(btrim(l.closer)) is null
 group by l.closer order by count(*) desc, l.closer;

-- C3. Filas de liam por closer como se muestran, con total. Esperado: una sola
--     fila "Lucas Deza" y una sola "Ivan" (suman las variantes), y la fila
--     total igual a select count(*) from fin_llamadas where cliente_id = 'liam'.
select x.mostrado as closer_mostrado, count(*) as filas
  from (select coalesce(public.fin_data_closer_mapa_base('liam') ->> lower(btrim(l.closer)), l.closer) as mostrado
          from public.fin_llamadas l where l.cliente_id = 'liam') x
 group by rollup (x.mostrado) order by x.mostrado nulls last;

-- C4. Permisos y firmas. Esperado: 2 filas. fin_data_closer_mapa con
--     authenticated = true y anon = false; fin_data_closer_mapa_base con ambos false.
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
       has_function_privilege('anon', p.oid, 'execute') as anon
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('fin_data_closer_mapa', 'fin_data_closer_mapa_base')
 order by p.proname;
