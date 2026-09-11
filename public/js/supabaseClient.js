import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://mptcnzpgztbiespxpbnp.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1wdGNuenBnenRiaWVzcHhwYm5wIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM2NDA2OTEsImV4cCI6MjA5OTIxNjY5MX0.2dcfZTgvwy9Fb-amRlyyNBO-uGaUc7DFh4CW-S9ORx4';

// sessionStorage en vez del default (localStorage): permite tener cuentas
// distintas logueadas en pestañas distintas de la misma ventana. Costo
// aceptado (seccion 3): cada pestaña nueva pide login de nuevo, incluso para
// la misma cuenta -- eso puede disparar el aviso de "sesión activa en otro
// lado" (registrar_sesion) para el mismo usuario abriendo una segunda
// pestaña propia, no solo para otro dispositivo. No hay forma confiable de
// distinguirlos sin sumar un identificador de dispositivo nuevo, y no vale
// la pena esa inversión por esta molestia menor.
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { storage: window.sessionStorage },
});
