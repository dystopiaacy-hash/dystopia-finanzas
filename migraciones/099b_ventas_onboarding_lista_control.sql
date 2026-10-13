-- =====================================================================
-- 099b_ventas_onboarding_lista_control.sql  ·  controles de la 099
-- =====================================================================
-- Consultas sueltas, de a una, en el SQL Editor. Solo lectura.

-- C1. La funcion existe, es security definer y no la ejecuta anon.
--     Esperado: 1 fila, security_definer = true, anon = false, authenticated = true.
select p.proname,
       p.prosecdef as security_definer,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.proname = 'cs_onboarding_lista_closer';

-- C2. Cuantos links hay por programa y estado (misma regla que la funcion).
--     Esperado: liam con las cantidades que ya conoce Producto; sin filas raras.
select o.programa_id,
       case when o.estado = 'completado' then 'completado'
            when o.vence_at < now() then 'vencido'
            when o.estado = 'en_curso' then 'en_curso'
            else 'sin_abrir' end as estado,
       count(*) as n
  from public.cs_onboardings o
 group by 1, 2
 order by 1, 2;

-- C3. Ningun onboarding queda afuera por el join con cs_clientes.
--     Esperado: 0.
select count(*) as sin_alumno
  from public.cs_onboardings o
  left join public.cs_clientes c on c.id = o.cliente_id and c.programa_id = o.programa_id
 where c.id is null;

-- C4. Desde la app (no se puede probar con auth.uid() en el editor): entrar con
--     ventas@liam.dystopia y abrir Onboarding. La lista debe traer los de C2 de
--     liam (hasta 300). Con el fundador debe decir que no tiene permiso.
