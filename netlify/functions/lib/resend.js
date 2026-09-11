// Helper compartido para la API REST de Resend (seccion 11, Fase 9). Se
// llama por fetch en vez de sumar su SDK como dependencia -- es una sola
// llamada, no lo justifica.
const RESEND_API_URL = 'https://api.resend.com/emails';

export async function enviarEmail({ to, subject, html }) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    throw new Error('Falta configurar RESEND_API_KEY en las variables de entorno de Netlify');
  }

  // Sin dominio propio verificado en Resend, este remitente por defecto es
  // el unico que la cuenta deja usar, y solo para mandarle a la propia
  // casilla del dueño de la cuenta -- sirve para probar el circuito antes
  // de verificar un dominio real. RESEND_FROM permite pisarlo en produccion.
  const from = process.env.RESEND_FROM || 'Chaupapel <onboarding@resend.dev>';

  const res = await fetch(RESEND_API_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ from, to, subject, html }),
  });

  if (!res.ok) {
    const detalle = await res.text().catch(() => '');
    throw new Error(`Resend respondió ${res.status}: ${detalle}`);
  }

  return res.json();
}
