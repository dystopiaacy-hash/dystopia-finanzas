/* Columnas configurables (072): lectura de la configuración, RPC de estructura
   (solo fundador) y de valores, y el cruce con las columnas que conoce la app.
   El orden lo resuelve fin_columnas_de: acá no se recalcula. */
import { sb } from './supabase.js';

export const TIPO_COLUMNA_LABEL = {
  texto: 'Texto', numero: 'Número', fecha: 'Fecha', casilla: 'Casilla', opcion: 'Opción', link: 'Link'
};

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw error;
  return data;
}

/* Vistas: 'pagos' y 'pnl' por cliente; 'resumen' y 'conciliacion' globales (cliente null). */
export const columnasDe = async (clienteId, vista) => (await rpc('fin_columnas_de', { p_cliente: clienteId, p_vista: vista })) || [];

/* Reportes: si la configuración no se puede leer, el reporte sale igual con las columnas por defecto. */
export const columnasReporte = (clienteId, vista) =>
  columnasDe(clienteId, vista).catch(e => { console.error('columnas', vista, e); return null; });

/* etiqueta null = nombre por defecto (solo en las del sistema). opciones null = no se tocan. */
export const columnaGuardar = (clienteId, vista, clave, { etiqueta = null, visible = true, opciones = null } = {}) =>
  rpc('fin_columna_guardar', {
    p_cliente: clienteId, p_vista: vista, p_clave: clave, p_etiqueta: etiqueta, p_visible: visible, p_opciones: opciones
  });

/* Devuelve la clave nueva. Solo vista pagos. */
export const columnaCrear = (clienteId, etiqueta, tipo, opciones = []) =>
  rpc('fin_columna_crear', { p_cliente: clienteId, p_etiqueta: etiqueta, p_tipo: tipo, p_opciones: tipo === 'opcion' ? opciones : [] });

/* claves = el orden completo, incluidas las ocultas. */
export const columnasOrdenar = (clienteId, vista, claves) =>
  rpc('fin_columnas_ordenar', { p_cliente: clienteId, p_vista: vista, p_claves: claves });

export const columnaArchivar = (clienteId, clave, archivar = true) =>
  rpc('fin_columna_archivar', { p_cliente: clienteId, p_clave: clave, p_archivar: archivar });

/* Renombra la opción y los valores ya cargados en los pagos. */
export const opcionRenombrar = (clienteId, clave, viejo, nuevo) =>
  rpc('fin_columna_opcion_renombrar', { p_cliente: clienteId, p_clave: clave, p_viejo: viejo, p_nuevo: nuevo });

/* valor: string | number | boolean | null (null borra el valor). */
export const pagoExtraGuardar = (clienteId, clavePago, columna, valor) =>
  rpc('fin_pago_extra_guardar', { p_cliente: clienteId, p_clave_pago: clavePago, p_columna: columna, p_valor: valor });

/* valor siempre texto: en catálogos el id del catálogo, en closer y setter el id del vendedor. */
export const pagoEditar = (clavePago, campo, valor) =>
  rpc('fin_pago_editar', { p_clave_pago: clavePago, p_campo: campo, p_valor: valor == null ? null : String(valor) });

/* Valores de las columnas nuevas, solo para las claves de la página: Map clave -> valores. */
export async function pagosExtra(clienteId, claves) {
  if (!claves.length) return new Map();
  const { data, error } = await sb.from('fin_pagos_extra').select('clave,valores').eq('cliente_id', clienteId).in('clave', claves);
  if (error) throw error;
  return new Map((data || []).map(r => [r.clave, r.valores || {}]));
}

/* Valores cuyo pago ya no existe (se corrigió en el Sheet o se anuló). */
export async function extrasHuerfanos() {
  const { data, error } = await sb.from('fin_v_pagos_extra_huerfanos').select('cliente_id,clave');
  if (error) throw error;
  return data || [];
}

/* Las funciones de la 072 ya hablan en castellano ("fin: ..."): se muestran tal cual. */
export function errorColumnas(e) {
  if (e && e.code === 'PGRST202') return 'Esa función todavía no existe en la base: falta correr la migración 072.';
  return (e && e.message) || String(e);
}

/* base: [{ k, lab, oculta?, fija? }] en el orden de siempre (lo que la app sabe dibujar).
   config: lo que devuelve fin_columnas_de, ya ordenado; null = nombres y orden por defecto.
   Devuelve:
     visibles   -> las que se dibujan, en orden
     todas      -> visibles + ocultas, en orden (para el panel y para mandar el orden)
     archivadas -> columnas nuevas archivadas (el dato sigue guardado) */
export function armarColumnas(base, config) {
  const deSistema = c => ({ ...c, sistema: true, original: c.lab, visible: !c.oculta });
  if (!config) {
    const todas = base.map(deSistema);
    return { todas, visibles: todas.filter(c => c.visible), archivadas: [] };
  }
  const porClave = new Map(base.map(c => [c.k, c]));
  const todas = [], archivadas = [], vistas = new Set();
  for (const r of config) {
    const b = porClave.get(r.clave);
    if (b) {
      vistas.add(r.clave);
      todas.push({ ...deSistema(b), lab: r.etiqueta || b.lab, visible: !!b.fija || r.visible !== false });
    } else if (!r.sistema && r.tipo) {
      const tipo = TIPO_COLUMNA_LABEL[r.tipo] ? r.tipo : 'texto';
      (r.archivada ? archivadas : todas).push({
        k: r.clave, lab: r.etiqueta || r.clave, sistema: false, tipo, visible: r.visible !== false,
        opciones: Array.isArray(r.opciones) ? r.opciones.map(String) : []
      });
    }
  }
  /* Una columna que la app conoce y la base todavía no lista va al final. */
  for (const b of base) if (!vistas.has(b.k)) todas.push(deSistema(b));
  return { todas, visibles: todas.filter(c => c.visible), archivadas };
}
