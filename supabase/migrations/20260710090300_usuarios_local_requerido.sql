-- Salvaguarda: un empleado aprobado sin local_id quedaria "fantasma" (con
-- status=approved pero sin acceso a ninguna fila, porque la policy generica
-- compara local_id = current_local_id() y null = null no es true en SQL).
-- La invitacion (seccion 3) no obliga a elegir local en el momento de
-- invitar -- si la organizacion tiene un solo local se asigna solo
-- (redimir_invitacion); si tiene varios, el admin debe elegirlo al aprobar,
-- antes de poder pasar a approved.
alter table usuarios
  add constraint usuarios_empleado_approved_requiere_local
  check (role = 'admin' or status <> 'approved' or local_id is not null);
