// sincronizar/nucleo.ts — el trabajo de una invocacion, sin HTTP. Recibe la
// base y Google por parametro para poder probarlo sin red (pruebas/corte.test.ts).
//
// Ciclo de vida de las corridas (CONTRATO.md seccion 4.2):
//  1. Barre las corridas que una invocacion anterior dejo abiertas hace mas
//     de HUERFANA_MIN: en_curso -> error con corte 'sin_cierre'; pendiente ->
//     omitida. Asi una funcion que murio queda escrita aunque nadie mire.
//  2. Abre TODAS las corridas de esta invocacion en 'pendiente', antes de
//     hablar con Google: si la funcion muere leyendo, ya hay rastro.
//  3. Fuente por fuente, EN SERIE: pasa a 'en_curso' justo antes de leerla,
//     registra payload_bytes antes de parsear, procesa y cierra.
//  Si muere en la fuente 3: la 3 queda en_curso (-> error), la 4..12 quedan
//  pendiente (-> omitida: no fallaron, no arrancaron).

import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';
import type { Descarga, Metadatos } from './google.ts';
import { matrizDesdeGrid } from '../_shared/grid.js';
import { procesarFuente } from '../_shared/procesar.js';
import {
  aplicarUmbralPayload, CORTE_SIN_CIERRE, HUERFANA_MIN, mensajeCorte, mensajeOmitida,
} from '../_shared/corridas.js';
import { gridDeTexto } from './google.ts';

const TIPOS = new Set(['pagos', 'opps', 'cuotas', 'data']);

export interface Fuente {
  id: number; cliente_id: string; spreadsheet_id: string; gid: number; nombre_hoja_esperado: string;
  tipo: string; forma: string | null; fila_encabezado: number; anio: number | null; tope_monto: number | null;
  alias: { campo: string; alias: string; obligatorio: boolean; posicion?: number | null }[];
}

export interface Google {
  token(): Promise<string>;
  metadatos(token: string, spreadsheetId: string): Promise<Metadatos>;
  descargarHoja(token: string, spreadsheetId: string, titulo: string): Promise<Descarga>;
}

export interface Opciones {
  fuenteId: number | null; dryRun: boolean; aceptarEncabezado: boolean; umbralPayload: number;
}

export type Resultado = {
  fuente_id: number; cliente_id: string; tipo: string; estado: string;
  mensaje?: string | null; escrito?: unknown; payload_bytes?: number | null;
};

// Corridas abiertas en ESTE worker (puede atender mas de una invocacion a la
// vez). Las lee el beforeunload de index.ts para marcarlas si el runtime lo
// mata. Se borran apenas cada corrida cierra.
export const ABIERTAS = new Map<number, 'pendiente' | 'en_curso'>();

export async function cargarFuentes(sb: SupabaseClient, fuenteId: number | null): Promise<Fuente[]> {
  let q = sb.from('fin_fuentes')
    .select('id,cliente_id,spreadsheet_id,gid,nombre_hoja_esperado,tipo,forma,fila_encabezado,anio,tope_monto,fin_alias_columnas(campo_canonico,alias,obligatorio,posicion)')
    .eq('activo', true).order('id');
  if (fuenteId !== null) q = q.eq('id', fuenteId);
  const { data, error } = await q;
  if (error) throw new Error(`leyendo fin_fuentes: ${error.message}`);
  return (data ?? []).map((f: any) => ({
    ...f,
    tope_monto: f.tope_monto === null ? null : Number(f.tope_monto),
    alias: (f.fin_alias_columnas ?? []).map((a: any) => ({
      campo: a.campo_canonico, alias: a.alias, obligatorio: a.obligatorio, posicion: a.posicion ?? null,
    })),
  }));
}

