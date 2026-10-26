-- =====================================================================
-- 229_liam_yt_es_youtube.sql
-- Liam: la fuente de agenda cruda 'YT' es lo mismo que YOUTUBE (decision de Joaquin).
-- La 228 sembro 'YT' en fin_fuentes_mapa con canonica propia ('YT'). Esta migracion la apunta a 'YOUTUBE'
-- y le copia la atribucion/captacion que tenga hoy la fila 'YOUTUBE' de Liam (hoy null = sin definir).
--
-- Decisiones:
--  * fin_fuentes_mapa: UPDATE acotado a (cliente_id='liam', fuente_cruda='YT'). Si la fila no existiera, se inserta.
--  * fin_catalogos: 'YT' queda ACTIVO a proposito. El webhook de agenda manda fuente='YT' tal cual (va a
--    fin_llamadas.tipo_booking) y el desplegable de Ventas se arma con el catalogo; desactivarlo podria hacer
--    que las agendas con 'YT' o el filtro fallen. El valor crudo 'YT' se canoniza a YOUTUBE por el mapa.
--  * 'YT VENTAS' (y YOUTUBE VENTAS, YOUTUBE SETTER) NO se tocan. Solo YT de Liam. Sin DELETE.
-- Re-ejecutable. Controles al final.
-- =====================================================================

begin;
set local lock_timeout = '10s';

do $g$
begin
  if not exists (select 1 from public.fin_fuentes_mapa where cliente_id = 'liam' and fuente_cruda = 'YOUTUBE' and fuente = 'YOUTUBE') then
    raise exception 'GUARDA 229: no existe el mapa liam YOUTUBE -> YOUTUBE. No se toca nada.';
  end if;
end
$g$;

-- Si por algun motivo no estaba la fila YT, se crea ya apuntando a YOUTUBE.
insert into public.fin_fuentes_mapa (cliente_id, fuente_cruda, fuente, captacion, atribucion)
select 'liam', 'YT', y.fuente, y.captacion, y.atribucion
  from public.fin_fuentes_mapa y
 where y.cliente_id = 'liam' and y.fuente_cruda = 'YOUTUBE'
   and not exists (select 1 from public.fin_fuentes_mapa m where m.cliente_id = 'liam' and m.fuente_cruda = 'YT');

-- YT -> YOUTUBE, misma atribucion y captacion que YOUTUBE
update public.fin_fuentes_mapa m
   set fuente = y.fuente,
       captacion = y.captacion,
       atribucion = y.atribucion,
       nota = '229: YT es lo mismo que YOUTUBE (Liam)'
  from public.fin_fuentes_mapa y
 where m.cliente_id = 'liam' and m.fuente_cruda = 'YT'
   and y.cliente_id = 'liam' and y.fuente_cruda = 'YOUTUBE'
   and (m.fuente, m.captacion, m.atribucion) is distinct from (y.fuente, y.captacion, y.atribucion);

do $v$
begin
  if not exists (select 1 from public.fin_fuentes_mapa m
                   join public.fin_fuentes_mapa y on y.cliente_id = m.cliente_id and y.fuente_cruda = 'YOUTUBE'
                  where m.cliente_id = 'liam' and m.fuente_cruda = 'YT'
                    and m.fuente = 'YOUTUBE' and m.atribucion is not distinct from y.atribucion) then
    raise exception 'VERIFICACION 229: YT no quedo mapeada a YOUTUBE';
  end if;
  if not exists (select 1 from public.fin_catalogos where cliente_id = 'liam' and dimension = 'fuente' and valor = 'YT' and activo) then
    raise exception 'VERIFICACION 229: YT deberia seguir activa en el catalogo de Liam';
  end if;
end
$v$;

commit;

-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================
-- C1. YT -> YOUTUBE con la misma atribucion que YOUTUBE. Esperado: 2 filas, fuente = YOUTUBE en ambas, atribucion igual.
-- select fuente_cruda, fuente, captacion, atribucion from public.fin_fuentes_mapa
--  where cliente_id = 'liam' and fuente_cruda in ('YT', 'YOUTUBE') order by fuente_cruda;

-- C2. YT VENTAS y las otras sin cambios. Esperado: YT VENTAS -> YT VENTAS (null); YOUTUBE VENTAS -> YOUTUBE VENTAS (null);
--     INSTAGRAM setter, LANDING landing, TIKTOK landing, TIKTOK (SETTER) setter; resto como estaba.
-- select fuente_cruda, fuente, captacion, atribucion, nota from public.fin_fuentes_mapa where cliente_id = 'liam' order by fuente_cruda;

-- C3. Catalogo de Liam sin cambios: YT activo, YT VENTAS activo, YOUTUBE activo.
-- select valor, orden, activo from public.fin_catalogos
--  where cliente_id = 'liam' and dimension = 'fuente' and valor in ('YT', 'YT VENTAS', 'YOUTUBE') order by valor;

-- C4. Otros clientes sin tocar. Esperado: 0 filas con nota de la 229 fuera de liam/YT.
-- select cliente_id, fuente_cruda from public.fin_fuentes_mapa where nota like '229:%';

-- =====================================================================
-- VUELTA ATRAS
-- =====================================================================
-- update public.fin_fuentes_mapa set fuente = 'YT', nota = null where cliente_id = 'liam' and fuente_cruda = 'YT';
