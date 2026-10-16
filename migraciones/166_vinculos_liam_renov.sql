-- 166_vinculos_liam_renov.sql  (numero asignado por el jefe)
-- Vincula en fin_cs_vinculo los pagos de renovacion/resell (RENOV, RENEW, RESELL) de liam que no tienen ficha,
-- SOLO los de confianza ALTA de migraciones/propuestas/vinculos-liam-renov.sql (mismo bloque de CTEs: si cambia
-- uno, cambia el otro). Los de Media/Baja/Sin candidato NO se tocan: decide Joaquin con el documento
-- migraciones/propuestas/vinculos-liam-renov.md.
--
-- QUE HACE: inserta filas en public.fin_cs_vinculo (cliente 'liam', alumno_norm del nombre de la hoja,
--   estado 'vinculado', origen 'manual'). No toca fin_pagos, fin_cuotas ni cs_*. Las fichas cerradas por la 164
--   (e4c8102a, be2a3e68, 2375ab58) nunca son candidatas: se vincula a las vigentes 28d200e3, 5955e47d, 17d1c875.
--
-- ANTES DE CORRER (obligatorio):
--   1. Correr la consulta propuestas/vinculos-liam-renov.sql y revisar las filas 'Alta' (nombre en hoja -> ficha).
--   2. Poner abajo, en v_esperado, la cantidad de NOMBRES distintos (alumno_norm) con confianza Alta.
--      Con v_esperado en null la migracion aborta. Si el numero real difiere (cambio la data), aborta.
--   3. Correr fuera de :00/:15/:30/:45 (sync) y de :03/:18/:33/:48 (cron fin_cs_vincular_auto, que escribe en la misma
--      tabla; ademas esta migracion toma un lock de la tabla).
-- Requiere: 129 (fin_cs_vinculo y funciones), 164 corrida (fichas vigentes), cs_renovaciones y cs_clientes_alias (Producto).
-- Re-ejecutable: la segunda vez aborta en la guarda (los nombres ya estan vinculados) y no cambia nada.

begin;
set local lock_timeout = '10s';
lock table public.fin_cs_vinculo in share row exclusive mode;

