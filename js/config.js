/* Mismo proyecto de Supabase que Dystopia CRM y Seguimiento (misma auth, mismos usuarios).
   La publishable key es pública por diseño: la seguridad la dan las políticas RLS.
   Verificada contra la de Seguimiento (js/config.js), que está en producción. */
export const SUPABASE_URL = 'https://alxdjcdfpdayucassfub.supabase.co';
export const SUPABASE_KEY = 'sb_publishable_EIkOqy24hED4t707eKnpDA_7s0DR4mE';

/* Zona horaria de negocio: hoy y vencimientos se calculan acá, nunca en UTC. */
export const TZ = 'America/Argentina/Buenos_Aires';

/* Salud de sincronización: el cron corre cada 15 min. Una fuente sin corrida
   buena hace más de esto se marca desactualizada; una corrida 'en_curso' más
   vieja que COLGADA_MIN se considera caída. */
export const DESACTUALIZADA_MIN = 60;
export const COLGADA_MIN = 10;
