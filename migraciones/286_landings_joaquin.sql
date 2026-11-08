-- =====================================================================
-- 286 · LANDINGS DE JOAQUIN EN EL CIERRE DE OCTUBRE 2026
-- ESCRITA, SIN CORRER, SQL NO probado (la corre el jefe).
--
-- Problema: las landings que cobra Joaquin estan cargadas como gasto del cliente (fin_webinar_gastos: AF 25/10 300, BPF 14/10 200)
-- pero no hay transferencia a Joaquin en fin_cierre_transferencias (en octubre solo tiene "Sueldo Joaquin 2026-10" 1.000).
-- Ademas, la landing de Liam vale 300 (no 200).
--
-- Que hace:
--   Bloque 0  guardas + valores actuales (un solo resultado).
--   Bloque 1  respaldo (fin_cierre_meses, fin_cierre_transferencias de octubre, fin_webinar_reglas, fin_webinar_gastos).
--   Bloques 2-5 (una sola transaccion, ver EJECUCION): reabre octubre (fin_cierre_reabrir, el RPC de "Reabrir mes"),
--             landing Liam 300 en regla y en el gasto de BPF 14/10, 2 transferencias manuales a Joaquin,
--             fin_cierre_generar('2026-10-01') ("Calcular transferencias") y fin_cierre_cerrar (foto nueva, "Cerrar mes").
--   Bloque 6  humo: la misma transaccion en modo SIMULACRO termina SIEMPRE en ERROR "HUMO 286 OK: ..." y se revierte sola.
--   Controles C1..C6 (sueltos, de a uno) y vuelta atras.
--
-- Estructura real usada (269/270):
--   * fin_cierre_transferencias.tipo acepta 'sueldo','comision','editor','equipo','socio','cliente','otro'; pagador_tipo acepta 'cliente'.
--   * Linea manual = auto=false y clave_auto NULL (el check exige clave_auto solo si auto). El indice unico (mes, clave_auto) admite
--     NULL repetidos. fin_cierre_generar solo hace upsert por clave_auto y solo da de baja filas con auto=true: no toca estas lineas.
--   * La vista fin_v_dys_ganancia_mes solo mira transferencias tipo 'comision': las landings (tipo 'otro') NO cambian ganancias ni
--     neta por si mismas. El efecto sobre el cierre viene del gasto de landing Liam +100 (200 -> 300): baja la ganancia de Liam,
--     la linea Liam->Dystopia (30% de 100 = ~30) y la neta de los socios (~15 c/u). Agus: su gasto de landing ya es 300, sin cambio.
--   * Los triggers fin_cierre_bloq frenan fin_webinar_gastos (por fecha) y fin_cierre_transferencias (por mes) mientras octubre
--     esta cerrado: por eso se reabre primero. fin_webinar_reglas no tiene trigger.
--   * fin_cierre_generar / reabrir / cerrar piden es_fundador(): en el SQL Editor hace falta el uuid de un fundador (ver EJECUCION).
--
-- NO tocado: fin_pagos, sync, comisiones, otros meses, JS. AF 20/09 (landing 300 de septiembre, Opps) NO se toca: ver NOTA al final.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas + valores actuales. Correr SOLO este bloque primero. Devuelve un resultado (jsonb) para mirar.
-- ---------------------------------------------------------------------
do $g$
declare
  v_min int := extract(minute from now() at time zone 'America/Argentina/Buenos_Aires')::int;
  v_n int;
