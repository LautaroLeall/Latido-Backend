-- ==============================================================================
-- LATIDO - Migración 005: Seguridad multi-tenant (endurecimiento)
-- ------------------------------------------------------------------------------
-- Objetivos:
--   1. Cada negocio ve ÚNICAMENTE sus propios datos (aislamiento por tenant).
--   2. Eliminar la recursión RLS en `profiles` (rompía el login).
--   3. Impedir escalada de privilegios (nadie puede auto-asignarse super_admin).
--   4. El público anónimo NO lee tablas directamente: solo usa RPCs controladas.
--   5. Desnormalizar `business_id` en respuestas/contactos para RLS O(1) y escalar.
-- Es idempotente: puede ejecutarse aunque la 002 ya se haya aplicado.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 0. Funciones auxiliares de identidad
--    SECURITY DEFINER → leen `profiles` sin disparar RLS (evita recursión infinita).
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'super_admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.my_business_id()
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.business_id FROM public.profiles p WHERE p.id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_business_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role = 'admin' AND p.business_id IS NOT NULL
  );
$$;

-- ------------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ------------------------------------------------------------------------------
-- Suspensión de negocios (solo Super Admin puede cambiarla)
ALTER TABLE public.businesses ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true;

-- Desnormalización del tenant en respuestas (RLS sin JOINs + índices por negocio)
ALTER TABLE public.responses
  ADD COLUMN IF NOT EXISTS business_id UUID REFERENCES public.businesses(id) ON DELETE CASCADE;
ALTER TABLE public.responses
  ADD COLUMN IF NOT EXISTS branch_id UUID REFERENCES public.branches(id) ON DELETE SET NULL;

UPDATE public.responses r
SET business_id = qc.business_id,
    branch_id   = qc.branch_id
FROM public.qr_codes qc
WHERE qc.id = r.qr_code_id AND r.business_id IS NULL;

ALTER TABLE public.responses ALTER COLUMN business_id SET NOT NULL;

ALTER TABLE public.response_contacts
  ADD COLUMN IF NOT EXISTS business_id UUID REFERENCES public.businesses(id) ON DELETE CASCADE;

UPDATE public.response_contacts rc
SET business_id = r.business_id
FROM public.responses r
WHERE r.id = rc.response_id AND rc.business_id IS NULL;

ALTER TABLE public.response_contacts ALTER COLUMN business_id SET NOT NULL;