-- ---------------------------------------------------------------------
-- 1. Candidatos (temporal, se borra al terminar la transaccion)
-- ---------------------------------------------------------------------
create temp table _v166 on commit drop as
with
pagos as (
  select p.id as pago_id, p.fecha, p.alumno, p.telefono, p.monto_usd, p.concepto, p.clave,
         public.fin_cs_norm_nombre(p.alumno) as an,
         public.fin_cs_norm_tel(p.telefono) as tel
    from public.fin_pagos p
   where p.cliente_id = 'liam'
     and p.concepto ~* '(renov|renew|resell)'
     and public.fin_cs_norm_nombre(p.alumno) is not null
     and not exists (
           select 1
             from public.fin_cs_vinculo v
             join public.cs_clientes c on c.id = v.cs_cliente_id and c.programa_id = 'liam'
            where v.cliente_id = 'liam' and v.estado = 'vinculado'
              and v.alumno_norm = public.fin_cs_norm_nombre(p.alumno))
),
fichas as (
  select c.id, c.nombre, c.estado, c.telefono, c.email, c.fecha_inicio, c.fecha_fin, c.pago_clave,
         public.fin_cs_norm_nombre(c.nombre) as nom,
         public.fin_cs_norm_tel(c.telefono) as tel
    from public.cs_clientes c
   where c.programa_id = 'liam'
     and left(c.id::text, 8) not in ('e4c8102a', 'be2a3e68', '2375ab58')
),
nombres as (
  select f.id as cs_id, f.nom, false as es_alias from fichas f where f.nom is not null
  union all
  select a.cliente_id, public.fin_cs_norm_nombre(a.alias), true
    from public.cs_clientes_alias a
   where a.programa_id = 'liam' and a.cliente_id in (select id from fichas)
),
cmp as (
  select p.pago_id, n.cs_id, n.es_alias,
         (n.nom = p.an) as ex,
         exists (select 1
                   from unnest((string_to_array(p.an, ' '))[2:]) a
                   join unnest((string_to_array(n.nom, ' '))[2:]) b on a = b
                  where length(a) >= 3) as ap,
         ( (least(length((string_to_array(p.an, ' '))[1]), length((string_to_array(n.nom, ' '))[1])) >= 3
            and (starts_with((string_to_array(n.nom, ' '))[1], (string_to_array(p.an, ' '))[1])
              or starts_with((string_to_array(p.an, ' '))[1], (string_to_array(n.nom, ' '))[1])))
           or (least(length((string_to_array(p.an, ' '))[1]), length((string_to_array(n.nom, ' '))[1])) >= 4
               and left((string_to_array(p.an, ' '))[1], 4) = left((string_to_array(n.nom, ' '))[1], 4)) ) as parecido,
         (cardinality(string_to_array(p.an, ' ')) = 1
          and length(p.an) >= 3
          and starts_with((string_to_array(n.nom, ' '))[1], p.an)) as corto
    from pagos p cross join nombres n
),
par as (
  select c.pago_id, c.cs_id as ficha_id,
         bool_or(c.ex and not c.es_alias) as ex_nombre,
         bool_or(c.ex and c.es_alias) as ex_alias,
         bool_or(c.ap) as ap, bool_or(c.parecido) as parecido, bool_or(c.corto) as corto
    from cmp c
   group by c.pago_id, c.cs_id
),
sen as (
  select pr.pago_id, pr.ficha_id, pr.ex_nombre, pr.ex_alias, pr.ap, pr.parecido, pr.corto,
         (p.clave is not null and f.pago_clave = p.clave) as s_clave,
         (p.tel is not null and p.tel = f.tel) as s_tel,
         rn.dias, coalesce(rn.dias <= 45, false) as s_fecha,
         f.nombre as f_nombre, f.estado as f_estado
    from par pr
    join pagos p on p.pago_id = pr.pago_id
    join fichas f on f.id = pr.ficha_id
    left join lateral (
      select min(abs(p.fecha - (coalesce(r.resultado_at, r.updated_at)
                                at time zone 'America/Argentina/Buenos_Aires')::date)) as dias
        from public.cs_renovaciones r
       where r.cliente_id = f.id and r.programa_id = 'liam' and r.estado = 'renovado') rn on true
),
cand as (
  select s.*,
         case when s.s_clave then 1
              when s.ex_nombre then 2
              when s.ex_alias then 3
              when s.s_tel and (s.ap or s.parecido) then 4
              when s.ap and s.parecido then 5
              when s.corto and s.s_fecha then 6
              when s.s_tel then 7
              when s.corto then 8
              when s.ap and s.s_fecha then 9
              when s.ap then 10 end as rk
    from sen s
),
top as (
  select c.*, min(c.rk) over (partition by c.pago_id) as rk_min
    from cand c
   where c.rk is not null
),
best as (
  select t.*,
         count(*) over (partition by t.pago_id) as n_top,
         row_number() over (partition by t.pago_id
                            order by (t.f_estado in ('finalizado', 'baja')), t.dias nulls last, t.f_nombre, t.ficha_id) as rn
    from top t
   where t.rk = t.rk_min
)
select p.pago_id, p.fecha, p.alumno, p.an, b.ficha_id, b.rk, b.f_nombre,
       case when b.ficha_id is null then 'Sin candidato'
            when b.rk <= 6 and b.n_top = 1 and b.f_estado not in ('finalizado', 'baja') then 'Alta'
            when b.rk <= 6 then 'Media'
            when b.rk in (7, 8) and b.n_top = 1 then 'Media'
            else 'Baja' end as confianza
  from pagos p
  left join best b on b.pago_id = p.pago_id and b.rn = 1;

-- ---------------------------------------------------------------------
-- 2. Guardas (si alguna falla, no se aplica nada)
-- ---------------------------------------------------------------------
do $$
declare
  v_esperado int := 9;      -- 16/10/2026 jefe: 9 nombres Alta segun la consulta (aprobado por Joaquin, incluido fede aime -> 85d2753e)
  v_alta     int;
  v_txt      text;
