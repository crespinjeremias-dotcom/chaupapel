// Mismos valores que public/js/supabaseClient.js. La anon key no es un
// secreto (esta pensada para exponerse en el cliente), asi que no hace
// falta pasarla por una env var de Netlify aparte -- a diferencia de
// SUPABASE_SERVICE_ROLE_KEY, que si es secreta. Si cambia el proyecto de
// Supabase, hay que actualizar los dos archivos.
export const SUPABASE_URL = 'https://mptcnzpgztbiespxpbnp.supabase.co';
export const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1wdGNuenBnenRiaWVzcHhwYm5wIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2NDA2OTEsImV4cCI6MjA5OTIxNjY5MX0.2dcfZTgvwy9Fb-amRlyyNBO-uGaUc7DFh4CW-S9ORx4';
