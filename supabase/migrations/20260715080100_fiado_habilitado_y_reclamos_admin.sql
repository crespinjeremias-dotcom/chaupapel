-- Toggle real para poder ocultar "Cuenta corriente" del menu si el negocio
-- no usa fiado (seccion 9: "funcionalidad opcional"). Todavia no hay pantalla
-- de configuracion para cambiarlo -- queda en true por default, listo para
-- cuando se construya esa pantalla, en vez de fingir un flag que no existe.
alter table locales add column fiado_habilitado boolean not null default true;

-- Redefine el alcance de "reclamos a proveedor": la Fase 1/4 lo habia dejado
-- con el patron generico (cualquier aprobado del local). Pedido explicito
-- posterior: el empleado no debe ni ver reclamos pendientes, solo el admin
-- gestiona esa parte de Proveedores. Reponer stock (que si sigue siendo del
-- empleado) no depende de reclamos_proveedor para nada.
drop policy reclamos_select on reclamos_proveedor;
create policy reclamos_select on reclamos_proveedor
  for select
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy reclamos_insert on reclamos_proveedor;
create policy reclamos_insert on reclamos_proveedor
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy reclamos_update on reclamos_proveedor;
create policy reclamos_update on reclamos_proveedor
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
