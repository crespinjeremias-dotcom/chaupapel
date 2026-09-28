-- Bug: destildar "fiado" en configuracion-local.html (fiado_habilitado = false)
-- solo ocultaba el link a clientes.html en el menu (menu.js) -- la pantalla de
-- venta (ventas.html) seguia mostrando la pestana "Fiado" sin condicion, y
-- registrar_venta (security definer, bypasea RLS) nunca chequeaba
-- locales.fiado_habilitado, asi que una venta a fiado se registraba igual
-- aunque el local la tuviera desactivada. Fix en dos capas: ventas.html oculta
-- la pestana cuando fiado_habilitado es false (misma tecnica que ya usa
-- menu.js), y esta migracion agrega la validacion real del lado del backend.
-- Misma funcion que 20260923090000, con el chequeo agregado.
create or replace function public.registrar_venta(
  p_turno_id uuid,
  p_local_id uuid,
  p_organization_id uuid,
  p_items jsonb,      -- [{ productoId, cantidad, precioUnitario }]
  p_es_fiado boolean,
  p_cliente_id uuid,
  p_pagos jsonb        -- [{ metodo, monto }], ignorado si p_es_fiado
)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario_id uuid := auth.uid();
  v_total numeric;
  v_venta ventas%rowtype;
  v_item jsonb;
  v_pago jsonb;
begin
  -- security definer bypasea RLS -- hay que reimplementar a mano las mismas
  -- condiciones que exigia la policy ventas_insert.
  if not (
    is_approved() and org_is_active() and p_organization_id = current_org_id()
    and (is_admin() or p_local_id = current_local_id())
    and local_is_active(p_local_id)
  ) then
    raise exception 'No autorizado';
  end if;

  if p_es_fiado and not exists (
    select 1 from locales where id = p_local_id and fiado_habilitado
  ) then
    raise exception 'Este local no tiene habilitada la venta a fiado';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta necesita al menos un item';
  end if;

  select coalesce(sum((it->>'cantidad')::numeric * (it->>'precioUnitario')::numeric), 0)
    into v_total
    from jsonb_array_elements(p_items) it;

  insert into ventas (local_id, organization_id, turno_id, usuario_id, cliente_id, es_fiado, total)
  values (
    p_local_id,
    p_organization_id,
    p_turno_id,
    v_usuario_id,
    case when p_es_fiado then p_cliente_id else null end,
    p_es_fiado,
    v_total
  )
  returning * into v_venta;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into venta_items (venta_id, producto_id, local_id, organization_id, cantidad, precio_unitario)
    values (
      v_venta.id,
      (v_item->>'productoId')::uuid,
      p_local_id,
      p_organization_id,
      (v_item->>'cantidad')::numeric,
      (v_item->>'precioUnitario')::numeric
    );
  end loop;

  if p_es_fiado then
    insert into cuenta_corriente_movimientos (cliente_id, local_id, organization_id, tipo, monto, venta_id, usuario_id)
    values (p_cliente_id, p_local_id, p_organization_id, 'fiado_nuevo', v_total, v_venta.id, v_usuario_id);
  else
    for v_pago in select * from jsonb_array_elements(p_pagos)
    loop
      insert into venta_pagos (venta_id, local_id, organization_id, metodo, monto)
      values (
        v_venta.id,
        p_local_id,
        p_organization_id,
        (v_pago->>'metodo')::metodo_pago_type,
        (v_pago->>'monto')::numeric
      );
    end loop;
  end if;

  return v_venta;
end;
$$;
