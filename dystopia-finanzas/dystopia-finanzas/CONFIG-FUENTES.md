# CONFIG-FUENTES.md — valores reales relevados el 2026-09-21

Estos son los `spreadsheet_id` y `gid` verificados corriendo Apps Script
sobre las planillas reales. NO los inventes ni los cambies.

Van a `002_seed_config.sql`, tabla `fin_fuentes`.

## Planillas de Finanzas

| cliente | spreadsheet_id | hoja | gid | tipo | sincronizar |
|---|---|---|---|---|---|
| liam | 1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo | Opps | 2122278614 | opps | SI |
| liam | 1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo | Pagos | 667978021 | pagos | SI |
| liam | 1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo | Cuotas | 677639895 | cuotas | SI |
| liam | 1DdyX9aZytVd9KzTPFbEqplsCc7Kc8WPGKXcfq1gXquo | Cargar Pago | 1088695891 | form | NO |
| agus | 13LtPK8GKJm9L86xtRaf3oK7Px8XVysX5_c75-iGzxoI | Opps | 2122278614 | opps | SI |
| agus | 13LtPK8GKJm9L86xtRaf3oK7Px8XVysX5_c75-iGzxoI | Pagos | 667978021 | pagos | SI |
| agus | 13LtPK8GKJm9L86xtRaf3oK7Px8XVysX5_c75-iGzxoI | Cargar Pago | 1318234547 | form | NO |
| teo | 1Ucqc0bV4Y7QoVi1QSoVUGDBj8j-jNs97iz1evNlx4J4 | Opps | 2122278614 | opps | SI |
| teo | 1Ucqc0bV4Y7QoVi1QSoVUGDBj8j-jNs97iz1evNlx4J4 | Pagos | 667978021 | pagos | SI |
| teo | 1Ucqc0bV4Y7QoVi1QSoVUGDBj8j-jNs97iz1evNlx4J4 | Cargar Pago | 1789848875 | form | NO |
| mauro | 156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ | Opps | 2122278614 | opps | SI |
| mauro | 156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ | Historico Pagos | 667978021 | pagos | SI |
| mauro | 156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ | Pagos Por Cobrar | 1304167527 | cuotas | SI |
| mauro | 156ek7kCgerEbBdbIdS0hd48oRpmlXrFOAbQPCkUz0xQ | Cargar Pago | 1087468288 | form | NO |
| lucas | 1i3D4rGie3W1svlhf8jWLZHcPLc_Hl2GvALbo_uQI7rQ | Opps | 0 | opps | SI |
| lucas | 1i3D4rGie3W1svlhf8jWLZHcPLc_Hl2GvALbo_uQI7rQ | PAGOS | 188432479 | pagos | SI |
| lucas | 1i3D4rGie3W1svlhf8jWLZHcPLc_Hl2GvALbo_uQI7rQ | Cargar Pago | 1609950162 | form | NO |

Nota: `teo` tiene una hoja CUOTAS pero vive en su planilla de CRM, no en la
de Finanzas. Ver abajo.

## Planillas de CRM — FASE 6, no se sincronizan todavia

Se dejan cargadas en `fin_fuentes` con `activo = false`.

| cliente | spreadsheet_id | hoja | gid | tipo |
|---|---|---|---|---|
| liam | 1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg | Data | 0 | data |
| liam | 1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg | Trazabilidad - Data | 33291330 | trazabilidad |
| liam | 1dXfTyN_P1SjfVpR6Uy5c6nIxt3q5dhMp2xauqf9ykYg | PAGOS NO TOCAR | 2019205895 | pagos_historico |
| teo | 1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U | DATA | 0 | data |
| teo | 1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U | TRAZABILIDAD | 99965983 | trazabilidad |
| teo | 1x2VqX4rzIXJRIrKM-De3amfxR6MO8gks-iXMAAZZh-U | CUOTAS | 93797201 | cuotas |
| mauro | 1jZXCyAZSDWnC2FlRDxB9w7KoO9pyPxIpZ-Kzhfb3u54 | Data | 10320787 | data |
| mauro | 1jZXCyAZSDWnC2FlRDxB9w7KoO9pyPxIpZ-Kzhfb3u54 | Trazabilidad - DATA | 1602859939 | trazabilidad |
| lucas | 13nn8Z25bZF25I5y2spkaB7_4j637rfWtJfsTyQJgSBI | DATA | 0 | data |
| lucas | 13nn8Z25bZF25I5y2spkaB7_4j637rfWtJfsTyQJgSBI | Trazabilidad Data | 72433952 | trazabilidad |

`agus` (De CERO a CEO) NO tiene planilla de CRM. Pendiente de confirmar si
no existe o si no se relevo.

## Hojas que NUNCA se sincronizan

Son formulas de Google Sheets, no datos: `Cargar Pago`, `Maestro de
Metricas`, `DASHBOARD`, `CRM Dashboard`, `Dashboard Trazabilidad`,
`Trazabilidad Dashboard`, `Dashoboard - Onboarding`, `Onboarding -
Dashboard`, `Onbaording Dashboard`, `EN PROCESO`.

## Dato que valida el diseño

En `mauro` la hoja `Pagos` fue renombrada a `Historico Pagos` y conservo el
gid 667978021, el mismo que en liam, agus y teo. Identificar por gid y no
por nombre es lo unico que mantiene esa fuente viva.

## Cantidad de filas al 2026-09-21 (control grueso post-sync)

liam Pagos 190 · agus Pagos 248 · teo Pagos 232 · mauro Historico Pagos 853
· lucas PAGOS 214 · liam Cuotas 9 · mauro Pagos Por Cobrar 17 · teo CUOTAS 28

Si despues de la primera sincronizacion los numeros difieren mucho de estos,
algo se esta descartando de mas.
