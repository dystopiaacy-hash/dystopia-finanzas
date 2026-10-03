-- =====================================================================
-- 074_ventas_columnas_acentos.sql  -  VENTAS: arreglo de la 073
-- =====================================================================
-- Correr COMPLETO en el SQL Editor de Supabase (una sola ejecucion).
-- Archivo 100% ASCII: los acentos van como escapes U&'...\00F3...', asi
-- que no se rompen aunque se copie con otra codificacion.
--
-- Por que: la 073 se copio al portapapeles desde PowerShell sin
-- -Encoding UTF8 y los acentos llegaron rotos a la base
-- (Calificacion, CC dia 1 y Telefono con caracteres raros).
--
-- Que hace:
--   1. fin_data_etiqueta_defecto: los 3 nombres por defecto, bien.
--   2. fin_data_columna_crear: la limpieza de acentos del nombre interno
--      (clave x_...) vuelve a funcionar. Las claves ya creadas no cambian.
--   3. fin_data_opcion_renombrar: renombrar una opcion a otra que ya
--      existe da error en vez de fusionarlas sin avisar.
--   4. Borra las columnas de prueba "ZZ prueba..." de liam (archivadas,
--      sin ningun valor cargado) y devuelve a "por defecto" los nombres
--      del sistema que quedaron iguales al de fabrica o rotos.
--
-- No toca: llamadas, la sync, las metricas, la configuracion real.
-- Se puede correr dos veces.
-- =====================================================================

begin;

set local lock_timeout = '8s';


-- =====================================================================
-- 1. NOMBRES POR DEFECTO
-- =====================================================================
create or replace function public.fin_data_etiqueta_defecto(p_clave text)
returns text
language sql immutable parallel safe set search_path = public
as $$
  select case p_clave
    when 'fecha_llamada'   then 'Fecha'
    when 'hora_llamada'    then 'Hora'
    when 'nombre'          then 'Nombre'
    when 'closer'          then 'Closer'
    when 'tipo_booking'    then 'Fuente'
    when 'show_up'         then 'Show up'
    when 'calificacion'    then U&'Calificaci\00F3n'
    when 'estado_llamada'  then 'Estado'
    when 'programa'        then 'Programa'
    when 'cc_dia1'         then U&'CC d\00EDa 1'
    when 'cc_cerrado'      then 'CC cerrado'
    when 'cc_seguimiento'  then 'CC seguimiento'
    when 'monto_restante'  then 'Monto restante'
    when 'telefono'        then U&'Tel\00E9fono'
    when 'instagram'       then 'Instagram'
    when 'email'           then 'Email'
    when 'contexto_setter' then 'Contexto setter'
    when 'contexto_closer' then 'Contexto closer'
  end
$$;


-- =====================================================================
-- 2. COLUMNA NUEVA (mismo cuerpo que la 073, con la limpieza en ASCII)
-- =====================================================================
create or replace function public.fin_data_columna_crear(
  p_cliente  text,
  p_etiqueta text,
  p_tipo     text,
  p_opciones jsonb default '[]'::jsonb
)
returns text
language plpgsql security definer set search_path = public
as $fn$
declare
  v_et    text := nullif(btrim(coalesce(p_etiqueta, '')), '');
  v_slug  text;
  v_clave text;
  v_orden int;
begin
  perform public.fin_data_exigir_fundador();
  perform public.fin_data_cliente_ok(p_cliente);
  if not public.fin_data_admite_nuevas(p_cliente) then
    raise exception 'ventas: % no admite columnas nuevas', p_cliente using errcode = '22023';
  end if;
  if v_et is null then
    raise exception 'ventas: la columna necesita nombre' using errcode = '22023';
  end if;
  if p_tipo is null or p_tipo not in ('texto','numero','fecha','casilla','opcion','link') then
    raise exception 'ventas: tipo de columna invalido (%)', p_tipo using errcode = '22023';
  end if;

  v_slug := left(trim(both '_' from regexp_replace(
              translate(lower(v_et), U&'\00E1\00E9\00ED\00F3\00FA\00F1\00FC', 'aeiounu'), '[^a-z0-9]+', '_', 'g')), 40);
  if v_slug = '' then v_slug := 'col'; end if;
  v_clave := 'x_' || v_slug || '_' || substr(md5(random()::text || clock_timestamp()::text), 1, 4);

  -- Al final: despues de la ultima guardada y de la ultima del sistema
  -- (posicion x 10), aunque nada se haya guardado todavia.
  select greatest(coalesce(max(orden), 0),
                  cardinality(public.fin_data_claves_sistema()) * 10) + 10
    into v_orden
  from public.fin_data_columnas where cliente_id = p_cliente;

  insert into public.fin_data_columnas (cliente_id, clave, sistema, etiqueta, orden, tipo, opciones, creado_por)
  values (p_cliente, v_clave, false, v_et, v_orden, p_tipo,
          case when p_tipo = 'opcion' then public.fin_data_opciones_limpias(coalesce(p_opciones, '[]'::jsonb))
               else '[]'::jsonb end,
          auth.uid());
  return v_clave;
end;
$fn$;


-- =====================================================================
-- 3. RENOMBRAR OPCION: sin fusiones silenciosas
-- =====================================================================
create or replace function public.fin_data_opcion_renombrar(
  p_cliente text, p_clave text, p_viejo text, p_nuevo text)
