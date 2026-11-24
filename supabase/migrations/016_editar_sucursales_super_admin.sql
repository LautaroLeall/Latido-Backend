-- ==============================================================================
-- LATIDO - Migración 016: Edición del nombre de sucursales (Admin y Super Admin)
-- ------------------------------------------------------------------------------
-- Permite que tanto el administrador del propio negocio como el Super Admin
-- puedan modificar el nombre de una sucursal desde su panel:
--   1. Amplía la política `branches_update` en `public.branches` para incluir
--      `is_super_admin()` además de `is_business_admin()` del propio negocio.
--   2. Valida longitud real del nombre (`2..60` caracteres) y protege
--      `business_id` y `created_at` mediante trigger `tg_branches_protect`.
-- Es idempotente.
-- ==============================================================================

-- 1. Validación de nombre en `branches`
ALTER TABLE public.branches DROP CONSTRAINT IF EXISTS chk_branch_name;
ALTER TABLE public.branches ADD CONSTRAINT chk_branch_name
  CHECK (char_length(btrim(name)) BETWEEN 2 AND 60);

-- 2. Trigger de integridad: al editar una sucursal solo puede cambiar `name`
CREATE OR REPLACE FUNCTION public.tg_branches_protect()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
    RAISE EXCEPTION 'No se puede mover una sucursal a otro negocio' USING ERRCODE = '42501';
  END IF;

  NEW.created_at := OLD.created_at;
  NEW.name       := btrim(coalesce(NEW.name, ''));

  IF char_length(NEW.name) < 2 OR char_length(NEW.name) > 60 THEN
    RAISE EXCEPTION 'El nombre de la sucursal debe tener entre 2 y 60 caracteres' USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_branches_protect ON public.branches;
CREATE TRIGGER trg_branches_protect
  BEFORE UPDATE ON public.branches
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_branches_protect();

REVOKE EXECUTE ON FUNCTION public.tg_branches_protect() FROM PUBLIC, anon, authenticated;

-- 3. Política RLS `branches_update`: Admin del propio negocio o Super Admin
DROP POLICY IF EXISTS branches_update ON public.branches;
CREATE POLICY branches_update ON public.branches
  FOR UPDATE TO authenticated
  USING (
    (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
    OR (SELECT public.is_super_admin())
  )
  WITH CHECK (
    (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
    OR (SELECT public.is_super_admin())
  );
