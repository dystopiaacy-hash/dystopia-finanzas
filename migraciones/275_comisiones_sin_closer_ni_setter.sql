-- =====================================================================
-- 275 · "NO HAY" (o vacio) como closer / setter NO genera comision
-- Numero asignado por el jefe. ESCRITA, SIN correr, SQL NO probado.
--
-- Problema: fin_v_cierre_ventas (269) solo trata como "sin persona" al texto vacio. Una venta con closer o setter
-- "NO HAY" (Teo, y tambien Liam: ej. setter "NO HAY") crea una comision a nombre de "NO HAY" (60 en Teo octubre).
--
-- Regla (todos los clientes: Agus, Liam, Teo): si el closer o el setter es vacio, "NO HAY", "no hay", "-", "N/A",
-- "ninguno/a", "sin closer/setter/asignar/dato(s)", "nadie", "none", "null", "no", "sin" (se normaliza: mayusculas, tildes,
-- espacios y signos), esa venta NO genera comision para ESE rol. El otro rol de la misma venta no se toca.
--
-- Que hace:
--   BLOQUE 1  fin_es_sin_persona(texto): la regla en un solo lugar (immutable).
--   BLOQUE 2  humo (se revierte solo: termina en ERROR "HUMO 275 OK ..." con cuantas filas toca el bloque 4 y por cuanto).
--   BLOQUE 3  fin_v_cierre_ventas recreada: mismas columnas que la 269. Con closer/setter sin persona: persona = null,
--             falta_persona = true, comision_usd = 0 (ya no busca el texto como alias de fin_personas).
--   BLOQUE 4  baja de las transferencias automaticas PENDIENTES de tipo comision cuyo destinatario es un "sin persona"
--             (meses abiertos), con respaldo en fin_cierre_transf_respaldo_275. NO toca las hechas ni los meses cerrados
--             (las lista el control C2). Es baja logica (activo = false), igual que hace fin_cierre_generar.
--   No cambia fin_cierre_generar ni fin_v_dys_ganancia_mes (ya leen la vista y las transferencias activas).
--   No toca fin_pagos, la sync, porcentajes, sueldos ni socios. No cierra octubre.
--   No hace falta correrla fuera de :00/:15/:30/:45: no toca tablas de la sync.
--
-- Ejecucion: bloques 1, 2, 3 y 4 de a uno (cada uno tiene su comentario BLOQUE); despues los controles de a uno.
--   Despues: en Cierre de mes, "Calcular transferencias" de octubre (fin_cierre_generar) recalcula neta, socios y clientes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BLOQUE 0. Guardas (solo lectura)
-- ---------------------------------------------------------------------
do $g$
begin
  if to_regclass('public.fin_v_cierre_ventas') is null or to_regclass('public.fin_cierre_transferencias') is null
     or to_regprocedure('public.fin_cierre_generar(date)') is null then
    raise exception 'GUARDA 275: falta la 269 (cierre de mes). No se toca nada.';
  end if;
  if to_regclass('public.fin_v_dys_ganancia_mes') is null then
    raise exception 'GUARDA 275: falta la 270 (fin_v_dys_ganancia_mes). No se toca nada.';
  end if;
  if pg_get_viewdef('public.fin_v_cierre_ventas'::regclass) not like '%no_comisiona%' then
    raise exception 'GUARDA 275: fin_v_cierre_ventas no es la de la 269. No se toca nada.';
  end if;
end
$g$;

