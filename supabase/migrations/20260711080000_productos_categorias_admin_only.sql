-- La policy generica de la Fase 1 (is_admin() OR local_id = current_local_id())
-- dejaba que cualquier empleado aprobado del local cree o edite productos y
-- categorias. La spec (seccion 2) es explicita: "Admin: Carga y edita
-- productos, categorias, proveedores" -- el empleado solo vende y ajusta
-- stock (ajustes_stock sigue con el patron generico, eso si es de cualquiera).
drop policy productos_insert on productos;
create policy productos_insert on productos
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy productos_update on productos;
create policy productos_update on productos
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy categorias_insert on categorias;
create policy categorias_insert on categorias
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy categorias_update on categorias;
create policy categorias_update on categorias
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
