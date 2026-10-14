-- =====================================================================
-- 120_ventas_agus_crm.sql
-- Ventas. Conecta el CRM de ventas de Agus (planilla "Ventas De Cero a
-- CEO", hoja de llamadas) como fuente tipo 'data', igual que Liam/Teo.
--
-- ESTADO: BORRADOR. NO correr hasta completar los 3 datos de abajo:
--   <ID_HOJA_AGUS>  id de la Google Sheet del CRM de Agus (el de la URL,
--                   entre /d/ y /edit). OJO: NO es el de la planilla de
--                   Finanzas de agus (13LtPK8G...): es otro archivo.
--   <GID_HOJA_AGUS> gid de la pestania de llamadas (numero tras #gid= en
--                   la URL de esa pestania). El sync busca la hoja por gid.
--   <NOMBRE_HOJA>   nombre de esa pestania, tal cual (en Teo es 'DATA').
-- Y completar el BLOQUE 2 (alias) con los encabezados REALES de la hoja:
-- la comparacion contra el xlsx no se pudo hacer en la sesion que armo
-- este archivo (no habia permiso para leer el xlsx). Los alias de Teo
-- (014_alias_data.sql) van de referencia comentados.
--
-- BLOQUE 1: alta de la fuente, INACTIVA (activo = false).
-- BLOQUE 2: alias de columnas (completar; si falta alguno obligatorio el
--           sync deja la corrida en error sin tocar datos).
-- BLOQUE 3: activar la fuente (correr SOLO con los 2 anteriores listos y
--           la hoja compartida con la cuenta de servicio de la sync).
-- Closers/setters: no hace falta migrar nada de entrada. La fila entra
-- con el texto del closer tal cual; el alias se une a fin_personas /
-- fin_data_closer_mapa despues (ver C5 y la nota del final).
--
-- Sin begin/commit (SQL Editor). Correr cada bloque entero. Evitar
-- :00/:15/:30/:45 (la sync lee estas tablas). Idempotente.
-- No toca datos de Liam ni de Teo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 1. Fuente Data de Agus (inactiva)
-- ---------------------------------------------------------------------
do $$
begin
  if '<ID_HOJA_AGUS>' like '<%' or '<GID_HOJA_AGUS>' like '<%' or '<NOMBRE_HOJA>' like '<%' then
    raise exception '120: completar <ID_HOJA_AGUS>, <GID_HOJA_AGUS> y <NOMBRE_HOJA> antes de correr';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'agus') then
    raise exception '120: no existe el cliente agus en crm_clients';
  end if;
end $$;

insert into public.fin_fuentes
  (cliente_id, spreadsheet_id, gid, nombre_hoja_esperado, tipo, forma, fila_encabezado, anio, tope_monto, activo)
select 'agus', '<ID_HOJA_AGUS>', <GID_HOJA_AGUS>, '<NOMBRE_HOJA>', 'data', null, 1, null, null, false
where not exists (select 1 from public.fin_fuentes where cliente_id = 'agus' and tipo = 'data');

-- ---------------------------------------------------------------------
-- BLOQUE 2. Alias de columnas (COMPLETAR con los encabezados reales)
-- Campos canonicos: nombre, fecha_llamada, closer (obligatorios);
-- show_up, calificacion, estado_llamada, tipo_booking, telefono,
-- instagram, email, programa, contexto_closer, contexto_setter,
-- cc_dia1, cc_cerrado, cc_seguimiento, monto_restante.
-- Referencia (Teo, 014): Nombre Completo / Fecha de llamada / Encargado
-- de la llamada / Show up / Calificacion / Estado de la llamada /
-- Fuente (tipo_booking) / Telefono / instagram / CONTEXTO CLOSER /
-- Programa / CC DIA 1 / CC TRATO CERRADO / CC en Seguimiento /
-- Monto restante a pagar.
-- ---------------------------------------------------------------------
-- insert into public.fin_alias_columnas (fuente_id, campo_canonico, alias, obligatorio, posicion)
-- select f.id, x.campo, x.alias, x.obligatorio, x.posicion
-- from (values
--   ('nombre',        '<encabezado real>', true,  null::int),
--   ('fecha_llamada', '<encabezado real>', true,  null),
--   ('closer',        '<encabezado real>', true,  null),
--   ('show_up',       '<encabezado real>', false, null)
--   -- ... resto de las columnas
-- ) as x(campo, alias, obligatorio, posicion)
-- join public.fin_fuentes f on f.cliente_id = 'agus' and f.tipo = 'data'
-- on conflict (fuente_id, campo_canonico, alias) do update
--   set obligatorio = excluded.obligatorio, posicion = excluded.posicion;

-- ---------------------------------------------------------------------
-- BLOQUE 3. Activar (solo cuando 1 y 2 estan listos y la hoja compartida)
-- ---------------------------------------------------------------------
-- update public.fin_fuentes set activo = true where cliente_id = 'agus' and tipo = 'data';

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno, comentados)
-- ---------------------------------------------------------------------
-- C1 fuente creada e inactiva (1 fila, activo=false hasta el bloque 3):
-- select id, spreadsheet_id, gid, nombre_hoja_esperado, activo from public.fin_fuentes where cliente_id = 'agus' and tipo = 'data';
-- C2 alias cargados (al menos fecha_llamada, closer, nombre obligatorios):
-- select campo_canonico, alias, obligatorio from public.fin_alias_columnas a join public.fin_fuentes f on f.id = a.fuente_id where f.cliente_id = 'agus' and f.tipo = 'data' order by 1;
-- C3 tras activar y esperar una corrida (15 min): estado ok/revisar y filas:
-- select estado, filas_leidas, filas_cargadas, filas_rechazadas, mensaje from public.fin_sync_corridas where fuente_id = (select id from public.fin_fuentes where cliente_id = 'agus' and tipo = 'data') order by inicio desc limit 3;
-- C4 llamadas de agus por mes:
-- select date_trunc('month', fecha_llamada) m, count(*) from public.fin_llamadas where cliente_id = 'agus' group by 1 order by 1;
-- C5 closers de agus sin vendedor (alias a dar de alta en fin_personas):
-- select closer, count(*) from public.fin_llamadas where cliente_id = 'agus' group by 1 order by 2 desc;

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (comentada). Antes de la primera corrida:
--   delete from public.fin_alias_columnas where fuente_id = (select id from public.fin_fuentes where cliente_id = 'agus' and tipo = 'data');
--   delete from public.fin_fuentes where cliente_id = 'agus' and tipo = 'data';
-- Con corridas ya hechas: solo apagar (no borrar):
--   update public.fin_fuentes set activo = false where cliente_id = 'agus' and tipo = 'data';
-- ---------------------------------------------------------------------
