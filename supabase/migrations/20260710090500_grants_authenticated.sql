-- RLS filtra FILAS, pero antes de eso Postgres exige el GRANT de tabla en
-- si. Las migraciones se corrieron con un rol distinto al que Supabase usa
-- para los defaults automaticos del dashboard, asi que hay que otorgarlo
-- explicito (y dejarlo automatico para tablas futuras via default privileges).
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
