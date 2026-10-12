-- =====================================================================
-- 085_ventas_liam_closers_lista.sql  -  VENTAS: desplegable de closers de Liam
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion), DESPUES
-- de la 084. Es un unico bloque DO: o queda todo o no queda nada.
-- Re-ejecutable. No toca la sync de Sheets, ni otros clientes, ni filas de
-- fin_llamadas (las filas viejas con closer "BPF" siguen mostrando "BPF").
-- Archivo ASCII. Evitar :00, :15, :30 y :45.
--
-- Los controles NO van aca: estan en 085b_ventas_liam_closers_control.sql,
-- una consulta suelta por vez.
--
-- Que hace:
--   0. Diagnostico de solo lectura (RAISE NOTICE) y guardas.
--   1. "BPF" es el nombre del programa, no un closer: deja de ofrecerse
--      (fin_personas.lista_closers = false para los alias de BPF de liam).
--      La persona/alias NO se borra: sigue atribuyendo.
--   2. fin_data_closers_de devuelve la lista en este orden: Lucas Deza, Ivan,
--      y despues los que se agregaron a mano (en orden de alta). La opcion
--      "+ Agregar nuevo" la pone el front al final.
-- =====================================================================

do $m085$
declare
  v_bpf_vend  bigint[];
  v_n         bigint;
  v_listados  text[];
begin
  perform set_config('lock_timeout', '8s', true);

  -- ===================================================================
  -- 0. DIAGNOSTICO (solo lectura) Y GUARDAS
  -- ===================================================================
  if to_regclass('public.fin_personas') is null
     or to_regclass('public.fin_vendedores') is null
     or to_regprocedure('public.fin_data_closers_de(text)') is null
     or to_regprocedure('public.fin_data_closer_agregar(text, text)') is null
     or to_regprocedure('public.fin_data_es_ventas(text)') is null
     or to_regprocedure('public.fin_normalizar_nombre(text)') is null then
    raise exception '085 ABORTADA: faltan funciones de la 077/084. Correr primero la 084.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fin_personas' and column_name = 'lista_closers') then
    raise exception '085 ABORTADA: fin_personas.lista_closers no existe (falta la 077).';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'liam') then
    raise exception '085 ABORTADA: el cliente liam no existe en crm_clients.';
  end if;

  select array_agg(btrim(alias) order by alias) into v_listados
    from public.fin_personas
   where cliente_id = 'liam' and lista_closers and (campo is null or campo in ('closer', 'ambos'));
  raise notice '085 diag: closers listados hoy en liam: %', coalesce(v_listados::text, '{}');

  -- ===================================================================
  -- 1. BPF DEJA DE OFRECERSE COMO CLOSER (solo liam)
  -- ===================================================================
  select coalesce(array_agg(v.id), '{}'::bigint[]) into v_bpf_vend
    from public.fin_vendedores v
   where v.nombre_norm = public.fin_normalizar_nombre('BPF');

  update public.fin_personas p
     set lista_closers = false
   where p.cliente_id = 'liam'
     and p.lista_closers
     and (public.fin_normalizar_nombre(p.alias) = public.fin_normalizar_nombre('BPF')
          or p.vendedor_id = any (v_bpf_vend));
  get diagnostics v_n = row_count;
  raise notice '085: % alias de BPF dejaron de ofrecerse como closer en liam', v_n;

  -- ===================================================================
  -- 2. ORDEN DE LA LISTA: Lucas Deza, Ivan, despues los agregados a mano
  -- ===================================================================
  -- Misma firma, mismo tipo de retorno y mismos permisos que la 077
  -- (create or replace los conserva). Solo cambia el orden del jsonb_agg.
  execute $q$
    create or replace function public.fin_data_closers_de(p_cliente text)
    returns jsonb
    language sql stable security definer set search_path = public
    as $fn$
      select coalesce(jsonb_agg(x.a order by x.rk, x.pid), '[]'::jsonb)
      from (
        select distinct on (coalesce(p.vendedor_id::text, lower(btrim(p.alias))))
               btrim(p.alias) as a,
               p.id as pid,
               case public.fin_normalizar_nombre(p.alias)
                 when 'lucas deza' then 1
                 when 'ivan'       then 2
                 else 3
               end as rk
          from public.fin_personas p
          left join public.fin_vendedores v on v.id = p.vendedor_id
         where p.cliente_id = p_cliente
           and (p.campo is null or p.campo in ('closer', 'ambos'))
           and p.lista_closers
           and (public.es_fundador() or public.fin_data_es_ventas(p_cliente))
         order by coalesce(p.vendedor_id::text, lower(btrim(p.alias))),
                  (public.fin_normalizar_nombre(p.alias) = v.nombre_norm) desc,
                  char_length(btrim(p.alias)) desc, p.id
      ) x
    $fn$
  $q$;

  -- ===================================================================
  -- 3. AUTOVERIFICACION (si algo no cierra, aborta y no queda nada)
  -- ===================================================================
  select array_agg(public.fin_normalizar_nombre(alias)) into v_listados
    from public.fin_personas
   where cliente_id = 'liam' and lista_closers and (campo is null or campo in ('closer', 'ambos'));
  if not (array['ivan', 'lucas deza']::text[] <@ coalesce(v_listados, '{}'::text[])) then
    raise exception '085 ABORTADA: la lista de closers de liam no tiene a Ivan y Lucas Deza (tiene: %)', v_listados;
  end if;
  if 'bpf' = any (coalesce(v_listados, '{}'::text[])) then
    raise exception '085 ABORTADA: BPF sigue en la lista de closers de liam';
  end if;
  if public.fin_data_closer_canonico('liam', 'Ivan Binsztein') is distinct from 'Ivan' then
    raise exception '085 ABORTADA: "Ivan Binsztein" ya no se lee como "Ivan"';
  end if;

  raise notice '085 OK';
end
$m085$;
