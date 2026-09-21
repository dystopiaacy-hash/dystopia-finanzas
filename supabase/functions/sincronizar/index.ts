// sincronizar/index.ts — Edge Function: Google Sheets (solo lectura) -> tablas fin_*.
//
// POST /functions/v1/sincronizar
//   Authorization: Bearer <sb_secret_... del proyecto>  (cron y curl; la
//                  service_role key LEGACY en JWT se rechaza, ver auth.ts)
//               o  Bearer <JWT de un fundador>          (boton "Sincronizar ahora")
//   Cuerpo (opcional, JSON):
//     { "fuente_id": 5 }                   solo esa fuente
//     { "fuente_id": 5, "aceptar_encabezado": true }  acepta un encabezado nuevo
//     { "dry_run": true }                  lee y parsea, NO escribe nada; devuelve solo conteos
//   La respuesta nunca trae contenido de filas (nombres, telefonos, montos):
//   solo conteos, estados y mensajes. El detalle queda en fin_filas_rechazadas.
//
// Por fuente: abre una corrida (en_curso), lee la hoja por gid como GRID
// (texto mostrado + valor real + tipo de formato por celda, ver
// _shared/grid.js y CONTRATO.md seccion 0), parsea y escribe
// TODO con fin_sync_escribir (005): una transaccion por fuente. Si una
// fuente falla, las demas siguen y la que fallo conserva sus datos.
// Nunca escribe en Google Sheets.
//
// Deploy: supabase functions deploy sincronizar --no-verify-jwt
// (la verificacion la hace este codigo, en auth.ts: sb_secret_ o fundador).

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';
import { tokenDeAcceso, metadatos, leerGrid } from './google.ts';
import { matrizDesdeGrid } from '../_shared/grid.js';
import { procesarFuente } from '../_shared/procesar.js';
import { autorizar, CLAVE_SERVICIO } from './auth.ts';

const URL_SB = Deno.env.get('SUPABASE_URL')!;
const TIPOS = new Set(['pagos', 'opps', 'cuotas']);

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo, null, 2), { status, headers: { ...CORS, 'content-type': 'application/json' } });
}

interface Fuente {
  id: number; cliente_id: string; spreadsheet_id: string; gid: number; nombre_hoja_esperado: string;
  tipo: string; forma: string | null; fila_encabezado: number; anio: number | null; tope_monto: number | null;
  alias: { campo: string; alias: string; obligatorio: boolean }[];
}

