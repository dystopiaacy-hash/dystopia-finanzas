// Reexport: el parser vive en supabase/functions/_shared/parsers/ para que la
// Edge Function lo empaquete. Este archivo solo existe para las pruebas en Node.
export * from '../supabase/functions/_shared/parsers/pagos.js';
