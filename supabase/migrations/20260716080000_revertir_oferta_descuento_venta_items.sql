-- Revierte la funcionalidad de oferta/descuento por item de venta: no se uso
-- en la practica y se decidio sacarla del todo en vez de arreglarla. El
-- precio de venta vuelve a ser 100% automatico (precio_venta_actual del
-- producto), sin excepcion editable. Las filas de prueba que usaban estas
-- columnas ya se borraron a mano antes de esta migracion.
alter table venta_items drop constraint venta_items_motivo_si_hay_oferta;
alter table venta_items drop column precio_lista;
alter table venta_items drop column motivo_descuento;
