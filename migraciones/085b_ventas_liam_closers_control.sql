-- =====================================================================
-- 085b_ventas_liam_closers_control.sql  -  CONTROLES de la 085
-- =====================================================================
-- Solo lectura. Correr DESPUES de la 085, UNA consulta por vez (el editor de
-- Supabase solo muestra el resultado de la ultima). Cada una esta separada
-- por una linea en blanco y se puede copiar y pegar sola.
-- =====================================================================

-- C1. Closers que ofrece el desplegable de liam, en el orden del desplegable.
--     Esperado: Lucas Deza, Ivan (y despues los agregados a mano). Sin BPF.
select p.alias, p.campo, p.lista_closers
  from public.fin_personas p
 where p.cliente_id = 'liam' and p.lista_closers
   and (p.campo is null or p.campo in ('closer', 'ambos'))
 order by case public.fin_normalizar_nombre(p.alias) when 'lucas deza' then 1 when 'ivan' then 2 else 3 end, p.id;

-- C2. BPF ya no esta ofrecido (esperado: 0).
select count(*) as bpf_ofrecido
  from public.fin_personas p
  left join public.fin_vendedores v on v.id = p.vendedor_id
 where p.cliente_id = 'liam' and p.lista_closers
   and (public.fin_normalizar_nombre(p.alias) = public.fin_normalizar_nombre('BPF')
        or v.nombre_norm = public.fin_normalizar_nombre('BPF'));

-- C3. Las filas viejas con closer BPF siguen intactas (informativo: debe dar el
--     mismo numero que antes de la 085; no se cambio ninguna fila de fin_llamadas).
select closer, count(*) as filas
  from public.fin_llamadas
 where cliente_id = 'liam' and upper(btrim(closer)) = 'BPF'
 group by 1 order by 1;

-- C4. La funcion sigue con sus permisos (esperado: 1 fila, authenticated_ejecuta = true,
--     anon_ejecuta = false).
select p.proname,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_ejecuta,
       has_function_privilege('anon', p.oid, 'execute') as anon_ejecuta
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'fin_data_closers_de';

-- C5. Una fila vieja "Ivan Binsztein" se sigue leyendo como "Ivan" (esperado: Ivan)
--     y BPF ya no es un closer valido para guardar (esperado: null).
select public.fin_data_closer_canonico('liam', 'Ivan Binsztein') as ivan_binsztein,
       public.fin_data_closer_canonico('liam', 'BPF') as bpf;
