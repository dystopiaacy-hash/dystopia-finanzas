// supabase/functions/ventas-agenda/index.ts
//
// Ventas, fase 3. Recibe el webhook de agenda de GHL, lo guarda crudo en
// fin_agendas_entrantes (con evento y de que ruta salio la cita) y llama a
// fin_procesar_agenda (migracion 131), que lo pasa a fin_llamadas. Si el
// procesamiento falla, el crudo queda y un cron lo reintenta.
//
// URL que se pega en GHL:
//   https://<ref>.supabase.co/functions/v1/ventas-agenda?cliente=liam&wf=liam-ig&token=<VENTAS_AGENDA_TOKEN>
//
// Deploy: con --no-verify-jwt (GHL no manda JWT de Supabase). La seguridad
// es el token de la URL, comparado en tiempo constante.

import { createClient } from 'npm:@supabase/supabase-js@2';

const CLIENTES = new Set(['liam', 'agus', 'teo']);
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

type Hallazgo = { valor: string; ruta: string } | null;

// Primer valor no vacio entre varias rutas ("a.b.c") del payload. Ignora
// objetos y merge fields sin resolver ("{{appointment.id}}").
function buscar(p: Record<string, any>, rutas: string[]): Hallazgo {
  for (const ruta of rutas) {
    let v: any = p;
    for (const k of ruta.split('.')) v = v && typeof v === 'object' ? v[k] : undefined;
    if (typeof v === 'number') v = String(v);
    if (typeof v !== 'string') continue;
    v = v.trim();
    if (v === '' || /^\{\{.*\}\}$/.test(v) || /^(null|undefined)$/i.test(v)) continue;
    return { valor: v, ruta };
  }
  return null;
}

// ID de la cita. Nunca calendar.id: es el ID del CALENDARIO (igual para todas
// las citas). "id" de primer nivel va al final y se descarta si es el del
// contacto (en GHL suele serlo). Si no hay ID, el crudo queda guardado igual
// y el procesamiento lo marca como sin_cita_id.
function buscarCitaId(p: Record<string, any>): Hallazgo {
  const h = buscar(p, [
    'appointment.id',
    'calendar.appointmentId',
    'calendar.appointment_id',
    'appointmentId',
    'appointment_id',
    'customData.cita_id',
    'id',
  ]);
  if (h && h.ruta === 'id' && h.valor === (p?.contact_id ?? p?.contactId)) return null;
  return h;
}

// Evento: customData.evento si viene; si no, se deduce del status de la cita.
// "agendada" sobre una cita ya existente con otra hora la vuelve
// "reprogramada" al procesar (en la base).
function normalizarEvento(t: string): 'agendada' | 'reprogramada' | 'cancelada' | 'desconocido' {
  const s = t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
  if (/(reprogram|reagend|resched)/.test(s)) return 'reprogramada';
  if (/(cancel|anulad)/.test(s)) return 'cancelada';
  if (/^(agendad|agenda|nuev|new|book|confirm|creat|schedul|reservad)/.test(s)) return 'agendada';
  return 'desconocido';
}

function buscarEvento(p: Record<string, any>): { evento: string; ruta: string | null } {
  const explicito = buscar(p, ['customData.evento', 'customData.event', 'evento']);
  if (explicito) return { evento: normalizarEvento(explicito.valor), ruta: explicito.ruta };
  const status = buscar(p, [
    'calendar.status',
    'calendar.appoinmentStatus', // GHL lo escribe asi en algunos payloads
    'calendar.appointmentStatus',
    'appointment.status',
    'appointment.appointmentStatus',
    'appointmentStatus',
    'status',
  ]);
  if (status) return { evento: normalizarEvento(status.valor), ruta: status.ruta };
  return { evento: 'desconocido', ruta: null };
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

  const cita = buscarCitaId(payload as any);
  const ev = buscarEvento(payload as any);

  const fila = {
    cliente_id: cliente,
    origen_wf: wf,
    ghl_cita_id: cita?.valor ?? null,
    cita_ruta: cita?.ruta ?? null,
    evento: ev.evento,
    evento_ruta: ev.ruta,
    payload,
  };
  let { data, error } = await sb.from('fin_agendas_entrantes').insert(fila).select('id').single();

  // 131 sin correr: las columnas nuevas no existen (42703 / PGRST204). Se guarda
  // como antes, sin evento ni rutas, para no perder el webhook.
  if (error && (error.code === '42703' || error.code === 'PGRST204')) {
    const { cita_ruta: _a, evento: _b, evento_ruta: _c, ...vieja } = fila;
    ({ data, error } = await sb.from('fin_agendas_entrantes').insert(vieja).select('id').single());
  }
  if (error || !data) {
    console.error('[ventas-agenda] insert', error?.message);
    return responder(500, { ok: false, error: 'no se pudo guardar' });
  }

  // Procesar a fin_llamadas. Si falla (o la 131 no esta), el crudo ya esta
  // guardado y el cron de respaldo lo procesa: nunca se devuelve error a GHL
  // por esto (GHL reintentaria y duplicaria filas crudas).
  let procesada: Record<string, unknown> | null = null;
  try {
    const r = await sb.rpc('fin_procesar_agenda', { p_id: data.id });
    if (r.error) console.error('[ventas-agenda] procesar', r.error.message);
    else procesada = r.data as Record<string, unknown>;
  } catch (e) {
    console.error('[ventas-agenda] procesar', String(e));
  }
  return responder(200, {
    ok: true,
    id: data.id,
    evento: ev.evento,
    ghl_cita_id: cita?.valor ?? null,
    procesada,
  });
});
