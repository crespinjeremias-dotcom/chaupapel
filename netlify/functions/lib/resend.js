// Envio de emails via Resend (seccion 11, Fase 9). API REST directa por
// fetch en vez del SDK oficial -- es una sola llamada, no justifica sumar
// una dependencia mas al package.json compartido de las functions.
const RESEND_API_URL = 'https://api.resend.com/emails';

export async function enviarEmail({ to, subject, html }) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) throw new Error('Falta configurar RESEND_API_KEY en Netlify');

  // onboarding@resend.dev funciona sin verificar dominio propio -- sirve
  // para arrancar, pero Resend lo limita a mandar solo a la casilla con la
  // que se creo la cuenta. En cuanto haya un dominio propio verificado en
  // Resend, configurar EMAIL_FROM con ese dominio para poder mandarle a
  // los clientes reales.
  const from = process.env.EMAIL_FROM || 'Chaupapel <onboarding@resend.dev>';

  const resp = await fetch(RESEND_API_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to, subject, html }),
  });

  if (!resp.ok) {
    const data = await resp.json().catch(() => ({}));
    throw new Error(data.message || `Resend respondió ${resp.status}`);
  }
}
