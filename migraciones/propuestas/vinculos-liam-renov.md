# Vinculación de pagos de renovación de liam sin ficha (propuesta, 16/10)

Estado: **consulta corrida el 16/10/2026 (solo SELECT, sin cambios); migración 166 sin correr.** Tabla completada con la salida real.

- Consulta (solo SELECT): `migraciones/propuestas/vinculos-liam-renov.sql`
- Migración (solo Alta): `migraciones/166_vinculos_liam_renov.sql` (con `v_esperado` por completar)

## Alcance

Pagos `fin_pagos` de liam con concepto RENOV, RENEW o RESELL cuyo alumno (`fin_cs_norm_nombre`) no tiene un `fin_cs_vinculo` vinculado a una ficha de liam. Según el relevamiento del 16/10: 20 de 30 sin vincular.

Las fichas cerradas por la 164 (`e4c8102a`, `be2a3e68`, `2375ab58`) no son candidatas. Se vincula a las vigentes `28d200e3`, `5955e47d` y `17d1c875`.

## Criterios de confianza

Señales por pago y ficha (el nombre de la ficha incluye sus alias de `cs_clientes_alias`, que cumplen el rol de apodo):

| Rango | Señal | Confianza |
|---|---|---|
| 1 | `pago_clave` de la ficha = `clave` del pago | Alta si es la única ficha de ese rango y está vigente |
| 2 | Nombre exacto normalizado | Alta (ídem) |
| 3 | Alias exacto | Alta (ídem) |
| 4 | Teléfono (8 últimos dígitos) + apellido o nombre de pila parecido | Alta (ídem) |
| 5 | Apellido igual + nombre de pila parecido (uno prefijo del otro, o 4 primeras letras iguales) | Alta (ídem) |
| 6 | Nombre de una sola palabra, prefijo del nombre de pila de la ficha + pago a 45 días o menos de una renovación `renovado` | Alta (ídem) |
| 7 | Solo teléfono igual (puede ser compartido) | Media si es única, si no Baja |
| 8 | Nombre de una palabra, prefijo, sin renovación cerca | Media si es única, si no Baja |
| 9 | Solo apellido igual (nombre de pila distinto) + renovación cerca | Baja |
| 10 | Solo apellido igual | Baja |
| (ninguna) | Sin señal | Sin candidato |

- Empate entre fichas del mismo rango, o ficha finalizada o de baja: baja de Alta a Media.
- Email: `fin_pagos` no tiene email, así que no hay señal por mail. La consulta trae `ficha_email` para mirarlo a ojo.
- El vínculo es por **nombre**, no por pago. Si un mismo nombre cae en dos fichas, la columna `fichas_distintas_mismo_nombre` es mayor que 1 y la migración aborta.

## Cómo completar este documento

1. Correr la consulta completa (una sola sentencia) y exportar el resultado.
2. Pegar cada fila en la tabla de abajo. Orden: Alta, Media, Baja, Sin candidato.
3. Contar los nombres distintos en Alta y ponerlos en `v_esperado` de la 166.

## Tabla de resultados (a completar con la salida de la consulta)

| Confianza | Pago (fecha) | Monto USD | Nombre en la hoja | Ficha propuesta (id8) | Estado ficha | Motivo | Otros candidatos |
|---|---|---|---|---|---|---|---|
| Alta | 2504851 (2026-02-12) | 240 | Dami Alfie | Damian Alfie (`55085941`) | activo | rango 5, apellido + nombre parecido (12 días de la renovación) | |
| Alta | 2504983 (2026-07-31) | 1000 | Fede Aimé | Federico Aime (`85d2753e`) | activo | rango 5 (1 día) | Lucas Aime [`f256102b`, rango 10] |
| Alta | 2505010 (2026-08-19) | 500 | fede aime | Federico Aime (`85d2753e`) | activo | rango 5 (20 días) | Lucas Aime [`f256102b`, rango 10] |
| Alta | 2504992 (2026-08-10) | 855 | Francisco Ravizzoli | Franco Ravizzoli (`97434d66`) | activo | rango 5 (48 días) | |
| Alta | 2504950 (2026-06-26) | 2500 | Lean Burella | Leandro Burella (`5bce0da5`) | activo | rango 5 (42 días) | |
| Alta | 2504981 (2026-07-30) | 500 | Leonel Abella | Leonel Abella Pulis (`6116c9dd`) | activo | rango 5 (20 días) | |
| Alta | 2505019 (2026-09-02) | 500 | leonel abella | Leonel Abella Pulis (`6116c9dd`) | activo | rango 5 (54 días) | |
| Alta | 2505069 (2026-09-28) | 750 | maria andrea | Maria andrea Bujan (`edcd8e77`) | activo | rango 5 (coincide "andrea", que es segundo nombre, no apellido; 103 días) | |
| Alta | 2504973 (2026-07-22) | 750 | Maria Bujan | Maria andrea Bujan (`edcd8e77`) | activo | rango 5 (35 días) | |
| Alta | 2505003 (2026-08-14) | 370 | Nahue | Nahuel Smerdel (`c82112ca`) | activo | rango 6, nombre abreviado + pago a 2 días de la renovación | Nahuel Fuentes [`07969f05`, rango 8] |
| Alta | 2504953 (2026-07-02) | 266 | Rodrigo Naranjo | Rodrigo Naranjo Sanna (`aa20cfc4`) | activo | rango 5 (8 días) | |
| Alta | 2504989 (2026-08-04) | 266 | Rodrigo Naranjo | Rodrigo Naranjo Sanna (`aa20cfc4`) | activo | rango 5 (41 días) | |
| Alta | 2505020 (2026-09-02) | 266.6 | rodrigo naranjo | Rodrigo Naranjo Sanna (`aa20cfc4`) | activo | rango 5 (70 días) | |
| Media | 2504980 (2026-07-29) | 750 | Clara | Clara Dodds (`4797f039`) | activo | rango 8, nombre abreviado sin renovación cerca (única ficha con ese prefijo; ojo: la ficha arranca el 01/09, después del pago) | |
| Baja | 2505025 (2026-09-05) | 500 | agustina Weisbek | Valentina Weisbek (`28072664`) | finalizado | rango 10, solo apellido | |
| Baja | 2504930 (2026-06-02) | 700 | Lautaro Saposnik | Sebastian Saposnik (`eeed7d49`) | activo | rango 9, solo apellido + 18 días de la renovación | |
| Sin candidato | 2504960 (2026-07-14) | 711 | Fran Ravizzolli | | | ninguna señal | (a ojo: Franco Ravizzoli `97434d66`; el apellido tiene doble "l" y por eso no cruza) |
| Sin candidato | 2504948 (2026-06-25) | 1000 | Nati | | | ninguna señal | |
| Sin candidato | 2504970 (2026-07-21) | 1000 | Nati | | | ninguna señal | |
| Sin candidato | 2504873 (2026-03-10) | 1500 | Valentín morello | | | ninguna señal | |

