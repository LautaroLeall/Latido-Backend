-- ==============================================================================
-- LATIDO - Migración 007: Planes por soportes, retención de datos y privacidad
-- ------------------------------------------------------------------------------
--   1. Planes editables por el Super Admin (todos incluyen lo mismo; cambia la
--      cantidad de SOPORTES = kits físicos QR + NFC).
--   2. Un soporte puede usarse en cualquier sucursal, siempre del mismo negocio.
--   3. Bug de privacidad: al borrar los datos del cliente, el mensaje enviado
--      (que contiene su nombre) se borra también.
--   4. Retención: contactos resueltos se purgan a los 12 meses (job diario).
-- Es idempotente.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Tabla de planes
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.plans (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code          TEXT NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9_-]{2,30}$'),
    name          TEXT NOT NULL CHECK (char_length(name) BETWEEN 2 AND 40),
    supports      INT  CHECK (supports IS NULL OR supports BETWEEN 1 AND 1000),
    price_monthly NUMERIC CHECK (price_monthly IS NULL OR price_monthly >= 0),
    currency      TEXT NOT NULL DEFAULT 'ARS',
    is_custom     BOOLEAN NOT NULL DEFAULT false,   -- true = "hablar por WhatsApp"
    highlighted   BOOLEAN NOT NULL DEFAULT false,   -- tarjeta destacada en la landing
    sort_order    INT NOT NULL DEFAULT 0,
    active        BOOLEAN NOT NULL DEFAULT true,    -- visible en la landing
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_plan_complete CHECK (is_custom OR (supports IS NOT NULL AND price_monthly IS NOT NULL))
);

DROP TRIGGER IF EXISTS trg_plans_updated_at ON public.plans;
CREATE TRIGGER trg_plans_updated_at
  BEFORE UPDATE ON public.plans
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.plans (code, name, supports, price_monthly, is_custom, highlighted, sort_order)
VALUES
  ('base',    'Plan Base',          1,    50000,  false, false, 10),
  ('plus',    'Plan Plus',          3,    100000, false, true,  20),
  ('premium', 'Plan Premium',       5,    175000, false, false, 30),
  ('custom',  'Plan Personalizado', NULL, NULL,   true,  false, 40)
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS plans_select_public ON public.plans;
DROP POLICY IF EXISTS plans_select_auth   ON public.plans;
DROP POLICY IF EXISTS plans_super_write   ON public.plans;

-- La landing (anónimo) solo ve los planes activos
CREATE POLICY plans_select_public ON public.plans
  FOR SELECT TO anon
  USING (active);

-- Usuarios logueados: planes activos + el plan de su propio negocio (aunque esté oculto)
-- (se crea más abajo, después de agregar businesses.plan_id)

CREATE POLICY plans_super_write ON public.plans
  FOR ALL TO authenticated
  USING ((SELECT public.is_super_admin()))
  WITH CHECK ((SELECT public.is_super_admin()));

-- ------------------------------------------------------------------------------
-- 2. Negocios: plan_id + ajuste manual de soportes (para el plan personalizado)
-- ------------------------------------------------------------------------------
ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS plan_id UUID REFERENCES public.plans(id) ON DELETE RESTRICT;
ALTER TABLE public.businesses
  ADD COLUMN IF NOT EXISTS supports_override INT CHECK (supports_override IS NULL OR supports_override BETWEEN 1 AND 1000);

-- Migrar el campo viejo `plan` (free/pro/enterprise) → plan_id
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'businesses' AND column_name = 'plan') THEN
    UPDATE public.businesses b
    SET plan_id = (SELECT id FROM public.plans WHERE code = CASE b.plan
                                                          WHEN 'pro'        THEN 'plus'
                                                          WHEN 'enterprise' THEN 'premium'
                                                          ELSE 'base' END)
    WHERE b.plan_id IS NULL;
  END IF;
END;
$$;

UPDATE public.businesses
SET plan_id = (SELECT id FROM public.plans WHERE code = 'base')
WHERE plan_id IS NULL;

ALTER TABLE public.businesses ALTER COLUMN plan_id SET NOT NULL;

CREATE POLICY plans_select_auth ON public.plans
  FOR SELECT TO authenticated
  USING (
    active
    OR id = (SELECT b.plan_id FROM public.businesses b WHERE b.id = (SELECT public.my_business_id()))
    OR (SELECT public.is_super_admin())
  );