async function cargarFuentes(sb: SupabaseClient, fuenteId: number | null): Promise<Fuente[]> {
  let q = sb.from('fin_fuentes')
    .select('id,cliente_id,spreadsheet_id,gid,nombre_hoja_esperado,tipo,forma,fila_encabezado,anio,tope_monto,fin_alias_columnas(campo_canonico,alias,obligatorio)')
    .eq('activo', true).order('id');
  if (fuenteId !== null) q = q.eq('id', fuenteId);
  const { data, error } = await q;
  if (error) throw new Error(`leyendo fin_fuentes: ${error.message}`);
  return (data ?? []).map((f: any) => ({
    ...f,
    tope_monto: f.tope_monto === null ? null : Number(f.tope_monto),
    alias: (f.fin_alias_columnas ?? []).map((a: any) => ({ campo: a.campo_canonico, alias: a.alias, obligatorio: a.obligatorio })),
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

async function abrirCorrida(sb: SupabaseClient, fuenteId: number): Promise<number> {
  const { data, error } = await sb.from('fin_sync_corridas').insert({ fuente_id: fuenteId }).select('id').single();
  if (error) throw new Error(`abriendo corrida: ${error.message}`);
  return data.id;
}

// Cierra una corrida en error SIN tocar datos.
async function cerrarConError(sb: SupabaseClient, corridaId: number, mensaje: string, extra: Record<string, unknown> = {}) {
  const { error } = await sb.from('fin_sync_corridas')
    .update({ estado: 'error', fin: new Date().toISOString(), mensaje, ...extra })
    .eq('id', corridaId);
  if (error) console.error(`no se pudo cerrar la corrida ${corridaId}: ${error.message}`);
}

type Resultado = { fuente_id: number; cliente_id: string; tipo: string; estado: string; mensaje?: string | null; escrito?: unknown };
type Lectura = { grid?: unknown; locale?: string; titulo?: string; error?: string };

async function sincronizarFuente(
  sb: SupabaseClient, f: Fuente, lectura: Lectura,
  opciones: { dryRun: boolean; aceptarEncabezado: boolean },
): Promise<Resultado> {
  const base = { fuente_id: f.id, cliente_id: f.cliente_id, tipo: f.tipo };
  let corridaId = 0;
  try {
    if (!opciones.dryRun) corridaId = await abrirCorrida(sb, f.id);
  } catch (e) {
    return { ...base, estado: 'error', mensaje: (e as Error).message };
  }
  try {
    if (lectura.error) {
      if (!opciones.dryRun) await cerrarConError(sb, corridaId, lectura.error);
      return { ...base, estado: 'error', mensaje: lectura.error };
    }
    const avisos: string[] = [];
    if (lectura.titulo !== f.nombre_hoja_esperado) {
      avisos.push(`la hoja se llama '${lectura.titulo}' y se esperaba '${f.nombre_hoja_esperado}' (se leyo igual por gid)`);
    }
    const matriz = matrizDesdeGrid(lectura.grid, lectura.locale);
    const previo = await corridaPrevia(sb, f.id);
    const r = await procesarFuente(f, matriz, previo, { aceptarEncabezado: opciones.aceptarEncabezado });
    const mensaje = [...avisos, r.mensaje, `locale ${lectura.locale}`].filter(Boolean).join(' · ');

    if (r.estado === 'error' || !r.datos) {
      if (!opciones.dryRun) {
        await cerrarConError(sb, corridaId, `${r.mensaje} · locale ${lectura.locale}`, {
          hash_encabezado: r.hash, controles: r.controles,
          filas_leidas: r.stats.leidas ?? null, filas_cargadas: 0,
        });
      }
      return { ...base, estado: 'error', mensaje: r.mensaje };
    }
    if (opciones.dryRun) {
      return { ...base, estado: r.estado, mensaje, escrito: { ...r.stats, controles: r.controles.length } };
    }
    const { data, error } = await sb.rpc('fin_sync_escribir', {
      p_corrida: corridaId, p_estado: r.estado, p_mensaje: mensaje, p_hash: r.hash,
      p_controles: r.controles, p_leidas: r.stats.leidas ?? null, p_descartadas: r.stats.descartadas ?? null,
      p_datos: r.datos,
    });
    if (error) throw new Error(`escribiendo (transaccion revertida, se conservan los datos anteriores): ${error.message}`);
    return { ...base, estado: r.estado, mensaje, escrito: data };
  } catch (e) {
    const msg = (e as Error).message;
    if (!opciones.dryRun) await cerrarConError(sb, corridaId, msg);
    return { ...base, estado: 'error', mensaje: msg };
  }
}

async function sincronizar(opciones: { fuenteId: number | null; dryRun: boolean; aceptarEncabezado: boolean }) {
  const sb = createClient(URL_SB, CLAVE_SERVICIO!, { auth: { persistSession: false } });
  const fuentes = await cargarFuentes(sb, opciones.fuenteId);
  const resultados: Resultado[] = [];

  let token: string | null = null;
  let errorToken: string | null = null;
  try { token = await tokenDeAcceso(); } catch (e) { errorToken = `no se pudo autenticar con Google: ${(e as Error).message}`; }

  // Una lectura de metadatos y una de grid por planilla (5 planillas = 10 llamadas).
  const porPlanilla = new Map<string, Fuente[]>();
  for (const f of fuentes) porPlanilla.set(f.spreadsheet_id, [...(porPlanilla.get(f.spreadsheet_id) ?? []), f]);

  for (const [spreadsheetId, grupo] of porPlanilla) {
    const lecturas = new Map<number, Lectura>();
    try {
      if (!token) throw new Error(errorToken ?? 'sin token de Google');
      const meta = await metadatos(token, spreadsheetId);
      const titulos: string[] = [];
      for (const f of grupo) {
        if (!TIPOS.has(f.tipo)) { lecturas.set(f.id, { error: `el tipo '${f.tipo}' no se sincroniza todavia` }); continue; }
        const hoja = meta.hojas.find((h) => h.gid === Number(f.gid));
        if (!hoja) { lecturas.set(f.id, { error: `no existe la hoja gid ${f.gid} ('${f.nombre_hoja_esperado}') en la planilla` }); continue; }
        lecturas.set(f.id, { titulo: hoja.titulo, locale: meta.locale });
        if (!titulos.includes(hoja.titulo)) titulos.push(hoja.titulo);
      }
      if (titulos.length) {
        const grids = await leerGrid(token, spreadsheetId, titulos);
        for (const l of lecturas.values()) {
          if (!l.titulo) continue;
          if (!grids.has(l.titulo)) l.error = `la respuesta de Google no trajo la hoja '${l.titulo}'`;
          else l.grid = grids.get(l.titulo);
        }
      }
    } catch (e) {
      for (const f of grupo) if (!lecturas.get(f.id)?.error) lecturas.set(f.id, { error: (e as Error).message });
    }
    for (const f of grupo) resultados.push(await sincronizarFuente(sb, f, lecturas.get(f.id) ?? { error: 'sin lectura' }, opciones));
  }
  return resultados;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'usar POST' }, 405);

  const quien = await autorizar(req);
  if (!quien) return responder({ error: 'no autorizado: hace falta una secret key sb_secret_ del proyecto o un usuario fundador' }, 401);
  if (!CLAVE_SERVICIO) {
    console.error('[auth] no hay ninguna sb_secret_ configurada (SUPABASE_SECRET_KEYS / SUPABASE_SERVICE_ROLE_KEY): no se puede hablar con la base');
    return responder({ error: 'la funcion no tiene una secret key sb_secret_ para hablar con la base' }, 500);
  }

  let cuerpo: any = {};
  try {
    const texto = await req.text();
    cuerpo = texto ? JSON.parse(texto) : {};
  } catch {
    return responder({ error: 'el cuerpo no es JSON valido' }, 400);
  }
  const fuenteId = Number.isInteger(cuerpo.fuente_id) ? cuerpo.fuente_id : null;
  const dryRun = cuerpo.dry_run === true;
  const opciones = {
    fuenteId, dryRun,
    aceptarEncabezado: cuerpo.aceptar_encabezado === true && fuenteId !== null,
  };

  const inicio = Date.now();
  try {
    const resultados = await sincronizar(opciones);
    const cuenta = (e: string) => resultados.filter((r) => r.estado === e).length;
    return responder({
      invocado_por: quien, dry_run: opciones.dryRun, segundos: (Date.now() - inicio) / 1000,
      resumen: { ok: cuenta('ok'), revisar: cuenta('revisar'), parcial: cuenta('parcial'), error: cuenta('error') },
      resultados,
    });
  } catch (e) {
    return responder({ error: (e as Error).message }, 500);
  }
});
