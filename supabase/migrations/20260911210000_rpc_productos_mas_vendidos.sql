-- Hallazgo #2 de la revision de Tarea 2 (seccion 15): "estadisticas" (Plan
-- Completo, productos mas vendidos por franja horaria) solo ocultaba el
-- boton en reportes.html -- nada impedia reconstruir el mismo agregado
-- consultando venta_items/ventas directo, porque esas tablas tienen que
-- seguir siendo legibles para el resto de la operacion (editar ventas,
-- cuenta corriente, etc.), asi que no se pueden restringir por plan.
--
-- En vez de tocar las tablas base, se envuelve el agregado en esta funcion
-- RPC: valida is_admin() + is_approved() + org_is_active() y el plan contra
-- 'estadisticas' antes de calcular nada. Limite aceptado (no es tan
-- air-tight como el bloqueo de locales): alguien podria reconstruir el
-- mismo agregado a mano con las filas sueltas de venta_items/ventas que ya
-- puede leer legitimamente -- sube bastante el esfuerzo, no lo hace
-- imposible, y no hay forma de cerrarlo del todo sin restringir lecturas
-- que otras partes del sistema si necesitan.
--
-- Reemplaza el query + agrupado que hacia productosMasVendidos() en
-- public/js/ventas.js -- mismo comportamiento (agregado de toda la
-- organizacion, no por local, igual que hoy) y misma firma de filtros.
create or replace function public.obtener_productos_mas_vendidos(
  p_desde timestamptz,
  p_hasta timestamptz,
  p_hora_desde int default null,
  p_hora_hasta int default null
)
returns table (producto_id uuid, nombre text, cantidad numeric)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_plan plan_type;
  v_plan_overrides jsonb;
begin
  if not (is_admin() and is_approved() and org_is_active()) then
    raise exception 'No autorizado';
  end if;

  select o.plan, o.plan_overrides into v_plan, v_plan_overrides
    from organizations o
    where o.id = current_org_id();

  if not coalesce((v_plan_overrides->>'estadisticas')::boolean, v_plan = 'completo') then
    raise exception 'Tu plan no incluye estadisticas';
  end if;

  -- La franja horaria se compara en hora de Argentina (mismo criterio que
  -- el codigo que reemplaza, que usaba new Date(...).getHours() del
  -- navegador) -- v.fecha es timestamptz, sin esto extract(hour ...)
  -- devolveria la hora en UTC, la sesion de Postgres por defecto.
  return query
    select vi.producto_id, coalesce(p.nombre, 'Producto eliminado') as nombre, sum(vi.cantidad) as cantidad
      from venta_items vi
      join ventas v on v.id = vi.venta_id
      left join productos p on p.id = vi.producto_id
      where v.organization_id = current_org_id()
        and v.fecha >= p_desde
        and v.fecha < p_hasta
        and v.estado <> 'anulada'
        and (p_hora_desde is null or extract(hour from v.fecha at time zone 'America/Argentina/Buenos_Aires') >= p_hora_desde)
        and (p_hora_hasta is null or extract(hour from v.fecha at time zone 'America/Argentina/Buenos_Aires') < p_hora_hasta)
      group by vi.producto_id, p.nombre
      order by sum(vi.cantidad) desc;
end;
$$;
