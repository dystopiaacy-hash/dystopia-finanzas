# DATOS-CONFIRMADOS.md — verificado en Supabase el 2026-09-21

No los vuelvas a consultar ni los asumas distinto. Esto ya se corrio.

## Postgres
- PostgreSQL 17.6. `security_invoker` en vistas esta soportado.

## Clientes (tabla `crm_clients`)
Columnas: `id text`, `nombre text`, `color text`, `orden int`,
`data jsonb`, `updated_at timestamptz`.

| id | nombre | orden |
|---|---|---|
| liam | Liam Wickham | 0 |
| agus | Agus Friedrichs | 1 |
| teo | Teo North | 2 |
| mauro | Mauro Escribano | 3 |
| lucas | Lucas Auletta | 4 |

Los 5 ids coinciden con los que usa CONFIG-FUENTES.md. Las FK de
`fin_fuentes.cliente_id` van contra `crm_clients(id)`.

## Miembros (tabla `crm_members`)
Columnas: `user_id uuid`, `rol text`, `nombre text`.
Contenido actual: 1 sola fila, rol `fundador`.

Consecuencia: los roles `cliente`, `editor`, `closer` y `setter` NO existen
todavia como filas. `rol` es `text`, no un enum. Antes de escribir el
esquema, verifica si hay un CHECK constraint sobre `crm_members.rol` con:

  select conname, pg_get_constraintdef(oid) from pg_constraint
  where conrelid = 'crm_members'::regclass;

Si existe un CHECK que limita los valores, la migracion tiene que
extenderlo para admitir `closer` y `setter`. Eso va en 001, no lo dejes
para despues.

## Asignaciones (tabla `crm_asignaciones`)
Columnas: `user_id uuid`, `cliente_id text`.
Es el mapeo usuario a cliente que ya usa `tiene_acceso()`. Reusalo, NO
crees una tabla equivalente.

## Funciones existentes (todas en `public`)
| funcion | argumentos | devuelve |
|---|---|---|
| `es_fundador()` | sin argumentos | boolean |
| `rol_actual()` | sin argumentos | text |
| `tiene_acceso(p_cliente_id text)` | text | boolean |
| `cs_hoy()` | sin argumentos | date |
| `cs_puede_ver(p_programa text)` | text | boolean |

`tiene_acceso` recibe el id del cliente como `text`, que es exactamente lo
que asume el PLAN.md. La RLS de `fin_*` se apoya en estas tres, no
escribas funciones nuevas equivalentes.

## Choques de nombre
No existe ninguna tabla con prefijo `fin_`. El namespace esta libre.

## pg_cron y pg_net: HABILITADOS
Verificado el 2026-09-21: `pg_cron` 1.6.4 y `pg_net` 0.20.4 estan activos.

- `004_cron.sql` se escribe normal, con `cron.schedule`.
- La Edge Function igual tiene que poder invocarse a mano por HTTP, para
  poder probarla sin esperar al cron. Eso no es un rodeo, es para testear.
- Recorda el error `42725` que aparecio en Seguimiento al comparar
  `tgenabled`: castealo a `::text`.
