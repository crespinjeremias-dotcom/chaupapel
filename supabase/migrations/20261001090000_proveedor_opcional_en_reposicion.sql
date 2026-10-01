-- Bug: reponer stock exigia un proveedor vinculado al producto -- si no
-- tenia ninguno, el frontend deshabilitaba "Registrar reposicion" y, aunque
-- se hubiera salteado eso, la base igual rechazaba el insert por el NOT NULL
-- de abajo. El proveedor es un dato opcional para este flujo: la reposicion
-- tiene que poder cargarse igual sin uno. aplicar_reposicion_stock() (el
-- trigger que suma stock y actualiza el precio de costo) no lee
-- proveedor_id, asi que no hace falta tocar nada mas.
alter table reposiciones_stock alter column proveedor_id drop not null;