-- Índices pensados para las consultas reales del panel
CREATE INDEX IF NOT EXISTS idx_responses_business_created ON public.responses (business_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_responses_qr_created       ON public.responses (qr_code_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_response_contacts_business ON public.response_contacts (business_id, status);
CREATE INDEX IF NOT EXISTS idx_profiles_business          ON public.profiles (business_id);
CREATE INDEX IF NOT EXISTS idx_branches_business          ON public.branches (business_id);
CREATE INDEX IF NOT EXISTS idx_qr_codes_business          ON public.qr_codes (business_id);
CREATE INDEX IF NOT EXISTS idx_businesses_owner           ON public.businesses (owner_id);

-- ------------------------------------------------------------------------------
-- 2. Triggers: el tenant se calcula en el servidor (nunca lo decide el cliente)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_responses_set_tenant()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business UUID;
  v_branch   UUID;
BEGIN
  SELECT qc.business_id, qc.branch_id INTO v_business, v_branch
  FROM public.qr_codes qc WHERE qc.id = NEW.qr_code_id;

  IF v_business IS NULL THEN
    RAISE EXCEPTION 'El código QR no existe' USING ERRCODE = 'P0002';
  END IF;

  NEW.business_id := v_business;
  NEW.branch_id   := v_branch;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_responses_set_tenant ON public.responses;
CREATE TRIGGER trg_responses_set_tenant
  BEFORE INSERT ON public.responses
  FOR EACH ROW EXECUTE FUNCTION public.tg_responses_set_tenant();

CREATE OR REPLACE FUNCTION public.tg_contacts_set_tenant()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  SELECT r.business_id INTO NEW.business_id
  FROM public.responses r WHERE r.id = NEW.response_id;

  IF NEW.business_id IS NULL THEN
    RAISE EXCEPTION 'La respuesta asociada no existe' USING ERRCODE = 'P0002';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contacts_set_tenant ON public.response_contacts;
CREATE TRIGGER trg_contacts_set_tenant
  BEFORE INSERT ON public.response_contacts
  FOR EACH ROW EXECUTE FUNCTION public.tg_contacts_set_tenant();

-- ------------------------------------------------------------------------------
-- 3. updated_at automático
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_businesses_updated_at ON public.businesses;
CREATE TRIGGER trg_businesses_updated_at
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_rescue_templates_updated_at ON public.rescue_templates;
CREATE TRIGGER trg_rescue_templates_updated_at
  BEFORE UPDATE ON public.rescue_templates
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------------------------
-- 4. Alta automática de perfil al registrarse
--    ⚠️ El rol SIEMPRE es 'admin' (sin negocio). Jamás se toma del cliente:
--    si se leyera de raw_user_meta_data cualquiera podría registrarse como super_admin.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.profiles (id, role, full_name)
  VALUES (
    NEW.id,
    'admin',
    coalesce(
      nullif(left(btrim(NEW.raw_user_meta_data->>'full_name'), 80), ''),
      split_part(NEW.email, '@', 1),
      'Nuevo usuario'
    )
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ------------------------------------------------------------------------------
-- 5. Protección de columnas sensibles
--    Desde la API (roles anon/authenticated) nadie cambia rol, negocio, plan ni dueño.
--    Las RPC SECURITY DEFINER (current_user = owner) y el SQL Editor sí pueden.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_profiles_protect()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') AND NOT public.is_super_admin() THEN
    IF NEW.id IS DISTINCT FROM OLD.id
        OR NEW.role IS DISTINCT FROM OLD.role
        OR NEW.business_id IS DISTINCT FROM OLD.business_id THEN
      RAISE EXCEPTION 'No tenés permiso para cambiar el rol o el negocio asignado'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profiles_protect ON public.profiles;
CREATE TRIGGER trg_profiles_protect
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.tg_profiles_protect();

CREATE OR REPLACE FUNCTION public.tg_businesses_protect()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('anon', 'authenticated') AND NOT public.is_super_admin() THEN
    IF NEW.id IS DISTINCT FROM OLD.id
        OR NEW.owner_id IS DISTINCT FROM OLD.owner_id
        OR NEW.plan IS DISTINCT FROM OLD.plan
        OR NEW.active IS DISTINCT FROM OLD.active THEN
      RAISE EXCEPTION 'No tenés permiso para cambiar el plan, el dueño o el estado del negocio'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_businesses_protect ON public.businesses;
CREATE TRIGGER trg_businesses_protect
  BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.tg_businesses_protect();

-- Validaciones de datos de configuración del negocio
ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS chk_business_name_len;
ALTER TABLE public.businesses ADD CONSTRAINT chk_business_name_len
  CHECK (char_length(name) BETWEEN 2 AND 80);

ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS chk_google_url;
ALTER TABLE public.businesses ADD CONSTRAINT chk_google_url
  CHECK (google_review_url IS NULL OR google_review_url ~* '^https://');

ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS chk_sla_range;
ALTER TABLE public.businesses ADD CONSTRAINT chk_sla_range
  CHECK (rescue_sla_minutes BETWEEN 5 AND 1440);

-- ------------------------------------------------------------------------------
-- 6. Reemplazo TOTAL de políticas RLS
--    Se borran todas las anteriores (002/003) y se recrean con las funciones auxiliares.
--    `(SELECT fn())` permite a Postgres cachear el valor una vez por consulta (rendimiento).
-- ------------------------------------------------------------------------------
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT policyname, tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename IN (
        'profiles', 'businesses', 'branches', 'qr_codes', 'survey_questions',
        'responses', 'response_contacts', 'rescue_templates', 'rescue_cases'
      )
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END;
$$;

ALTER TABLE public.survey_questions ENABLE ROW LEVEL SECURITY;

-- ── PROFILES ──────────────────────────────────────────────────────────────────
CREATE POLICY profiles_select ON public.profiles
  FOR SELECT TO authenticated
  USING (
    id = (SELECT auth.uid())
    OR (business_id IS NOT NULL AND business_id = (SELECT public.my_business_id()))
    OR (SELECT public.is_super_admin())
  );

CREATE POLICY profiles_update_self ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));

CREATE POLICY profiles_update_super ON public.profiles
  FOR UPDATE TO authenticated
  USING ((SELECT public.is_super_admin()))
  WITH CHECK ((SELECT public.is_super_admin()));

-- ── BUSINESSES ────────────────────────────────────────────────────────────────
CREATE POLICY businesses_select ON public.businesses
  FOR SELECT TO authenticated
  USING (
    id = (SELECT public.my_business_id())
    OR (SELECT public.is_super_admin())
  );

CREATE POLICY businesses_update ON public.businesses
  FOR UPDATE TO authenticated
  USING (
    (id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
    OR (SELECT public.is_super_admin())
  )
  WITH CHECK (
    (id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
    OR (SELECT public.is_super_admin())
  );

CREATE POLICY businesses_super_insert ON public.businesses
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT public.is_super_admin()));

CREATE POLICY businesses_super_delete ON public.businesses
  FOR DELETE TO authenticated
  USING ((SELECT public.is_super_admin()));

-- ── BRANCHES ──────────────────────────────────────────────────────────────────
CREATE POLICY branches_select ON public.branches
  FOR SELECT TO authenticated
  USING (
    business_id = (SELECT public.my_business_id())
    OR (SELECT public.is_super_admin())
  );

CREATE POLICY branches_update ON public.branches
  FOR UPDATE TO authenticated
  USING (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
  WITH CHECK (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()));

-- ── QR_CODES ──────────────────────────────────────────────────────────────────
-- Alta y activación solo vía RPC (garantiza token seguro y coherencia negocio/sucursal)
CREATE POLICY qr_codes_select ON public.qr_codes
  FOR SELECT TO authenticated
  USING (
    business_id = (SELECT public.my_business_id())
    OR (SELECT public.is_super_admin())
  );

-- ── SURVEY_QUESTIONS ──────────────────────────────────────────────────────────
CREATE POLICY survey_questions_select ON public.survey_questions
  FOR SELECT TO authenticated
  USING (business_id = (SELECT public.my_business_id()));

CREATE POLICY survey_questions_write ON public.survey_questions
  FOR ALL TO authenticated
  USING (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
  WITH CHECK (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()));

-- ── RESPONSES (anónimas) ──────────────────────────────────────────────────────
-- Inserción: SOLO vía submit_feedback(). Lectura: SOLO el propio negocio.
-- El Super Admin ve agregados vía get_platform_overview(), nunca comentarios.
CREATE POLICY responses_select ON public.responses
  FOR SELECT TO authenticated
  USING (business_id = (SELECT public.my_business_id()));

-- ── RESPONSE_CONTACTS (datos personales · Ley 25.326) ─────────────────────────
CREATE POLICY contacts_select ON public.response_contacts
  FOR SELECT TO authenticated
  USING (business_id = (SELECT public.my_business_id()));

CREATE POLICY contacts_update ON public.response_contacts
  FOR UPDATE TO authenticated
  USING (business_id = (SELECT public.my_business_id()))
  WITH CHECK (business_id = (SELECT public.my_business_id()));

-- Derecho de supresión: el admin del negocio puede borrar los datos personales
-- (la respuesta anónima y las métricas se conservan).
CREATE POLICY contacts_delete ON public.response_contacts
  FOR DELETE TO authenticated
  USING (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()));

