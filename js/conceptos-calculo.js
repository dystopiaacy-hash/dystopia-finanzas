/* Cálculo de la torta de cash collected por concepto, sin DOM ni Supabase
   (lo usa js/views/conceptos.js y lo prueba pruebas/conceptos.mjs).
   REGLA: el total es SIEMPRE la suma real de las 4 categorías, con signo.
   Una categoría negativa (devoluciones) resta del total; en la torta ocupa
   su valor absoluto y se marca como devolución. */

/* Orden fijo de la torta y la leyenda. */
export const CATEGORIAS_CONCEPTO = [
  { clave: 'venta_nueva', label: 'Ventas nuevas', color: 'var(--cat-venta-nueva)' },
  { clave: 'producto', label: 'Producto', color: 'var(--cat-producto)', ayuda: 'Resell, upsell, renovación, comunidad' },
  { clave: 'cuota', label: 'Cuotas', color: 'var(--cat-cuota)' },
  { clave: 'sin_clasificar', label: 'Sin clasificar', color: 'var(--cat-sin-clasificar)' }
];

const n = v => Number(v) || 0;
/* Suma en centavos: evita que 0.1 + 0.2 deje un total que no cierra. */
const sumar = vals => Math.round(vals.reduce((s, v) => s + Math.round(n(v) * 100), 0)) / 100;

/* filas: de fin_v_cash_collected_concepto, ya filtradas por mes y cliente.
   Devuelve las 4 categorías (siempre las 4) y los totales.
   - monto: suma con signo.  devolucion: monto < 0.
   - peso: |monto|, lo que ocupa en la torta.
   - pct: participación en la torta (peso / suma de pesos), con el signo del
     monto; null si la torta está vacía.
   Una categoría fuera de las 4 conocidas cuenta como sin_clasificar. */
export function calcularTorta(filas) {
  const acc = new Map(CATEGORIAS_CONCEPTO.map(c => [c.clave, { ...c, montos: [], pagos: 0 }]));
  for (const f of filas) {
    const c = acc.get(f.categoria) || acc.get('sin_clasificar');
    c.montos.push(f.monto_usd);
    c.pagos += n(f.pagos);
  }
  const categorias = [...acc.values()].map(({ montos, ...c }) => {
    const monto = sumar(montos);
    return { ...c, monto, devolucion: monto < 0, peso: Math.abs(monto) };
  });
  const pesoTotal = sumar(categorias.map(c => c.peso));
  for (const c of categorias) {
    c.pct = pesoTotal > 0 ? Math.sign(c.monto) * (c.peso / pesoTotal) * 100 : null;
  }
  return {
    categorias,
    total: sumar(categorias.map(c => c.monto)),
    pagos: categorias.reduce((s, c) => s + c.pagos, 0),
    pesoTotal
  };
}
