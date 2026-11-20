-- ==============================================================================
-- LATIDO - Migración 010: Preguntas editables del formulario + gestión Super Admin
-- ------------------------------------------------------------------------------
--   1. `survey_questions`: agrega `options` (etiquetas editables), `placeholder`,
--      `active` y `updated_at` para que cada negocio personalice su ticket.
--   2. `get_business_by_token()`: devuelve las preguntas activas del negocio
--      (si todavía no configuró ninguna, devuelve `[]` y el ticket usa las
--      preguntas predeterminadas).
--   3. `get_platform_overview()`: suma datos del dueño (nombre y email de acceso),
--      cantidad de sucursales y primer token activo para que el Super Admin
--      administre cada cuenta sin tocar jamás datos de clientes finales.
-- Es idempotente.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Personalización del formulario (survey_questions)
-- ------------------------------------------------------------------------------
ALTER TABLE public.survey_questions
  ADD COLUMN IF NOT EXISTS options     TEXT[]      NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS placeholder TEXT,
  ADD COLUMN IF NOT EXISTS active      BOOLEAN     NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE public.survey_questions DROP CONSTRAINT IF EXISTS chk_sq_text_len;
ALTER TABLE public.survey_questions ADD CONSTRAINT chk_sq_text_len
  CHECK (char_length(btrim(question_text)) BETWEEN 2 AND 160);

ALTER TABLE public.survey_questions DROP CONSTRAINT IF EXISTS chk_sq_options_len;
ALTER TABLE public.survey_questions ADD CONSTRAINT chk_sq_options_len
  CHECK (cardinality(options) <= 12);

ALTER TABLE public.survey_questions DROP CONSTRAINT IF EXISTS chk_sq_placeholder_len;
ALTER TABLE public.survey_questions ADD CONSTRAINT chk_sq_placeholder_len
  CHECK (placeholder IS NULL OR char_length(placeholder) <= 160);

CREATE INDEX IF NOT EXISTS idx_survey_questions_business_order
  ON public.survey_questions (business_id, order_index, created_at);

DROP TRIGGER IF EXISTS trg_survey_questions_updated_at ON public.survey_questions;
CREATE TRIGGER trg_survey_questions_updated_at
  BEFORE UPDATE ON public.survey_questions
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ------------------------------------------------------------------------------
-- 2. Ticket público: incluir las preguntas personalizadas del negocio
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_by_token(p_token TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_token IS NULL OR char_length(p_token) > 64 THEN
    RETURN jsonb_build_object('token_valid', false);
  END IF;

  SELECT jsonb_build_object(
    'token_valid',        true,
    'business_name',      b.name,
    'branch_name',        br.name,
    'logo_url',           b.logo_url,
    'review_destination', b.review_destination,
    'google_review_url',  b.google_review_url,
    'rescue_enabled',     b.rescue_enabled,
    'rescue_threshold',   b.rescue_threshold,
    'survey_questions',   coalesce(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'id',            sq.id,
            'type',          sq.type,
            'question_text', sq.question_text,
            'options',       sq.options,
            'placeholder',   sq.placeholder,
            'active',        sq.active,
            'order_index',   sq.order_index
          )
          ORDER BY sq.order_index ASC, sq.created_at ASC
        )
        FROM public.survey_questions sq
        WHERE sq.business_id = b.id
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM public.qr_codes qc
  JOIN public.businesses b  ON b.id  = qc.business_id
  JOIN public.branches   br ON br.id = qc.branch_id
  WHERE qc.token = p_token
    AND qc.active
    AND b.active;

  RETURN coalesce(v_result, jsonb_build_object('token_valid', false));
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_business_by_token(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_business_by_token(text) TO anon, authenticated;

-- ------------------------------------------------------------------------------
-- 3. Libro mayor del Super Admin: suma datos del dueño del negocio (cliente B2B),
--    sucursales y primer token activo. Mantiene 0 acceso a datos de clientes finales.
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_platform_overview();

CREATE OR REPLACE FUNCTION public.get_platform_overview()
RETURNS TABLE (
  business_id     UUID,
  name            TEXT,
  owner_name      TEXT,
  owner_email     TEXT,
  plan_id         UUID,
  plan_name       TEXT,
  plan_custom     BOOLEAN,
  supports_limit  INT,
  branches_count  BIGINT,
  primary_token   TEXT,
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
    pr.full_name,
    u.email::text,
    b.plan_id,
    p.name,
    p.is_custom,
    public.business_supports(b.id),
    (SELECT count(*) FROM public.branches br WHERE br.business_id = b.id),
    (SELECT q.token FROM public.qr_codes q WHERE q.business_id = b.id AND q.active ORDER BY q.created_at ASC LIMIT 1),
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
  LEFT JOIN public.profiles pr ON pr.id = b.owner_id
  LEFT JOIN auth.users u ON u.id = b.owner_id
  WHERE public.is_super_admin()
  ORDER BY b.created_at DESC;
$$;

REVOKE EXECUTE ON FUNCTION public.get_platform_overview() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_platform_overview() TO authenticated;
