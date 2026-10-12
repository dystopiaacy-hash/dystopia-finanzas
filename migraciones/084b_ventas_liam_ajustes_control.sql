-- =====================================================================
-- 084b_ventas_liam_ajustes_control.sql  -  CONTROLES de la 084
-- =====================================================================
-- Solo lectura. Correr DESPUES de la 084, UNA consulta por vez (el editor de
-- Supabase solo muestra el resultado de la ultima). Cada una esta separada
-- por una linea en blanco y se puede copiar y pegar sola.
-- =====================================================================

-- C1. No tiene que haber filas de liam en SEGUIMIENTO CUOTAS (esperado: 0).
select count(*) as filas_seguimiento_cuotas
  from public.fin_llamadas
 where cliente_id = 'liam' and upper(btrim(estado_llamada)) = 'SEGUIMIENTO CUOTAS';

-- C2. Clasificacion real de los estados de seguimiento de liam. Esperado:
--     EN SEGUIMIENTO con cerradas = 0; ADENTRO EN SEGUIMIENTO con cerradas = filas.
select estado_llamada, count(*) as filas, count(*) filter (where es_cerrada) as cerradas
  from public.fin_v_llamadas_clasificadas
 where cliente_id = 'liam' and estado_llamada in ('EN SEGUIMIENTO', 'ADENTRO EN SEGUIMIENTO', 'SEGUIMIENTO CUOTAS')
 group by 1 order by 1;

-- C3. Catalogo de estados de liam: EN SEGUIMIENTO activo, SEGUIMIENTO CUOTAS inactivo.
select valor, activo, orden
  from public.fin_catalogos
 where cliente_id = 'liam' and dimension = 'estado'
 order by orden, valor;

-- C4. Closers que ofrece el desplegable de liam (lista_closers = true).
--     Esperado: Ivan y Lucas Deza (y BPF, mas los que se agreguen desde la app).
select p.alias, p.campo, v.nombre as vendedor, p.lista_closers
  from public.fin_personas p
  left join public.fin_vendedores v on v.id = p.vendedor_id
 where p.cliente_id = 'liam' and p.lista_closers
 order by p.alias;

-- C5. Una fila vieja "Ivan Binsztein" se lee como "Ivan" (esperado: Ivan) y
--     Matias Ortuno no es closer de la lista (esperado: null).
select public.fin_data_closer_canonico('liam', 'Ivan Binsztein') as ivan_binsztein,
       public.fin_data_closer_canonico('liam', U&'Mat\00EDas Ortu\00F1o') as matias;

-- C6. Las funciones nuevas existen (esperado: 1 fila; execute para authenticated).
select p.proname, has_function_privilege('authenticated', p.oid, 'execute') as authenticated_ejecuta
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'fin_data_closer_agregar';

-- C7. Politicas de lectura que se le abrieron al rol ventas (solo select).
--     Esperado: todas con cmd = SELECT.
select tablename, policyname, cmd
  from pg_policies
 where schemaname = 'public' and policyname like '%\_lectura\_ventas\_dash'
 order by tablename;

-- C8. El rol ventas no tiene ninguna politica de escritura nueva (esperado: 0).
select count(*) as politicas_escritura_ventas_dash
  from pg_policies
 where schemaname = 'public' and policyname like '%\_lectura\_ventas\_dash' and cmd <> 'SELECT';

-- C9. Las otras clientes no se tocaron: sus estados siguen igual (solo informativo).
select cliente_id, count(*) filter (where upper(btrim(estado_llamada)) = 'SEGUIMIENTO CUOTAS') as seguimiento_cuotas
  from public.fin_llamadas
 group by 1 order by 1;