-- Los negocios nuevos arrancan en el Plan Base
CREATE OR REPLACE FUNCTION public.tg_businesses_default_plan()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.plan_id IS NULL THEN
    SELECT id INTO NEW.plan_id FROM public.plans WHERE code = 'base';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_default_plan ON public.businesses;
CREATE TRIGGER trg_businesses_default_plan
  BEFORE INSERT ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.tg_businesses_default_plan();

-- Quitar el campo viejo (la restricción CHECK asociada se elimina sola)
ALTER TABLE public.businesses DROP COLUMN IF EXISTS plan;

-- Protección: solo el Super Admin cambia plan, soportes, dueño o estado
CREATE OR REPLACE FUNCTION public.tg_businesses_protect()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') AND NOT public.is_super_admin() THEN
    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.owner_id IS DISTINCT FROM OLD.owner_id
       OR NEW.plan_id IS DISTINCT FROM OLD.plan_id
       OR NEW.supports_override IS DISTINCT FROM OLD.supports_override
       OR NEW.active IS DISTINCT FROM OLD.active THEN
      RAISE EXCEPTION 'No tenés permiso para cambiar el plan, el dueño o el estado del negocio'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Soportes disponibles de un negocio = ajuste manual, o los del plan
CREATE OR REPLACE FUNCTION public.business_supports(p_business UUID)
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(b.supports_override, p.supports, 0)
  FROM public.businesses b
  JOIN public.plans p ON p.id = b.plan_id
  WHERE b.id = p_business;
$$;

-- Uso actual de soportes del negocio del usuario (panel: "2 de 3 en uso")
CREATE OR REPLACE FUNCTION public.get_my_supports()
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'limit',      public.business_supports(b.id),
    'used',       (SELECT count(*) FROM public.qr_codes q WHERE q.business_id = b.id AND q.active),
    'plan_name',  p.name
  )
  FROM public.businesses b
  JOIN public.plans p ON p.id = b.plan_id
  WHERE b.id = public.my_business_id();
$$;

-- ------------------------------------------------------------------------------
-- 3. Sucursales y soportes
--    Un soporte (QR + NFC) se puede usar en cualquier sucursal del mismo negocio.
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_branch_with_qr(text);