begin
  if v_min in (0, 14, 15, 29, 30, 44, 45, 59) then
    raise exception 'GUARDA 286: no correr en los minutos :00/:15/:30/:45 (corre la sync). Reintentar.';
  end if;
  if to_regclass('public.fin_cierre_transferencias') is null or to_regclass('public.fin_cierre_meses') is null then
    raise exception 'GUARDA 286: falta la 269 (cierre de mes)';
  end if;
  if to_regclass('public.fin_webinar_reglas') is null or to_regclass('public.fin_webinar_gastos') is null then
    raise exception 'GUARDA 286: falta la 267 (webinars)';
  end if;
  if not exists (select 1 from public.fin_cierre_meses m where m.mes = date '2026-10-01' and m.estado = 'cerrado') then
    raise exception 'GUARDA 286: octubre 2026 NO esta cerrado en fin_cierre_meses (esta migracion parte de octubre cerrado). Mirar el estado antes de seguir';
  end if;
  select count(*) into v_n from public.fin_cierre_transferencias t
   where t.mes = date '2026-10-01' and t.activo and t.tipo = 'sueldo' and t.concepto ilike '%joaqu%';
  if v_n <> 1 then
    raise exception 'GUARDA 286: se esperaba 1 sueldo activo de Joaquin en octubre y hay % (de ahi se toma el destinatario)', v_n;
  end if;
  select count(*) into v_n from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
   where w.cliente_id = 'liam' and w.fecha = date '2026-10-14' and g.concepto = 'landing' and g.activo;
  if v_n <> 1 then
    raise exception 'GUARDA 286: se esperaba 1 gasto de landing activo en BPF 14/10 y hay %', v_n;
  end if;
  select count(*) into v_n from public.fin_webinars w where w.cliente_id = 'agus' and w.fecha = date '2026-10-25' and w.activo;
  if v_n <> 1 then
    raise exception 'GUARDA 286: no encuentro el webinar AF 25/10 (agus) activo (hay %)', v_n;
  end if;
  if exists (select 1 from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.concepto in ('Landing webinar AF 25/10', 'Landing webinar BPF 14/10') and t.activo) then
    raise notice 'AVISO 286: ya hay transferencias de landing activas en octubre: el bloque 4 no las duplica';
  end if;
end
$g$;

select jsonb_build_object(
  'octubre_cierre', (select to_jsonb(m) - 'snapshot' from public.fin_cierre_meses m where m.mes = date '2026-10-01'),
  'regla_liam_landing', (select to_jsonb(r) from public.fin_webinar_reglas r where r.cliente_id = 'liam' and r.concepto = 'landing'),
  'landing_bpf_14_10', (select jsonb_agg(to_jsonb(g)) from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
                         where w.cliente_id = 'liam' and w.fecha = date '2026-10-14' and g.concepto = 'landing'),
  'landing_af_25_10', (select jsonb_agg(to_jsonb(g)) from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
                        where w.cliente_id = 'agus' and w.fecha = date '2026-10-25' and g.concepto = 'landing'),
  'transf_joaquin_octubre', (select jsonb_agg(jsonb_build_object('id', t.id, 'tipo', t.tipo, 'destinatario', t.destinatario, 'concepto', t.concepto,
                               'monto_usd', t.monto_usd, 'estado', t.estado, 'activo', t.activo, 'auto', t.auto, 'clave_auto', t.clave_auto))
                              from public.fin_cierre_transferencias t
                             where t.mes = date '2026-10-01' and t.activo and (t.destinatario ilike '%joaqu%' or t.concepto ilike '%landing%')),
  'liam_a_dystopia', (select jsonb_agg(jsonb_build_object('id', t.id, 'monto_usd', t.monto_usd, 'monto_calc', t.monto_calc, 'estado', t.estado, 'pagador', t.pagador_tipo))
                        from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.clave_auto = 'cli:liam'),
  'agus_a_dystopia', (select jsonb_agg(jsonb_build_object('id', t.id, 'monto_usd', t.monto_usd, 'estado', t.estado))
                        from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.clave_auto = 'cli:agus'),
  'socios', (select jsonb_agg(jsonb_build_object('id', t.id, 'destinatario', t.destinatario, 'monto_usd', t.monto_usd, 'estado', t.estado))
               from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.tipo = 'socio'),
  'hechas_octubre', (select count(*) from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.estado = 'hecha')
) as valores_actuales_286;

-- ---------------------------------------------------------------------
-- BLOQUE 1. Respaldo de lo que se toca (no se pisa al re-correr: create table if not exists). Sin RLS publica.
-- ---------------------------------------------------------------------
create table if not exists public.fin_cierre_meses_bak_286 as
  select now() as respaldado_en, m.* from public.fin_cierre_meses m where m.mes = date '2026-10-01';
create table if not exists public.fin_cierre_transf_bak_286 as
  select now() as respaldado_en, t.* from public.fin_cierre_transferencias t where t.mes = date '2026-10-01';
create table if not exists public.fin_webinar_reglas_bak_286 as
  select now() as respaldado_en, r.* from public.fin_webinar_reglas r where r.cliente_id = 'liam' and r.concepto = 'landing';