// Ultima corrida buena (no error, cerrada) de la fuente: base del hash y de la guarda de hoja vacia.
async function corridaPrevia(sb: SupabaseClient, fuenteId: number) {
  const { data, error } = await sb.from('fin_sync_corridas')
    .select('hash_encabezado,filas_cargadas')
    .eq('fuente_id', fuenteId).in('estado', ['ok', 'revisar', 'parcial'])
    .order('inicio', { ascending: false }).limit(1).maybeSingle();
  if (error) throw new Error(`leyendo corridas previas: ${error.message}`);
  return data ? { hash: data.hash_encabezado, filas_cargadas: data.filas_cargadas } : null;
}

// Paso 1. Devuelve cuantas marco de cada tipo (para el log).
export async function barrerHuerfanas(sb: SupabaseClient, ahoraMs = Date.now()) {
  const limite = new Date(ahoraMs - HUERFANA_MIN * 60_000).toISOString();
  const fin = new Date(ahoraMs).toISOString();
  const cortadas = await sb.from('fin_sync_corridas')
    .update({ estado: 'error', corte: CORTE_SIN_CIERRE, fin, mensaje: mensajeCorte(CORTE_SIN_CIERRE) })
    .eq('estado', 'en_curso').lt('inicio', limite).select('id');
  const omitidas = await sb.from('fin_sync_corridas')
    .update({ estado: 'omitida', corte: CORTE_SIN_CIERRE, fin, mensaje: mensajeOmitida(CORTE_SIN_CIERRE) })
    .eq('estado', 'pendiente').lt('inicio', limite).select('id');
  const error = cortadas.error ?? omitidas.error;
  if (error) throw new Error(`barriendo corridas huerfanas: ${error.message}`);
  return { cortadas: cortadas.data?.length ?? 0, omitidas: omitidas.data?.length ?? 0 };
}

// Paso 2. Una fila por fuente, todas en 'pendiente', en un solo insert.
async function abrirCorridas(sb: SupabaseClient, fuentes: Fuente[], invocacion: string): Promise<Map<number, number>> {
  const { data, error } = await sb.from('fin_sync_corridas')
    .insert(fuentes.map((f) => ({ fuente_id: f.id, estado: 'pendiente', invocacion })))
    .select('id,fuente_id');
  if (error) throw new Error(`abriendo corridas: ${error.message}`);
  const ids = new Map<number, number>();
  for (const c of data ?? []) ids.set(c.fuente_id, c.id);
  return ids;
}

async function actualizar(sb: SupabaseClient, corridaId: number, campos: Record<string, unknown>) {
  const { error } = await sb.from('fin_sync_corridas').update(campos).eq('id', corridaId);
  if (error) throw new Error(`actualizando la corrida ${corridaId}: ${error.message}`);
}

// Cierra una corrida en error SIN tocar datos. Nunca tira: si no puede, lo loguea
// y la corrida la termina de cerrar el barrido de la invocacion siguiente.
async function cerrarConError(sb: SupabaseClient, corridaId: number, mensaje: string, extra: Record<string, unknown> = {}) {
  try {
    const { error } = await sb.from('fin_sync_corridas')
      .update({ estado: 'error', fin: new Date().toISOString(), mensaje, ...extra })
      .eq('id', corridaId);
    if (error) console.error(`no se pudo cerrar la corrida ${corridaId}: ${error.message}`);
  } catch (e) {
    console.error(`no se pudo cerrar la corrida ${corridaId}: ${(e as Error).message}`);
  }
}

type Planilla = { token?: string; meta?: Metadatos; error?: string };

