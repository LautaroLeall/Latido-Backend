-- ==============================================================================
-- LATIDO - Migración 009: Alta de negocios por el Super Admin
-- ------------------------------------------------------------------------------
-- Modelo de acceso: NO hay registro público. Solo el Super Admin crea las cuentas
-- de los negocios (desde su panel → Edge Function `create-business-account`).
-- Los negocios solo inician sesión en /login.
--
-- Esta función arma todo lo del lado de la base en UNA transacción:
-- negocio + sucursal + primer soporte (QR) + vínculo con la cuenta del dueño.
-- Solo puede ejecutarla `service_role` (la Edge Function); ningún usuario de la
-- API (anon / authenticated) puede llamarla directamente.
-- Es idempotente.
-- ==============================================================================

-- Eliminar firma anterior si existía (idempotencia)
DROP FUNCTION IF EXISTS public.admin_provision_business(uuid, text, text, text, uuid);

CREATE OR REPLACE FUNCTION public.admin_provision_business(
  p_owner_id          UUID,
  p_business_name     TEXT,
  p_branch_name       TEXT DEFAULT 'Casa central',
  p_manager_name      TEXT DEFAULT NULL,
  p_plan_id           UUID DEFAULT NULL,
  p_supports_override INT  DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_profile           RECORD;
  v_plan              RECORD;
  v_name              TEXT;
  v_branch_name       TEXT;
  v_manager           TEXT;
  v_supports_override INT;
  v_business_id       UUID;
  v_branch_id         UUID;
  v_token             TEXT;
BEGIN
  -- La cuenta del dueño debe existir, ser de tipo admin y no tener negocio todavía
  SELECT * INTO v_profile FROM public.profiles WHERE id = p_owner_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La cuenta del dueño no existe' USING ERRCODE = 'P0002';
  END IF;
  IF v_profile.role <> 'admin' THEN
    RAISE EXCEPTION 'La cuenta del dueño debe ser de tipo administrador de negocio' USING ERRCODE = '42501';
  END IF;
  IF v_profile.business_id IS NOT NULL THEN
    RAISE EXCEPTION 'Esa cuenta ya tiene un negocio asociado' USING ERRCODE = '23505';
  END IF;

  v_name := left(btrim(coalesce(p_business_name, '')), 80);
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'El nombre del negocio es demasiado corto' USING ERRCODE = '22023';
  END IF;

  v_branch_name := coalesce(nullif(left(btrim(coalesce(p_branch_name, '')), 60), ''), 'Casa central');
  v_manager     := coalesce(
    nullif(left(btrim(coalesce(p_manager_name, '')), 60), ''),
    nullif(btrim(split_part(coalesce(v_profile.full_name, ''), ' ', 1)), '')
  );

  -- Plan elegido (o el Plan Base si no se indica)
  SELECT * INTO v_plan
  FROM public.plans
  WHERE id = coalesce(p_plan_id, (SELECT id FROM public.plans WHERE code = 'base'));

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El plan elegido no existe' USING ERRCODE = 'P0002';
  END IF;

  IF v_plan.is_custom THEN
    v_supports_override := coalesce(p_supports_override, 1);
    IF v_supports_override < 1 OR v_supports_override > 1000 THEN
      RAISE EXCEPTION 'Los soportes deben ser un número entero entre 1 y 1000' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_supports_override := NULL;
  END IF;

  INSERT INTO public.businesses (owner_id, name, manager_name, plan_id, supports_override)
  VALUES (p_owner_id, v_name, v_manager, v_plan.id, v_supports_override)
  RETURNING id INTO v_business_id;

  INSERT INTO public.branches (business_id, name)
  VALUES (v_business_id, v_branch_name)
  RETURNING id INTO v_branch_id;

  v_token := public.generate_qr_token(v_name || ' ' || v_branch_name);

  INSERT INTO public.qr_codes (business_id, branch_id, token)
  VALUES (v_business_id, v_branch_id, v_token);

  UPDATE public.profiles SET business_id = v_business_id WHERE id = p_owner_id;

  RETURN jsonb_build_object(
    'business_id', v_business_id,
    'branch_id',   v_branch_id,
    'token',       v_token
  );
END;
$$;

-- Solo la Edge Function (service_role) puede ejecutarla
REVOKE EXECUTE ON FUNCTION public.admin_provision_business(uuid, text, text, text, uuid, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_provision_business(uuid, text, text, text, uuid, int) TO service_role;

-- Cerrar el auto-alta de negocios: ya no existe /registro ni /onboarding público
REVOKE EXECUTE ON FUNCTION public.create_my_business(text, text, text) FROM PUBLIC, anon, authenticated;
