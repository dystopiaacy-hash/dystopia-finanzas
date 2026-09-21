-- 000_inspeccion.sql — Dystopia Finanzas
-- SOLO LECTURA. No modifica nada. Se corre en el SQL Editor de Supabase.
--
-- Casi toda la inspeccion de la fase 1 ya se corrio el 2026-09-21 y esta
-- volcada en DATOS-CONFIRMADOS.md (version de Postgres, ids de crm_clients,
-- firmas de es_fundador/rol_actual/tiene_acceso, pg_cron y pg_net, choque de
-- nombres fin_). No se repite aca.
--
-- Lo unico que falta relevar: si crm_members.rol tiene un CHECK constraint
-- que limite los valores. 001_esquema_fin.sql lo resuelve solo (si existe,
-- lo extiende con 'closer' y 'setter'; si no existe, no hace nada), pero
-- conviene ver el resultado antes de correr 001.

-- 1) Todos los constraints de crm_members (CHECK = contype 'c').
select conname,
       contype,
       pg_get_constraintdef(oid) as definicion
from pg_constraint
where conrelid = 'public.crm_members'::regclass
order by conname;

-- 2) Valores de rol que hay hoy en la tabla (control: se espera solo 'fundador').
select rol, count(*) as cantidad
from public.crm_members
group by rol
order by rol;
