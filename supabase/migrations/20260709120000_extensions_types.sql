-- Extensiones necesarias
create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "pg_trgm";    -- busqueda por nombre (autocompletado productos/clientes)

-- Tipos enumerados usados en todo el esquema
create type plan_type as enum ('basico', 'medio', 'completo');
create type modo_turno_type as enum ('individual', 'compartida');
create type user_role_type as enum ('admin', 'empleado');
create type user_status_type as enum ('pending', 'approved', 'rejected');
create type motivo_ajuste_type as enum ('rotura', 'vencido', 'robo', 'error_conteo', 'otro');
create type estado_turno_type as enum ('abierto', 'cerrado');
create type estado_venta_type as enum ('activa', 'editada', 'anulada');
create type metodo_pago_type as enum ('efectivo', 'transferencia');
create type tipo_movimiento_cc_type as enum ('fiado_nuevo', 'cobro_fiado', 'saldo_favor_generado', 'saldo_favor_usado');
create type tipo_devolucion_type as enum ('devolucion', 'cambio');
create type resolucion_cambio_type as enum ('resuelto_ahora', 'saldo_pendiente');
create type estado_reclamo_type as enum ('pendiente', 'repuesto');
