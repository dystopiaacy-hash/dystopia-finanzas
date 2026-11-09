-- =====================================================================
-- 288 · Gastos mensuales de herramientas: Bunny (confirmado) y ManyChat (A CONFIRMAR)
-- ESCRITA, SIN correr, SQL NO probado. La corre Joaquin a mano. Número asignado por el jefe.
--
-- QUE HACE
--   Bloque 1 (CONFIRMADO): Bunny Stream, pago US$ 25,00 el 9/11/2026 con la tarjeta de Dystopia (credito prepago, lo usa solo el
--            panel de alumnos de Agus). Cliente agus, noviembre 2026, reparto «Compartido segun comision» (como la IA).
--   Bloque 2 (A CONFIRMAR, APAGADO): ManyChat por cliente y mes. La distribucion sale de los totales que paso Joaquin y NO esta
--            confirmada: ver la tabla en el reporte de la sesion. Por defecto no inserta nada (x288.manychat = 'no').
--
-- CATEGORIA: «Herramientas» no existe en fin_gasto_categorias; la que corresponde es «Software y suscripciones» (174). Se usa esa
--            (si la renombraron o no existe, se frena). En la pantalla Gastos > Desglose se agrupa como «herramientas».
-- NO PISA NADA: solo INSERT. Un gasto no se carga si ya hay uno activo del mismo cliente y mes con «bunny» / «manychat» en la
--            descripcion (mismo texto, o cualquiera: se avisa por NOTICE). Todo lo insertado lleva nota que empieza con «288:».
-- MESES CERRADOS: fin_gastos tiene el trigger fin_cierre_bloq (269): un gasto fechado en un mes cerrado se rechaza. El cierre de octubre
--            esta cerrado y NO se reabre aca. El bloque 2 salta (NOTICE) cualquier mes cerrado: Sep/Oct de ManyChat quedan para decidir
--            (reabrir el mes o dejarlos fuera) en otra tarea.
-- LUCAS: fin_gastos.entidad solo admite liam / agus / teo / dystopia (check de la 174) y Lucas esta de baja (107): sus US$ 81,65 (sep)
--            y 65 (oct) NO se cargan. Decision pendiente (¿100% Dystopia?).
-- SIMULACRO: por defecto x288.simulacro = 'si': corre todo y termina en ERROR «SIMULACRO 288 OK ...» (se revierte solo).
--            Para aplicar de verdad, cambiar 'si' por 'no' en el set_config de cada bloque.
-- No correr a las :00/:15/:30/:45 (sync) ni a las 9:00.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (solo lectura)
-- ---------------------------------------------------------------------
do $g$
declare v_falta text := '';
begin
  if to_regclass('public.fin_gastos') is null then v_falta := v_falta || ' fin_gastos(174)'; end if;
  if to_regclass('public.fin_gasto_categorias') is null then v_falta := v_falta || ' fin_gasto_categorias(174)'; end if;
  if to_regclass('public.fin_cierre_meses') is null then v_falta := v_falta || ' fin_cierre_meses(269)'; end if;
  if v_falta <> '' then raise exception 'GUARDA 288: faltan:%', v_falta; end if;
  if (select count(*) from public.fin_gasto_categorias where lower(btrim(nombre)) = 'software y suscripciones') <> 1 then
    raise exception 'GUARDA 288: no hay exactamente 1 categoria «Software y suscripciones» (¿la renombraron?). Ver C1 y ajustar el nombre en los bloques 1 y 2.';
  end if;
  if extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int in (0, 14, 15, 29, 30, 44, 45, 59) then
    raise exception 'GUARDA 288: correla en otro minuto (la sync corre a :00/:15/:30/:45).';
  end if;
  if not exists (select 1 from public.crm_clients where id = 'agus') then raise exception 'GUARDA 288: no existe el cliente agus'; end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Bunny (CONFIRMADO)
