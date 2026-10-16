/* Lectura mensual de números con IA (148). Lee fin_lecturas_mes (RLS: fundador y finanzas asignado) y llama a la
   Edge Function ia-lectura-mensual para regenerar. Los permisos los decide la base; acá solo se ofrece o no la pantalla. */
import { sb } from './supabase.js';

/* Clientes (liam/agus/teo) donde el usuario puede ver la lectura. Si la 148 no está corrida, ninguno. */
export async function lecturaClientes() {
  const { data, error } = await sb.rpc('fin_lectura_clientes');
  if (error) { console.warn('fin_lectura_clientes', error.message); return []; }
  return data || [];
}

/* Historial de un cliente, la más nueva primero. */
export async function lecturasDe(cliente) {
  const { data, error } = await sb.from('fin_lecturas_mes')
    .select('id,periodo,texto,origen,generado_en,modelo')
    .eq('cliente_id', cliente).order('generado_en', { ascending: false }).limit(200);
  if (error) throw error;
  return data || [];
}

/* Pide una lectura nueva del mes (se suma al historial). Devuelve la lectura. */
export async function lecturaRegenerar(cliente, periodo) {
  const { data, error } = await sb.functions.invoke('ia-lectura-mensual', { body: { accion: 'regenerar', cliente, periodo } });
  if (error) {
    let detalle = error.message;
    try { const j = await error.context.json(); if (j && j.error) detalle = j.error; } catch { /* sin cuerpo */ }
    throw new Error(detalle);
  }
  if (!data || data.ok === false) throw new Error((data && data.error) || 'No se pudo generar la lectura.');
  return data.lectura;
}
