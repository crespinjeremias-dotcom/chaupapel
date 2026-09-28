-- Auditoria de permisos (GRANTs) contra la base real. Hallazgos:
--
--   1. service_role no tenia SELECT/INSERT/UPDATE/DELETE sobre NINGUNA tabla de
--      public. El proyecto no autoexpone tablas nuevas a los roles de la API
--      (ver auto_expose_new_tables en supabase/config.toml), y la migracion
--      20260710090500 solo otorgo permisos a `authenticated`. Como service_role
--      tiene BYPASSRLS pero no bypasea los GRANTs de tabla, las tres Netlify
--      Functions que la usan fallaban:
--        - toggle-organizacion  -> "permission denied for table super_admins"
--          (suspender / reactivar una organizacion)
--        - alertas-stock-email  -> nunca pudo leer locales/productos/usuarios
--          (el digest diario de stock bajo no funcionaba)
--   2. Todas las funciones de public eran ejecutables por anon y PUBLIC (el
--      default de Postgres). Las que validan auth.uid() / is_admin() por dentro
--      rechazaban al anonimo con "No autorizado", pero no hay motivo para que un
--      anonimo pueda ni invocarlas (y varias, como max_locales() o
--      local_is_active(), no validan nada y contestan sobre cualquier id).
--
-- Nota: el error "more than one relationship ... 'usuarios' and 'locales'" no
-- es de permisos -- lo causo la FK locales.eliminacion_solicitada_por
-- (20260925090000). Se corrige del lado del cliente indicando la relacion
-- (locales!usuarios_local_id_fkey en auth.js y empleados.js); no hay cambio de
-- schema para eso.

-- ============================================================================
-- PARTE 1: service_role
-- ============================================================================

grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Para que las tablas que se creen desde ahora no repitan el problema.
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;
alter default privileges for role postgres in schema public grant select, insert, update, delete on tables to service_role;
alter default privileges in schema public grant usage, select on sequences to service_role;
alter default privileges for role postgres in schema public grant usage, select on sequences to service_role;

-- ============================================================================
-- PARTE 2: EXECUTE de las funciones propias (no las de extensiones como pg_trgm)
-- Solo `authenticated` (la app con sesion) y service_role. Las funciones de
-- trigger quedan como estan: no se invocan por API y el trigger no necesita
-- EXECUTE de quien dispara la fila.
--
-- IMPORTANTE para funciones nuevas: Postgres las crea ejecutables por PUBLIC.
-- Toda RPC nueva tiene que hacer explicitamente
--   revoke execute on function public.<f>(...) from public, anon;
--   grant execute on function public.<f>(...) to authenticated;
-- ============================================================================

do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f'
      and p.prorettype <> 'trigger'::regtype
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$$;

-- El unico que si tiene que poder llamar alguien sin sesion: el alta de una
-- organizacion valida el codigo de activacion ANTES del signUp (auth.js).
grant execute on function public.validar_codigo_activacion(text) to anon;

-- Solo la corre pg_cron (como postgres): ni la app ni service_role.
revoke execute on function public.purgar_locales_vencidos() from public, anon, authenticated, service_role;
