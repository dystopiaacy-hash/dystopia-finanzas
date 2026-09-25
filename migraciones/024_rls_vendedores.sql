-- =====================================================================
-- 024_rls_vendedores.sql
-- Cierra el acceso de closers y setters a las tablas de comisiones y
-- saca el comodin de alias entre clientes. Prepara el alta de esos roles.
--
-- EL AGUJERO: cuatro politicas de las migraciones 011 y 012 conceden con
-- tiene_acceso() pelado, sin mirar el rol, y ademas con una rama
-- "cliente_id in (fin_clientes_del_usuario())".
--
-- fin_clientes_del_usuario() devuelve los clientes donde el usuario tiene
-- fila en fin_personas. Y esa fila es justo la que hay que crear para que
-- funcione el matcheo por alias de fin_llamadas y fin_pagos.
--
-- O sea: al dar de alta un closer como corresponde, esa rama ya le
-- concedia fin_liquidaciones, fin_liquidacion_items,
-- fin_vendedor_asignaciones y fin_vendedores del cliente entero. Las
-- comisiones de todos sus companeros, incluido el pct_override.
--
-- No hay forma de configurar un closer bien sin abrirlo. El patron
-- correcto ya estaba en el codigo: fin_pnl, crm_revenue, fin_pagos y
-- fin_llamadas conceden con rol_actual() = 'cliente' and tiene_acceso().
-- Las cuatro sueltas son las que escribi yo en las tablas con la plata.
--
-- EL COMODIN: en fin_llamadas, fin_pagos y fin_cuotas la condicion es
-- "(p.cliente_id is null or p.cliente_id = cliente_id)". Con cliente_id
-- nulo, el alias matchea contra TODOS los clientes. "FELIPE" en teo es
-- Felipe Byrne y en lucas hay un Felipe Vatovec: dos personas distintas,
-- mismo alias. Uno leeria las llamadas del otro. Se exige cliente_id.
--
-- QUE DECIDE ESTA MIGRACION: closers y setters no acceden a ninguna
-- tabla de comisiones, ni a la propia. La agencia pidio que vean
-- llamadas, no comisiones. Se concede exactamente lo pedido, porque
-- despues se puede agregar y no se puede des-mostrar.
--
-- QUE NO PUEDE ARREGLAR: fin_llamadas no tiene columna setter. Ningun
-- cliente la tiene en la hoja Data. No se puede saber que setter agendo
-- que llamada, asi que no hay acceso de setter a llamadas. Es un pedido
-- a la agencia, no algo que se resuelva en SQL.
--
-- VERIFICADO ANTES DE ESCRIBIRLA: no hay ninguna fila de fin_personas
-- con user_id. Ningun usuario pierde acceso que hoy tenga.
-- =====================================================================

begin;

-- =====================================================================
-- 1. TABLAS DE COMISIONES: solo fundador y cliente.
-- =====================================================================

drop policy if exists fin_liq_lectura on fin_liquidaciones;
create policy fin_liq_lectura on fin_liquidaciones
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
  );

drop policy if exists fin_liq_items_lectura on fin_liquidacion_items;
create policy fin_liq_items_lectura on fin_liquidacion_items
  for select using (
    es_fundador()
    or exists (
      select 1 from fin_liquidaciones l
      where l.id = fin_liquidacion_items.liquidacion_id
        and rol_actual() = 'cliente'
        and tiene_acceso(l.cliente_id)
    )
  );

drop policy if exists fin_asignaciones_lectura on fin_vendedor_asignaciones;
create policy fin_asignaciones_lectura on fin_vendedor_asignaciones
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
  );

drop policy if exists fin_vendedores_lectura on fin_vendedores;
create policy fin_vendedores_lectura on fin_vendedores
  for select using (
    es_fundador()
    or exists (
      select 1 from fin_vendedor_asignaciones a
      where a.vendedor_id = fin_vendedores.id
        and rol_actual() = 'cliente'
        and tiene_acceso(a.cliente_id)
    )
  );

-- El mapa de fuentes lo cree hoy con el mismo atajo. Mismo criterio.
drop policy if exists fin_fuentes_mapa_lectura on fin_fuentes_mapa;
create policy fin_fuentes_mapa_lectura on fin_fuentes_mapa
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
  );