create table if not exists public.fin_webinar_gastos_bak_286 as
  select now() as respaldado_en, g.* from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
   where w.cliente_id in ('liam', 'agus') and w.fecha in (date '2026-10-14', date '2026-10-25') and g.concepto = 'landing';
alter table public.fin_cierre_meses_bak_286 enable row level security;
alter table public.fin_cierre_transf_bak_286 enable row level security;
alter table public.fin_webinar_reglas_bak_286 enable row level security;
alter table public.fin_webinar_gastos_bak_286 enable row level security;
-- Esperado: meses 1 fila, transferencias = las de octubre al momento del respaldo, reglas 1, gastos 2.
-- select (select count(*) from public.fin_cierre_meses_bak_286) m, (select count(*) from public.fin_cierre_transf_bak_286) t,
--        (select count(*) from public.fin_webinar_reglas_bak_286) r, (select count(*) from public.fin_webinar_gastos_bak_286) g;

-- ---------------------------------------------------------------------
-- EJECUCION (bloques 2 a 5 + humo 6): UNA sola corrida del editor, de "begin;" a "commit;" inclusive.
--   1) Reemplazar <UUID-FUNDADOR> por el uuid de un fundador (las funciones piden es_fundador()).
--   2) Primera vez con el simulacro en 'si' (valor por defecto): termina en ERROR "HUMO 286 OK: ..." y NADA queda guardado
--      (si el editor deja la transaccion abierta, correr "rollback;"). Ahi se leen los numeros antes -> despues.
--   3) Para aplicar: cambiar 'si' por 'no' en la linea set_config('x286.simulacro', ...) y correr de nuevo.
-- ---------------------------------------------------------------------
begin;
set local lock_timeout = '10s';
select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
select set_config('x286.simulacro', 'si', true);   -- 'si' = humo (bloque 6, se revierte) · 'no' = aplicar de verdad

do $v$
begin
  if current_setting('request.jwt.claim.sub', true) is null or current_setting('request.jwt.claim.sub', true) like '<%' then
    raise exception 'GUARDA 286: falta reemplazar <UUID-FUNDADOR> por el uuid de un fundador';
  end if;
  if not coalesce(public.es_fundador(), false) then
    raise exception 'GUARDA 286: ese uuid no es fundador (es_fundador() = false)';
  end if;
  if to_regclass('public.fin_cierre_transf_bak_286') is null then
    raise exception 'GUARDA 286: falta correr el bloque 1 (respaldo)';
  end if;
  if exists (select 1 from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.estado = 'hecha'
                and t.clave_auto = 'cli:liam') then
    raise notice 'AVISO 286: Liam->Dystopia de octubre ya esta HECHA: fin_cierre_generar no cambia su monto_usd (solo monto_calc) y el cierre avisara la diferencia';
  end if;
end
$v$;

-- BLOQUE 2. Reabrir octubre con el mismo RPC que usa "Reabrir mes" (deja fin_cierre_log 'reabrir' y reaperturas + 1).
do $b2$
begin
  if exists (select 1 from public.fin_cierre_meses m where m.mes = date '2026-10-01' and m.estado = 'cerrado') then
    perform public.fin_cierre_reabrir(date '2026-10-01', '286: landings de Joaquin (landing Liam 300 + transferencias a Joaquin)');
  end if;
  if not exists (select 1 from public.fin_cierre_meses m where m.mes = date '2026-10-01' and m.estado = 'abierto') then
    raise exception 'BLOQUE 2 (286): octubre no quedo abierto';
  end if;
end
$b2$;

-- BLOQUE 3. Landing de Liam = 300: regla (para webinars nuevos) y gasto de BPF 14/10.
do $b3$
declare v_n int;
begin
  insert into public.fin_webinar_reglas as r (cliente_id, concepto, monto_usd, nota)
  values ('liam', 'landing', 300, 'Landing por webinar (la cobra Joaquin) 300 desde 8/11')
  on conflict (cliente_id, concepto) do update set monto_usd = excluded.monto_usd, nota = excluded.nota;

  update public.fin_webinar_gastos g
     set monto_usd = 300,
         nota = coalesce(nullif(g.nota || ' · ', ' · '), '') || '286: landing 200 -> 300 (la cobra Joaquin)'
    from public.fin_webinars w
   where w.id = g.webinar_id and w.cliente_id = 'liam' and w.fecha = date '2026-10-14' and g.concepto = 'landing' and g.activo;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'BLOQUE 3 (286): se actualizaron % gastos de landing de BPF 14/10 (esperado 1)', v_n; end if;