CREATE OR REPLACE FUNCTION public.create_branch_with_qr(
  p_branch_name TEXT,
  p_with_qr     BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business_id UUID := public.my_business_id();
  v_biz_name    TEXT;
  v_name        TEXT;
  v_branch_id   UUID;
  v_token       TEXT;
BEGIN
  IF NOT public.is_business_admin() OR v_business_id IS NULL THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede crear sucursales' USING ERRCODE = '42501';
  END IF;

  v_name := left(btrim(coalesce(p_branch_name, '')), 60);
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'El nombre de la sucursal es demasiado corto' USING ERRCODE = '22023';
  END IF;

  IF (SELECT count(*) FROM public.branches WHERE business_id = v_business_id) >= 50 THEN
    RAISE EXCEPTION 'Alcanzaste el máximo de sucursales permitidas' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(p_with_qr, true)
     AND (SELECT count(*) FROM public.qr_codes WHERE business_id = v_business_id AND active)
         >= public.business_supports(v_business_id) THEN
    RAISE EXCEPTION 'Usaste todos los soportes de tu plan. Creá la sucursal sin soporte o pedí más soportes.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT name INTO v_biz_name FROM public.businesses WHERE id = v_business_id;

  INSERT INTO public.branches (business_id, name)
  VALUES (v_business_id, v_name)
  RETURNING id INTO v_branch_id;

  IF coalesce(p_with_qr, true) THEN
    v_token := public.generate_qr_token(v_biz_name || ' ' || v_name);
    INSERT INTO public.qr_codes (business_id, branch_id, token)
    VALUES (v_business_id, v_branch_id, v_token);
  END IF;

  RETURN jsonb_build_object('branch_id', v_branch_id, 'token', v_token);
END;
$$;

-- Asignar un soporte nuevo a una sucursal que todavía no tiene
CREATE OR REPLACE FUNCTION public.add_qr_to_branch(p_branch_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business_id UUID := public.my_business_id();
  v_label       TEXT;
  v_token       TEXT;
BEGIN
  IF NOT public.is_business_admin() OR v_business_id IS NULL THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede asignar soportes' USING ERRCODE = '42501';
  END IF;

  SELECT b.name || ' ' || br.name INTO v_label
  FROM public.branches br
  JOIN public.businesses b ON b.id = br.business_id
  WHERE br.id = p_branch_id AND br.business_id = v_business_id;

  IF v_label IS NULL THEN
    RAISE EXCEPTION 'Sucursal no encontrada' USING ERRCODE = 'P0002';
  END IF;

  IF (SELECT count(*) FROM public.qr_codes WHERE business_id = v_business_id AND active)
     >= public.business_supports(v_business_id) THEN
    RAISE EXCEPTION 'Usaste todos los soportes de tu plan. Pedí más soportes para sumar otro.'
      USING ERRCODE = 'P0001';
  END IF;

  v_token := public.generate_qr_token(v_label);
  INSERT INTO public.qr_codes (business_id, branch_id, token)
  VALUES (v_business_id, p_branch_id, v_token);

  RETURN jsonb_build_object('token', v_token);
END;
$$;

-- Mover un soporte a otra sucursal (misma URL, mismo chip NFC, sin regrabar nada)
CREATE OR REPLACE FUNCTION public.move_qr_to_branch(p_qr_id UUID, p_branch_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business_id UUID := public.my_business_id();
BEGIN
  IF NOT public.is_business_admin() OR v_business_id IS NULL THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede mover soportes' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.branches WHERE id = p_branch_id AND business_id = v_business_id) THEN
    RAISE EXCEPTION 'Sucursal no encontrada' USING ERRCODE = 'P0002';
  END IF;

  UPDATE public.qr_codes
  SET branch_id = p_branch_id
  WHERE id = p_qr_id AND business_id = v_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR no encontrado' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

-- Reactivar un QR también respeta el límite de soportes
CREATE OR REPLACE FUNCTION public.set_qr_active(p_qr_id UUID, p_active BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business_id UUID := public.my_business_id();
  v_was_active  BOOLEAN;
BEGIN
  IF NOT public.is_business_admin() THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede modificar QRs' USING ERRCODE = '42501';
  END IF;

  SELECT active INTO v_was_active
  FROM public.qr_codes WHERE id = p_qr_id AND business_id = v_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF coalesce(p_active, false) AND NOT v_was_active
     AND (SELECT count(*) FROM public.qr_codes WHERE business_id = v_business_id AND active)
         >= public.business_supports(v_business_id) THEN
    RAISE EXCEPTION 'Usaste todos los soportes de tu plan. Desactivá otro QR o pedí más soportes.'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.qr_codes SET active = coalesce(p_active, false) WHERE id = p_qr_id;
END;
$$;

-- ------------------------------------------------------------------------------
-- 4. Libro mayor del Super Admin (con plan y soportes)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_platform_overview();

CREATE OR REPLACE FUNCTION public.get_platform_overview()
RETURNS TABLE (
  business_id     UUID,
  name            TEXT,
  plan_id         UUID,
  plan_name       TEXT,
  plan_custom     BOOLEAN,
  supports_limit  INT,
  active          BOOLEAN,
  created_at      TIMESTAMPTZ,
  responses_total BIGINT,
  responses_30d   BIGINT,
  avg_stars       NUMERIC,
  rescued         BIGINT,
  open_cases      BIGINT,
  qr_active       BIGINT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    b.id,
    b.name,
    b.plan_id,
    p.name,
    p.is_custom,
    public.business_supports(b.id),
    b.active,
    b.created_at,
    (SELECT count(*) FROM public.responses r WHERE r.business_id = b.id),
    (SELECT count(*) FROM public.responses r WHERE r.business_id = b.id AND r.created_at >= now() - interval '30 days'),
    (SELECT round(avg(r.stars)::numeric, 1) FROM public.responses r WHERE r.business_id = b.id),
    (SELECT count(*) FROM public.rescue_cases rc WHERE rc.business_id = b.id AND rc.outcome = 'recovered'),
    (SELECT count(*) FROM public.rescue_cases rc WHERE rc.business_id = b.id AND rc.status IN ('open', 'contacted')),
    (SELECT count(*) FROM public.qr_codes q WHERE q.business_id = b.id AND q.active)
  FROM public.businesses b
  JOIN public.plans p ON p.id = b.plan_id
  WHERE public.is_super_admin()
  ORDER BY b.created_at DESC;
$$;

-- ------------------------------------------------------------------------------
-- 5. PRIVACIDAD — al borrar los datos del cliente se borra también el mensaje enviado
--    (contiene el nombre). Se ejecuta ANTES del guard (orden alfabético de triggers).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_rescue_cases_erase_message()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.contact_id IS NOT NULL AND NEW.contact_id IS NULL THEN
    NEW.message_sent := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rescue_cases_erase_message ON public.rescue_cases;
CREATE TRIGGER trg_rescue_cases_erase_message
  BEFORE UPDATE ON public.rescue_cases
  FOR EACH ROW EXECUTE FUNCTION public.tg_rescue_cases_erase_message();

-- El guard no debe borrar quién descartó un caso cuando solo cambia el contacto
CREATE OR REPLACE FUNCTION public.tg_rescue_cases_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.id                  := OLD.id;
  NEW.business_id         := OLD.business_id;
  NEW.response_id         := OLD.response_id;
  NEW.stars_snapshot      := OLD.stars_snapshot;
  NEW.created_at          := OLD.created_at;
  NEW.sla_due_at          := OLD.sla_due_at;
  NEW.avg_ticket_snapshot := OLD.avg_ticket_snapshot;
  NEW.overdue_notified_at := coalesce(OLD.overdue_notified_at, NEW.overdue_notified_at);
  IF NEW.contact_id IS DISTINCT FROM OLD.contact_id AND NEW.contact_id IS NOT NULL THEN
    NEW.contact_id := OLD.contact_id;
  END IF;

  IF OLD.status IN ('resolved', 'dismissed') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Este caso ya está cerrado' USING ERRCODE = 'P0001';
  END IF;

  IF OLD.first_contacted_at IS NOT NULL THEN
    NEW.first_contacted_at := OLD.first_contacted_at;
  ELSIF NEW.status IN ('contacted', 'resolved') AND OLD.status = 'open' THEN
    NEW.first_contacted_at := now();
  ELSE
    NEW.first_contacted_at := NULL;
  END IF;

  IF NEW.status = 'resolved' THEN
    IF NEW.outcome IS NULL THEN
      RAISE EXCEPTION 'Indicá el resultado del rescate' USING ERRCODE = '22023';
    END IF;
    NEW.resolved_at     := coalesce(OLD.resolved_at, now());
    NEW.resolved_by     := coalesce(OLD.resolved_by, auth.uid());
    NEW.recovered_value := CASE WHEN NEW.outcome = 'recovered' THEN OLD.avg_ticket_snapshot ELSE 0 END;
  ELSE
    NEW.outcome         := NULL;
    NEW.resolved_at     := NULL;
    NEW.resolved_by     := CASE WHEN NEW.status = 'dismissed' THEN coalesce(OLD.resolved_by, auth.uid()) ELSE NULL END;
    NEW.recovered_value := 0;
  END IF;

  NEW.resolution_note := left(NEW.resolution_note, 1000);
  NEW.message_sent    := left(NEW.message_sent, 4000);
  RETURN NEW;
END;
$$;

-- ------------------------------------------------------------------------------
-- 6. Retención: contactos resueltos se borran a los 12 meses.
--    Tope de seguridad: ningún contacto vive más de 24 meses aunque nunca se resuelva.
--    La respuesta anónima y las métricas se conservan.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.purge_expired_contacts(p_months INT DEFAULT 12)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deleted INT;
BEGIN
  DELETE FROM public.response_contacts rc
  WHERE (rc.status = 'resolved'
         AND coalesce(rc.handled_at, rc.consent_at) < now() - make_interval(months => greatest(p_months, 1)))
     OR rc.consent_at < now() - make_interval(months => greatest(p_months, 1) * 2);

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- La programación diaria (pg_cron) NO se activa desde esta migración, a propósito:
-- tocar extensiones del sistema desde un script es delicado. Ver el paso opcional en
-- Backend/supabase/optional/programar_purga_contactos.sql (se ejecuta a mano, una vez,
-- después de habilitar pg_cron en Dashboard → Database → Extensions).

-- ------------------------------------------------------------------------------
-- 7. Permisos de ejecución
-- ------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.tg_businesses_default_plan()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_rescue_cases_erase_message()   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.purge_expired_contacts(integer)   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.business_supports(uuid)           FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.get_my_supports() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_my_supports() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.create_branch_with_qr(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_branch_with_qr(text, boolean) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.add_qr_to_branch(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.add_qr_to_branch(uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.move_qr_to_branch(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.move_qr_to_branch(uuid, uuid) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.set_qr_active(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_qr_active(uuid, boolean) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.get_platform_overview() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_platform_overview() TO authenticated;
