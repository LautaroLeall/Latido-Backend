-- ==============================================================================
-- LATIDO - Migración 015: Gestión operativa de kits físicos (QR + NFC) por Super Admin
-- ------------------------------------------------------------------------------
-- Permite al Super Admin gestionar el ciclo completo de armado y entrega de
-- soportes físicos llave en mano (logo + QR + chip NTAG213):
--   1. Suma `delivered_at` y `kit_notes` a `public.qr_codes` (100% aditivo).
--   2. `super_list_kits()`: cola global de todos los soportes de la plataforma
--      priorizando los pendientes de grabar NFC / entregar, con métricas
--      agregadas de uso (0 PII de clientes finales).
--   3. `super_update_kit(...)`: actualiza estado NFC (`pending` | `programmed` |
--      `inactive`), marca entrega física (`delivered_at`), activa/desactiva
--      respetando el límite del plan y guarda notas internas del soporte.
--   4. `super_create_kit(...)`: permite al Super Admin emitir un soporte extra
--      (en sucursal existente o nueva) para preparar el kit antes de entregarlo.
-- Es idempotente.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Columnas de seguimiento de entrega y notas del kit en `qr_codes`
-- ------------------------------------------------------------------------------
ALTER TABLE public.qr_codes
  ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS kit_notes    TEXT;

ALTER TABLE public.qr_codes DROP CONSTRAINT IF EXISTS chk_qr_kit_notes;
ALTER TABLE public.qr_codes ADD CONSTRAINT chk_qr_kit_notes
  CHECK (kit_notes IS NULL OR char_length(kit_notes) <= 300);

CREATE INDEX IF NOT EXISTS idx_qr_codes_kit_status
  ON public.qr_codes (active, nfc_status, delivered_at);

-- ------------------------------------------------------------------------------
-- 2. Cola global de kits QR + NFC para Super Admin (0 PII de clientes finales)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.super_list_kits();

