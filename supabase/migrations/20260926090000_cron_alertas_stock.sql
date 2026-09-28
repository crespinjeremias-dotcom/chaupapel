-- El digest de stock bajo (netlify/functions/alertas-stock-email.js) pasa de
-- cron de Netlify a pg_cron. Motivo: la funcion se autorizaba con el header
-- x-nf-event: schedule, que cualquiera puede mandar a mano. Ahora exige
-- siempre un secreto compartido, y pg_cron (que ya usamos para
-- purgar-locales-vencidos) lo manda por header via pg_net.
--
-- El secreto y la URL NO van en el repo: se leen de Supabase Vault en cada
-- corrida. Setup manual, una sola vez (SQL editor):
--
--   select vault.create_secret('<mismo valor que ALERTAS_STOCK_SECRET en Netlify>', 'alertas_stock_secret');
--   select vault.create_secret('https://<tu-sitio>.netlify.app/.netlify/functions/alertas-stock-email', 'alertas_stock_url');
--
-- Para rotar: vault.update_secret(id, nuevo_valor) y cambiar tambien la env
-- var en Netlify. Sin alguno de los dos secretos la corrida no hace nada y
-- deja un WARNING en cron.job_run_details.
--
-- pg_net es asincronico: la respuesta HTTP de la funcion queda en
--   select * from net._http_response order by created desc limit 10;
-- (status_code 200 = digest procesado; 403 = el secreto no coincide;
-- 500 = falta ALERTAS_STOCK_SECRET / SUPABASE_* en Netlify).
-- Para pausarlo: select cron.unschedule('alertas-stock-email');
-- Prueba manual: select public.disparar_alertas_stock();

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create or replace function public.disparar_alertas_stock()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_secreto text;
  v_url text;
begin
  select decrypted_secret into v_secreto from vault.decrypted_secrets where name = 'alertas_stock_secret';
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'alertas_stock_url';

  if v_secreto is null or v_url is null then
    raise warning 'disparar_alertas_stock: faltan los secretos alertas_stock_secret / alertas_stock_url en Vault';
    return;
  end if;

  perform net.http_post(
    url := v_url,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-alertas-secret', v_secreto),
    timeout_milliseconds := 30000
  );
end;
$$;

revoke execute on function public.disparar_alertas_stock() from public, anon, authenticated;

-- 12:00 UTC = 9am Argentina (el mismo horario que tenia el cron de Netlify).
-- cron.schedule con un nombre existente actualiza el job, no lo duplica.
select cron.schedule('alertas-stock-email', '0 12 * * *', 'select public.disparar_alertas_stock()');