end
$b3$;

-- BLOQUE 4. Transferencias manuales a Joaquin (auto=false, clave_auto NULL: fin_cierre_generar no las toca ni las duplica).
--   Destinatario = el mismo del sueldo de Joaquin en octubre. tipo 'otro'. Paga el cliente. Idempotente por mes + concepto.
do $b4$
declare v_dest text; v_n int;
begin
  select t.destinatario into v_dest from public.fin_cierre_transferencias t
   where t.mes = date '2026-10-01' and t.activo and t.tipo = 'sueldo' and t.concepto ilike '%joaqu%';
  if v_dest is null then raise exception 'BLOQUE 4 (286): no encuentro el destinatario del sueldo de Joaquin'; end if;

  insert into public.fin_cierre_transferencias (mes, tipo, destinatario, concepto, monto_usd, cliente_id, pagador_tipo, estado, auto, clave_auto, nota)
  select date '2026-10-01', 'otro', v_dest, v.concepto, v.monto, v.cliente, 'cliente', 'pendiente', false, null, v.nota
    from (values
      ('Landing webinar AF 25/10',  300::numeric, 'agus', '286: landing que cobra Joaquin; ya esta como gasto del cliente en Webinars (no resta de nuevo en la ganancia)'),
      ('Landing webinar BPF 14/10', 300::numeric, 'liam', '286: landing que cobra Joaquin; ya esta como gasto del cliente en Webinars (no resta de nuevo en la ganancia)')
    ) as v(concepto, monto, cliente, nota)
   where not exists (select 1 from public.fin_cierre_transferencias x
                      where x.mes = date '2026-10-01' and x.concepto = v.concepto and x.activo);
  get diagnostics v_n = row_count;
  raise notice 'BLOQUE 4 (286): % transferencias insertadas (destinatario %)', v_n, v_dest;
end
$b4$;

-- BLOQUE 5. Recalcular ("Calcular transferencias") y volver a cerrar ("Cerrar mes": la foto jsonb se arma de nuevo).
do $b5$
begin
  perform public.fin_cierre_generar(date '2026-10-01');
  perform public.fin_cierre_cerrar(date '2026-10-01', '286: cierre de octubre con landings de Joaquin');
  if not exists (select 1 from public.fin_cierre_meses m where m.mes = date '2026-10-01' and m.estado = 'cerrado') then
    raise exception 'BLOQUE 5 (286): octubre no quedo cerrado';
  end if;
end
$b5$;

-- BLOQUE 6. Humo / cierre de la transaccion. Con simulacro 'si' termina SIEMPRE en ERROR "HUMO 286 OK" (revierte todo lo de arriba).
do $h$
declare
  v_msg text; v_fail text := '';
  v_liam_antes numeric; v_liam_desp numeric; v_agus_antes numeric; v_agus_desp numeric;
  v_soc_antes numeric; v_soc_desp numeric; v_land int; v_snap int;
