-- Genera un codigo corto (8 hex mayusculas, sin ambiguedad O/0 ni I/1 porque
-- el alfabeto hex no las usa) para que el admin lo comparta por WhatsApp
-- (seccion 3) sin tener que inventarlo a mano en el front.
create or replace function public.generar_codigo_invitacion()
returns text
language sql
volatile
as $$
  select upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
$$;

alter table invitaciones alter column codigo set default generar_codigo_invitacion();
