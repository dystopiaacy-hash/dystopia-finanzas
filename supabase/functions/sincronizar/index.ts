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
//   solo conteos, estados, tamanios de payload y mensajes. El resto queda en
//   fin_filas_rechazadas.
//
// El trabajo esta en nucleo.ts: abre todas las corridas en 'pendiente', lee
// cada hoja por gid como GRID (texto mostrado + valor real + tipo de formato
// por celda, ver _shared/grid.js y CONTRATO.md seccion 0), una por vez,
// registra payload_bytes, parsea y escribe TODO con fin_sync_escribir (005):
// una transaccion por fuente. Si una fuente falla, las demas siguen y la que
// fallo conserva sus datos. Si la FUNCION muere (memoria, CPU, tiempo), queda
// escrito: ver CONTRATO.md seccion 4.2. Nunca escribe en Google Sheets.
//
// Secretos opcionales:
//   FIN_PAYLOAD_UMBRAL_BYTES  por encima, la corrida queda en 'revisar' con
//                             motivo 'payload grande' (default en _shared/corridas.js).
//
// Deploy: supabase functions deploy sincronizar --no-verify-jwt
// (la verificacion la hace este codigo, en auth.ts: sb_secret_ o fundador).

import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.116.0';
import { tokenDeAcceso, metadatos, descargarHoja } from './google.ts';
import { alApagar, sincronizar, type Google } from './nucleo.ts';
import { umbralPayload } from '../_shared/corridas.js';
import { autorizar, CLAVE_SERVICIO } from './auth.ts';

const URL_SB = Deno.env.get('SUPABASE_URL')!;
const UMBRAL_PAYLOAD = umbralPayload(Deno.env.get('FIN_PAYLOAD_UMBRAL_BYTES'));
const GOOGLE: Google = { token: tokenDeAcceso, metadatos, descargarHoja };

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, OPTIONS',
};

function responder(cuerpo: unknown, status = 200) {
  return new Response(JSON.stringify(cuerpo, null, 2), { status, headers: { ...CORS, 'content-type': 'application/json' } });
}

// Un solo cliente por worker: lo usan las invocaciones y el beforeunload.
let sbServicio: SupabaseClient | null = null;
function servicio(): SupabaseClient | null {
  if (!sbServicio && CLAVE_SERVICIO) sbServicio = createClient(URL_SB, CLAVE_SERVICIO, { auth: { persistSession: false } });
  return sbServicio;
}

// El runtime avisa antes de matar el worker, con el motivo en detail.reason
// ('memory', 'cpu', 'wall_clock', 'early_drop', 'termination'). alApagar no
// bloquea ni demora el cierre: ver nucleo.ts.
addEventListener('beforeunload', (ev) => {
  const motivo = String((ev as CustomEvent<{ reason?: string }>).detail?.reason ?? 'desconocido');
  alApagar(servicio(), motivo);
});

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return responder({ error: 'usar POST' }, 405);

  const quien = await autorizar(req);
  if (!quien) return responder({ error: 'no autorizado: hace falta una secret key sb_secret_ del proyecto o un usuario fundador' }, 401);
  const sb = servicio();
  if (!sb) {
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
  const opciones = {
    fuenteId,
    dryRun: cuerpo.dry_run === true,
    aceptarEncabezado: cuerpo.aceptar_encabezado === true && fuenteId !== null,
    umbralPayload: UMBRAL_PAYLOAD,
  };

  const inicio = Date.now();
  try {
    const resultados = await sincronizar(sb, GOOGLE, opciones);
    const cuenta = (e: string) => resultados.filter((r) => r.estado === e).length;
    return responder({
      invocado_por: quien, dry_run: opciones.dryRun, segundos: (Date.now() - inicio) / 1000,
      umbral_payload_bytes: UMBRAL_PAYLOAD,
      resumen: { ok: cuenta('ok'), revisar: cuenta('revisar'), parcial: cuenta('parcial'), error: cuenta('error') },
      resultados,
    });
  } catch (e) {
    return responder({ error: (e as Error).message }, 500);
  }
});
