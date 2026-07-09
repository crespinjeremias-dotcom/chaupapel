-- Perfil de aplicacion asociado 1 a 1 con auth.users. El id es el mismo uuid
-- que auth.users.id (no hay un id propio separado) para simplificar joins y RLS.
create table usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  local_id uuid references locales(id) on delete set null,
  role user_role_type not null default 'empleado',
  status user_status_type not null default 'pending',
  nombre text not null,
  email text,
  telefono text,
  current_session_id uuid,      -- session_id del JWT activo, para forzar sesion unica por dispositivo
  last_login_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_usuarios_organization on usuarios(organization_id);
create index idx_usuarios_local on usuarios(local_id);

comment on column usuarios.local_id is 'Null para admin (ve todos los locales de su organizacion). Obligatorio en la practica para empleado.';
comment on column usuarios.status is 'pending = esperando aprobacion del admin tras registrarse con codigo de invitacion. El admin de una organizacion nueva se crea directamente en approved.';
comment on column usuarios.current_session_id is 'Usado por el flujo de "sesion unica por dispositivo" (seccion 3): al loguear se compara/reemplaza contra la sesion activa anterior.';
