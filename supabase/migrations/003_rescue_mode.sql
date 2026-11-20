-- ==============================================================================
-- LATIDO - Migración 003: Modo Rescate y Procedimientos RPC
-- ==============================================================================

-- 1. Plantillas de mensaje de rescate (WhatsApp / Email)
CREATE TABLE IF NOT EXISTS public.rescue_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID REFERENCES public.businesses(id) ON DELETE CASCADE, -- NULL = plantilla global por defecto
    stars INT NOT NULL CHECK (stars BETWEEN 1 AND 3),
    channel TEXT NOT NULL CHECK (channel IN ('whatsapp', 'email')),
    subject TEXT, -- Solo relevante para email
    body TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_business_template UNIQUE (business_id, stars, channel)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rescue_templates_default_uniq
    ON public.rescue_templates (stars, channel) WHERE business_id IS NULL;

-- 2. Casos de Rescate (Misión con Reloj)
CREATE TABLE IF NOT EXISTS public.rescue_cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    response_id UUID UNIQUE NOT NULL REFERENCES public.responses(id) ON DELETE CASCADE,
    contact_id UUID REFERENCES public.response_contacts(id) ON DELETE SET NULL,
    stars_snapshot INT NOT NULL CHECK (stars_snapshot BETWEEN 1 AND 5),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sla_due_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'contacted', 'resolved', 'dismissed')),
    overdue_notified_at TIMESTAMPTZ,
    first_contacted_at TIMESTAMPTZ,
    contact_channel TEXT CHECK (contact_channel IN ('whatsapp', 'email', 'call')),
    template_id UUID REFERENCES public.rescue_templates(id) ON DELETE SET NULL,
    message_source TEXT NOT NULL DEFAULT 'template' CHECK (message_source IN ('template', 'ai')),
    message_sent TEXT,
    outcome TEXT CHECK (outcome IN ('recovered', 'no_response', 'declined')),
    resolved_at TIMESTAMPTZ,
    resolved_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    resolution_note TEXT,
    avg_ticket_snapshot NUMERIC NOT NULL DEFAULT 0,
    recovered_value NUMERIC NOT NULL DEFAULT 0,
    CONSTRAINT chk_resolved_outcome CHECK (status <> 'resolved' OR outcome IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_rescue_cases_biz_status_sla ON public.rescue_cases(business_id, status, sla_due_at);

-- Habilitar RLS en Modo Rescate
ALTER TABLE public.rescue_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rescue_cases ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Lectura de plantillas (globales y propias)"
ON public.rescue_templates FOR SELECT
TO authenticated
USING (
    business_id IS NULL OR EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = rescue_templates.business_id AND b.owner_id = auth.uid()
    )
);

CREATE POLICY "Admin gestiona plantillas propias"
ON public.rescue_templates FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = rescue_templates.business_id AND b.owner_id = auth.uid()
    )
);

CREATE POLICY "Admin gestiona casos de rescate de su negocio"
ON public.rescue_cases FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = rescue_cases.business_id AND b.owner_id = auth.uid()
    )
);

-- 3. Vista de Métricas de Rescate
CREATE OR REPLACE VIEW public.rescue_metrics WITH (security_invoker = true) AS
SELECT
    business_id,
    date_trunc('month', created_at) AS month,
    count(*) AS cases_total,
    count(*) FILTER (WHERE status = 'resolved') AS cases_closed,
    count(*) FILTER (WHERE outcome = 'recovered') AS recovered,
    coalesce(sum(recovered_value), 0) AS recovered_value,
    avg(extract(epoch FROM (first_contacted_at - created_at)) / 60)
        FILTER (WHERE first_contacted_at IS NOT NULL) AS avg_first_response_min,
    count(*) FILTER (WHERE first_contacted_at <= sla_due_at) AS within_sla
FROM public.rescue_cases
WHERE status <> 'dismissed'
GROUP BY business_id, date_trunc('month', created_at);

-- 4. Función Transaccional de Envío de Feedback (submit_feedback)
CREATE OR REPLACE FUNCTION public.submit_feedback(
    p_token TEXT,
    p_stars INT,
    p_tags TEXT[],
    p_comment TEXT,
    p_contact_name TEXT DEFAULT NULL,
    p_contact_email TEXT DEFAULT NULL,
    p_contact_phone TEXT DEFAULT NULL,
    p_preferred_channel TEXT DEFAULT 'whatsapp'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_qr RECORD;
    v_biz RECORD;
    v_response_id UUID;
    v_contact_id UUID;
    v_case_id UUID;
    v_sla_due TIMESTAMPTZ;
BEGIN
    -- Validar token
    SELECT qc.id, qc.business_id, qc.branch_id, qc.active
    INTO v_qr
    FROM public.qr_codes qc
    WHERE qc.token = p_token AND qc.active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Token de QR no válido o inactivo';
    END IF;

    -- Obtener negocio
    SELECT b.id, b.rescue_enabled, b.rescue_threshold, b.rescue_sla_minutes, b.avg_ticket_value
    INTO v_biz
    FROM public.businesses b
    WHERE b.id = v_qr.business_id;

    -- 1. Insertar respuesta anónima
    INSERT INTO public.responses (qr_code_id, stars, tags, comment)
    VALUES (v_qr.id, p_stars, coalesce(p_tags, '{}'), p_comment)
    RETURNING id INTO v_response_id;

    -- 2. Insertar contacto si fue provisto
    IF p_contact_name IS NOT NULL AND (p_contact_email IS NOT NULL OR p_contact_phone IS NOT NULL) THEN
        INSERT INTO public.response_contacts (
            response_id,
            full_name,
            email,
            phone,
            preferred_channel,
            consent_at
        )
        VALUES (
            v_response_id,
            trim(p_contact_name),
            nullif(trim(p_contact_email), ''),
            nullif(trim(p_contact_phone), ''),
            coalesce(p_preferred_channel, 'whatsapp'),
            NOW()
        )
        RETURNING id INTO v_contact_id;

        -- 3. Si califica para Modo Rescate (stars <= umbral y rescate activo)
        IF v_biz.rescue_enabled AND p_stars <= v_biz.rescue_threshold THEN
            v_sla_due := NOW() + (v_biz.rescue_sla_minutes || ' minutes')::INTERVAL;

            INSERT INTO public.rescue_cases (
                business_id,
                response_id,
                contact_id,
                stars_snapshot,
                sla_due_at,
                status,
                avg_ticket_snapshot
            )
            VALUES (
                v_biz.id,
                v_response_id,
                v_contact_id,
                p_stars,
                v_sla_due,
                'open',
                v_biz.avg_ticket_value
            )
            RETURNING id INTO v_case_id;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'response_id', v_response_id,
        'rescue_case_id', v_case_id
    );
END;
$$;
