-- vinculos-liam-renov.sql  (SOLO SELECT; no escribe nada)
-- Propuesta de vinculacion de los pagos de renovacion/resell de liam que no tienen ficha de Producto.
--
-- Una sola sentencia, una fila por PAGO. Pagos = fin_pagos de liam con concepto que contiene RENOV, RENEW o RESELL
-- y cuyo alumno (fin_cs_norm_nombre) NO tiene un fin_cs_vinculo 'vinculado' a una ficha existente de liam.
-- Se descartan como candidatas las fichas cerradas por la 164 (e4c8102a, be2a3e68, 2375ab58): se vincula a las
-- vigentes 28d200e3, 5955e47d y 17d1c875.
--
-- SENALES (por pago x ficha; el nombre de la ficha incluye sus alias de cs_clientes_alias, que hacen de "apodo"):
--   clave     fin_pagos.clave = cs_clientes.pago_clave
--   exacto    nombre normalizado igual al de la ficha (o a un alias)
--   tel       ultimos 8 digitos del telefono del pago = los de la ficha
--   apellido  comparten alguna palabra (>= 3 letras) que no es la primera del nombre
--   parecido  primer nombre: uno es prefijo del otro (>= 3 letras) o comparten las 4 primeras letras
--   corto     el pago trae UNA sola palabra (ej. "Nahue") y es prefijo (>= 3 letras) del primer nombre de la ficha
--   fecha     el pago cae a <= 45 dias de la fecha de resultado de una renovacion 'renovado' de la ficha (cs_renovaciones)
--   Email: fin_pagos NO tiene email, no hay senal por mail; la columna ficha_email sirve para mirarlo a ojo.
--
-- RANGO de la mejor senal (1 es la mas fuerte) y CONFIANZA:
--   1 clave igual | 2 nombre exacto | 3 alias exacto | 4 tel + (apellido o parecido) | 5 apellido + parecido
--   6 corto + fecha cerca                          -> Alta si es la unica ficha de ese rango y esta vigente
--                                                     (si hay empate, o la ficha esta finalizada/baja: Media)
--   7 solo tel | 8 corto sin fecha cerca           -> Media si es unica, si no Baja
--   9 solo apellido + fecha cerca | 10 solo apellido -> Baja (nombre de pila distinto)
--   sin ninguna senal                              -> Sin candidato
-- Importante: el vinculo es por NOMBRE (alumno_norm), no por pago. Si un mismo nombre aparece con dos fichas
-- distintas en distintos pagos, mirar la columna fichas_distintas_mismo_nombre.
-- Si cambias la logica aca, cambiala igual en 166_vinculos_liam_renov.sql (mismo bloque de CTEs).

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
),
clasif as (
  select p.pago_id, p.fecha, p.alumno, p.an, p.telefono, p.monto_usd, p.concepto,
         b.ficha_id, b.rk, b.n_top, b.dias, b.f_estado,
         case when b.ficha_id is null then 'Sin candidato'
              when b.rk <= 6 and b.n_top = 1 and b.f_estado not in ('finalizado', 'baja') then 'Alta'
              when b.rk <= 6 then 'Media'
              when b.rk in (7, 8) and b.n_top = 1 then 'Media'
              else 'Baja' end as confianza,
         case b.rk
           when 1 then 'pago_clave igual al de la ficha'
           when 2 then 'nombre exacto normalizado'
           when 3 then 'alias de la ficha igual al nombre'
           when 4 then 'telefono igual + nombre/apellido parecido'
           when 5 then 'apellido igual + nombre de pila parecido'
           when 6 then 'nombre abreviado sin apellido + pago a ' || b.dias || ' dias de la renovacion'
           when 7 then 'solo telefono igual (puede ser compartido)'
           when 8 then 'nombre abreviado sin apellido, sin renovacion cerca'
           when 9 then 'solo apellido igual (nombre de pila distinto), pago a ' || b.dias || ' dias de la renovacion'
           when 10 then 'solo apellido igual (nombre de pila distinto)'
           else 'ninguna senal (nombre, alias, telefono, apellido)' end
         || case when b.n_top > 1 then ' | EMPATE con ' || (b.n_top - 1) || ' ficha(s) mas del mismo rango' else '' end
         || case when b.f_estado in ('finalizado', 'baja') then ' | ficha ' || b.f_estado else '' end
           as motivo
    from pagos p
    left join best b on b.pago_id = p.pago_id and b.rn = 1
)
select cl.confianza,
       cl.pago_id,
       cl.fecha as fecha_pago,
       cl.monto_usd,
       cl.concepto,
       cl.alumno as nombre_en_hoja,
       cl.an as alumno_norm,
       cl.telefono as tel_pago,
       (select v.estado from public.fin_cs_vinculo v
         where v.cliente_id = 'liam' and v.alumno_norm = cl.an) as vinculo_actual,
       f.id as ficha_id,
       left(f.id::text, 8) as ficha_id8,
       f.nombre as ficha_nombre,
       f.estado as ficha_estado,
       f.telefono as ficha_tel,
       f.email as ficha_email,
       f.fecha_inicio, f.fecha_fin,
       cl.dias as dias_pago_vs_renovacion,
       cl.rk as rango_senal,
       cl.motivo,
       cl.n_top as fichas_empatadas,
       ot.otros as otros_candidatos,
       (select count(distinct c3.ficha_id) from clasif c3 where c3.an = cl.an) as fichas_distintas_mismo_nombre
  from clasif cl
  left join fichas f on f.id = cl.ficha_id
  left join lateral (
    select string_agg(f2.nombre || ' [' || left(f2.id::text, 8) || ', rango ' || c2.rk || ']',
                      ' | ' order by c2.rk, f2.nombre) as otros
      from top c2
      join fichas f2 on f2.id = c2.ficha_id
     where c2.pago_id = cl.pago_id and c2.ficha_id is distinct from cl.ficha_id) ot on true
 order by case cl.confianza when 'Alta' then 1 when 'Media' then 2 when 'Baja' then 3 else 4 end,
          cl.an, cl.fecha;