async function correrFuente(
  sb: SupabaseClient, google: Google, f: Fuente, planilla: Planilla, corridaId: number, opciones: Opciones,
): Promise<Resultado> {
  const base = { fuente_id: f.id, cliente_id: f.cliente_id, tipo: f.tipo };
  const dry = opciones.dryRun;
  let bytes: number | null = null;
  try {
    if (!dry) {
      await actualizar(sb, corridaId, { estado: 'en_curso' });
      ABIERTAS.set(corridaId, 'en_curso');
    }
    const fallar = async (mensaje: string, extra: Record<string, unknown> = {}): Promise<Resultado> => {
      if (!dry) await cerrarConError(sb, corridaId, mensaje, extra);
      return { ...base, estado: 'error', mensaje, payload_bytes: bytes };
    };
    if (planilla.error) return await fallar(planilla.error);
    if (!TIPOS.has(f.tipo)) return await fallar(`el tipo '${f.tipo}' no se sincroniza todavia`);
    const meta = planilla.meta!;
    const hoja = meta.hojas.find((h) => h.gid === Number(f.gid));
    if (!hoja) return await fallar(`no existe la hoja gid ${f.gid} ('${f.nombre_hoja_esperado}') en la planilla`);

    let descarga: Descarga | null = await google.descargarHoja(planilla.token!, f.spreadsheet_id, hoja.titulo);
    bytes = descarga.bytes;
    // Antes del JSON.parse: si muere parseando, el tamanio ya quedo escrito.
    if (!dry) {
      try { await actualizar(sb, corridaId, { payload_bytes: bytes }); } catch (e) { console.error((e as Error).message); }
    }
    const grid = gridDeTexto(descarga.texto, hoja.titulo);
    descarga = null; // suelta el texto antes de armar la matriz

    const avisos: string[] = [];
    if (hoja.titulo !== f.nombre_hoja_esperado) {
      avisos.push(`la hoja se llama '${hoja.titulo}' y se esperaba '${f.nombre_hoja_esperado}' (se leyo igual por gid)`);
    }
    const matriz = matrizDesdeGrid(grid, meta.locale);
    const previo = await corridaPrevia(sb, f.id);
    const r = await procesarFuente(f, matriz, previo, { aceptarEncabezado: opciones.aceptarEncabezado });
    const { estado, controles } = aplicarUmbralPayload(r.estado, r.controles, bytes, opciones.umbralPayload);
    const grande = controles.length > (r.controles?.length ?? 0) ? `payload grande: ${bytes} bytes (umbral ${opciones.umbralPayload})` : null;
    const mensaje = [...avisos, r.mensaje, grande, `locale ${meta.locale}`].filter(Boolean).join(' · ');

    if (estado === 'error' || !r.datos) {
      return await fallar(`${[r.mensaje, grande].filter(Boolean).join(' · ')} · locale ${meta.locale}`, {
        hash_encabezado: r.hash, controles, filas_leidas: r.stats.leidas ?? null, filas_cargadas: 0,
      });
    }
    if (dry) {
      return { ...base, estado, mensaje, payload_bytes: bytes, escrito: { ...r.stats, controles: controles.length } };
    }
    const { data, error } = await sb.rpc('fin_sync_escribir', {
      p_corrida: corridaId, p_estado: estado, p_mensaje: mensaje, p_hash: r.hash,
      p_controles: controles, p_leidas: r.stats.leidas ?? null, p_descartadas: r.stats.descartadas ?? null,
      p_datos: r.datos,
    });
    if (error) throw new Error(`escribiendo (transaccion revertida, se conservan los datos anteriores): ${error.message}`);
    return { ...base, estado, mensaje, payload_bytes: bytes, escrito: data };
  } catch (e) {
    const msg = (e as Error).message;
    if (!dry) await cerrarConError(sb, corridaId, msg);
    return { ...base, estado: 'error', mensaje: msg, payload_bytes: bytes };
  } finally {
    ABIERTAS.delete(corridaId);
  }
}