-- ---------------------------------------------------------------------
-- BLOQUE 1. La regla en un solo lugar
-- ---------------------------------------------------------------------
create or replace function public.fin_es_sin_persona(p text)
returns boolean language sql immutable as $f$
  select btrim(regexp_replace(lower(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN')), '[^a-z0-9]+', ' ', 'g'))
         in ('', 'no hay', 'nohay', 'ninguno', 'ninguna', 'ningun', 'n a', 'na', 'sin closer', 'sin setter', 'sin asignar',
             'sin dato', 'sin datos', 'nadie', 'none', 'null', 'no', 'sin')
$f$;

comment on function public.fin_es_sin_persona(text) is
  '275: true si el closer/setter es vacio o un marcador de "nadie" (NO HAY, -, N/A, ninguno...). Ese rol no genera comision.';

revoke all on function public.fin_es_sin_persona(text) from public, anon;
grant execute on function public.fin_es_sin_persona(text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 2. Humo (se revierte solo: termina SIEMPRE en ERROR "HUMO 275 OK ...")
-- ---------------------------------------------------------------------
do $h$
declare n int; usd numeric; t text;
begin
  -- la regla: tiene que decir que si
  foreach t in array array['', '   ', 'NO HAY', 'no hay', 'No  Hay', ' NO-HAY ', '-', '--', 'N/A', 'n/a', 'NA', 'Ninguno', 'NINGUNA',
                           'Sin closer', 'sin setter', 'Sin asignar', 'Nadie', 'NULL', 'none', 'Ningún', 'NÓ HAY'] loop
    if not public.fin_es_sin_persona(t) then
      raise exception 'HUMO 275: la regla no reconoce [%]', t;
    end if;
  end loop;
  if public.fin_es_sin_persona(null) is not true then raise exception 'HUMO 275: null tiene que ser sin persona'; end if;
  -- y tiene que decir que no a personas reales
  foreach t in array array['Juani', 'JUANI', 'Male', 'Franco Lagrega', 'Ivo', 'Nacho', 'Valen', 'Bill', 'Naza', 'Lucas Financiera', 'Noelia'] loop
    if public.fin_es_sin_persona(t) then raise exception 'HUMO 275: la regla toma por vacio a [%]', t; end if;
  end loop;

  -- cuanto toca el bloque 4 (mismo criterio), en meses abiertos y pendientes
  select count(*), coalesce(sum(t2.monto_usd), 0) into n, usd
    from public.fin_cierre_transferencias t2
   where t2.tipo = 'comision' and t2.auto and t2.activo and t2.estado = 'pendiente'
     and public.fin_es_sin_persona(t2.destinatario)
     and not exists (select 1 from public.fin_cierre_meses m where m.mes = t2.mes and m.estado = 'cerrado');
  raise exception 'HUMO 275 OK: el bloque 4 daria de baja % filas por USD %', n, usd;
end
$h$;

-- ---------------------------------------------------------------------
-- BLOQUE 3. fin_v_cierre_ventas: mismas columnas que la 269; el alias "sin persona" no busca vendedor ni comisiona
-- ---------------------------------------------------------------------
create or replace view public.fin_v_cierre_ventas as
with base as (
  select p.cliente_id, (date_trunc('month', p.fecha))::date as mes, coalesce(p.clave, 'id:' || p.id) as pago_clave,
         p.fecha, p.alumno, p.programa, p.concepto, p.monto_usd, p.closer, p.setter
    from public.fin_pagos p
   where p.cliente_id in ('liam', 'agus', 'teo') and public.es_fundador()
), roles as (
  select b.*, 'closer'::text as rol, b.closer as alias from base b
  union all
  select b.*, 'setter'::text as rol, b.setter as alias from base b
), nrm as (
  -- 275: vacio / NO HAY / - / N/A / ninguno... => alias_ok null (esa venta no comisiona en ese rol)
  select r.*, case when public.fin_es_sin_persona(r.alias) then null else btrim(r.alias) end as alias_ok
    from roles r
), res as (
  select r.*, v.nombre as vendedor, v.es_persona, ag.comisiona
    from nrm r
    left join lateral (
      select vv.id, vv.nombre, vv.es_persona
        from public.fin_personas a
        join public.fin_vendedores vv on vv.id = a.vendedor_id
       where r.alias_ok is not null
         and lower(btrim(a.alias)) = lower(btrim(r.alias_ok))
         and (a.cliente_id = r.cliente_id or a.cliente_id is null)
         and (a.campo is null or a.campo in (r.rol, 'ambos'))
       order by (a.cliente_id is not null) desc
       limit 1) v on true
    left join lateral (
      select g.comisiona from public.fin_vendedor_asignaciones g
       where g.vendedor_id = v.id and g.cliente_id = r.cliente_id limit 1) ag on true
), calc as (
  select s.*,
         case when s.alias_ok is null then null else coalesce(s.vendedor, btrim(s.alias_ok)) end as persona,
         case when s.alias_ok is null then null else public.fin_normalizar_nombre(coalesce(s.vendedor, btrim(s.alias_ok))) end as persona_norm
    from res s
)
select c.mes, c.cliente_id, c.pago_clave, c.fecha, c.alumno, c.programa, c.concepto, c.monto_usd, c.rol,
       c.persona, c.persona_norm,
       (c.alias_ok is null) as falta_persona,
       (c.alias_ok is not null and (coalesce(c.es_persona, true) = false or coalesce(c.comisiona, true) = false)) as no_comisiona,
       (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct') as pct_base,
       (select cp.porcentaje from public.fin_cierre_comision_persona cp
         where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
         order by (cp.cliente_id is not null) desc limit 1) as pct_persona,
       cv.porcentaje as pct_venta,
       coalesce(cv.porcentaje,
                (select cp.porcentaje from public.fin_cierre_comision_persona cp
                  where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
                  order by (cp.cliente_id is not null) desc limit 1),
                (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct'), 0) as pct_aplicado,
       case when c.alias_ok is null or c.alias_ok is not null and (coalesce(c.es_persona, true) = false or coalesce(c.comisiona, true) = false) then 0
            else round(c.monto_usd * coalesce(cv.porcentaje,
                (select cp.porcentaje from public.fin_cierre_comision_persona cp
                  where cp.persona_norm = c.persona_norm and cp.rol = c.rol and (cp.cliente_id = c.cliente_id or cp.cliente_id is null)
                  order by (cp.cliente_id is not null) desc limit 1),
                (select pa.valor from public.fin_cierre_parametros pa where pa.clave = 'comision_' || c.rol || '_pct'), 0) / 100, 2) end as comision_usd
  from calc c
  left join public.fin_cierre_comision_venta cv on cv.cliente_id = c.cliente_id and cv.pago_clave = c.pago_clave and cv.rol = c.rol;

revoke all on public.fin_v_cierre_ventas from public, anon, authenticated;
grant select on public.fin_v_cierre_ventas to authenticated;
grant select on public.fin_v_cierre_ventas to service_role;

-- ---------------------------------------------------------------------
-- BLOQUE 4. Baja de las comisiones ya generadas a "NO HAY" (pendientes, automaticas, meses abiertos). Con respaldo.
-- ---------------------------------------------------------------------
create table if not exists public.fin_cierre_transf_respaldo_275 (
  transferencia_id bigint primary key,
  mes date not null,
  cliente_id text,
  destinatario text not null,
  concepto text not null,
  monto_usd numeric not null,
  activo_antes boolean not null,
  respaldado_en timestamptz not null default now()
);
alter table public.fin_cierre_transf_respaldo_275 enable row level security;
revoke all on public.fin_cierre_transf_respaldo_275 from public, anon, authenticated;
grant select on public.fin_cierre_transf_respaldo_275 to service_role;

insert into public.fin_cierre_transf_respaldo_275 (transferencia_id, mes, cliente_id, destinatario, concepto, monto_usd, activo_antes)
select t.id, t.mes, t.cliente_id, t.destinatario, t.concepto, t.monto_usd, t.activo
  from public.fin_cierre_transferencias t
 where t.tipo = 'comision' and t.auto and t.activo and t.estado = 'pendiente'
   and public.fin_es_sin_persona(t.destinatario)
   and not exists (select 1 from public.fin_cierre_meses m where m.mes = t.mes and m.estado = 'cerrado')
on conflict (transferencia_id) do nothing;

update public.fin_cierre_transferencias t
   set activo = false, monto_calc = 0,
       nota = left(coalesce(nullif(t.nota, '') || ' · ', '') || '275: baja, closer/setter sin persona (NO HAY o vacio)', 500),
       actualizado_en = now()
 where t.id in (select transferencia_id from public.fin_cierre_transf_respaldo_275)
   and t.tipo = 'comision' and t.auto and t.activo and t.estado = 'pendiente'
   and public.fin_es_sin_persona(t.destinatario)
   and not exists (select 1 from public.fin_cierre_meses m where m.mes = t.mes and m.estado = 'cerrado');

-- ---------------------------------------------------------------------
-- CONTROLES (de a uno). Los que leen vistas piden fundador: poner el uuid en la misma ejecucion.
-- ---------------------------------------------------------------------
-- C1. Lo que dio de baja el bloque 4: cuantas filas y por cuanto, por mes y cliente. Esperado Teo octubre: 1 fila por USD 60 (a verificar).
-- select r.mes, r.cliente_id, r.destinatario, count(*) as filas, sum(r.monto_usd) as usd
--   from public.fin_cierre_transf_respaldo_275 r group by 1, 2, 3 order by 1, 2, 3;
-- C1b. Total.
-- select count(*) as filas, coalesce(sum(monto_usd), 0) as usd from public.fin_cierre_transf_respaldo_275;
-- C2. Comisiones a "sin persona" que NO se tocaron (hechas, o de meses cerrados): decidir a mano. Esperado: 0 filas.
-- select t.id, t.mes, t.cliente_id, t.destinatario, t.monto_usd, t.estado, t.activo
--   from public.fin_cierre_transferencias t
--  where t.tipo = 'comision' and public.fin_es_sin_persona(t.destinatario)
--    and t.id not in (select transferencia_id from public.fin_cierre_transf_respaldo_275)
--    and (t.activo or t.estado = 'hecha') order by t.mes, t.cliente_id;
-- C3. Ventas con closer/setter sin persona, octubre, por cliente y rol (con fundador). Todas deben tener persona null y comision 0.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select cliente_id, rol, count(*) as ventas, sum(monto_usd) as usd_vendido, sum(comision_usd) as comision_usd,
--        count(*) filter (where persona is not null) as con_persona_por_error
--   from public.fin_v_cierre_ventas where mes = date '2026-10-01' and falta_persona group by 1, 2 order by 1, 2;
-- C4. Que no queden comisiones calculadas para nadie llamado NO HAY / vacio (con fundador). Esperado: 0 filas.
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select mes, cliente_id, rol, persona, sum(comision_usd) from public.fin_v_cierre_ventas
--  where public.fin_es_sin_persona(persona) and comision_usd <> 0 group by 1, 2, 3, 4;
-- C5. Porcentajes cargados a mano para un "sin persona" (por persona o por venta). Esperado: 0 filas (si hay, borrar a mano).
-- select 'persona' as donde, persona, rol, porcentaje from public.fin_cierre_comision_persona where public.fin_es_sin_persona(persona)
-- union all
-- select 'venta', pago_clave, rol, porcentaje from public.fin_cierre_comision_venta;  -- revisar a ojo los de pagos con closer/setter vacio
-- C6. Alias de fin_personas / vendedores que se llamen "NO HAY" (no cambian el resultado ahora, pero conviene limpiar). Esperado: 0 filas.
-- select a.id, a.alias, a.cliente_id, a.campo, v.nombre from public.fin_personas a left join public.fin_vendedores v on v.id = a.vendedor_id
--  where public.fin_es_sin_persona(a.alias) or public.fin_es_sin_persona(v.nombre);
-- C7. Despues de correr "Calcular transferencias" de octubre (fin_cierre_generar): comisiones activas de octubre por destinatario (sin NO HAY).
-- select cliente_id, destinatario, monto_usd, estado, activo from public.fin_cierre_transferencias
--  where tipo = 'comision' and mes = date '2026-10-01' and activo order by cliente_id, destinatario;
-- C8. Totales de octubre por cliente despues de recalcular (con fundador). Esperado: Agus->Dys 25.390,50 · Liam 17.966,21 · Teo 4.361,47 (los de antes, a comparar).
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select entidad, facturacion_usd, ganancia_dystopia_usd from public.fin_v_dys_ganancia_mes where mes = date '2026-10-01' order by entidad;

-- =====================================================================
-- DIAGNOSTICO PUNTO 3 (webinar BPF 14/10): solo lectura, NO forma parte de la migracion. Correr de a uno, con fundador.
--   Esperado por la regla: 19 pagos / 15.099,36. Hoy da 18 / 14.074,36. Diferencia exacta: USD 1.025.
-- D1. Los pagos de Liam que la app cuenta como Webinar en la ventana 14-28/10 (deberian ser 18 / 14.074,36):
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select v.fecha, v.alumno, v.monto_usd, v.fuente_planilla, v.fuente_final, v.criterio, v.primer_pago_fecha
--   from public.fin_v_pago_fuente v
--  where v.cliente_id = 'liam' and v.es_webinar and v.fecha between date '2026-10-14' and date '2026-10-28' order by v.fecha, v.alumno;
-- D2. Cualquier pago de Liam de USD 1.025 (o cercano) desde el 14/10, este o no en la ventana:
-- select p.id, p.fecha, p.alumno, p.monto_usd, p.origen, p.fila_planilla, p.fuente_lead, p.fuente_ingreso, p.nota
--   from public.fin_pagos p where p.cliente_id = 'liam' and p.fecha >= date '2026-10-14' and p.monto_usd between 1024 and 1026;
-- D3. Si las filas 303-307 de la hoja de Liam llegaron a la base. Esperado octubre Liam: 62 pagos / 70.431,36 (si da 57 / 63.345,36 las 5 filas NO entraron):
-- select count(*) as pagos, sum(monto_usd) as usd, max(fecha) as ultima_fecha
--   from public.fin_pagos where cliente_id = 'liam' and fecha >= date '2026-10-01' and fecha < date '2026-11-01';
-- D4. Pagos de Liam en la ventana que NO son Webinar y por que (si el de 1.025 esta aca, el criterio lo dice):
-- select set_config('request.jwt.claim.sub', '<UUID-FUNDADOR>', true);
-- select v.fecha, v.alumno, v.monto_usd, v.fuente_planilla, v.fuente_final, v.criterio, v.primer_pago_fecha
--   from public.fin_v_pago_fuente v
--  where v.cliente_id = 'liam' and not v.es_webinar and v.fecha between date '2026-10-14' and date '2026-10-28' order by v.fecha, v.alumno;

-- =====================================================================
-- VUELTA ATRAS
--   update public.fin_cierre_transferencias t set activo = r.activo_antes, nota = null, actualizado_en = now()
--     from public.fin_cierre_transf_respaldo_275 r where r.transferencia_id = t.id;   -- (la nota se pisa: ajustar si tenia texto)
--   Para la vista: volver a correr el bloque "create or replace view fin_v_cierre_ventas" de la 269.
--   drop function public.fin_es_sin_persona(text);   -- solo despues de volver la vista a la 269 (la vista la usa)
--   drop table public.fin_cierre_transf_respaldo_275;
-- =====================================================================
