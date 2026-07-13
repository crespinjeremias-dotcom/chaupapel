-- Mismo problema que productos/categorias (ver 20260711080000): la seccion 2
-- es explicita en que "Admin: Carga y edita productos, categorias,
-- proveedores". La vinculacion producto-proveedor tambien se gestiona desde
-- la pantalla de Proveedores (seccion 5), asi que sigue el mismo criterio.
drop policy proveedores_insert on proveedores;
create policy proveedores_insert on proveedores
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy proveedores_update on proveedores;
create policy proveedores_update on proveedores
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active())
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy producto_proveedor_insert on producto_proveedor;
create policy producto_proveedor_insert on producto_proveedor
  for insert
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy producto_proveedor_delete on producto_proveedor;
create policy producto_proveedor_delete on producto_proveedor
  for delete
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
