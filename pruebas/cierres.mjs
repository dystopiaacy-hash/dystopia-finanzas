// pruebas/cierres.mjs — gate del parser de la pestaña "Clientes" (cierres) de
// la planilla de ventas de Agus. Fixture ANONIMIZADO escrito a mano: nombres
// "Cliente 01..", montos redondos. Nada de la planilla real.
// Verifica: carga de filas validas (fecha serial, ISO y dd/mm/aaaa; montos con
// "$", coma y punto), "Mes" ignorada, fila sin fecha y sin cliente = descartada,
// fecha invalida = fila rechazada, monto no numerico = celda rechazada (la fila
// se carga con NULL), encabezado repetido, columnas obligatorias faltantes,
// invariante filas_leidas = cargadas + rechazadas + descartadas y el camino
// completo por procesarFuente (tipo 'cierres', hash estable, datos.cierres).
// Uso: node pruebas/cierres.mjs

import { procesarFuente } from '../supabase/functions/_shared/procesar.js';
import { parseCierres } from '../supabase/functions/_shared/parsers/cierres.js';

const fallas = [];
const check = (ok, msg) => { if (!ok) fallas.push(msg); };

const ENC = ['Fecha de cierre', 'Mes', 'Cliente', 'Producto', 'Fuente', 'Estructura de pago', 'Estado',
  'Cash día 1 (USD)', 'Trato cerrado (USD)'];

// 46301 = 2026-10-06 en serial de Sheets.
const matriz = [
  ENC,
  [46301, 'Octubre', 'Cliente 01', 'Programa A', 'Instagram', '2 cuotas', 'Activo', 500, 2000],
  ['2026-10-09', 'Octubre', 'Cliente 02', 'Programa B', 'TikTok', 'Contado', 'Activo', '$ 1.500,50', '1.500,50'],
  ['12/10/2026', 'Octubre', 'Cliente 03', 'Programa A', null, '3 cuotas', 'Pausado', 300, 3000],
  [], // vacia
  [null, null, null, null, null, null, null, 1300, 6500], // totales sin cliente ni fecha
  ['Fecha de cierre', 'Mes', 'Cliente'], // encabezado repetido
  ['no es fecha', 'Octubre', 'Cliente 04', 'Programa A', 'Instagram', 'Contado', 'Activo', 100, 100], // fecha no parsea
  [46303, 'Octubre', null, 'Programa A', 'Instagram', 'Contado', 'Activo', 100, 100], // falta cliente
  [46304, 'Octubre', 'Cliente 05', 'Programa B', 'Instagram', 'Contado', 'Activo', 'pendiente', '#DIV/0!'], // montos malos
  [46305, 'Octubre', 'Cliente 06', 'Programa B', 'Instagram', 'Contado', 'Activo', null, null], // sin montos: ok
];

const r = parseCierres(matriz, { fila_encabezado: 1 });
check(!r.error, `no deberia dar error: ${r.error}`);
check(r.filas.length === 5, `se esperaban 5 filas cargadas, hay ${r.filas.length}`);
check(r.filas[0].fecha_cierre === '2026-10-06', `serial -> 2026-10-06, dio ${r.filas[0].fecha_cierre}`);
check(r.filas[1].fecha_cierre === '2026-10-09', 'ISO se carga igual');
check(r.filas[1].cash_dia1 === 1500.5 && r.filas[1].trato_cerrado === 1500.5, `montos con $ y coma: ${r.filas[1].cash_dia1}/${r.filas[1].trato_cerrado}`);
check(r.filas[2].fecha_cierre === '2026-10-12', 'dd/mm/aaaa dia primero');
check(r.filas[2].fuente === null, 'fuente vacia queda null');
check(r.filas[0].producto === 'Programa A' && r.filas[0].estado === 'Activo' && r.filas[0].estructura_pago === '2 cuotas', 'texto copiado');
check(!('mes' in r.filas[0]), 'la columna Mes no se guarda');
check(r.stats.rechazadas === 2, `filas rechazadas: se esperaban 2 (fecha, cliente), hay ${r.stats.rechazadas}`);
check(r.stats.celdas_rechazadas === 2, `celdas rechazadas: se esperaban 2, hay ${r.stats.celdas_rechazadas}`);
const f5 = r.filas.find((f) => f.nombre === 'Cliente 05');
check(f5 && f5.cash_dia1 === null && f5.trato_cerrado === null, 'monto malo: la fila se carga con null');
check(r.descartadas.length === 3, `descartadas: se esperaban 3 (vacia, totales, encabezado), hay ${r.descartadas.length}`);
check(r.stats.filas_leidas === r.stats.filas_cargadas + r.stats.rechazadas + r.stats.descartadas,
  `invariante: ${r.stats.filas_leidas} != ${r.stats.filas_cargadas} + ${r.stats.rechazadas} + ${r.stats.descartadas}`);

// Columnas obligatorias.
const sinTrato = parseCierres([ENC.filter((h) => !/Trato/.test(h)), [46301, 'x', 'c']], {});
check(/trato_cerrado/.test(sinTrato.error || ''), `sin "Trato cerrado" debe dar error: ${sinTrato.error}`);

// Camino completo.
const fuente = { tipo: 'cierres', cliente_id: 'agus', fila_encabezado: 1, alias: [] };
const p1 = await procesarFuente(fuente, matriz, null);
check(p1.estado === 'ok' || p1.estado === 'parcial', `estado inesperado: ${p1.estado}`);
check(p1.datos && p1.datos.cierres.length === 5 && p1.datos.llamadas.length === 0, 'datos.cierres cargado y llamadas vacio');
check(p1.stats.cargadas === 5, `stats.cargadas = ${p1.stats.cargadas}`);
const p2 = await procesarFuente(fuente, matriz, { hash: p1.hash, filas_cargadas: 5 });
check(p2.estado === p1.estado && p2.hash === p1.hash, 'misma hoja, mismo hash y estado');
// Hoja que viene sin filas validas cuando antes tenia: no se toca nada.
const vacia = await procesarFuente(fuente, [ENC, [null, 'Octubre']], { hash: p1.hash, filas_cargadas: 5 });
check(vacia.estado === 'error', `hoja sin filas validas con previo debe dar error, dio ${vacia.estado}`);
// Cambio de encabezado: error salvo aceptarEncabezado.
const otra = matriz.map((f, i) => (i === 0 ? [...ENC, 'Nueva'] : f));
const cambio = await procesarFuente(fuente, otra, { hash: p1.hash, filas_cargadas: 5 });
check(cambio.estado === 'error', 'encabezado cambiado debe dar error');

if (fallas.length) {
  console.error(`cierres: ${fallas.length} fallas`);
  for (const f of fallas) console.error(' - ' + f);
  process.exit(1);
}
console.log('cierres: OK');
