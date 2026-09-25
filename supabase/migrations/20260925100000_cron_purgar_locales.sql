-- Corrida diaria de purgar_locales_vencidos() (migracion 20260925090000/91000).
-- 06:00 UTC = 03:00 en Argentina. Va en una migracion aparte, despues de
-- probar el cascade con datos reales (transaccion con rollback).
--
-- pg_cron corre como postgres, sin sesion de usuario. Cada corrida queda en
-- cron.job_run_details:
--   select * from cron.job_run_details order by start_time desc limit 10;
-- Los locales que fallan se saltean con un WARNING y se reintentan al dia
-- siguiente. Para pausarlo: select cron.unschedule('purgar-locales-vencidos');

create extension if not exists pg_cron with schema pg_catalog;

-- cron.schedule con un nombre existente actualiza el job, no lo duplica.
select cron.schedule('purgar-locales-vencidos', '0 6 * * *', 'select public.purgar_locales_vencidos()');