begin
  if to_regclass('public.fin_cs_vinculo') is null or to_regclass('public.cs_renovaciones') is null
     or to_regclass('public.cs_clientes_alias') is null then
    raise exception 'GUARDA 166: faltan fin_cs_vinculo (129), cs_renovaciones o cs_clientes_alias (Producto)';
  end if;
  -- 164 corrida: las 3 vigentes existen y las 3 cerradas ya no estan activas
  if (select count(*) from public.cs_clientes c
       where c.programa_id = 'liam' and left(c.id::text, 8) in ('28d200e3', '5955e47d', '17d1c875')) <> 3 then
    raise exception 'GUARDA 166: no estan las 3 fichas vigentes (28d200e3, 5955e47d, 17d1c875). Falta la 164?';
  end if;
  if exists (select 1 from public.cs_clientes c
              where c.programa_id = 'liam' and left(c.id::text, 8) in ('e4c8102a', 'be2a3e68', '2375ab58')
                and c.estado <> 'finalizado') then
    raise exception 'GUARDA 166: alguna ficha duplicada (e4c8102a, be2a3e68, 2375ab58) no esta finalizada. Falta la 164?';
  end if;
  if v_esperado is null then
    raise exception 'GUARDA 166: completar v_esperado con la cantidad de nombres Alta de la consulta propuestas/vinculos-liam-renov.sql';
  end if;

  select count(distinct t.an) into v_alta from _v166 t where t.confianza = 'Alta';
  if v_alta <> v_esperado then
    raise exception 'GUARDA 166: nombres Alta = % y se esperaban %. Si ya se corrio, todo esta vinculado; si no, la data cambio: rehacer la consulta.',
      v_alta, v_esperado;
  end if;

  -- un mismo nombre no puede apuntar a dos fichas distintas entre sus pagos
  select string_agg(x.an, ', ') into v_txt
    from (select t.an from _v166 t where t.ficha_id is not null
           group by t.an having count(distinct t.ficha_id) > 1) x;
  if v_txt is not null then
    raise exception 'GUARDA 166: nombres con fichas distintas segun el pago (decidir a mano): %', v_txt;
  end if;

  -- ya existen vinculos (de cualquier estado) para esos nombres
  select string_agg(v.alumno_norm || ' (' || v.estado || ')', ', ') into v_txt
    from public.fin_cs_vinculo v
   where v.cliente_id = 'liam'
     and v.alumno_norm in (select t.an from _v166 t where t.confianza = 'Alta');
  if v_txt is not null then
    raise exception 'GUARDA 166: ya existe vinculo para: %. No se aplica nada.', v_txt;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Aplicar: un vinculo por nombre (alumno_norm), a la ficha Alta
-- ---------------------------------------------------------------------
insert into public.fin_cs_vinculo (cliente_id, alumno_norm, alumno_ejemplo, estado, cs_cliente_id, origen)
select 'liam', t.an,
       (array_agg(t.alumno order by t.fecha desc, t.pago_id desc))[1],
       'vinculado',
       (array_agg(t.ficha_id))[1],
       'manual'
  from _v166 t
 where t.confianza = 'Alta'
 group by t.an;

-- ---------------------------------------------------------------------
-- 4. Vinculo manual agregado por el jefe el 16/10/2026 (aprobado por Joaquin):
--    "Fran Ravizzolli" (pago 2504960, 14/07, sin candidato en la consulta) -> ficha Franco Ravizzoli 97434d66.
--    Misma forma que los Alta (alumno_norm = fin_cs_norm_nombre(alumno), estado 'vinculado', origen 'manual').
--    Guarda propia: si ya existe un vinculo para ese nombre, o falta el pago o la ficha, aborta todo.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.fin_pagos p
                  where p.id = 2504960 and p.cliente_id = 'liam' and p.alumno = 'Fran Ravizzolli') then
    raise exception 'GUARDA 166 (Fran): no esta el pago 2504960 de "Fran Ravizzolli" en liam';
  end if;
  if not exists (select 1 from public.cs_clientes c
                  where c.id = '97434d66-c029-4c1e-9d2a-45fc6d85d884' and c.programa_id = 'liam'
                    and c.estado not in ('finalizado', 'baja')) then
    raise exception 'GUARDA 166 (Fran): la ficha 97434d66 (Franco Ravizzoli) no esta o no esta vigente en liam';
  end if;
  if exists (select 1 from public.fin_cs_vinculo v
              where v.cliente_id = 'liam' and v.alumno_norm = public.fin_cs_norm_nombre('Fran Ravizzolli')) then
    raise exception 'GUARDA 166 (Fran): ya existe vinculo para "%". No se aplica nada.', public.fin_cs_norm_nombre('Fran Ravizzolli');
  end if;
