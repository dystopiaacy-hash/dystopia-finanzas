-- =====================================================================
-- 087b_ventas_liam_unificar_lucas_control.sql  -  CONTROLES de la 087
-- =====================================================================
-- Solo lectura. Correr DESPUES de la 087, UNA consulta por vez (el editor de
-- Supabase solo muestra el resultado de la ultima). Cada una esta separada
-- por una linea en blanco y se puede copiar y pegar sola.
-- =====================================================================

-- C1. Alias de Lucas en liam. Esperado: 2 filas (o mas si hay otros alias de la
--     misma persona), todas con el mismo vendedor; "Lucas Deza" lista_closers = true
--     y "LUCAS" lista_closers = false. Un solo true en total.
select p.id, p.alias, p.campo, p.lista_closers, v.nombre as vendedor
  from public.fin_personas p
  left join public.fin_vendedores v on v.id = p.vendedor_id
 where p.cliente_id = 'liam'
   and (lower(btrim(p.alias)) in ('lucas', 'lucas deza') or v.nombre_norm = public.fin_normalizar_nombre('Lucas Deza'))
 order by p.id;

-- C2. Closers que ofrece el desplegable de liam, en orden. Esperado: Lucas Deza,
--     Ivan (y despues los agregados a mano). Sin "LUCAS" ni "LUCAS DEZA".
select p.alias, p.campo, p.lista_closers
  from public.fin_personas p
 where p.cliente_id = 'liam' and p.lista_closers
   and (p.campo is null or p.campo in ('closer', 'ambos'))
 order by case public.fin_normalizar_nombre(p.alias) when 'lucas deza' then 1 when 'ivan' then 2 else 3 end, p.id;

-- C3. Como se leen las filas viejas. Esperado: lucas = Lucas Deza,
--     lucas_deza = Lucas Deza, ivan_binsztein = Ivan.
select public.fin_data_closer_canonico('liam', 'LUCAS') as lucas,
       public.fin_data_closer_canonico('liam', 'LUCAS DEZA') as lucas_deza,
       public.fin_data_closer_canonico('liam', 'Ivan Binsztein') as ivan_binsztein;

-- C4. Misma persona para comisiones y dashboard. Esperado: vendedores = 1 y
--     sin_vendedor = 0.
select count(distinct p.vendedor_id) as vendedores,
       count(*) filter (where p.vendedor_id is null) as sin_vendedor
  from public.fin_personas p
 where p.cliente_id = 'liam' and lower(btrim(p.alias)) in ('lucas', 'lucas deza');

-- C5. Filas viejas intactas (informativo: mismas filas por closer que antes de la
--     087; la 087 no toca fin_llamadas). La columna se_lee_como es el nombre que
--     se guarda si se edita la fila.
select l.closer, count(*) as filas,
       public.fin_data_closer_canonico('liam', l.closer) as se_lee_como
  from public.fin_llamadas l
 where l.cliente_id = 'liam' and lower(btrim(l.closer)) in ('lucas', 'lucas deza')
 group by l.closer order by l.closer;