-- ---------------------------------------------------------------------
select set_config('x288.simulacro', 'si', false);   -- cambiar a 'no' para aplicar

do $b$
declare
  v_cat bigint; v_fecha date := date '2026-11-09'; v_n int := 0; v_sim text := current_setting('x288.simulacro', true);
begin
  select id into v_cat from public.fin_gasto_categorias where lower(btrim(nombre)) = 'software y suscripciones';
  if exists (select 1 from public.fin_cierre_meses m where m.mes = date_trunc('month', v_fecha)::date and m.estado = 'cerrado') then
    raise exception 'BLOQUE 1 288: noviembre 2026 esta cerrado; no se carga.';
  end if;
  if exists (select 1 from public.fin_gastos g where g.entidad = 'agus' and g.activo and g.descripcion ilike '%bunny%'
                and date_trunc('month', g.fecha) = date_trunc('month', v_fecha)) then
    raise notice 'BLOQUE 1 288: ya hay un gasto de Bunny de Agus en noviembre; no se inserta otro.';
  else
    insert into public.fin_gastos (entidad, categoria_id, descripcion, monto, moneda, tipo_cambio, fecha, recurrente, reparto, nota)
    values ('agus', v_cat, 'Bunny Stream: credito prepago (panel de alumnos de Agus)', 25, 'USD', null, v_fecha, false, 'comision',
            '288: pago 9/11/2026 con la tarjeta de Dystopia. Credito prepago de Bunny Stream, lo usa solo el panel de alumnos de Agus.');
    v_n := 1;
  end if;
  if v_sim = 'si' then raise exception 'SIMULACRO 288 OK (bloque 1): insertaria % gasto(s) de Bunny. Cambiar x288.simulacro a «no» para aplicar.', v_n; end if;
end
$b$;

-- ---------------------------------------------------------------------
-- BLOQUE 2. ManyChat (A CONFIRMAR: apagado por defecto)
-- Distribucion PROPUESTA (USD). Se deduce de los totales (sep 215,65 / oct 694,94 / nov al 8: 120) y de los montos por cliente;
-- que Liam 69/138 y Lucas 81,65/65/0 sean sep/oct y no otra combinacion NO esta confirmado:
--                 sep       oct       nov (al 8)
--   Liam          69,00    138,00      0
--   Agus           0       426,94    120,00   (oct = wallet WhatsApp 390 + excedente 36,94; nov = 120)
--   Teo           65,00     65,00      0
--   Lucas         81,65     65,00      0      (NO se carga: ver cabecera)
--   Total        215,65    694,94    120,00
-- Fecha: primer dia del mes; no recurrente (los montos cambian); reparto «comision» propuesto (A CONFIRMAR).
-- Para cargarlo: x288.manychat = 'si' y x288.simulacro = 'no'.
-- ---------------------------------------------------------------------
select set_config('x288.manychat', 'no', false);     -- 'si' = cargar la tabla propuesta (despues de confirmarla)
select set_config('x288.simulacro', 'si', false);    -- 'no' para aplicar

do $m$
declare
  v_cat bigint; r record; v_ins int := 0; v_skip int := 0; v_sim text := current_setting('x288.simulacro', true);
