-- Punto abierto de la Fase 1 (ver docs/modelo-datos.md): al anular una venta
-- fiada hay que revertir la deuda que se habia generado en cuenta_corriente_
-- movimientos. Ningun valor existente del enum representa bien "se anulo la
-- venta que origino este fiado" sin confundir reportes de cobros reales
-- (reusar 'cobro_fiado' mezclaria plata efectivamente cobrada con
-- anulaciones). Va en su propia migracion porque ALTER TYPE ... ADD VALUE no
-- puede usarse en la misma transaccion en la que se agrega.
alter type tipo_movimiento_cc_type add value 'fiado_anulado';
