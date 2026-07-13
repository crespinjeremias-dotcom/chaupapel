-- Borrado logico de productos y proveedores, distinto de "activo": activo es
-- reversible y pensado para uso administrativo (ej. "pausar" un producto de
-- temporada); eliminado es terminal desde la UI y saca a la fila de
-- CUALQUIER listado operativo, pero la fila sigue existiendo en la base para
-- que ventas/reposiciones/ajustes/vinculos ya cargados sigan resolviendo el
-- nombre via join normal, sin necesidad de "snapshotear" el dato en otro lado.
alter table productos add column deleted_at timestamptz;
alter table proveedores add column deleted_at timestamptz;

-- El indice unico de codigo de barras pasa a ignorar productos eliminados,
-- para poder reutilizar el codigo en un producto nuevo si el original se
-- elimino (si no, el codigo quedaria "reservado" para siempre).
drop index if exists idx_productos_codigo_barras;
create unique index idx_productos_codigo_barras
  on productos(local_id, codigo_barras)
  where codigo_barras is not null and deleted_at is null;

-- USING controla la fila VIEJA (bloquea updates -- incluido activo o
-- cualquier edicion -- sobre algo ya eliminado); WITH CHECK controla la fila
-- NUEVA y a proposito no repite la condicion, porque el propio update que
-- marca deleted_at por primera vez tiene que poder pasar. No cambia nada del
-- aislamiento multi-tenant (organization_id/local_id intactos).
drop policy productos_update on productos;
create policy productos_update on productos
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active() and deleted_at is null)
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());

drop policy proveedores_update on proveedores;
create policy proveedores_update on proveedores
  for update
  using (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active() and deleted_at is null)
  with check (organization_id = current_org_id() and is_admin() and is_approved() and org_is_active());
