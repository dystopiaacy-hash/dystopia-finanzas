// supabase/functions/ventas-agenda/index.ts
//
// Ventas, fase 3. Recibe el webhook de agenda de GHL y lo guarda crudo en
// fin_agendas_entrantes. No procesa ni toca fin_llamadas.
//
// URL que se pega en GHL:
//   https://<ref>.supabase.co/functions/v1/ventas-agenda?cliente=liam&wf=liam-ig&token=<VENTAS_AGENDA_TOKEN>
//
// Deploy: con --no-verify-jwt (GHL no manda JWT de Supabase). La seguridad
// es el token de la URL, comparado en tiempo constante.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CLIENTES = new Set(['liam', 'lucas', 'teo']);
const MAX_BYTES = 256 * 1024;

const TOKEN = Deno.env.get('VENTAS_AGENDA_TOKEN') ?? '';
const sb = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  { auth: { persistSession: false } },
);

function responder(status: number, cuerpo: Record<string, unknown>) {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function mismoToken(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Busca el ID de la cita en los lugares donde GHL suele ponerlo.
// Si no lo encuentra devuelve null: el payload crudo queda guardado igual.
function buscarCitaId(p: Record<string, any>): string | null {
  const candidatos = [
    p?.calendar?.appointmentId,
    p?.calendar?.id,
    p?.appointment?.id,
    p?.appointmentId,
    p?.appointment_id,
    p?.customData?.cita_id,
  ];
  for (const c of candidatos) {
    if (typeof c === 'string' && c.trim() !== '') return c.trim();
    if (typeof c === 'number') return String(c);
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return responder(405, { ok: false, error: 'solo POST' });

  const url = new URL(req.url);
  if (!mismoToken(url.searchParams.get('token') ?? '', TOKEN)) {
    return responder(401, { ok: false, error: 'token invalido' });
  }

  const cliente = (url.searchParams.get('cliente') ?? '').trim().toLowerCase();
  if (!CLIENTES.has(cliente)) return responder(400, { ok: false, error: 'cliente invalido' });
  const wf = (url.searchParams.get('wf') ?? '').trim().slice(0, 80) || null;

  const crudo = await req.text();
  if (crudo.length > MAX_BYTES) return responder(413, { ok: false, error: 'payload demasiado grande' });

  // GHL manda JSON. Si llegara otra cosa, se guarda como texto para no perderla.
  let payload: Record<string, unknown>;
  try {
    const p = JSON.parse(crudo);
    payload = p && typeof p === 'object' && !Array.isArray(p) ? p : { _valor: p };
  } catch {
    payload = { _crudo: crudo, _content_type: req.headers.get('content-type') };
  }

  const { data, error } = await sb
    .from('fin_agendas_entrantes')
    .insert({ cliente_id: cliente, origen_wf: wf, ghl_cita_id: buscarCitaId(payload as any), payload })
    .select('id')
    .single();

  if (error) {
    console.error('[ventas-agenda] insert', error.message);
    return responder(500, { ok: false, error: 'no se pudo guardar' });
  }
  return responder(200, { ok: true, id: data.id });
});
