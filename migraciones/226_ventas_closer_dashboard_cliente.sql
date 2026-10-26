-- =====================================================================
-- 226_ventas_closer_dashboard_cliente.sql
-- El closer ve en el Dashboard las metricas del CLIENTE ENTERO de los
-- clientes que tiene asignados (crm_asignaciones), igual que el rol ventas.
--
-- COMO: dos RPC security definer que devuelven AGREGADOS, sin abrir
-- fin_llamadas ni fin_cierres (la RLS de esas tablas no se toca):
--   1. fin_ventas_metricas_closer()  -> las mismas filas de
--      fin_v_metricas_ventas (una por cliente y mes, solo conteos y sumas),
--      para los clientes asignados al closer.
--   2. fin_ventas_cierres_closer()   -> los cierres de fin_cierres SIN la
--      columna nombre (la persona que compro), para los asignados.
-- Devuelven jsonb (to_jsonb de la fila): si la vista cambia de columnas, la
-- funcion no se rompe ni se borra con un drop cascade de la vista.
-- Solo responden para rol_actual() = 'closer'; para cualquier otro rol (o
-- un closer sin asignaciones) devuelven 0 filas. Los otros roles siguen
-- leyendo las vistas/tablas directo, como hasta hoy.
--
-- QUE QUEDA VISIBLE de otros closers: NADA con nombre. La vista agrupa por
-- cliente y mes (no trae closer, setter ni comision). Un closer ve cuantas
-- cerradas y cuanto cash tuvo el cliente en total, no quien las cerro.
-- fin_cierres no tiene columna de closer; se omite "nombre" (comprador).
--
-- Requiere: fin_v_metricas_ventas (030+), fin_cierres (121), rol_actual(),
-- fin_asignado() (075).
-- No toca: fin_llamadas, fin_cierres, politicas, comisiones, proyeccion.
-- =====================================================================

begin;
set local lock_timeout = '5s';

-- ---- Guardas ----
do $$
begin
  if to_regclass('public.fin_v_metricas_ventas') is null then
    raise exception '226: falta fin_v_metricas_ventas';
  end if;
  if to_regclass('public.fin_cierres') is null then
    raise exception '226: falta fin_cierres (migracion 121)';
  end if;
  if to_regprocedure('public.rol_actual()') is null then
    raise exception '226: falta rol_actual()';
  end if;
  if to_regprocedure('public.fin_asignado(text)') is null then
    raise exception '226: falta fin_asignado (migracion 075)';
  end if;
  if to_regprocedure('public.fin_ventas_metricas_closer()') is not null
     or to_regprocedure('public.fin_ventas_cierres_closer()') is not null then
    raise exception '226: ya existe fin_ventas_metricas_closer o fin_ventas_cierres_closer';
  end if;
end $$;

-- ---- 1. Metricas por cliente y mes ----
create function public.fin_ventas_metricas_closer()
returns setof jsonb
language sql stable security definer set search_path = ''
as $$
  select to_jsonb(m)
  from public.fin_v_metricas_ventas m
  where public.rol_actual() = 'closer'
    and public.fin_asignado(m.cliente_id)
  order by m.cliente_id, m.periodo;
$$;

-- ---- 2. Cierres (sin nombre del comprador) ----
create function public.fin_ventas_cierres_closer()
returns table (
  cliente_id text, fecha_cierre date, estado text, cash_dia1 numeric,
  trato_cerrado numeric, producto text, fuente text, estructura_pago text
)
language sql stable security definer set search_path = ''
as $$
  select c.cliente_id, c.fecha_cierre, c.estado, c.cash_dia1,
         c.trato_cerrado, c.producto, c.fuente, c.estructura_pago
  from public.fin_cierres c
  where public.rol_actual() = 'closer'
    and public.fin_asignado(c.cliente_id)
  order by c.id;
$$;

revoke all on function public.fin_ventas_metricas_closer() from public, anon;
revoke all on function public.fin_ventas_cierres_closer()  from public, anon;
grant execute on function public.fin_ventas_metricas_closer() to authenticated;
grant execute on function public.fin_ventas_cierres_closer()  to authenticated;

commit;


-- =====================================================================
-- CONTROLES (de a uno, en el SQL Editor; no modifican nada)
-- =====================================================================

-- C1. Las dos funciones existen, son security definer y no estan abiertas a anon.
--   select p.proname, p.prosecdef,
--          has_function_privilege('anon', p.oid, 'execute') as anon,
--          has_function_privilege('authenticated', p.oid, 'execute') as auth
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname in ('fin_ventas_metricas_closer', 'fin_ventas_cierres_closer');
--   -- esperado: 2 filas, prosecdef = true, anon = false, auth = true

-- C2. Closer simulado: ve los totales de SU cliente asignado y de ningun otro.
--     Reemplazar <UID_CLOSER> por el user_id de un closer con asignacion
--     (o crear uno de prueba y asignarlo a mano; el rol sale de crm_members).
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UID_CLOSER>', 'role', 'authenticated')::text, true);
--   select m->>'cliente_id' as cliente, count(*) as meses, sum((m->>'agendadas')::int) as agendadas
--   from public.fin_ventas_metricas_closer() m group by 1 order by 1;
--   -- esperado: solo los clientes de sus crm_asignaciones
--   select distinct cliente_id from public.fin_ventas_cierres_closer();
--   -- esperado: solo clientes asignados (o 0 filas)
--   rollback;

-- C3. Esos totales son los mismos que ve ventas para el mismo cliente. Con el
--     usuario ventas asignado (p. ej. "Ventas BPF" de liam), SU lectura:
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UID_VENTAS>', 'role', 'authenticated')::text, true);
--   select cliente_id, periodo, agendadas, cerradas, cc_cobrado_data
--   from public.fin_v_metricas_ventas where cliente_id = 'liam' order by periodo desc limit 3;
--   rollback;
--   -- Comparar contra la misma consulta del closer asignado a liam (C2, filtrando
--   -- m->>'cliente_id' = 'liam'). Para probar sin closer real: asignar el closer
--   -- de prueba a liam en crm_asignaciones y borrarlo al terminar.

-- C4. Un closer NO ve el cliente de otro: con el closer simulado de C2,
--     fin_ventas_metricas_closer() no debe traer ningun cliente fuera de sus asignaciones.
--   (la misma consulta de C2; comparar contra crm_asignaciones del usuario)

-- C5. Los demas roles no cambian: ventas, finanzas y cliente reciben 0 filas de
--     estas RPC (siguen leyendo las vistas) y fin_llamadas/fin_cierres no tienen
--     politicas nuevas.
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims',
--     json_build_object('sub', '<UID_VENTAS>', 'role', 'authenticated')::text, true);
--   select count(*) from public.fin_ventas_metricas_closer();   -- esperado 0
--   select count(*) from public.fin_ventas_cierres_closer();    -- esperado 0
--   rollback;
--   select policyname from pg_policies
--   where tablename in ('fin_llamadas', 'fin_cierres') order by 1;  -- mismas que antes de la 226

-- C6. Anon no puede llamarlas:
--   begin; set local role anon; select * from public.fin_ventas_metricas_closer(); rollback;
--   -- esperado: permission denied for function


-- =====================================================================
-- VUELTA ATRAS (comentada)
-- =====================================================================
--   begin;
--   drop function if exists public.fin_ventas_metricas_closer();
--   drop function if exists public.fin_ventas_cierres_closer();
--   commit;
