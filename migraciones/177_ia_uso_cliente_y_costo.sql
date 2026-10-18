-- 177_ia_uso_cliente_y_costo.sql  (numero asignado por el jefe)
-- Corrige filas viejas de public.ia_uso (SIN CORRER; Joaquin la corre a mano).
-- El codigo nuevo (supabase/functions/_shared/ia.ts, clienteParaUso) ya escribe cliente_id = liam|agus|teo|dystopia.
--
-- QUE HACE (un solo bloque, atomico):
--   A. cliente_id de las funciones de ESTA app (app finanzas: leer_comprobante, lectura_mensual;
--      app ventas: calificacion_leads, analisis_llamada, devolucion_semanal): minusculas y sin espacios;
--      si no es liam/agus/teo pasa a 'dystopia'. Estas funciones siempre recibieron el cliente_id de las
--      tablas fin_* (fin_comprobantes, fin_lecturas_mes, fin_leads_*, fin_llamadas/fin_devoluciones_closer),
--      que ya es texto 'liam'/'agus'/'teo': aca solo cambian filas con mayusculas, espacios o null.
--      Filas de otras funciones (por ejemplo ventas / chat_interno con cliente_id null, que escribe
--      ia-preguntar en otro repo) NO se tocan: la vista de la 174 ya las manda a Dystopia.
--   B. costo_usd = 0 o null con tokens guardados, SOLO modelos Claude con precio conocido (todas las apps):
--      claude-haiku-5-5 0,10/0,50 por M (si entrada > 100K: 0,50/2,50), claude-sonnet-5-5 2/10,
--      claude-haiku-4-5 y claude-haiku-4-5-20251001 1/5. Gemini NO se recalcula (precio por audio/imagen
--      y no se guarda el tipo de token): quedan como estan.
--   Respaldo: tabla ia_uso_bak_177 (id, cliente_id y costo_usd viejos) con RLS sin policies.
--
-- Depende de: 137 (ia_uso). Guarda: ia_uso debe tener columna id (para poder volver atras).
-- No correr a las :00/:15/:30/:45.

do $m177$
declare
  v_a int; v_b int; v_ids int;