export async function sincronizar(sb: SupabaseClient, google: Google, opciones: Opciones): Promise<Resultado[]> {
  if (!opciones.dryRun) {
    try {
      const b = await barrerHuerfanas(sb);
      if (b.cortadas || b.omitidas) console.error(`[corte] barrido: ${b.cortadas} corridas cortadas y ${b.omitidas} omitidas de invocaciones anteriores`);
    } catch (e) {
      console.error((e as Error).message); // no frena la sincronizacion
    }
  }

  const fuentes = await cargarFuentes(sb, opciones.fuenteId);
  const invocacion = crypto.randomUUID();
  let ids = new Map<number, number>();
  if (!opciones.dryRun) {
    try {
      ids = await abrirCorridas(sb, fuentes, invocacion);
    } catch (e) {
      const mensaje = (e as Error).message;
      return fuentes.map((f) => ({ fuente_id: f.id, cliente_id: f.cliente_id, tipo: f.tipo, estado: 'error', mensaje }));
    }
    for (const id of ids.values()) ABIERTAS.set(id, 'pendiente');
  }

  const resultados: Resultado[] = [];
  try {
    let token: string | undefined;
    let errorToken: string | undefined;
    try { token = await google.token(); } catch (e) { errorToken = `no se pudo autenticar con Google: ${(e as Error).message}`; }

    const porPlanilla = new Map<string, Fuente[]>();
    for (const f of fuentes) porPlanilla.set(f.spreadsheet_id, [...(porPlanilla.get(f.spreadsheet_id) ?? []), f]);

    // En serie: una planilla, y dentro una hoja, por vez. Mas lento, pero el
    // pico de memoria es el de UNA hoja.
    for (const [spreadsheetId, grupo] of porPlanilla) {
      const planilla: Planilla = { token };
      try {
        if (!token) throw new Error(errorToken ?? 'sin token de Google');
        planilla.meta = await google.metadatos(token, spreadsheetId);
      } catch (e) {
        planilla.error = (e as Error).message;
      }
      for (const f of grupo) resultados.push(await correrFuente(sb, google, f, planilla, ids.get(f.id) ?? 0, opciones));
    }
    return resultados;
  } finally {
    // Algo tiro por afuera de correrFuente: lo que haya quedado abierto de ESTA
    // invocacion se cierra ya, en vez de esperar al barrido.
    const quedaron = [...ids.values()].filter((id) => ABIERTAS.has(id));
    for (const id of quedaron) {
      const estaba = ABIERTAS.get(id);
      ABIERTAS.delete(id);
      if (estaba === 'en_curso') await cerrarConError(sb, id, 'la invocacion termino con un error inesperado antes de cerrar esta corrida');
      else {
        const { error } = await sb.from('fin_sync_corridas')
          .update({ estado: 'omitida', fin: new Date().toISOString(), mensaje: 'no se llego a intentar: la invocacion termino con un error inesperado' })
          .eq('id', id).eq('estado', 'pendiente');
        if (error) console.error(`no se pudo cerrar la corrida ${id}: ${error.message}`);
      }
    }
  }
}

// Paso (c): el runtime va a matar el worker. Best effort y SIN bloquear:
// devuelve enseguida (no es async, no usa waitUntil) y las escrituras salen en
// segundo plano. Si no llegan, no pasa nada peor que hoy: el barrido de la
// invocacion siguiente las cierra como 'sin_cierre'. Los filtros por estado
// garantizan que nunca pisa una corrida que ya cerro bien.
export function alApagar(sb: SupabaseClient | null, motivo: string): void {
  try {
    const enCurso = [...ABIERTAS].filter(([, e]) => e === 'en_curso').map(([id]) => id);
    const pendientes = [...ABIERTAS].filter(([, e]) => e === 'pendiente').map(([id]) => id);
    if (!enCurso.length && !pendientes.length) return; // apagado normal por inactividad
    console.error(`[corte] el runtime apaga el worker (${motivo}) con corridas abiertas: en_curso ${enCurso.join(',') || '-'} · pendiente ${pendientes.length}`);
    ABIERTAS.clear();
    if (!sb) return;
    const fin = new Date().toISOString();
    const ignorar = () => {};
    if (enCurso.length) {
      Promise.resolve(sb.from('fin_sync_corridas')
        .update({ estado: 'error', corte: motivo, fin, mensaje: mensajeCorte(motivo) })
        .in('id', enCurso).eq('estado', 'en_curso'))
        .then(ignorar, ignorar);
    }
    if (pendientes.length) {
      Promise.resolve(sb.from('fin_sync_corridas')
        .update({ estado: 'omitida', corte: motivo, fin, mensaje: mensajeOmitida(motivo) })
        .in('id', pendientes).eq('estado', 'pendiente'))
        .then(ignorar, ignorar);
    }
  } catch {
    // best effort: nunca propaga
  }
}