begin
  if current_setting('x288.manychat', true) is distinct from 'si' then
    raise notice 'BLOQUE 2 288: ManyChat apagado (x288.manychat <> si). No se inserta nada.';
    return;
  end if;
  select id into v_cat from public.fin_gasto_categorias where lower(btrim(nombre)) = 'software y suscripciones';
  for r in
    select * from (values
      ('liam', date '2026-09-01',  69.00::numeric), ('liam', date '2026-10-01', 138.00),
      ('agus', date '2026-10-01', 426.94),          ('agus', date '2026-11-01', 120.00),
      ('teo',  date '2026-09-01',  65.00),          ('teo',  date '2026-10-01',  65.00)
    ) as t(entidad, fecha, monto)
  loop
    if exists (select 1 from public.fin_cierre_meses m where m.mes = r.fecha and m.estado = 'cerrado') then
      raise notice 'BLOQUE 2 288: % % esta cerrado; se salta.', r.entidad, r.fecha; v_skip := v_skip + 1; continue;
    end if;
    if exists (select 1 from public.fin_gastos g where g.entidad = r.entidad and g.activo and g.descripcion ilike '%manychat%'
                  and date_trunc('month', g.fecha) = r.fecha) then
      raise notice 'BLOQUE 2 288: % % ya tiene un gasto de ManyChat; se salta.', r.entidad, r.fecha; v_skip := v_skip + 1; continue;
    end if;
    insert into public.fin_gastos (entidad, categoria_id, descripcion, monto, moneda, tipo_cambio, fecha, recurrente, reparto, nota)
    values (r.entidad, v_cat, 'ManyChat ' || to_char(r.fecha, 'YYYY-MM'), r.monto, 'USD', null, r.fecha, false, 'comision',
            '288: distribucion A CONFIRMAR por Joaquin (totales: sep 215,65 / oct 694,94 / nov al 8: 120).');
    v_ins := v_ins + 1;
  end loop;
  if v_sim = 'si' then raise exception 'SIMULACRO 288 OK (bloque 2): insertaria % y saltaria % gastos de ManyChat.', v_ins, v_skip; end if;
end
$m$;

-- ---------------------------------------------------------------------
-- CONTROLES (correr DE A UNO; el editor muestra solo el ultimo resultado)
-- ---------------------------------------------------------------------
-- C1. La categoria que se usa:
-- select id, nombre, clave, activa from public.fin_gasto_categorias where lower(btrim(nombre)) in ('software y suscripciones', 'herramientas');
--
-- C2. Lo que ya habia de Bunny / ManyChat antes (para no duplicar), con su categoria y si el mes esta cerrado:
-- select g.id, g.entidad, g.fecha, g.descripcion, g.monto, g.moneda, g.reparto, g.activo, c.nombre as categoria,
--        exists (select 1 from public.fin_cierre_meses m where m.mes = date_trunc('month', g.fecha)::date and m.estado = 'cerrado') as mes_cerrado
--   from public.fin_gastos g join public.fin_gasto_categorias c on c.id = g.categoria_id
--  where g.descripcion ilike '%bunny%' or g.descripcion ilike '%manychat%' order by g.fecha, g.entidad;
--
-- C3. Lo cargado por esta migracion:
-- select id, entidad, fecha, descripcion, monto, reparto, activo from public.fin_gastos where nota like '288:%' order by fecha, entidad;
--
-- C4. Estado de los meses (cuales estan cerrados):
-- select mes, estado from public.fin_cierre_meses order by mes desc limit 6;
--
-- C5. Aparece en la vista de gastos con el reparto (usar la sesion de un fundador; si devuelve 0 filas, set_config del claim):
-- select mes, entidad, descripcion, monto_usd, porcentaje_dystopia, usd_dystopia, usd_cliente
--   from public.fin_gastos_mes_base where descripcion ilike '%bunny%' or descripcion ilike '%manychat%' order by mes, entidad;
--
-- C6. Nada duplicado (debe dar 0 filas):
-- select entidad, date_trunc('month', fecha) as mes, count(*) from public.fin_gastos
--  where activo and (descripcion ilike '%bunny%' or descripcion ilike '%manychat%') group by 1, 2 having count(*) > 1;
--
-- C7. Suma de ManyChat por mes y cliente contra los totales de Joaquin (215,65 / 694,94 / 120):
-- select date_trunc('month', fecha)::date as mes, entidad, sum(monto) from public.fin_gastos
--  where activo and descripcion ilike '%manychat%' group by rollup (1, 2) order by 1, 2;

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (solo lo de esta migracion; baja logica, no borra)
-- ---------------------------------------------------------------------
-- update public.fin_gastos set activo = false, editado_en = now() where nota like '288:%';