CREATE OR REPLACE FUNCTION public.super_list_kits()
RETURNS TABLE (
  qr_id              UUID,
  token              TEXT,
  active             BOOLEAN,
  nfc_status         TEXT,
  delivered_at       TIMESTAMPTZ,
  kit_notes          TEXT,
  created_at         TIMESTAMPTZ,
  branch_id          UUID,
  branch_name        TEXT,
  business_id        UUID,
  business_name      TEXT,
  business_logo_url  TEXT,
  business_active    BOOLEAN,
  review_destination TEXT,
  owner_name         TEXT,
  owner_email        TEXT,
  plan_name          TEXT,
  supports_limit     INT,
  responses_total    BIGINT,
  responses_30d      BIGINT,
  last_response_at   TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo el Super Admin puede consultar la cola de kits' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    q.id,
    q.token,
    q.active,
    q.nfc_status,
    q.delivered_at,
    q.kit_notes,
    q.created_at,
    br.id,
    br.name,
    b.id,
    b.name,
    b.logo_url,
    b.active,
    b.review_destination,
    pr.full_name,
    u.email::text,
    p.name,
    public.business_supports(b.id),
    (SELECT count(*) FROM public.responses r WHERE r.qr_code_id = q.id),
    (SELECT count(*) FROM public.responses r WHERE r.qr_code_id = q.id AND r.created_at >= now() - interval '30 days'),
    (SELECT max(r.created_at) FROM public.responses r WHERE r.qr_code_id = q.id)
  FROM public.qr_codes q
  JOIN public.branches br  ON br.id = q.branch_id
  JOIN public.businesses b ON b.id  = q.business_id
  JOIN public.plans p      ON p.id  = b.plan_id
  LEFT JOIN public.profiles pr ON pr.id = b.owner_id
  LEFT JOIN auth.users u       ON u.id  = b.owner_id
  ORDER BY
    CASE
      WHEN NOT q.active OR NOT b.active THEN 4
      WHEN q.delivered_at IS NULL AND q.nfc_status = 'pending' THEN 1
      WHEN q.delivered_at IS NULL THEN 2
      ELSE 3
    END ASC,
    q.created_at DESC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.super_list_kits() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.super_list_kits() TO authenticated;

-- ------------------------------------------------------------------------------
-- 3. Actualizar estado NFC, entrega física, activación y notas de un kit
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.super_update_kit(uuid, text, boolean, boolean, text, boolean);

CREATE OR REPLACE FUNCTION public.super_update_kit(
  p_qr_id       UUID,
  p_nfc_status  TEXT    DEFAULT NULL,
  p_delivered   BOOLEAN DEFAULT NULL,
  p_active      BOOLEAN DEFAULT NULL,
  p_kit_notes   TEXT    DEFAULT NULL,
  p_clear_notes BOOLEAN DEFAULT FALSE
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_qr           RECORD;
  v_next_nfc     TEXT;
  v_next_deliv   TIMESTAMPTZ;
  v_next_active  BOOLEAN;
  v_next_notes   TEXT;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo el Super Admin puede gestionar el estado de los kits' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_qr FROM public.qr_codes WHERE id = p_qr_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Soporte QR/NFC no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF p_nfc_status IS NOT NULL AND p_nfc_status NOT IN ('pending', 'programmed', 'inactive') THEN
    RAISE EXCEPTION 'Estado NFC inválido' USING ERRCODE = '22023';
  END IF;

  v_next_active := coalesce(p_active, v_qr.active);
  IF v_next_active AND NOT v_qr.active THEN
    IF (SELECT count(*) FROM public.qr_codes WHERE business_id = v_qr.business_id AND active)
       >= public.business_supports(v_qr.business_id) THEN
      RAISE EXCEPTION 'Este negocio ya usa todos los soportes activos de su plan. Subí su plan o desactivá otro soporte primero.'
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_next_nfc := coalesce(p_nfc_status, v_qr.nfc_status);

  IF p_delivered IS TRUE THEN
    v_next_deliv := coalesce(v_qr.delivered_at, now());
    IF p_nfc_status IS NULL AND v_next_nfc = 'pending' THEN
      v_next_nfc := 'programmed';
    END IF;
  ELSIF p_delivered IS FALSE THEN
    v_next_deliv := NULL;
  ELSE
    v_next_deliv := v_qr.delivered_at;
  END IF;

  IF coalesce(p_clear_notes, FALSE) THEN
    v_next_notes := NULL;
  ELSIF p_kit_notes IS NOT NULL THEN
    v_next_notes := nullif(left(btrim(p_kit_notes), 300), '');
  ELSE
    v_next_notes := v_qr.kit_notes;
  END IF;

  UPDATE public.qr_codes
  SET
    active       = v_next_active,
    nfc_status   = v_next_nfc,
    delivered_at = v_next_deliv,
    kit_notes    = v_next_notes
  WHERE id = p_qr_id;

  RETURN jsonb_build_object(
    'qr_id',        p_qr_id,
    'active',       v_next_active,
    'nfc_status',   v_next_nfc,
    'delivered_at', v_next_deliv,
    'kit_notes',    v_next_notes
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.super_update_kit(uuid, text, boolean, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.super_update_kit(uuid, text, boolean, boolean, text, boolean) TO authenticated;

-- ------------------------------------------------------------------------------
-- 4. Crear un nuevo soporte QR + NFC para un negocio existente (sucursal nueva o existente)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.super_create_kit(uuid, uuid, text, text);

CREATE OR REPLACE FUNCTION public.super_create_kit(
  p_business_id UUID,
  p_branch_id   UUID DEFAULT NULL,
  p_branch_name TEXT DEFAULT NULL,
  p_kit_notes   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_biz         RECORD;
  v_branch_id   UUID;
  v_branch_name TEXT;
  v_token       TEXT;
  v_qr_id       UUID;
  v_notes       TEXT;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo el Super Admin puede crear kits para un negocio' USING ERRCODE = '42501';
  END IF;

  SELECT id, name INTO v_biz FROM public.businesses WHERE id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Negocio no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF (SELECT count(*) FROM public.qr_codes WHERE business_id = p_business_id AND active)
     >= public.business_supports(p_business_id) THEN
    RAISE EXCEPTION 'Este negocio alcanzó el límite de soportes de su plan. Subí su plan o sus soportes primero.'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    SELECT id, name INTO v_branch_id, v_branch_name
    FROM public.branches
    WHERE id = p_branch_id AND business_id = p_business_id;
    IF v_branch_id IS NULL THEN
      RAISE EXCEPTION 'Sucursal no encontrada para este negocio' USING ERRCODE = 'P0002';
    END IF;
  ELSE
    v_branch_name := left(btrim(coalesce(p_branch_name, '')), 60);
    IF char_length(v_branch_name) < 2 THEN
      RAISE EXCEPTION 'Indicá una sucursal existente o un nombre de sucursal válido (mínimo 2 caracteres)' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM public.branches WHERE business_id = p_business_id) >= 50 THEN
      RAISE EXCEPTION 'Este negocio alcanzó el máximo de sucursales permitidas' USING ERRCODE = 'P0001';
    END IF;
    INSERT INTO public.branches (business_id, name)
    VALUES (p_business_id, v_branch_name)
    RETURNING id INTO v_branch_id;
  END IF;

  v_notes := nullif(left(btrim(coalesce(p_kit_notes, '')), 300), '');
  v_token := public.generate_qr_token(v_biz.name || ' ' || v_branch_name);

  INSERT INTO public.qr_codes (business_id, branch_id, token, nfc_status, kit_notes)
  VALUES (p_business_id, v_branch_id, v_token, 'pending', v_notes)
  RETURNING id INTO v_qr_id;

  RETURN jsonb_build_object(
    'qr_id',       v_qr_id,
    'branch_id',   v_branch_id,
    'branch_name', v_branch_name,
    'token',       v_token
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.super_create_kit(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.super_create_kit(uuid, uuid, text, text) TO authenticated;
