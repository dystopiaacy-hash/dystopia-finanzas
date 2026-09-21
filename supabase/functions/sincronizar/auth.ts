// sincronizar/auth.ts — quien puede invocar la funcion. Politica EXPLICITA:
//
//   ACEPTA
//   1. Una secret key NUEVA de Supabase (prefijo "sb_secret_") que coincida
//      exactamente con una de las configuradas en el proyecto. Es lo que usa
//      el cron (004_cron.sql) y el curl de prueba.
//      Se leen de SUPABASE_SECRET_KEYS (JSON que inyecta Supabase) y, si ahi
//      no hay, de SUPABASE_SERVICE_ROLE_KEY solo si ese valor empieza con
//      "sb_secret_".
//   2. El JWT de un usuario logueado, verificado contra Supabase Auth, cuyo
//      rol sea fundador (public.es_fundador() corriendo como ese usuario).
//      Es el boton "Sincronizar ahora" de la app.
//
//   RECHAZA (a proposito, no por casualidad)
//   - La service_role key LEGACY (un JWT con role = service_role). Las keys
//     legacy estan deprecadas y no se pueden rotar sin rotar el JWT secret
//     de todo el proyecto. Si alguna vez se necesita, se agrega aca a mano.
//   - La anon key legacy y cualquier sb_publishable_ (son publicas).
//   - Una sb_secret_ que no coincide, un JWT vencido o invalido, un usuario
//     que no es fundador, y la falta de header.
//
// Cada negativa deja UNA linea en los logs con el motivo. Nunca se loguea
// la key, el token ni un fragmento de ellos (ni prefijo ni ultimos caracteres).

import { createClient } from 'npm:@supabase/supabase-js@2.116.0';

const URL_SB = Deno.env.get('SUPABASE_URL')!;

function valoresDe(nombre: string): string[] {
  const crudo = Deno.env.get(nombre);
  if (!crudo) return [];
  try {
    const j = JSON.parse(crudo);
    if (Array.isArray(j)) return j.filter((v) => typeof v === 'string');
    if (j && typeof j === 'object') return Object.values(j).filter((v): v is string => typeof v === 'string');
    if (typeof j === 'string') return [j];
  } catch { /* no es JSON: valor plano */ }
  return [crudo];
}

// Secret keys nuevas aceptadas. Solo "sb_secret_...": un JWT legacy aca se descarta.
const SECRETAS = (() => {
  const desdeLista = valoresDe('SUPABASE_SECRET_KEYS').filter((k) => k.startsWith('sb_secret_'));
  if (desdeLista.length) return { claves: desdeLista, origen: 'SUPABASE_SECRET_KEYS' };
  const sr = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (sr.startsWith('sb_secret_')) return { claves: [sr], origen: 'SUPABASE_SERVICE_ROLE_KEY' };
  return { claves: [] as string[], origen: 'ninguno' };
})();

// Key con la que la funcion habla con la base (service_role). Misma politica: solo sb_secret_.
export const CLAVE_SERVICIO: string | null = SECRETAS.claves[0] ?? null;

// Para verificar un JWT de usuario hace falta una key publica como apikey.
const CLAVE_PUBLICA = valoresDe('SUPABASE_PUBLISHABLE_KEYS').find((k) => k.startsWith('sb_publishable_'))
  ?? Deno.env.get('SUPABASE_ANON_KEY') ?? null;

// Al arrancar: que hay configurado, por TIPO. Ningun valor.
console.log(`[auth] secret keys aceptadas: ${SECRETAS.claves.length} (origen: ${SECRETAS.origen}); `
  + `SUPABASE_SERVICE_ROLE_KEY es ${tipoDe(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '')}; `
  + `key publica para usuarios: ${CLAVE_PUBLICA ? tipoDe(CLAVE_PUBLICA) : 'ninguna'}`);

// Tipo de credencial sin exponerla.
function tipoDe(t: string): string {
  if (!t) return 'vacia';
  if (t.startsWith('sb_secret_')) return 'sb_secret';
  if (t.startsWith('sb_publishable_')) return 'sb_publishable';
  const partes = t.split('.');
  if (partes.length === 3) {
    try {
      const p = JSON.parse(atob(partes[1].replace(/-/g, '+').replace(/_/g, '/')));
      if (p.role === 'service_role') return 'jwt_legacy_service_role';
      if (p.role === 'anon') return 'jwt_legacy_anon';
      return 'jwt_usuario';
    } catch { return 'jwt_ilegible'; }
  }
  return 'desconocida';
}

// Comparacion de largo fijo para no filtrar por tiempo cuanto coincide.
function iguales(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let dif = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) dif |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return dif === 0;
}

function rechazo(motivo: string, req: Request): null {
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'sin-ip';
  console.warn(`[auth] rechazo: ${motivo} (ip ${ip})`);
  return null;
}

// Devuelve quien invoco ('secret_key' | 'fundador:<user_id>') o null (y loguea el motivo).
export async function autorizar(req: Request): Promise<string | null> {
  const header = req.headers.get('authorization');
  if (!header) return rechazo('falta el header Authorization', req);
  const m = header.match(/^Bearer\s+(\S+)$/i);
  if (!m) return rechazo('Authorization no tiene la forma "Bearer <token>"', req);
  const token = m[1];
  const tipo = tipoDe(token);

  switch (tipo) {
    case 'sb_secret':
      if (SECRETAS.claves.some((k) => iguales(k, token))) {
        console.log('[auth] ok: secret key');
        return 'secret_key';
      }
      return rechazo('sb_secret_ que no coincide con ninguna secret key del proyecto', req);
    case 'jwt_legacy_service_role':
      return rechazo('service_role key legacy (JWT): no aceptada por politica, usar una sb_secret_', req);
    case 'jwt_legacy_anon':
    case 'sb_publishable':
      return rechazo(`${tipo}: es una key publica, no autoriza`, req);
    case 'jwt_usuario':
      break;
    default:
      return rechazo(`token de tipo ${tipo}`, req);
  }

  if (!CLAVE_PUBLICA) return rechazo('no hay key publica configurada para verificar usuarios', req);
  const comoUsuario = createClient(URL_SB, CLAVE_PUBLICA, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false },
  });
  const { data: u, error: eu } = await comoUsuario.auth.getUser(token);
  if (eu || !u?.user) return rechazo(`JWT de usuario invalido o vencido${eu ? ` (${eu.message})` : ''}`, req);
  const { data: fundador, error: ef } = await comoUsuario.rpc('es_fundador');
  if (ef) return rechazo(`no se pudo verificar el rol del usuario ${u.user.id} (${ef.message})`, req);
  if (fundador !== true) return rechazo(`el usuario ${u.user.id} no es fundador`, req);
  console.log(`[auth] ok: fundador ${u.user.id}`);
  return `fundador:${u.user.id}`;
}