begin
  select coalesce(sum(b.monto_usd), 0) into v_liam_antes from public.fin_cierre_transf_bak_286 b where b.activo and b.clave_auto = 'cli:liam';
  select coalesce(sum(t.monto_usd), 0) into v_liam_desp from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.clave_auto = 'cli:liam';
  select coalesce(sum(b.monto_usd), 0) into v_agus_antes from public.fin_cierre_transf_bak_286 b where b.activo and b.clave_auto = 'cli:agus';
  select coalesce(sum(t.monto_usd), 0) into v_agus_desp from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.clave_auto = 'cli:agus';
  select coalesce(sum(b.monto_usd), 0) into v_soc_antes from public.fin_cierre_transf_bak_286 b where b.activo and b.tipo = 'socio';
  select coalesce(sum(t.monto_usd), 0) into v_soc_desp from public.fin_cierre_transferencias t where t.mes = date '2026-10-01' and t.activo and t.tipo = 'socio';
  select count(*) into v_land from public.fin_cierre_transferencias t
   where t.mes = date '2026-10-01' and t.activo and t.estado = 'pendiente' and not t.auto and t.tipo = 'otro' and t.monto_usd = 300
     and t.pagador_tipo = 'cliente' and t.concepto in ('Landing webinar AF 25/10', 'Landing webinar BPF 14/10');
  select jsonb_array_length(m.snapshot -> 'transferencias') into v_snap from public.fin_cierre_meses m where m.mes = date '2026-10-01';

  if v_land <> 2 then v_fail := v_fail || ' · landings activas pendientes=' || v_land || ' (esperado 2)'; end if;
  if not exists (select 1 from public.fin_cierre_meses m where m.mes = date '2026-10-01' and m.estado = 'cerrado') then v_fail := v_fail || ' · octubre no esta cerrado'; end if;
  if (select r.monto_usd from public.fin_webinar_reglas r where r.cliente_id = 'liam' and r.concepto = 'landing') <> 300 then v_fail := v_fail || ' · regla Liam landing <> 300'; end if;
  if exists (select 1 from public.fin_cierre_transf_bak_286 b join public.fin_cierre_transferencias t on t.id = b.id
              where b.estado = 'hecha' and (t.monto_usd, t.estado, t.fecha_pago, t.destinatario, t.concepto, t.activo, t.pagador_tipo)
                is distinct from (b.monto_usd, b.estado, b.fecha_pago, b.destinatario, b.concepto, b.activo, b.pagador_tipo)) then
    v_fail := v_fail || ' · se modifico una transferencia HECHA';
  end if;
  if v_agus_antes <> v_agus_desp then v_fail := v_fail || ' · Agus->Dystopia cambio (' || v_agus_antes || ' -> ' || v_agus_desp || ')'; end if;
  if v_fail <> '' then raise exception 'HUMO 286 FALLO:%', v_fail; end if;

  v_msg := 'Liam->Dystopia ' || v_liam_antes || ' -> ' || v_liam_desp || ' (esperado baja ~30) · socios en total ' || v_soc_antes || ' -> ' || v_soc_desp
        || ' (esperado baja ~30 = ~15 c/u) · Agus->Dystopia ' || v_agus_antes || ' -> ' || v_agus_desp || ' (sin cambio) · landings nuevas ' || v_land
        || ' · transferencias en la foto del cierre ' || v_snap;
  if current_setting('x286.simulacro', true) = 'no' then
    raise notice '286 APLICADA: %', v_msg;
  else
    raise exception 'HUMO 286 OK: %', v_msg;
  end if;
end
$h$;
commit;

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno). Los que usan vistas o funciones de fundador necesitan, en la MISMA ejecucion:
--   select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- ---------------------------------------------------------------------
-- C1. Landing de Liam = 300 en la regla y en el gasto de BPF 14/10 (Agus AF 25/10 sigue en 300). Esperado: regla 300, liam 300, agus 300.
-- select (select r.monto_usd from public.fin_webinar_reglas r where r.cliente_id = 'liam' and r.concepto = 'landing') as regla_liam,
--        (select g.monto_usd from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
--          where w.cliente_id = 'liam' and w.fecha = date '2026-10-14' and g.concepto = 'landing' and g.activo) as gasto_bpf_14_10,
--        (select g.monto_usd from public.fin_webinar_gastos g join public.fin_webinars w on w.id = g.webinar_id
--          where w.cliente_id = 'agus' and w.fecha = date '2026-10-25' and g.concepto = 'landing' and g.activo) as gasto_af_25_10;

-- C2. Las 2 transferencias nuevas: activas, pendientes, manuales, a Joaquin (mismo destinatario que el sueldo), pagador cliente. Esperado: 2 filas de 300.
-- select t.id, t.tipo, t.destinatario, t.concepto, t.monto_usd, t.cliente_id, t.pagador_tipo, t.estado, t.activo, t.auto, t.clave_auto,
--        t.destinatario = (select s.destinatario from public.fin_cierre_transferencias s where s.mes = t.mes and s.tipo = 'sueldo' and s.activo and s.concepto ilike '%joaqu%') as mismo_destinatario_que_sueldo
--   from public.fin_cierre_transferencias t
--  where t.mes = date '2026-10-01' and t.concepto in ('Landing webinar AF 25/10', 'Landing webinar BPF 14/10') order by t.id;

