# PLAN-FINANZAS-2.md · reestructuración de Finanzas

Base: FASE0-FINANZAS.md, con las decisiones V1 a V7 aprobadas el
2026-10-02.

## Reglas
- Claude nunca ejecuta SQL.
  - Las migraciones van numeradas en `migraciones/`, probadas dos veces
    contra un Postgres local con el esquema real.
  - Cada una trae controles al final, que se corren de a uno.
- El código lo cambia Claude Code: primero grep, nunca archivos enteros, y
  sin push hasta que Joaquín pruebe.
- Mauro queda afuera de toda la reestructuración (V3). Sus datos se
  quedan como están.
- Las cuotas y la renovación (liam Cuotas, mauro Pagos Por Cobrar,
  columnas L a O de lucas) pasan a Producto/Seguimiento (V4). No se tocan
  acá.

## Orden

El orden que aprendimos en Ventas: identidad, esquema, protección del
corte en la sync, grilla de solo lectura, corte por cliente y recién
después la edición.

| fase | qué | dónde | migración | estado |
|---|---|---|---|---|
| 1 | Identidad estable de cada pago (`clave`) y reconexión de las liquidaciones | Supabase | 062 | **lista para correr** |
| 2 | El ingreso del P&L sale de Pagos (V2). Opps aporta solo gastos. Alerta si el "ventas" de Opps no cuadra con Pagos | Supabase + pantallas de Finanzas | 063 | pendiente |
| 3 | Catálogos de Pagos: concepto, método, quién recibe (separados, V5) y programa. Mapeo de lo histórico al valor canónico. Concepto REFUND (V6) | Supabase | 064 | pendiente |
| 4 | Protección del corte: `fin_pagos.origen` ('sheet' o 'app'). La sync borra solo filas 'sheet' y no escribe en una fuente cortada (igual que la 060 para llamadas) | Supabase + parser | 065 | pendiente |
| 5 | Grilla de Pagos de solo lectura en Finanzas: filtros, rechazos a la vista, fecha del último pago cargado por cliente | dystopia-finanzas (Claude Code) | no | pendiente |
| 6 | Carga de pagos en la app: formulario que reemplaza "Cargar Pago" (con validación de monto y comprobante) y refunds como pago negativo que apunta a la `clave` original | Claude Code + 066 | 066 | pendiente |
| 7 | Corte por cliente. Primero agus y liam, que cargan al día; teo y lucas al cerrar el mes. Se marca `cortada_en` y se saca el menú "Cargar pago" de esa planilla. La fecha la decide Nacho | Supabase + planillas | no | pendiente |
| 8 | Gastos (V7, después de Pagos): tabla de gastos con catálogo en vez de los 12 bloques de Opps. P&L calculado. Resolver el doble conteo de comisiones de vendedores | todo | 067+ | pendiente |
| 9 | Pendientes sueltos: Julia Aguirre (comisión sobre neto, `base_calculo`), Salud (fuentes Data y "revisado"), comisión neta de refunds | | | pendiente |

## Lo que depende de la agencia (mensaje de FASE0, sección 12)
- **Antes de la fase 2:**
  - Borrar las filas de prueba de liam (182 a 190) y mauro (852 y 853).
  - Corregir los rótulos de Opps de agus y lucas.
- **Antes de la fase 3:** confirmar el catálogo único de conceptos (punto 10).
- **Antes de la fase 7:** fecha de corte de cada cliente (punto 13).
- **Antes de la fase 8:** definir el doble conteo de comisiones (punto 9).

## Hallazgos de la fase 1 (para no perderlos)
- **Liquidación de lucas 2026-06:**
  - Cerrada con 62 líneas.
  - Los 62 `pago_id` ya no existían. La 062 las reconecta por
    fecha + alumno + monto.
- **Pagos cargados tarde después de un cierre:** hasta la 062 no se
  liquidaban nunca (la 012 solo admite un ajuste a mano). Ahora aparecen
  en `fin_v_comisiones_fuera_de_cierre`.
- **Faltan en la carpeta las migraciones 023 y 026:** crean
  `fin_fuentes_mapa` y `fin_setter_periodo`. Las de la 024 a la 036 las
  necesitan para correr desde cero.