Resumen (corrida del 16/10/2026, consulta sin cambios): **por pago** Alta 13 · Media 1 · Baja 2 · Sin candidato 4 (total 20, esperado 20). **Por nombre (alumno_norm)** Alta 9 · Media 1 · Baja 2 · Sin candidato 3 (total 15). Ningún nombre cae en dos fichas (`fichas_distintas_mismo_nombre` = 1 en todas las filas con ficha).

- **v_esperado de la 166 = 9** (dami alfie, fede aime, francisco ravizzoli, lean burella, leonel abella, maria andrea, maria bujan, nahue, rodrigo naranjo).
- Contraste con los casos conocidos: Ravizzoli, Burella, Nahue (rango 6, 2 días), Abella, Bujan y Naranjo dan Alta como se esperaba; Saposnik y Weisbek dan Baja; morello Sin candidato. Clara da Media (rango 8). Nati da Sin candidato (no hay ficha de liam que empiece con "nati").
- Ruido / a revisar: "Fran Ravizzolli" (07/14, 711 USD) es casi seguro Franco Ravizzoli pero queda Sin candidato por el tipeo del apellido; vincularlo a mano a `97434d66`. "maria andrea" entra en Alta por el segundo nombre, no por apellido: es correcto en este caso. Clara Dodds tiene ficha que arranca después del pago.

## Casos ya conocidos (a contrastar con la salida)

| Nombre en la hoja | Ficha esperada | Lo que debería dar la consulta |
|---|---|---|
| Francisco Ravizzoli | Franco Ravizzoli (`97434d66`) | Alta, rango 5 (apellido + nombre parecido, prefijo común "franc") |
| Lean Burella | Leandro Burella (`5bce0da5`) | Alta, rango 5 |
| Nahue | Nahuel Smerdel (`c82112ca`) | Alta si el pago del 14/08 cae a 45 días o menos de la renovación (rango 6); si no, Media (rango 8) |
| Leonel Abella Pulis | Leonel Abella Pulis (`6116c9dd`) | Alta si el nombre coincide o comparte apellido; ver la salida |
| Maria andrea Bujan | Maria andrea Bujan (`edcd8e77`) | Ídem |
| Rodrigo Naranjo Sanna | Rodrigo Naranjo Sanna (`aa20cfc4`) | Ídem |
| Lautaro Saposnik | Sebastian Saposnik | Baja (solo apellido): decide Joaquín |
| agustina Weisbek | Valentina Weisbek (finalizada) | Baja (solo apellido): decide Joaquín |
| Valentín morello | sin ficha | Sin candidato |
| Nati | sin definir | Media o Baja según haya una sola ficha con ese prefijo; ver la salida |
| Clara | sin definir | Ídem |

Los nombres de las hojas de Abella, Bujan y Naranjo no se conocen; si el pago está escrito con otro formato, saldrá en Media o Baja y hay que revisarlo.

## Decisiones para Joaquín

- Media y Baja: ninguna se aplica con la 166. Para cada una, elegir ficha o dejar sin vincular. Se puede hacer desde la pantalla Vincular o con una migración aparte (pedir número).
- Para los dudosos (Saposnik, Weisbek, morello, Nati, Clara): confirmar si es la misma persona antes de vincular.
- Confirmar que la 164 está corrida (la 166 aborta si no están las 3 fichas vigentes).