begin
  if to_regclass('public.ia_uso') is null then raise exception 'GUARDA 177: falta ia_uso (137)'; end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='ia_uso' and column_name='id') then
    raise exception 'GUARDA 177: ia_uso no tiene columna id; sin ella no hay vuelta atras. Mirar select * from ia_uso limit 1 y pedir otra version';
  end if;
  if to_regclass('public.ia_uso_bak_177') is not null then
    raise exception 'GUARDA 177: ya existe ia_uso_bak_177 (ya se corrio). Para repetir, primero la vuelta atras del final';
  end if;

  create table public.ia_uso_bak_177 as
    select u.id, u.cliente_id, u.costo_usd, now() as respaldado_en
    from public.ia_uso u
    where (
        (u.app, u.funcion) in (('finanzas','leer_comprobante'),('finanzas','lectura_mensual'),
          ('ventas','calificacion_leads'),('ventas','analisis_llamada'),('ventas','devolucion_semanal'))
        and u.cliente_id is distinct from
            (case when lower(btrim(u.cliente_id::text)) in ('liam','agus','teo') then lower(btrim(u.cliente_id::text)) else 'dystopia' end)
      )
      or (coalesce(u.costo_usd,0) = 0 and u.tokens_entrada is not null and u.tokens_salida is not null
          and u.modelo in ('claude-haiku-5-5','claude-sonnet-5-5','claude-haiku-4-5','claude-haiku-4-5-20251001'));
  alter table public.ia_uso_bak_177 enable row level security;
  revoke all on public.ia_uso_bak_177 from public, anon, authenticated;
  select count(*) into v_ids from public.ia_uso_bak_177;

  -- A. cliente
  update public.ia_uso u
     set cliente_id = case when lower(btrim(u.cliente_id::text)) in ('liam','agus','teo') then lower(btrim(u.cliente_id::text)) else 'dystopia' end
   where (u.app, u.funcion) in (('finanzas','leer_comprobante'),('finanzas','lectura_mensual'),
          ('ventas','calificacion_leads'),('ventas','analisis_llamada'),('ventas','devolucion_semanal'))
     and u.cliente_id is distinct from
         (case when lower(btrim(u.cliente_id::text)) in ('liam','agus','teo') then lower(btrim(u.cliente_id::text)) else 'dystopia' end);
  get diagnostics v_a = row_count;

  -- B. costo
  update public.ia_uso u
     set costo_usd = round(((u.tokens_entrada * p.ent + u.tokens_salida * p.sal) / 1000000.0)::numeric, 6)
    from (select m.modelo,
                 m.ent, m.sal from (values
                   ('claude-haiku-5-5', 0.10, 0.50), ('claude-sonnet-5-5', 2.0, 10.0),
                   ('claude-haiku-4-5', 1.0, 5.0), ('claude-haiku-4-5-20251001', 1.0, 5.0)) as m(modelo, ent, sal)) p
   where u.modelo = p.modelo and coalesce(u.costo_usd,0) = 0
     and u.tokens_entrada is not null and u.tokens_salida is not null
     and not (u.modelo = 'claude-haiku-5-5' and u.tokens_entrada > 100000);
  get diagnostics v_b = row_count;
  -- Haiku 5.5 con mas de 100K de entrada: tarifa alta de todo el pedido
  update public.ia_uso u
     set costo_usd = round(((u.tokens_entrada * 0.50 + u.tokens_salida * 2.50) / 1000000.0)::numeric, 6)
   where u.modelo = 'claude-haiku-5-5' and coalesce(u.costo_usd,0) = 0
     and u.tokens_entrada > 100000 and u.tokens_salida is not null;

  raise notice '177: respaldadas % filas; cliente corregido en %; costo recalculado en % (mas las de Haiku >100K)', v_ids, v_a, v_b;
end
$m177$;

-- CONTROLES (correr DE A UNO, descomentando):
-- C1. Filas de nuestras funciones que no quedaron en liam/agus/teo/dystopia (debe dar 0):
-- select count(*) from public.ia_uso where (app, funcion) in (('finanzas','leer_comprobante'),('finanzas','lectura_mensual'),('ventas','calificacion_leads'),('ventas','analisis_llamada'),('ventas','devolucion_semanal')) and cliente_id not in ('liam','agus','teo','dystopia');
-- C2. Cliente por app/funcion (mirar que no haya UUID ni null en las nuestras):
-- select app, funcion, cliente_id, count(*) from public.ia_uso group by 1,2,3 order by 1,2,3;
-- C3. Filas Claude con costo 0/null que siguen (deberian ser solo las sin tokens, es decir con ok=false):
-- select ok, count(*) from public.ia_uso where coalesce(costo_usd,0)=0 and modelo like 'claude-%' group by 1;
-- C4. Gasto por mes, modelo y cliente (octubre deberia acercarse al gasto real):
-- select to_char(creado_en at time zone 'America/Argentina/Buenos_Aires','YYYY-MM') mes, modelo, cliente_id, count(*) n, round(sum(costo_usd)::numeric,2) usd from public.ia_uso group by 1,2,3 order by 1 desc,2,3;
-- C5. Gemini con costo 0/null (no recalculado, hay que mirar a mano):
-- select app, funcion, modelo, count(*) from public.ia_uso where modelo like 'gemini%' and coalesce(costo_usd,0)=0 group by 1,2,3;
-- C6. Filas respaldadas:
-- select count(*) from public.ia_uso_bak_177;

-- VUELTA ATRAS (descomentar y correr):
-- update public.ia_uso u set cliente_id = b.cliente_id, costo_usd = b.costo_usd from public.ia_uso_bak_177 b where b.id = u.id;
-- drop table public.ia_uso_bak_177;
