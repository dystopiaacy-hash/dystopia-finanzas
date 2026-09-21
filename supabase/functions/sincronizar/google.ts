// sincronizar/google.ts — lectura de Google Sheets con la service account.
// SOLO LECTURA: el scope es spreadsheets.readonly y no hay ninguna llamada de
// escritura. La service account tampoco tiene permiso de editor.
// La credencial sale del secreto GOOGLE_SA_JSON (JSON completo de la SA).

const SCOPE = 'https://www.googleapis.com/auth/spreadsheets.readonly';
const API = 'https://sheets.googleapis.com/v4/spreadsheets';
const REINTENTOS = 4;
const REINTENTABLES = new Set([429, 500, 502, 503, 504]);

export class ErrorGoogle extends Error {
  constructor(public status: number, mensaje: string) {
    super(mensaje);
  }
}

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === 'string' ? new TextEncoder().encode(bytes) : bytes;
  let s = '';
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function pemADer(pem: string): Uint8Array<ArrayBuffer> {
  const limpio = pem.replace(/-----(BEGIN|END) PRIVATE KEY-----/g, '').replace(/\s+/g, '');
  return Uint8Array.from(atob(limpio), (c) => c.charCodeAt(0));
}

const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));

// fetch con reintentos para 429 y 5xx: backoff exponencial con jitter
// (1s, 2s, 4s, 8s + hasta 1s), respetando Retry-After si viene (tope 30s).
async function pedir(url: string, init: RequestInit = {}): Promise<Response> {
  for (let intento = 0; ; intento++) {
    let res: Response;
    try {
      res = await fetch(url, init);
    } catch (e) {
      if (intento >= REINTENTOS) throw new ErrorGoogle(0, `red: ${(e as Error).message}`);
      await espera(1000 * 2 ** intento + Math.random() * 1000);
      continue;
    }
    if (res.ok || !REINTENTABLES.has(res.status) || intento >= REINTENTOS) return res;
    const retryAfter = Number(res.headers.get('retry-after'));
    await res.body?.cancel();
    const ms = Number.isFinite(retryAfter) && retryAfter > 0
      ? Math.min(retryAfter, 30) * 1000
      : 1000 * 2 ** intento + Math.random() * 1000;
    await espera(ms);
  }
}

async function errorDe(res: Response, contexto: string): Promise<ErrorGoogle> {
  let detalle = '';
  try { detalle = (await res.json())?.error?.message ?? ''; } catch { /* sin cuerpo */ }
  const causa = res.status === 403 ? 'la service account no tiene permiso de lector sobre la planilla'
    : res.status === 404 ? 'la planilla no existe o no esta compartida con la service account'
    : res.status === 429 ? 'Google limito las lecturas (429) y siguio limitando despues de reintentar'
    : `HTTP ${res.status}`;
  return new ErrorGoogle(res.status, `${contexto}: ${causa}${detalle ? ` (${detalle})` : ''}`);
}

export async function tokenDeAcceso(): Promise<string> {
  const crudo = Deno.env.get('GOOGLE_SA_JSON');
  if (!crudo) throw new Error('falta el secreto GOOGLE_SA_JSON en Supabase Edge Functions');
  const sa = JSON.parse(crudo);
  const ahora = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri || 'https://oauth2.googleapis.com/token';
  const cabecera = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const cuerpo = b64url(JSON.stringify({ iss: sa.client_email, scope: SCOPE, aud: tokenUri, iat: ahora, exp: ahora + 3600 }));
  const clave = await crypto.subtle.importKey(
    'pkcs8', pemADer(sa.private_key), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const firma = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', clave, new TextEncoder().encode(`${cabecera}.${cuerpo}`)));
  const res = await pedir(tokenUri, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${cabecera}.${cuerpo}.${b64url(firma)}`,
    }),
  });
  if (!res.ok) throw await errorDe(res, 'token de Google');
  return (await res.json()).access_token;
}

export interface Hoja { gid: number; titulo: string }
export interface Metadatos { locale: string; hojas: Hoja[] }

export async function metadatos(token: string, spreadsheetId: string): Promise<Metadatos> {
  const campos = 'properties.locale,sheets.properties(sheetId,title)';
  const res = await pedir(`${API}/${encodeURIComponent(spreadsheetId)}?fields=${encodeURIComponent(campos)}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw await errorDe(res, `planilla ${spreadsheetId}`);
  const j = await res.json();
  return {
    locale: j.properties?.locale ?? 'en_US',
    hojas: (j.sheets ?? []).map((s: any) => ({ gid: Number(s.properties.sheetId), titulo: String(s.properties.title) })),
  };
}

export function rangoHoja(titulo: string): string {
  return `'${titulo.replace(/'/g, "''")}'`;
}

// Solo los campos que usa grid.js. Sin este filtro la respuesta trae formato
// de celda completo, bordes, validaciones, formato condicional, etc.
export const CAMPOS_GRID =
  'sheets(properties(title),data(startRow,rowData(values(formattedValue,effectiveValue,effectiveFormat/numberFormat/type))))';

// UNA hoja por llamada, como grid: por celda, el texto mostrado, el valor real
// y el tipo de formato. Ver _shared/grid.js y CONTRATO.md seccion 0 (por que
// NO se usa values.get con FORMATTED_VALUE).
// Se separa en dos pasos a proposito: descargarHoja devuelve el texto y su
// tamanio en bytes SIN parsearlo, para que la corrida registre payload_bytes
// antes del JSON.parse (que es donde mas memoria se usa). Si la funcion muere
// parseando, el tamanio ya quedo escrito. Una hoja por vez tambien baja el
// pico: mauro eran 3 hojas y 2,9 MB en una sola respuesta.
export interface Descarga { texto: string; bytes: number }

export async function descargarHoja(token: string, spreadsheetId: string, titulo: string): Promise<Descarga> {
  const qs = new URLSearchParams({ includeGridData: 'true', fields: CAMPOS_GRID });
  qs.append('ranges', rangoHoja(titulo));
  const res = await pedir(`${API}/${encodeURIComponent(spreadsheetId)}?${qs}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw await errorDe(res, `lectura de '${titulo}' en ${spreadsheetId}`);
  const crudo = await res.arrayBuffer();
  const bytes = crudo.byteLength;
  const texto = new TextDecoder().decode(crudo);
  console.log(`[google] grid ${spreadsheetId.slice(0, 6)} '${titulo}': ${bytes} bytes`);
  return { texto, bytes };
}

// El bloque data[0] de la hoja pedida.
export function gridDeTexto(texto: string, titulo: string): unknown {
  const j = JSON.parse(texto);
  const hoja = (j.sheets ?? []).find((s: any) => s.properties?.title === titulo);
  if (!hoja) throw new Error(`la respuesta de Google no trajo la hoja '${titulo}'`);
  return hoja.data?.[0] ?? {};
}
