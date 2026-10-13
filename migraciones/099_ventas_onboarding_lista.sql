-- =====================================================================
-- 099_ventas_onboarding_lista.sql  ·  VENTAS, pantalla "Onboarding"
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion). Numero
-- asignado por el jefe. Controles en 099b_ventas_onboarding_lista_control.sql
-- (consultas sueltas, de a una). Evitar los minutos :00, :15, :30 y :45.
--
-- Requiere: 093 y 096 de Producto (cs_onboardings, cs_clientes, cs_productos,
-- cs_ob_es_closer) y 097 (misma regla de busqueda de alumnos).
--
-- Que hace
--   Crea UNA funcion de solo lectura: cs_onboarding_lista_closer(p_programa).
--   Devuelve, del mas reciente al mas viejo (maximo 300), los alumnos del
--   programa que ya tienen link de onboarding generado. Nada mas:
--     alumno (nombre), telefono, producto, link_at, vence_at, estado
--   estado: sin_abrir | en_curso | completado | vencido  (vencido = no completado
--   y vence_at < now()). NO devuelve token, respuestas ni progreso. El telefono
--   va porque la pantalla busca por telefono y pide el link con
--   cs_onboarding_link_closer(programa, telefono, nombre).
--   Permiso: el mismo de cs_onboarding_link_estado_closer (cs_ob_es_closer:
--   rol ventas o closer asignado al cliente). Fundador: SIN_PERMISO (igual
--   que las otras cs_onboarding_*closer).
--
-- Que NO hace: no escribe nada, no crea tablas, no toca funciones existentes.
-- Re-ejecutable: create or replace. Si falla, el mensaje empieza con "ventas 099:".
-- =====================================================================

begin;

set local lock_timeout = '8s';

-- ---------------------------------------------------------------------
-- 0. DIAGNOSTICO Y GUARDAS
-- ---------------------------------------------------------------------
do $chk$
declare
  v_esperado_tablas  constant int := 3;
  v_tablas           int;
  v_falta            text;
begin
  select count(*) into v_tablas
    from (values ('public.cs_onboardings'), ('public.cs_clientes'), ('public.cs_productos')) r(t)
   where to_regclass(r.t) is not null;
  if v_tablas <> v_esperado_tablas then
    raise exception 'ventas 099: faltan tablas de Producto (hay % de %). Tienen que estar corridas la 093 y la 096.',
      v_tablas, v_esperado_tablas;
  end if;

  select string_agg(f, ', ' order by f) into v_falta
    from unnest(array['public.cs_ob_es_closer(text)', 'auth.uid()']) as f
   where to_regprocedure(f) is null;
  if v_falta is not null then
    raise exception 'ventas 099: faltan funciones: %. La 096 de Producto no esta aplicada.', v_falta;
  end if;

  raise notice 'ventas 099: diagnostico OK. Existe la funcion: %',
    (to_regprocedure('public.cs_onboarding_lista_closer(text)') is not null);
end
$chk$;

-- ---------------------------------------------------------------------
-- 1. FUNCION
-- ---------------------------------------------------------------------
create or replace function public.cs_onboarding_lista_closer(p_programa text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $fn$
declare
  v_limite constant int := 300;
begin
  if auth.uid() is null or not public.cs_ob_es_closer(p_programa) then
    raise exception 'SIN_PERMISO: no tenes permiso para este cliente' using errcode = '42501', hint = 'SIN_PERMISO';
  end if;

  return coalesce((
    select jsonb_agg(x.fila order by x.link_at desc, x.alumno)
      from (
        select o.created_at as link_at,
               c.nombre     as alumno,
               jsonb_build_object(
                 'alumno',   c.nombre,
                 'telefono', c.telefono,
                 'producto', pr.nombre,
                 'link_at',  o.created_at,
                 'vence_at', o.vence_at,
                 'estado',   case
                               when o.estado = 'completado' then 'completado'
                               when o.vence_at < now()      then 'vencido'
                               when o.estado = 'en_curso'   then 'en_curso'
                               else 'sin_abrir'
                             end) as fila
          from public.cs_onboardings o
          join public.cs_clientes c  on c.id = o.cliente_id and c.programa_id = o.programa_id
          left join public.cs_productos pr on pr.id = c.producto_id
         where o.programa_id = p_programa
         order by o.created_at desc, c.nombre
         limit v_limite
      ) x
  ), '[]'::jsonb);
end;
$fn$;

revoke all on function public.cs_onboarding_lista_closer(text) from public, anon, authenticated;
grant execute on function public.cs_onboarding_lista_closer(text) to authenticated;

commit;
