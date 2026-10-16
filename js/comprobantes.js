/* Comprobantes de pago (143, IA Fase 3): subida al bucket privado `comprobantes`, lectura con la Edge Function
   comprobante-leer y RPC de la bandeja. Nada de acá crea un pago: eso es Cargar pago (fin_pago_cargar) y,
   recién después, fin_comp_confirmar vincula el comprobante con el pago. Los permisos los decide la base. */
import { sb } from './supabase.js';

const BUCKET = 'comprobantes';
const TIPOS = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'application/pdf': 'pdf' };
const MAX_BYTES = 10 * 1024 * 1024;
const MAX_IMAGEN = 4 * 1024 * 1024;   // la API de visión admite 5 MB por imagen: más grande se achica acá
export const ACCEPT = Object.keys(TIPOS).join(',');

async function rpc(nombre, args = {}) {
  const { data, error } = await sb.rpc(nombre, args);
  if (error) throw error;
  return data;
}

export const comprobantesMios = () => rpc('fin_comp_mios');
export const comprobantesBandeja = filtro => rpc('fin_comp_bandeja', { p_filtro: filtro });
export const comprobanteObtener = id => rpc('fin_comp_obtener', { p_id: id });
export const comprobanteConfirmar = (id, pagoClave) => rpc('fin_comp_confirmar', { p_id: id, p_pago_clave: pagoClave });
export const comprobanteDescartar = (id, motivo) => rpc('fin_comp_descartar', { p_id: id, p_motivo: motivo });

/* Mensaje de error si el archivo no sirve; '' si está bien. */
export function validarArchivo(f) {
  if (!f) return 'Elegí un archivo.';
  if (!TIPOS[f.type]) return 'El archivo tiene que ser una imagen (jpg, png o webp) o un PDF.';
  if (f.size > MAX_BYTES && f.type === 'application/pdf') return 'El PDF no puede pasar de 10 MB.';
  return '';
}

/* Una imagen de más de 4 MB (foto de cámara, captura grande) se achica a JPG de hasta 2000 px de lado. */
async function prepararArchivo(f) {
  if (f.type === 'application/pdf' || f.size <= MAX_IMAGEN) return f;
  const img = await createImageBitmap(f);
  const k = Math.min(1, 2000 / Math.max(img.width, img.height));
  const c = document.createElement('canvas');
  c.width = Math.round(img.width * k);
  c.height = Math.round(img.height * k);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  img.close();
  const blob = await new Promise(ok => c.toBlob(ok, 'image/jpeg', 0.85));
  if (!blob) throw new Error('No se pudo achicar la imagen. Probá con una captura de pantalla.');
  return blob;
}

/* Sube el archivo y lo registra. Devuelve el id del comprobante. */
export async function subirComprobante(cliente, archivo) {
  const falla = validarArchivo(archivo);
  if (falla) throw new Error(falla);
  const blob = await prepararArchivo(archivo);
  if (blob.size > MAX_BYTES) throw new Error('El archivo no puede pasar de 10 MB.');
  const path = `${cliente}/${crypto.randomUUID()}.${TIPOS[blob.type]}`;
  const { error } = await sb.storage.from(BUCKET).upload(path, blob, { contentType: blob.type, upsert: false });
  if (error) throw new Error(`No se pudo subir el archivo: ${error.message}`);
  return rpc('fin_comp_registrar', {
    p_cliente: cliente, p_path: path, p_nombre: archivo.name || 'comprobante', p_mime: blob.type, p_bytes: blob.size
  });
}

/* Dispara la lectura con IA. Quien confirma recibe {ok, estado, extraido, propuesta, duplicados, confianza};
   quien solo sube, {ok, estado}. Si falla, el comprobante queda pendiente igual. */
export async function leerComprobante(id, reintentar = false) {
  const { data, error } = await sb.functions.invoke('comprobante-leer', { body: { comprobante_id: id, reintentar } });
  if (error) {
    let detalle = error.message;
    try { const j = await error.context.json(); if (j && j.error) detalle = j.error; } catch { /* sin cuerpo */ }
    throw new Error(detalle);
  }
  return data;
}

/* Link temporal (5 min) para ver el archivo. */
export async function urlComprobante(path) {
  const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, 300);
  if (error) throw error;
  return data.signedUrl;
}

/* Comprobante elegido en la bandeja para precargar Cargar pago (se consume una sola vez). */
let precarga = null;
export const dejarPrecarga = comp => { precarga = comp; };
export const tomarPrecarga = () => { const c = precarga; precarga = null; return c; };

/* Texto corto para mostrar lo leído: "USD 500,00 · 12/10/2026 · Banco Galicia". */
export function resumenLeido(x) {
  if (!x) return '';
  const monto = x.monto != null
    ? `${x.moneda || ''} ${new Intl.NumberFormat('es-AR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(x.monto)}`.trim() : 'monto ilegible';
  const fecha = x.fecha ? x.fecha.split('-').reverse().join('/') : 'sin fecha';
  return [monto, fecha, x.banco_o_billetera].filter(Boolean).join(' · ');
}
