// pruebas/pagos-encabezado.mjs — el hash del encabezado de PAGOS no depende del orden de las columnas
// (se mapean por nombre), pero si de los nombres y de la posicion de las columnas sin titulo.
// Datos inventados. Uso: node pruebas/pagos-encabezado.mjs

import { procesarFuente, hashEncabezado } from '../supabase/functions/_shared/procesar.js';

const fallas = [];
const check = (ok, msg) => { if (!ok) fallas.push(msg); };

const ALIAS = [
  { campo: 'fecha', alias: 'Fecha', obligatorio: true }, { campo: 'alumno', alias: 'NOMBRE DEL ALUMNO', obligatorio: true },
  { campo: 'monto', alias: 'PAGO', obligatorio: true }, { campo: 'concepto', alias: 'CONCEPTO', obligatorio: false },
];
const fuente = { tipo: 'pagos', cliente_id: 'teo', fila_encabezado: 1, tope_monto: null, alias: ALIAS };
const ENC_VIEJO = ['Fecha', 'NOMBRE DEL ALUMNO', 'CONCEPTO', 'PAGO'];
const ENC_NUEVO = ['Fecha', 'NOMBRE DEL ALUMNO', 'PAGO', 'CONCEPTO'];   // PAGO antes de CONCEPTO (Teo, 20/10)
const fila = (enc, a, m, c) => enc.map((h) => ({ Fecha: 46300, 'NOMBRE DEL ALUMNO': a, PAGO: m, CONCEPTO: c })[h]);

// 1. Mismo conjunto de nombres, otro orden: mismo hash nuevo; el hash viejo (por posicion) sigue siendo distinto.
check(await hashEncabezado('pagos', ENC_VIEJO) === await hashEncabezado('pagos', ENC_NUEVO), 'pagos: el orden de las columnas no deberia cambiar el hash');
check(await hashEncabezado('pagos', ENC_VIEJO, true) !== await hashEncabezado('pagos', ENC_NUEVO, true), 'pagos: el hash por posicion deberia distinguir el orden');
// Otros tipos siguen por posicion.
check(await hashEncabezado('cuotas', ENC_VIEJO) !== await hashEncabezado('cuotas', ENC_NUEVO), 'cuotas: el hash tiene que seguir dependiendo del orden');

// 2. Un nombre distinto o una columna nueva SI cambia el hash; una columna sin titulo que se mueve tambien.
check(await hashEncabezado('pagos', [...ENC_NUEVO, 'MAIL']) !== await hashEncabezado('pagos', ENC_NUEVO), 'pagos: una columna nueva tiene que cambiar el hash');
check(await hashEncabezado('pagos', ['Fecha', 'NOMBRE', 'PAGO', 'CONCEPTO']) !== await hashEncabezado('pagos', ENC_NUEVO), 'pagos: un nombre cambiado tiene que cambiar el hash');
check(await hashEncabezado('pagos', ['Fecha', '', 'NOMBRE DEL ALUMNO', 'PAGO', 'CONCEPTO']) !== await hashEncabezado('pagos', ['Fecha', 'NOMBRE DEL ALUMNO', '', 'PAGO', 'CONCEPTO']),
  'pagos: mover una columna sin titulo tiene que cambiar el hash');
check(await hashEncabezado('pagos', [...ENC_NUEVO, '', '']) === await hashEncabezado('pagos', ENC_NUEVO), 'pagos: las celdas vacias del final no cuentan');

// 3. procesarFuente: la ultima corrida buena tiene el hash viejo (por posicion) del MISMO encabezado -> sigue andando.
const viejoPos = await hashEncabezado('pagos', ENC_NUEVO, true);
const conViejo = await procesarFuente(fuente, [ENC_NUEVO, fila(ENC_NUEVO, 'Ana', 100, 'FEE')], { hash: viejoPos, filas_cargadas: 1 });
check(conViejo.estado !== 'error' && conViejo.datos?.pagos.length === 1, 'pagos: el hash viejo del mismo encabezado tiene que aceptarse');
check(conViejo.hash === await hashEncabezado('pagos', ENC_NUEVO), 'pagos: la corrida tiene que guardar el hash nuevo');

// 4. Reordenar columnas con la corrida previa ya en hash nuevo: sigue andando y lee por nombre.
const previoNuevo = { hash: await hashEncabezado('pagos', ENC_VIEJO), filas_cargadas: 1 };
const reorden = await procesarFuente(fuente, [ENC_NUEVO, fila(ENC_NUEVO, 'Ana', 100, 'FEE')], previoNuevo);
check(reorden.estado !== 'error', 'pagos: reordenar columnas no deberia dar error de encabezado');
check(reorden.datos?.pagos[0]?.monto_usd === 100 && reorden.datos?.pagos[0]?.concepto === 'FEE', 'pagos: tiene que leer monto y concepto por nombre');

// 5. Un encabezado con otra columna (hash viejo de OTRO encabezado) sigue dando error, y aceptarEncabezado lo deja pasar.
const otro = await procesarFuente(fuente, [ENC_NUEVO, fila(ENC_NUEVO, 'Ana', 100, 'FEE')], { hash: await hashEncabezado('pagos', ['Fecha', 'X', 'PAGO']), filas_cargadas: 1 });
check(otro.estado === 'error' && /cambio el encabezado/.test(otro.mensaje), 'pagos: un encabezado distinto tiene que dar error');
const acepta = await procesarFuente(fuente, [ENC_NUEVO, fila(ENC_NUEVO, 'Ana', 100, 'FEE')], { hash: await hashEncabezado('pagos', ['Fecha', 'X', 'PAGO']), filas_cargadas: 1 }, { aceptarEncabezado: true });
check(acepta.estado !== 'error', 'pagos: aceptarEncabezado tiene que dejarlo pasar');

if (fallas.length) { console.error(`pagos-encabezado: ${fallas.length} falla(s)`); fallas.forEach((f) => console.error('  - ' + f)); process.exit(1); }
console.log('pagos-encabezado: OK');