returns int
language plpgsql security definer set search_path = public
as $fn$
declare
  v_col   public.fin_data_columnas%rowtype;
  v_nuevo text := btrim(coalesce(p_nuevo, ''));
  v_n     int;
begin
  perform public.fin_data_exigir_fundador();
  select * into v_col from public.fin_data_columnas
  where cliente_id = p_cliente and clave = p_clave and not sistema and tipo = 'opcion';
  if v_col.id is null then
    raise exception 'ventas: % no es una columna nueva de opciones', p_clave using errcode = 'P0002';
  end if;
  if v_nuevo = '' then
    raise exception 'ventas: la opcion necesita nombre' using errcode = '22023';
  end if;
  if not (v_col.opciones ? p_viejo) then
    raise exception 'ventas: la opcion "%" no existe', p_viejo using errcode = 'P0002';
  end if;
  if v_nuevo <> p_viejo and v_col.opciones ? v_nuevo then
    raise exception 'ventas: ya existe la opcion "%"', v_nuevo using errcode = '22023';
  end if;

  update public.fin_data_columnas
     set opciones = public.fin_data_opciones_limpias(
                      (select jsonb_agg(case when e = p_viejo then v_nuevo else e end order by o)
                       from jsonb_array_elements_text(opciones) with ordinality as t(e, o))),
         updated_at = now()
   where id = v_col.id;

  update public.fin_llamadas
     set campos_extra = jsonb_set(campos_extra, array[p_clave], to_jsonb(v_nuevo))
   where cliente_id = p_cliente and campos_extra->>p_clave = p_viejo;
  get diagnostics v_n = row_count;
  return v_n;
end;
$fn$;



-- =====================================================================
-- 4. LIMPIEZA: columnas de prueba de liam (archivadas, sin valores)
-- =====================================================================
delete from public.fin_data_columnas c
 where c.cliente_id = 'liam'
   and not c.sistema
   and c.archivada
   and c.etiqueta like 'ZZ prueba%'
   and not exists (select 1 from public.fin_llamadas l
                   where l.cliente_id = c.cliente_id and l.campos_extra ? c.clave);

-- Del sistema: un nombre igual al de por defecto, o con los caracteres
-- rotos de la 073, vuelve a "por defecto" (null). Asi toma el bueno.
update public.fin_data_columnas
   set etiqueta = null, updated_at = now()
 where sistema
   and etiqueta is not null
   and (etiqueta like U&'%\00C3%' or etiqueta = public.fin_data_etiqueta_defecto(clave));


-- =====================================================================
-- 5. PRUEBA DE HUMO (se revierte sola)
-- =====================================================================
do $humo$
declare
  v_k   text;
  v_err text;
begin
  begin
    perform set_config('request.jwt.claim.sub',
      (select user_id::text from public.crm_members where rol = 'fundador' limit 1), true);

    if public.fin_data_etiqueta_defecto('calificacion') <> U&'Calificaci\00F3n'
       or public.fin_data_etiqueta_defecto('telefono') <> U&'Tel\00E9fono'
       or public.fin_data_etiqueta_defecto('cc_dia1') <> U&'CC d\00EDa 1' then
      raise exception 'humo 1: nombres por defecto';
    end if;

    v_k := public.fin_data_columna_crear('liam', U&'Se\00F1a cobrada', 'opcion', '["Alfa","Beta"]');
    if v_k !~ '^x_sena_cobrada_[0-9a-f]{4}$' then raise exception 'humo 2: clave %', v_k; end if;

    begin
      perform public.fin_data_opcion_renombrar('liam', v_k, 'Beta', 'Alfa');
      raise exception 'humo 3: fusiono dos opciones';
    exception when invalid_parameter_value then null;
    end;
    perform public.fin_data_opcion_renombrar('liam', v_k, 'Beta', 'Gamma');
    if (select opciones from public.fin_data_columnas where cliente_id = 'liam' and clave = v_k)
       <> '["Alfa","Gamma"]'::jsonb then
      raise exception 'humo 4: renombrar normal';
    end if;

    raise exception 'humo_ok';
  exception when others then
    get stacked diagnostics v_err = message_text;
    if v_err <> 'humo_ok' then
      raise exception '074 abortada en la prueba de humo: %', v_err;
    end if;
  end;
end
$humo$;

commit;


-- =====================================================================
-- 6. CONTROLES (correr de a uno, despues del Success)
-- =====================================================================
-- C1. Los nombres por defecto, bien escritos:
--     Calificacion con tilde | CC dia 1 con tilde | Telefono con tilde
-- select public.fin_data_etiqueta_defecto('calificacion'),
--        public.fin_data_etiqueta_defecto('cc_dia1'),
--        public.fin_data_etiqueta_defecto('telefono');

-- C2. No quedan columnas de prueba en liam: tiene que dar 0.
-- select count(*) from public.fin_data_columnas
--  where cliente_id = 'liam' and etiqueta like 'ZZ prueba%';

-- C3. Ningun nombre guardado con caracteres rotos: tiene que dar 0.
-- select count(*) from public.fin_data_columnas where etiqueta like U&'%\00C3%';
