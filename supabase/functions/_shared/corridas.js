// _shared/corridas.js — ciclo de vida de una corrida y umbral de payload.
// Sin dependencias de Deno ni de red: lo prueban pruebas/corte.test.ts y la
// Edge Function lo importa tal cual. Ver CONTRATO.md seccion 4.2.
//
// Estados de fin_sync_corridas (006):
//   pendiente -> la invocacion la abrio al arrancar; todavia no se toco la fuente.
//   en_curso  -> se empezo a leer esta fuente (Google, parseo o escritura).
//   ok | revisar | parcial | error -> termino.
//   omitida   -> la invocacion murio ANTES de llegar a esta fuente: no fallo,
//                nunca arranco. No cuenta como problema en Salud.
// Una corrida que muere en_curso termina en 'error' con `corte` = motivo
// ('memory', 'cpu', 'wall_clock', ... del runtime, o 'sin_cierre' si la
// encontro la invocacion siguiente sin saber por que murio).

export const ESTADOS_ABIERTOS = Object.freeze(['pendiente', 'en_curso']);

// Una corrida abierta hace mas que esto murio con su invocacion. Tiene que
// ser mayor que el wall clock maximo de una Edge Function (400 s en Pro) para
// no pisar una invocacion viva (cron + boton manual a la vez). Igual que
// COLGADA_MIN del frontend (js/config.js).
export const HUERFANA_MIN = 10;

export const CORTE_SIN_CIERRE = 'sin_cierre';

export function mensajeCorte(motivo) {
  return `la funcion se corto durante esta corrida (${motivo || CORTE_SIN_CIERRE}). ` +
    'Probable limite de memoria, CPU o tiempo: ver payload_bytes y los logs de la funcion. No se toco ningun dato.';
}

export function mensajeOmitida(motivo) {
  return `no se llego a intentar: la funcion se corto antes, en otra fuente (${motivo || CORTE_SIN_CIERRE}). Los datos anteriores siguen intactos.`;
}

// --- Payload grande ----------------------------------------------------------
// Hoy (2026-09-21) la hoja mas grande es mauro pagos: ~2,5 MB filtrada, con un
// pico de heap de ~29 MB contra 256 MB de limite. 5 MB es el doble de hoy:
// avisa con tiempo, lejos todavia del limite. Se cambia sin redeploy con el
// secreto FIN_PAYLOAD_UMBRAL_BYTES de la Edge Function.
export const UMBRAL_PAYLOAD_DEFECTO = 5_000_000;
export const MOTIVO_PAYLOAD = 'payload grande';

export function umbralPayload(valorEnv) {
  if (valorEnv === undefined || valorEnv === null || String(valorEnv).trim() === '') return UMBRAL_PAYLOAD_DEFECTO;
  const n = Number(String(valorEnv).trim());
  return Number.isInteger(n) && n > 0 ? n : UMBRAL_PAYLOAD_DEFECTO;
}

// Si el payload de la fuente supera el umbral: agrega el control y una corrida
// 'ok' pasa a 'revisar'. revisar, parcial y error quedan como estan (ya son
// iguales o peores). Los datos se cargan igual: es un aviso, no un rechazo.
export function aplicarUmbralPayload(estado, controles, bytes, umbral) {
  const lista = Array.isArray(controles) ? controles : [];
  if (!Number.isFinite(bytes) || bytes <= umbral) return { estado, controles: lista };
  return {
    estado: estado === 'ok' ? 'revisar' : estado,
    controles: [...lista, { motivo: MOTIVO_PAYLOAD, payload_bytes: bytes, umbral_bytes: umbral }],
  };
}
