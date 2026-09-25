// pruebas/conceptos.mjs — torta de cash collected por concepto.
// El total tiene que ser SIEMPRE la suma real de las 4 categorías, con signo:
// una categoría negativa (devoluciones) resta, y un mes negativo da negativo.
// Uso: node pruebas/conceptos.mjs     (sin dependencias)

import { calcularTorta, CATEGORIAS_CONCEPTO } from '../js/conceptos-calculo.js';

const fallas = [];
const casos = [];
const ok = (cond, msg) => { if (!cond) fallas.push(msg); };
const cerca = (a, b) => Math.abs(a - b) < 1e-9;
const fila = (categoria, monto_usd, pagos = 1, cliente_id = 'liam') => ({ cliente_id, anio: 2026, mes: 9, categoria, monto_usd, pagos });

function caso(nombre, filas, { total, pagos }) {
  const t = calcularTorta(filas);
  const suma4 = t.categorias.reduce((s, c) => s + Math.round(c.monto * 100), 0) / 100;
  ok(t.categorias.length === 4, `${nombre}: tiene que haber 4 categorías, hay ${t.categorias.length}`);
  ok(t.categorias.map(c => c.clave).join() === CATEGORIAS_CONCEPTO.map(c => c.clave).join(), `${nombre}: orden de categorías`);
  ok(cerca(t.total, suma4), `${nombre}: total ${t.total} != suma de las 4 categorías ${suma4}`);
  ok(cerca(t.total, total), `${nombre}: total ${t.total}, esperado ${total}`);
  ok(t.pagos === pagos, `${nombre}: pagos ${t.pagos}, esperado ${pagos}`);
  for (const c of t.categorias) {
    ok(c.devolucion === c.monto < 0, `${nombre}: ${c.clave} devolucion mal marcada`);
    ok(cerca(c.peso, Math.abs(c.monto)), `${nombre}: ${c.clave} peso != |monto|`);
    if (c.pct != null) ok(Math.sign(c.pct) === Math.sign(c.monto) || c.monto === 0, `${nombre}: ${c.clave} pct con signo distinto al monto`);
  }
  if (t.pesoTotal > 0) {
    const sumaPct = t.categorias.reduce((s, c) => s + Math.abs(c.pct), 0);
    ok(Math.abs(sumaPct - 100) < 1e-6, `${nombre}: |pct| suma ${sumaPct}, no 100`);
  } else {
    ok(t.categorias.every(c => c.pct == null), `${nombre}: sin torta, pct tiene que ser null`);
  }
  casos.push(`${nombre.padEnd(46)} total ${String(t.total).padStart(9)}  pagos ${t.pagos}`);
  return t;
}

caso('mes vacío: 4 categorías en 0', [], { total: 0, pagos: 0 });

caso('todo positivo', [fila('venta_nueva', 1000, 2), fila('producto', 300), fila('cuota', 200, 3)], { total: 1500, pagos: 6 });

const conDev = caso('producto negativo resta del total', [
  fila('venta_nueva', 1000), fila('producto', -250, 2), fila('cuota', 500), fila('sin_clasificar', 50)
], { total: 1300, pagos: 5 });
const prod = conDev.categorias.find(c => c.clave === 'producto');
ok(prod.devolucion && prod.monto === -250 && prod.peso === 250, 'producto negativo: monto -250, peso 250, devolucion');
ok(prod.pct < 0, 'producto negativo: pct negativo');
ok(cerca(conDev.pesoTotal, 1800), `producto negativo: la torta pesa |montos| = 1800, da ${conDev.pesoTotal}`);

caso('total del mes negativo', [fila('venta_nueva', 100), fila('cuota', -400, 2)], { total: -300, pagos: 3 });

caso('solo devoluciones', [fila('sin_clasificar', -80), fila('producto', -20)], { total: -100, pagos: 2 });

caso('varios clientes se suman por categoría', [
  fila('venta_nueva', 500, 1, 'liam'), fila('venta_nueva', 700, 1, 'agus'), fila('cuota', -100, 1, 'teo'), fila('cuota', 300, 2, 'agus')
], { total: 1400, pagos: 5 });

caso('se compensan a 0 dentro de una categoría', [fila('cuota', 200), fila('cuota', -200)], { total: 0, pagos: 2 });

const raro = caso('categoría desconocida cuenta como sin_clasificar', [fila('otra_cosa', 40), fila('sin_clasificar', 10)], { total: 50, pagos: 2 });
ok(raro.categorias.find(c => c.clave === 'sin_clasificar').monto === 50, 'categoría desconocida: sin_clasificar = 50');

caso('centavos: 0,1 + 0,2 cierra en 0,3', [fila('venta_nueva', 0.1), fila('venta_nueva', 0.2)], { total: 0.3, pagos: 2 });

caso('monto como texto (numeric de PostgREST)', [fila('venta_nueva', '1234.56'), fila('producto', '-34.56')], { total: 1200, pagos: 2 });

console.log(casos.join('\n'));
if (fallas.length) {
  console.error(`\nFALLAS (${fallas.length}):\n  ${fallas.join('\n  ')}`);
  process.exit(1);
}
console.log(`\nconceptos: OK (${casos.length} casos)`);