-- ── RESCUE_TEMPLATES ──────────────────────────────────────────────────────────
CREATE POLICY templates_select ON public.rescue_templates
  FOR SELECT TO authenticated
  USING (business_id IS NULL OR business_id = (SELECT public.my_business_id()));

CREATE POLICY templates_write_own ON public.rescue_templates
  FOR ALL TO authenticated
  USING (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()))
  WITH CHECK (business_id = (SELECT public.my_business_id()) AND (SELECT public.is_business_admin()));

CREATE POLICY templates_write_global ON public.rescue_templates
  FOR ALL TO authenticated
  USING (business_id IS NULL AND (SELECT public.is_super_admin()))
  WITH CHECK (business_id IS NULL AND (SELECT public.is_super_admin()));

-- ── RESCUE_CASES ──────────────────────────────────────────────────────────────
-- Alta solo vía submit_feedback(). Sin DELETE: el historial es auditable.
CREATE POLICY rescue_cases_select ON public.rescue_cases
  FOR SELECT TO authenticated
  USING (business_id = (SELECT public.my_business_id()));

CREATE POLICY rescue_cases_update ON public.rescue_cases
  FOR UPDATE TO authenticated
  USING (business_id = (SELECT public.my_business_id()))
  WITH CHECK (business_id = (SELECT public.my_business_id()));

-- ------------------------------------------------------------------------------
-- 7. Corrección de plantillas semilla: '\n' literal → salto de línea real
-- ------------------------------------------------------------------------------
UPDATE public.rescue_templates
SET body = replace(body, '\n', E'\n')
WHERE strpos(body, '\n') > 0;

-- ------------------------------------------------------------------------------
-- 8. Permisos de ejecución de funciones internas
-- ------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.handle_new_user()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_responses_set_tenant()  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_contacts_set_tenant()   FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_profiles_protect()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_businesses_protect()    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_updated_at()           FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.is_super_admin()    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.my_business_id()    FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_business_admin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_super_admin()    TO authenticated;
GRANT  EXECUTE ON FUNCTION public.my_business_id()    TO authenticated;
GRANT  EXECUTE ON FUNCTION public.is_business_admin() TO authenticated;
