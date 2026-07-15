-- Ofertas/descuentos puntuales por item de venta: precio_lista guarda el
-- precio de catalogo al momento de la venta (referencia), precio_unitario
-- sigue siendo el precio final realmente cobrado (sin cambios en su
-- significado -- "cada venta registra el precio al que se vendio"). Ambas
-- columnas quedan null en el caso normal (sin oferta); solo se completan
-- cuando el vendedor activa la excepcion explicitamente.
alter table venta_items add column precio_lista numeric;
alter table venta_items add column motivo_descuento text;

alter table venta_items add constraint venta_items_motivo_si_hay_oferta
  check (precio_lista is null or motivo_descuento is not null);