end $$;

insert into public.fin_cs_vinculo (cliente_id, alumno_norm, alumno_ejemplo, estado, cs_cliente_id, origen)
select 'liam', public.fin_cs_norm_nombre(p.alumno), p.alumno, 'vinculado',
       '97434d66-c029-4c1e-9d2a-45fc6d85d884'::uuid, 'manual'
  from public.fin_pagos p
 where p.id = 2504960 and p.cliente_id = 'liam';

-- ---------------------------------------------------------------------
-- 5. Verificacion final (jefe 16/10/2026): esta transaccion creo exactamente 10 nombres (9 Alta + Fran).
-- ---------------------------------------------------------------------
do $$
declare v_n int;
begin
  select count(*) into v_n from public.fin_cs_vinculo v
   where v.cliente_id = 'liam' and v.origen = 'manual' and v.estado = 'vinculado' and v.creado_en = now();
  if v_n <> 10 then
    raise exception 'GUARDA 166 final: se crearon % vinculos y se esperaban 10 (9 Alta + Fran). No se aplica nada.', v_n;
  end if;
end $$;

commit;

-- ===========================================================================
-- CONTROLES: correr DE A UNO (el editor muestra solo el ultimo resultado).
-- ===========================================================================
-- C1. Lo que se creo (todas las filas comparten creado_en: ese valor se usa en la vuelta atras).
--     Esperado: 10 filas (v_esperado 9 Alta + Fran Ravizzolli, jefe 16/10); cada alumno_finanzas con su ficha; ficha_estado no finalizado.
--   select v.creado_en, v.alumno_ejemplo as alumno_finanzas, c.nombre as ficha, left(c.id::text, 8) as ficha_id8,
--          c.estado as ficha_estado
--     from public.fin_cs_vinculo v join public.cs_clientes c on c.id = v.cs_cliente_id
--    where v.cliente_id = 'liam' and v.origen = 'manual' and v.estado = 'vinculado'
--      and v.creado_en = (select max(v2.creado_en) from public.fin_cs_vinculo v2
--                          where v2.cliente_id = 'liam' and v2.origen = 'manual')
--    order by 2;
--
-- C2. Nunca a una ficha cerrada por la 164. Esperado: 0 filas.
--   select v.alumno_ejemplo, left(v.cs_cliente_id::text, 8) from public.fin_cs_vinculo v
--    where v.cliente_id = 'liam' and left(v.cs_cliente_id::text, 8) in ('e4c8102a', 'be2a3e68', '2375ab58');
--
-- C3. Pagos de renovacion de liam que siguen sin ficha (esperado: los Media/Baja/Sin candidato; antes eran 20 de 30; con Fran manual quedan 6).
--   select count(*) as sin_vincular
--     from public.fin_pagos p
--    where p.cliente_id = 'liam' and p.concepto ~* '(renov|renew|resell)'
--      and not exists (select 1 from public.fin_cs_vinculo v join public.cs_clientes c on c.id = v.cs_cliente_id
--                       where v.cliente_id = 'liam' and v.estado = 'vinculado'
--                         and v.alumno_norm = public.fin_cs_norm_nombre(p.alumno));
--
-- C4. Estado de pagos de las fichas tocadas (solo conteos, sin montos).
--   select e.cs_cliente_id, e.nombres_finanzas, e.cuotas_total, e.cuotas_atrasadas, e.ultimo_pago
--     from public.fin_cs_estado_pagos('liam') e
--    where e.nombres_finanzas > 1 order by e.ultimo_pago desc nulls last;
--
-- ---------------------------------------------------------------------
-- VUELTA ATRAS (solo borra los vinculos creados por esta migracion; poner el creado_en que dio C1):
--   begin;
--   delete from public.fin_cs_vinculo
--    where cliente_id = 'liam' and origen = 'manual' and estado = 'vinculado'
--      and creado_en = '<creado_en de C1>'::timestamptz;      -- debe borrar 10 filas (9 Alta + Fran)
--   commit;
--   -- La vinculacion automatica (cron) NO los rehace como manual, pero puede volver a vincular los que
--   -- coincidan por pago_clave, telefono o nombre exacto: es lo esperado. Para dejarlos sin vinculo a proposito
--   -- usar 'desvincular' desde la pantalla Vincular.