-- C3. Octubre cerrado de nuevo, con la foto actualizada (las 2 landings dentro) y el registro del cierre/reapertura. Esperado: cerrado, reaperturas + 1, foto con 2 landings, log reabrir + cerrar de hoy.
-- select m.estado, m.reaperturas, m.cerrado_en, m.reabierto_en,
--        (select count(*) from jsonb_array_elements(m.snapshot -> 'transferencias') e where e ->> 'concepto' like 'Landing webinar%') as landings_en_la_foto,
--        (select jsonb_agg(jsonb_build_object('accion', l.accion, 'en', l.en, 'nota', l.nota) order by l.id desc) from (select * from public.fin_cierre_log where mes = m.mes order by id desc limit 2) l) as ultimos_log
--   from public.fin_cierre_meses m where m.mes = date '2026-10-01';

-- C4. ANTES (respaldo) y DESPUES de todas las lineas de octubre. Esperado: cli:liam baja ~30 (30% de 100), socio:* bajan ~15 c/u, cli:agus igual, sueldo igual, las 2 landings aparecen solo en "despues".
-- select coalesce(b.clave_auto, t.clave_auto, t.concepto) as linea, coalesce(t.destinatario, b.destinatario) as destinatario,
--        b.monto_usd as antes, t.monto_usd as despues, t.monto_usd - b.monto_usd as diferencia, coalesce(t.estado, b.estado) as estado
--   from public.fin_cierre_transf_bak_286 b
--   full join public.fin_cierre_transferencias t on t.id = b.id and t.mes = date '2026-10-01' and t.activo
--  where b.id is null or b.activo
--  order by 1;

-- C5. Ninguna transferencia HECHA modificada (compara respaldo vs ahora, sin monto_calc ni actualizado_en que generar si mueve). Esperado: 0 filas.
-- select b.id, b.destinatario, b.concepto, b.monto_usd as antes, t.monto_usd as despues, b.estado, t.estado as estado_ahora
--   from public.fin_cierre_transf_bak_286 b join public.fin_cierre_transferencias t on t.id = b.id
--  where b.estado = 'hecha'
--    and (t.monto_usd, t.estado, t.fecha_pago, t.destinatario, t.concepto, t.activo, t.pagador_tipo, t.comprobante, t.cliente_id)
--        is distinct from (b.monto_usd, b.estado, b.fecha_pago, b.destinatario, b.concepto, b.activo, b.pagador_tipo, b.comprobante, b.cliente_id);

-- C6. Aviso "hecha con otro monto que el calculado" (si Liam->Dystopia o un socio estaba HECHO, su monto no se mueve y queda la diferencia). Esperado: 0 filas, o lo que se decida a mano.
-- select t.id, t.clave_auto, t.destinatario, t.monto_usd, t.monto_calc from public.fin_cierre_transferencias t
--  where t.mes = date '2026-10-01' and t.activo and t.estado = 'hecha' and t.monto_calc is not null and t.monto_calc <> t.monto_usd;

-- ---------------------------------------------------------------------
-- VUELTA ATRAS (solo si hace falta; reabrir con Reabrir mes o con fin_cierre_reabrir y fundador, luego esto y volver a cerrar)
-- ---------------------------------------------------------------------
-- begin;
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select public.fin_cierre_reabrir(date '2026-10-01', '286: vuelta atras');
-- update public.fin_cierre_transferencias set activo = false, baja_manual = true, actualizado_en = now()
--  where mes = date '2026-10-01' and not auto and concepto in ('Landing webinar AF 25/10', 'Landing webinar BPF 14/10');
-- update public.fin_webinar_reglas r set monto_usd = b.monto_usd, nota = b.nota from public.fin_webinar_reglas_bak_286 b where r.cliente_id = b.cliente_id and r.concepto = b.concepto;
-- update public.fin_webinar_gastos g set monto_usd = b.monto_usd, nota = b.nota from public.fin_webinar_gastos_bak_286 b where g.id = b.id;
-- select public.fin_cierre_generar(date '2026-10-01');
-- select public.fin_cierre_cerrar(date '2026-10-01', '286: vuelta atras');
-- commit;

-- NOTA: AF 20/09 (landing 300 de Joaquin, cargada en Opps de septiembre) NO se toca. Septiembre no esta en esta tarea;
-- si tambien necesita una transferencia a Joaquin, hace falta decidir (mes ya cerrado o no) y pedir otro numero.
