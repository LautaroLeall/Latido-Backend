-- ==============================================================================
-- LATIDO - Migración 012: Diagnóstico detallado por negocio para Super Admin
-- ------------------------------------------------------------------------------
-- Agrega la RPC de solo lectura `get_business_diagnostics(p_business_id UUID)`
-- para que el Super Admin vea cómo rinde cada negocio y cómo ayudarlo a mejorar,
-- SIN modificar ninguna tabla, política ni RPC existente y SIN exponer jamás
-- datos personales ni comentarios de clientes finales (Ley 25.326).
--
-- Incluye:
--   · Configuración y salud de onboarding (logo, destino Google, Modo Rescate,
--     encuesta personalizada, último inicio de sesión del dueño).
--   · Métricas de actividad (7d, 30d, 30d previos, promedio, distribución 1–5★,
--     top 6 etiquetas de los últimos 90 días, última opinión recibida).
--   · Salud del Modo Rescate (casos por estado, SLA vencido, tasa de rescate,
--     cumplimiento de SLA, tiempo promedio de primer contacto y ventas estimadas).
--   · Desglose por sucursal (QRs activos, estado de chips NFC y actividad 30d).
--   · Actividad reciente estrictamente anonimizada (solo estrellas, sucursal,
--     etiquetas, fecha y banderas booleanas has_contact / has_comment / estado).
-- Es idempotente y 100% aditiva.
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.get_business_diagnostics(p_business_id UUID)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_business JSONB;
  v_metrics  JSONB;
  v_rescue   JSONB;
  v_branches JSONB;
  v_recent   JSONB;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Solo el Super Admin puede consultar el diagnóstico de un negocio'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Falta el identificador del negocio'
      USING ERRCODE = '22023';
  END IF;

  -- 1. Configuración del negocio y datos B2B del dueño (sin PII de clientes finales)
  SELECT jsonb_build_object(
    'business_id',          b.id,
    'name',                 b.name,
    'logo_url',             b.logo_url,
    'active',               b.active,
    'created_at',           b.created_at,
    'updated_at',           b.updated_at,
    'plan_id',              b.plan_id,
    'plan_name',            p.name,
    'plan_custom',          p.is_custom,
    'supports_limit',       public.business_supports(b.id),
    'review_destination',   b.review_destination,
    'has_google_url',       (b.google_review_url IS NOT NULL AND btrim(b.google_review_url) <> ''),
    'google_review_url',    b.google_review_url,
    'rescue_enabled',       b.rescue_enabled,
    'rescue_threshold',     b.rescue_threshold,
    'rescue_sla_minutes',   b.rescue_sla_minutes,
    'avg_ticket_value',     b.avg_ticket_value,
    'currency',             b.currency,
    'manager_name',         b.manager_name,
    'has_custom_survey',    EXISTS (SELECT 1 FROM public.survey_questions sq WHERE sq.business_id = b.id),
    'owner_name',           pr.full_name,
    'owner_email',          u.email::text,
    'owner_last_sign_in_at', u.last_sign_in_at
  )
  INTO v_business
  FROM public.businesses b
  JOIN public.plans p         ON p.id  = b.plan_id
  LEFT JOIN public.profiles pr ON pr.id = b.owner_id
  LEFT JOIN auth.users u       ON u.id  = b.owner_id
  WHERE b.id = p_business_id;

  IF v_business IS NULL THEN
    RETURN NULL;
  END IF;

  -- 2. Métricas agregadas de opiniones, tendencia y aspectos top (sin comentarios)
  SELECT jsonb_build_object(
    'responses_total',    count(*),
    'responses_7d',       count(*) FILTER (WHERE r.created_at >= now() - interval '7 days'),
    'responses_30d',      count(*) FILTER (WHERE r.created_at >= now() - interval '30 days'),
    'responses_prev_30d', count(*) FILTER (WHERE r.created_at >= now() - interval '60 days' AND r.created_at < now() - interval '30 days'),
    'avg_stars_all',      round(avg(r.stars)::numeric, 2),
    'avg_stars_30d',      round(avg(r.stars) FILTER (WHERE r.created_at >= now() - interval '30 days')::numeric, 2),
    'low_ratings_30d',    count(*) FILTER (WHERE r.stars <= 2 AND r.created_at >= now() - interval '30 days'),
    'last_response_at',   max(r.created_at),
    'distribution', jsonb_build_object(
      '1', count(*) FILTER (WHERE r.stars = 1),
      '2', count(*) FILTER (WHERE r.stars = 2),
      '3', count(*) FILTER (WHERE r.stars = 3),
      '4', count(*) FILTER (WHERE r.stars = 4),
      '5', count(*) FILTER (WHERE r.stars = 5)
    ),
    'top_tags', coalesce(
      (
        SELECT jsonb_agg(jsonb_build_object('tag', t.tag, 'count', t.cnt) ORDER BY t.cnt DESC, t.tag ASC)
        FROM (
          SELECT unnest(r2.tags) AS tag, count(*) AS cnt
          FROM public.responses r2
          WHERE r2.business_id = p_business_id
            AND r2.created_at >= now() - interval '90 days'
          GROUP BY 1
          ORDER BY cnt DESC, 1 ASC
          LIMIT 6
        ) t
      ),
      '[]'::jsonb
    )
  )
  INTO v_metrics
  FROM public.responses r
  WHERE r.business_id = p_business_id;

  -- 3. Salud del Modo Rescate (solo agregados, sin mensajes ni contactos)
  SELECT jsonb_build_object(
    'cases_total',      count(*),
    'cases_open',       count(*) FILTER (WHERE rc.status = 'open'),
    'cases_contacted',  count(*) FILTER (WHERE rc.status = 'contacted'),
    'cases_overdue',    count(*) FILTER (WHERE rc.status = 'open' AND rc.sla_due_at <= now()),
    'cases_recovered',  count(*) FILTER (WHERE rc.outcome = 'recovered'),
    'cases_no_response',count(*) FILTER (WHERE rc.outcome = 'no_response'),
    'cases_declined',   count(*) FILTER (WHERE rc.outcome = 'declined'),
    'cases_dismissed',  count(*) FILTER (WHERE rc.status = 'dismissed'),
    'recovered_value',  coalesce(sum(rc.recovered_value) FILTER (WHERE rc.outcome = 'recovered'), 0),
    'within_sla_count', count(*) FILTER (WHERE rc.first_contacted_at IS NOT NULL AND rc.first_contacted_at <= rc.sla_due_at),
    'contacted_total',  count(*) FILTER (WHERE rc.first_contacted_at IS NOT NULL),
    'avg_first_response_min', round(
      avg(extract(epoch FROM (rc.first_contacted_at - rc.created_at)) / 60.0)
      FILTER (WHERE rc.first_contacted_at IS NOT NULL AND rc.first_contacted_at >= rc.created_at)::numeric,
      0
    )
  )
  INTO v_rescue
  FROM public.rescue_cases rc
  WHERE rc.business_id = p_business_id;

  -- 4. Desglose por sucursal + estado de soportes QR y NFC
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'branch_id',        br.id,
        'name',             br.name,
        'created_at',       br.created_at,
        'qr_total',         (SELECT count(*) FROM public.qr_codes q WHERE q.branch_id = br.id),
        'qr_active',        (SELECT count(*) FROM public.qr_codes q WHERE q.branch_id = br.id AND q.active),
        'nfc_programmed',   (SELECT count(*) FROM public.qr_codes q WHERE q.branch_id = br.id AND q.active AND q.nfc_status = 'programmed'),
        'nfc_pending',      (SELECT count(*) FROM public.qr_codes q WHERE q.branch_id = br.id AND q.active AND q.nfc_status = 'pending'),
        'responses_30d',    (SELECT count(*) FROM public.responses r WHERE r.branch_id = br.id AND r.created_at >= now() - interval '30 days'),
        'avg_stars_30d',    (SELECT round(avg(r.stars)::numeric, 1) FROM public.responses r WHERE r.branch_id = br.id AND r.created_at >= now() - interval '30 days'),
        'last_response_at', (SELECT max(r.created_at) FROM public.responses r WHERE r.branch_id = br.id)
      )
      ORDER BY br.created_at ASC
    ),
    '[]'::jsonb
  )
  INTO v_branches
  FROM public.branches br
  WHERE br.business_id = p_business_id;

  -- 5. Últimas 12 opiniones estrictamente anonimizadas (CERO PII, CERO texto libre)
  SELECT coalesce(
    jsonb_agg(item ORDER BY item->>'created_at' DESC),
    '[]'::jsonb
  )
  INTO v_recent
  FROM (
    SELECT jsonb_build_object(
      'stars',         r.stars,
      'tags',          r.tags,
      'branch_name',   br.name,
      'has_comment',   (r.comment IS NOT NULL AND btrim(r.comment) <> ''),
      'has_contact',   EXISTS (SELECT 1 FROM public.response_contacts c WHERE c.response_id = r.id),
      'rescue_status', (SELECT rc.status FROM public.rescue_cases rc WHERE rc.response_id = r.id LIMIT 1),
      'rescue_outcome',(SELECT rc.outcome FROM public.rescue_cases rc WHERE rc.response_id = r.id LIMIT 1),
      'created_at',    r.created_at
    ) AS item
    FROM public.responses r
    LEFT JOIN public.branches br ON br.id = r.branch_id
    WHERE r.business_id = p_business_id
    ORDER BY r.created_at DESC
    LIMIT 12
  ) sub;

  RETURN jsonb_build_object(
    'business',        v_business,
    'metrics',         v_metrics,
    'rescue',          v_rescue,
    'branches',        v_branches,
    'recent_activity', v_recent
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_business_diagnostics(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_business_diagnostics(uuid) TO authenticated;
