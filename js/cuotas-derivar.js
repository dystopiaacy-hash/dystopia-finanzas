/* Programa y Closer de las cuotas (116): manda la planilla; si la cuota no los trae se toman de los
   Pagos del mismo alumno (mismo cliente, nombre normalizado). Closer: el pago más reciente del mismo
   programa de la cuota, y si no hay, el más reciente con closer. Lo derivado se marca para la pantalla. */

export const normNombre = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

const lleno = v => v != null && String(v).trim() !== '';

/* pagos: filas de fin_pagos (cliente_id, fecha, alumno, programa, closer). Devuelve Map clave -> pagos por fecha desc. */
export function indexarPagos(pagos) {
  const m = new Map();
  for (const p of pagos) {
    const a = normNombre(p.alumno);
    if (!a) continue;
    const k = `${p.cliente_id}|${a}`;
    if (!m.has(k)) m.set(k, []);
    m.get(k).push(p);
  }
  for (const l of m.values()) l.sort((x, y) => String(y.fecha).localeCompare(String(x.fecha)));
  return m;
}

/* Devuelve { programa, closer, programaDerivado, closerDerivado } para una cuota (fila de fin_v_cobranzas). */
export function derivarCuota(c, indice) {
  const r = { programa: c.programa, closer: c.closer, programaDerivado: false, closerDerivado: false };
  if (lleno(r.programa) && lleno(r.closer)) return r;
  const pagos = indice.get(`${c.cliente_id}|${normNombre(c.alumno)}`) || [];
  if (!lleno(r.programa)) {
    const p = pagos.find(x => lleno(x.programa));
    if (p) { r.programa = p.programa; r.programaDerivado = true; }
  }
  if (!lleno(r.closer)) {
    const mismo = lleno(r.programa) ? normNombre(r.programa) : null;
    const p = (mismo && pagos.find(x => lleno(x.closer) && normNombre(x.programa) === mismo))
      || pagos.find(x => lleno(x.closer));
    if (p) { r.closer = p.closer; r.closerDerivado = true; }
  }
  return r;
}
