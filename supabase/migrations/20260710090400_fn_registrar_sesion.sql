-- Sesion unica por dispositivo (seccion 3). No bloquea el login en si (eso
-- ya paso via supabase.auth.signInWithPassword antes de llamar esto) --
-- informa si habia otra sesion activa distinta, para que el front pueda
-- mostrar la alerta "ya hay una sesion abierta en otro dispositivo" y,
-- si el usuario confirma, cerrar esa sesion anterior con
-- supabase.auth.signOut({ scope: 'others' }).
create or replace function public.registrar_sesion(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previa uuid;
begin
  if auth.uid() is null then
    raise exception 'Se requiere estar autenticado';
  end if;

  select current_session_id into v_previa from usuarios where id = auth.uid();

  update usuarios
    set current_session_id = p_session_id,
        last_login_at = now()
    where id = auth.uid();

  return v_previa is not null and v_previa is distinct from p_session_id;
end;
$$;

comment on function public.registrar_sesion is 'p_session_id sale del claim session_id del JWT recien emitido (supabase-js no lo expone directo: se decodifica del access_token en el cliente).';
