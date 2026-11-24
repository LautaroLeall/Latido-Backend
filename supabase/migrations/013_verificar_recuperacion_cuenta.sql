-- ==============================================================================
-- LATIDO - Migración 013: Verificación segura de cuenta en recuperación (/recuperar)
-- ------------------------------------------------------------------------------
-- Garantiza que antes de enviar un email de recuperación de contraseña exista
-- realmente:
--   1. Un Super Admin registrado con ese email, o
--   2. Un usuario vinculado a un negocio creado y activo en Latido.
--
-- Privacidad y seguridad:
--   - Devuelve únicamente { eligible: boolean, reason: 'ok' | 'not_found' | 'suspended' }.
--   - Nunca expone nombres, roles, IDs, negocios ni otros datos personales.
--   - Incluye registro efímero con hash MD5 (sin guardar emails en texto plano)
--     para limitar intentos abusivos por email y ráfagas globales.
--   - Tabla auxiliar con RLS activado y sin permisos para anon/authenticated.
-- Es idempotente.
-- ==============================================================================

CREATE TABLE IF NOT EXISTS public.recovery_check_log (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_hash text NOT NULL,
  checked_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_recovery_check_log_hash_time
  ON public.recovery_check_log (email_hash, checked_at DESC);

CREATE INDEX IF NOT EXISTS idx_recovery_check_log_time
  ON public.recovery_check_log (checked_at DESC);

ALTER TABLE public.recovery_check_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.recovery_check_log FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.check_recovery_account(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_email       text := lower(btrim(coalesce(p_email, '')));
  v_hash        text;
  v_email_hits  integer;
  v_global_hits integer;
  v_rec         record;
BEGIN
  -- Validación básica de formato
  IF v_email = '' OR length(v_email) > 254 OR position('@' IN v_email) <= 1 THEN
    RETURN jsonb_build_object('eligible', false, 'reason', 'not_found');
  END IF;

  -- Limpieza oportunista del historial efímero (> 15 minutos)
  DELETE FROM public.recovery_check_log
  WHERE checked_at < now() - interval '15 minutes';

  v_hash := md5(v_email);

  -- Anti-abuso por email (máx. 8 consultas en 15 min) y ráfaga global (máx. 120 en 5 min)
  SELECT count(*) INTO v_email_hits
  FROM public.recovery_check_log
  WHERE email_hash = v_hash
    AND checked_at >= now() - interval '15 minutes';

  IF v_email_hits >= 8 THEN
    RAISE EXCEPTION 'Demasiados intentos para este email. Esperá unos minutos y probá de nuevo.';
  END IF;

  SELECT count(*) INTO v_global_hits
  FROM public.recovery_check_log
  WHERE checked_at >= now() - interval '5 minutes';

  IF v_global_hits >= 120 THEN
    RAISE EXCEPTION 'Demasiadas consultas en este momento. Esperá unos minutos y probá de nuevo.';
  END IF;

  INSERT INTO public.recovery_check_log (email_hash) VALUES (v_hash);

  -- Buscar usuario real en auth.users + perfil + negocio vinculado
  SELECT p.role, b.id AS business_id, b.active AS business_active
  INTO v_rec
  FROM auth.users u
  JOIN public.profiles p ON p.id = u.id
  LEFT JOIN public.businesses b ON b.id = p.business_id
  WHERE lower(u.email) = v_email
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('eligible', false, 'reason', 'not_found');
  END IF;

  -- Super Admin siempre habilitado para recuperar su acceso
  IF v_rec.role = 'super_admin' THEN
    RETURN jsonb_build_object('eligible', true, 'reason', 'ok');
  END IF;

  -- Cuentas sin negocio creado no pueden recuperar acceso al panel
  IF v_rec.business_id IS NULL THEN
    RETURN jsonb_build_object('eligible', false, 'reason', 'not_found');
  END IF;

  -- Negocio suspendido: no enviar enlace, informar estado para que contacte soporte
  IF v_rec.business_active IS NOT TRUE THEN
    RETURN jsonb_build_object('eligible', false, 'reason', 'suspended');
  END IF;

  RETURN jsonb_build_object('eligible', true, 'reason', 'ok');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.check_recovery_account(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.check_recovery_account(text) TO anon, authenticated;