-- =====================================================================
-- 2. COMODIN DE ALIAS: se exige cliente_id en fin_personas.
--    Ademas fin_cuotas y fin_pagos pasan a exigir p.campo, que hoy solo
--    exige fin_llamadas. Un setter con alias igual al de un closer no
--    tiene por que leer lo del closer.
-- =====================================================================

drop policy if exists fin_llamadas_lectura on fin_llamadas;
create policy fin_llamadas_lectura on fin_llamadas
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
    or (rol_actual() = 'closer' and exists (
          select 1 from fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_llamadas.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_llamadas.closer))
        ))
    -- Sin rama de setter: fin_llamadas no tiene columna setter.
  );

drop policy if exists fin_pagos_lectura on fin_pagos;
create policy fin_pagos_lectura on fin_pagos
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
    or (rol_actual() = 'closer' and exists (
          select 1 from fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_pagos.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.closer))
        ))
    or (rol_actual() = 'setter' and exists (
          select 1 from fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('setter', 'ambos')
            and p.cliente_id = fin_pagos.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_pagos.setter))
        ))
  );

drop policy if exists fin_cuotas_lectura on fin_cuotas;
create policy fin_cuotas_lectura on fin_cuotas
  for select using (
    es_fundador()
    or (rol_actual() = 'cliente' and tiene_acceso(cliente_id))
    or (rol_actual() = 'closer' and exists (
          select 1 from fin_personas p
          where p.user_id = auth.uid()
            and p.campo in ('closer', 'ambos')
            and p.cliente_id = fin_cuotas.cliente_id
            and lower(btrim(p.alias)) = lower(btrim(fin_cuotas.closer))
        ))
  );

commit;


-- =====================================================================
-- CONTROLES (de a uno)
-- =====================================================================

-- 1. ESTRUCTURAL: ninguna politica fin_ concede con tiene_acceso sin
--    nombrar el rol. Es el patron que causo el agujero.
select 'tiene_acceso sin guardia de rol' as control, count(*) as valor_esperado_0
from pg_policies
where schemaname = 'public'
  and tablename like 'fin_%'
  and qual like '%tiene_acceso%'
  and qual not like '%rol_actual()%';

-- 2. ESTRUCTURAL: ninguna politica matchea alias contra todos los
--    clientes.
select 'comodin de cliente_id nulo' as control, count(*) as valor_esperado_0
from pg_policies
where schemaname = 'public'
  and qual like '%p.cliente_id IS NULL%';

-- 3. ESTRUCTURAL: fin_clientes_del_usuario() ya no concede en ninguna
--    politica. La funcion queda, por si se usa a proposito mas adelante.
select 'fin_clientes_del_usuario todavia concede' as control,
       count(*) as valor_esperado_0
from pg_policies
where schemaname = 'public'
  and qual like '%fin_clientes_del_usuario%';

-- 4. NO ROMPI NADA: el fundador sigue viendo todo. Estos conteos tienen
--    que dar igual que antes de la migracion (corren como fundador).
select 'liquidaciones' as tabla, count(*) from fin_liquidaciones
union all select 'liquidacion_items', count(*) from fin_liquidacion_items
union all select 'vendedores', count(*) from fin_vendedores
union all select 'vendedor_asignaciones', count(*) from fin_vendedor_asignaciones
union all select 'llamadas', count(*) from fin_llamadas
union all select 'pagos', count(*) from fin_pagos
union all select 'cuotas', count(*) from fin_cuotas
union all select 'fuentes_mapa', count(*) from fin_fuentes_mapa;

-- 5. Las politicas como quedaron, para leerlas.
select tablename, policyname, cmd, qual
from pg_policies
where schemaname = 'public'
  and tablename in ('fin_liquidaciones', 'fin_liquidacion_items',
                    'fin_vendedores', 'fin_vendedor_asignaciones',
                    'fin_llamadas', 'fin_pagos', 'fin_cuotas',
                    'fin_fuentes_mapa')
order by tablename, policyname;

-- 6. Alias repetidos entre clientes: la razon por la que se saco el
--    comodin. Cada fila es un alias que existe en mas de un cliente y
--    que, con cliente_id nulo, habria cruzado datos.
select lower(btrim(closer)) as alias,
       count(distinct cliente_id) as clientes,
       string_agg(distinct cliente_id, ', ' order by cliente_id) as cuales,
       count(*) as llamadas
from fin_llamadas
where nullif(btrim(closer), '') is not null
group by 1
having count(distinct cliente_id) > 1
order by llamadas desc;
