-- ==============================================================================
-- LATIDO - Migración 006: RPCs del producto, Modo Rescate y Realtime
-- ------------------------------------------------------------------------------
--   · generate_qr_token()      → tokens no adivinables (interno)
--   · get_business_by_token()  → datos públicos mínimos para el ticket (anon)
--   · submit_feedback()        → alta atómica + validación + honeypot + anti-flood (anon)
--   · create_my_business()     → onboarding: negocio + sucursal + primer QR (admin)
--   · create_branch_with_qr()  → nueva sucursal con su QR (admin)
--   · set_qr_active()          → activar / desactivar un QR (admin)
--   · get_business_stats()     → métricas agregadas del panel (admin/employee)
--   · get_platform_overview()  → libro mayor sin datos personales (super_admin)
--   · Guardas de integridad del Modo Rescate + Realtime
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Generador de tokens QR/NFC
--    Formato: slug-legible-xxxxxxxxxxxx (12 hex = 48 bits aleatorios → no enumerable)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.generate_qr_token(text, text);

CREATE OR REPLACE FUNCTION public.generate_qr_token(p_label TEXT)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
SET search_path = ''
AS $$
DECLARE
  v_slug  TEXT;
  v_token TEXT;
BEGIN
  v_slug := lower(coalesce(p_label, ''));
  v_slug := translate(v_slug, 'áàäâãéèëêíìïîóòöôõúùüûñç', 'aaaaaeeeeiiiiooooouuuunc');
  v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
  v_slug := btrim(left(btrim(v_slug, '-'), 32), '-');
  IF v_slug = '' THEN
    v_slug := 'latido';
  END IF;

  LOOP
    v_token := v_slug || '-' || left(replace(gen_random_uuid()::text, '-', ''), 12);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.qr_codes q WHERE q.token = v_token);
  END LOOP;

  RETURN v_token;
END;
$$;

-- ------------------------------------------------------------------------------
-- 2. Datos públicos del negocio para el ticket (lo que ve el cliente al escanear)
--    Nunca expone owner_id, ticket promedio ni datos internos.
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
    'rescue_threshold',   b.rescue_threshold
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

-- ------------------------------------------------------------------------------
-- 3. Envío de feedback (reemplaza la versión de la 003)
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.submit_feedback(text, integer, text[], text, text, text, text, text);

CREATE OR REPLACE FUNCTION public.submit_feedback(
  p_token             TEXT,
  p_stars             INTEGER,
  p_tags              TEXT[]  DEFAULT '{}',
  p_comment           TEXT    DEFAULT NULL,
  p_contact_name      TEXT    DEFAULT NULL,
  p_contact_email     TEXT    DEFAULT NULL,
  p_contact_phone     TEXT    DEFAULT NULL,
  p_preferred_channel TEXT    DEFAULT 'whatsapp',
  p_consent           BOOLEAN DEFAULT false,
  p_website           TEXT    DEFAULT NULL   -- honeypot: los humanos nunca lo completan
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_qr          RECORD;
  v_recent      INTEGER;
  v_tags        TEXT[];
  v_comment     TEXT;
  v_name        TEXT;
  v_email       TEXT;
  v_phone       TEXT;
  v_phone_dig   TEXT;
  v_channel     TEXT;
  v_response_id UUID;
  v_contact_id  UUID;
  v_case_id     UUID;
BEGIN
  -- Honeypot: respondemos OK para no darle pistas al bot, pero no guardamos nada
  IF coalesce(btrim(p_website), '') <> '' THEN
    RETURN jsonb_build_object('success', true, 'rescue', false);
  END IF;

  IF p_stars IS NULL OR p_stars NOT BETWEEN 1 AND 5 THEN
    RAISE EXCEPTION 'Elegí una calificación de 1 a 5 estrellas' USING ERRCODE = '22023';
  END IF;

  -- QR + negocio activos
  SELECT qc.id AS qr_id,
          b.id  AS business_id,
          b.rescue_enabled,
          b.rescue_threshold,
          b.rescue_sla_minutes,
          b.avg_ticket_value
  INTO v_qr
  FROM public.qr_codes qc
  JOIN public.businesses b ON b.id = qc.business_id
  WHERE qc.token = p_token AND qc.active AND b.active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Token de QR no válido o inactivo' USING ERRCODE = 'P0002';
  END IF;

  -- Anti-flood por QR (máx. 20 opiniones por minuto en un mismo punto físico)
  SELECT count(*) INTO v_recent
  FROM public.responses r
  WHERE r.qr_code_id = v_qr.qr_id
    AND r.created_at > now() - interval '1 minute';

  IF v_recent >= 20 THEN
    RAISE EXCEPTION 'Recibimos muchas opiniones seguidas. Probá de nuevo en un minuto.'
      USING ERRCODE = 'P0001';
  END IF;

  -- Saneamiento de etiquetas y comentario
  SELECT coalesce(array_agg(DISTINCT left(btrim(t), 30)), '{}')
  INTO v_tags
  FROM unnest(coalesce(p_tags, '{}'::TEXT[])) AS t
  WHERE btrim(t) <> '';

  IF cardinality(v_tags) > 10 THEN
    v_tags := v_tags[1:10];
  END IF;

  v_comment := nullif(left(btrim(coalesce(p_comment, '')), 1000), '');

  -- Saneamiento de contacto (opcional)
  v_name      := nullif(left(btrim(coalesce(p_contact_name, '')), 120), '');
  v_email     := nullif(lower(btrim(coalesce(p_contact_email, ''))), '');
  v_phone_dig := regexp_replace(coalesce(p_contact_phone, ''), '[^0-9]', '', 'g');
  v_phone     := nullif(v_phone_dig, '');

  IF v_name IS NOT NULL OR v_email IS NOT NULL OR v_phone IS NOT NULL THEN
    IF v_name IS NULL OR char_length(v_name) < 3 THEN
      RAISE EXCEPTION 'Ingresá tu nombre y apellido' USING ERRCODE = '22023';
    END IF;
    IF v_email IS NOT NULL AND (char_length(v_email) > 254 OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
      RAISE EXCEPTION 'El formato del email no es válido' USING ERRCODE = '22023';
    END IF;
    IF v_phone IS NOT NULL AND char_length(v_phone) NOT BETWEEN 8 AND 15 THEN
      RAISE EXCEPTION 'El teléfono debe tener entre 8 y 15 dígitos' USING ERRCODE = '22023';
    END IF;
    IF v_email IS NULL AND v_phone IS NULL THEN
      RAISE EXCEPTION 'Completá al menos un medio de contacto (email o teléfono)' USING ERRCODE = '22023';
    END IF;
    IF NOT coalesce(p_consent, false) THEN
      RAISE EXCEPTION 'Necesitamos tu consentimiento para poder contactarte' USING ERRCODE = '22023';
    END IF;

    -- Canal coherente con los datos disponibles
    v_channel := coalesce(p_preferred_channel, 'whatsapp');
    IF v_channel NOT IN ('whatsapp', 'email', 'call') THEN
      v_channel := 'whatsapp';
    END IF;
    IF v_channel IN ('whatsapp', 'call') AND v_phone IS NULL THEN
      v_channel := 'email';
    ELSIF v_channel = 'email' AND v_email IS NULL THEN
      v_channel := 'whatsapp';
    END IF;
  END IF;

  -- 1) Respuesta anónima (el trigger asigna business_id / branch_id)
  INSERT INTO public.responses (qr_code_id, stars, tags, comment)
  VALUES (v_qr.qr_id, p_stars, v_tags, v_comment)
  RETURNING id INTO v_response_id;

  -- 2) Contacto aislado (solo con consentimiento)
  IF v_name IS NOT NULL THEN
    INSERT INTO public.response_contacts (response_id, full_name, email, phone, preferred_channel, consent_at)
    VALUES (v_response_id, v_name, v_email, v_phone, v_channel, now())
    RETURNING id INTO v_contact_id;

    -- 3) Caso de rescate con reloj si corresponde
    IF v_qr.rescue_enabled AND p_stars <= v_qr.rescue_threshold THEN
      INSERT INTO public.rescue_cases (
        business_id, response_id, contact_id, stars_snapshot,
        sla_due_at, status, contact_channel, avg_ticket_snapshot
      )
      VALUES (
        v_qr.business_id, v_response_id, v_contact_id, p_stars,
        now() + make_interval(mins => v_qr.rescue_sla_minutes),
        'open', v_channel, v_qr.avg_ticket_value
      )
      RETURNING id INTO v_case_id;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', true, 'rescue', v_case_id IS NOT NULL);
END;
$$;

-- ------------------------------------------------------------------------------
-- 4. Onboarding: el admin recién registrado crea su negocio
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_my_business(
  p_name         TEXT,
  p_branch_name  TEXT DEFAULT 'Casa central',
  p_manager_name TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid         UUID := auth.uid();
  v_profile     RECORD;
  v_name        TEXT;
  v_branch_name TEXT;
  v_manager     TEXT;
  v_business_id UUID;
  v_branch_id   UUID;
  v_token       TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Necesitás iniciar sesión' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No encontramos tu perfil' USING ERRCODE = 'P0002';
  END IF;
  IF v_profile.role <> 'admin' THEN
    RAISE EXCEPTION 'Solo un administrador puede crear un negocio' USING ERRCODE = '42501';
  END IF;
  IF v_profile.business_id IS NOT NULL THEN
    RAISE EXCEPTION 'Tu cuenta ya tiene un negocio asociado' USING ERRCODE = '23505';
  END IF;

  v_name := left(btrim(coalesce(p_name, '')), 80);
  IF char_length(v_name) < 2 THEN
    RAISE EXCEPTION 'El nombre del negocio es demasiado corto' USING ERRCODE = '22023';
  END IF;

  v_branch_name := coalesce(nullif(left(btrim(coalesce(p_branch_name, '')), 60), ''), 'Casa central');
  v_manager     := coalesce(nullif(left(btrim(coalesce(p_manager_name, '')), 60), ''), v_profile.full_name);

  INSERT INTO public.businesses (owner_id, name, manager_name)
  VALUES (v_uid, v_name, v_manager)
  RETURNING id INTO v_business_id;

  INSERT INTO public.branches (business_id, name)
  VALUES (v_business_id, v_branch_name)
  RETURNING id INTO v_branch_id;

  v_token := public.generate_qr_token(v_name || ' ' || v_branch_name);

  INSERT INTO public.qr_codes (business_id, branch_id, token)
  VALUES (v_business_id, v_branch_id, v_token);

  UPDATE public.profiles SET business_id = v_business_id WHERE id = v_uid;

  RETURN jsonb_build_object('business_id', v_business_id, 'token', v_token);
END;
$$;

-- ------------------------------------------------------------------------------
-- 5. Nueva sucursal con su QR
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_branch_with_qr(p_branch_name TEXT)
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

  SELECT name INTO v_biz_name FROM public.businesses WHERE id = v_business_id;

  INSERT INTO public.branches (business_id, name)
  VALUES (v_business_id, v_name)
  RETURNING id INTO v_branch_id;

  v_token := public.generate_qr_token(v_biz_name || ' ' || v_name);

  INSERT INTO public.qr_codes (business_id, branch_id, token)
  VALUES (v_business_id, v_branch_id, v_token);

  RETURN jsonb_build_object('branch_id', v_branch_id, 'token', v_token);
END;
$$;

-- ------------------------------------------------------------------------------
-- 6. Activar / desactivar un QR (p. ej. lámina robada o dañada)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_qr_active(p_qr_id UUID, p_active BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_business_admin() THEN
    RAISE EXCEPTION 'Solo el administrador del negocio puede modificar QRs' USING ERRCODE = '42501';
  END IF;

  UPDATE public.qr_codes
  SET active = coalesce(p_active, false)
  WHERE id = p_qr_id
    AND business_id = public.my_business_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR no encontrado' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

-- ------------------------------------------------------------------------------
-- 7. Métricas del panel (agregadas en la BD → no se descargan miles de filas)
--    SECURITY INVOKER: respeta RLS, cada negocio solo agrega lo suyo.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_stats(p_days INTEGER DEFAULT 7)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $$
  WITH base AS (
    SELECT r.stars, r.tags
    FROM public.responses r
    WHERE r.business_id = public.my_business_id()
      AND r.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 365)))
  )
  SELECT jsonb_build_object(
    'total',        (SELECT count(*) FROM base),
    'avg',          (SELECT round(avg(stars)::numeric, 1) FROM base),
    'low',          (SELECT count(*) FROM base WHERE stars <= 2),
    'distribution', (SELECT coalesce(jsonb_object_agg(s::text, c), '{}'::jsonb)
                      FROM (SELECT stars AS s, count(*) AS c FROM base GROUP BY stars) d),
    'tags',         (SELECT coalesce(jsonb_object_agg(t, c), '{}'::jsonb)
                      FROM (SELECT unnest(tags) AS t, count(*) AS c FROM base GROUP BY 1) x)
  );
$$;

-- ------------------------------------------------------------------------------
-- 8. Libro mayor del Super Admin (solo agregados, cero datos personales)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_platform_overview()
RETURNS TABLE (
  business_id     UUID,
  name            TEXT,
  plan            TEXT,
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
    b.plan,
    b.active,
    b.created_at,
    (SELECT count(*) FROM public.responses r WHERE r.business_id = b.id),
    (SELECT count(*) FROM public.responses r WHERE r.business_id = b.id AND r.created_at >= now() - interval '30 days'),
    (SELECT round(avg(r.stars)::numeric, 1) FROM public.responses r WHERE r.business_id = b.id),
    (SELECT count(*) FROM public.rescue_cases rc WHERE rc.business_id = b.id AND rc.outcome = 'recovered'),
    (SELECT count(*) FROM public.rescue_cases rc WHERE rc.business_id = b.id AND rc.status IN ('open', 'contacted')),
    (SELECT count(*) FROM public.qr_codes q WHERE q.business_id = b.id AND q.active)
  FROM public.businesses b
  WHERE public.is_super_admin()
  ORDER BY b.created_at DESC;
$$;

-- ------------------------------------------------------------------------------
-- 9. Integridad del Modo Rescate
--    Aunque alguien actualice la tabla directo por la API, el servidor manda:
--    campos congelados, transiciones válidas y valor recuperado calculado acá.
-- ------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_rescue_cases_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  -- Campos inmutables
  NEW.id                  := OLD.id;
  NEW.business_id         := OLD.business_id;
  NEW.response_id         := OLD.response_id;
  NEW.stars_snapshot      := OLD.stars_snapshot;
  NEW.created_at          := OLD.created_at;
  NEW.sla_due_at          := OLD.sla_due_at;
  NEW.avg_ticket_snapshot := OLD.avg_ticket_snapshot;
  NEW.overdue_notified_at := coalesce(OLD.overdue_notified_at, NEW.overdue_notified_at);
  -- contact_id solo puede pasar a NULL (borrado de datos personales)
  IF NEW.contact_id IS DISTINCT FROM OLD.contact_id AND NEW.contact_id IS NOT NULL THEN
    NEW.contact_id := OLD.contact_id;
  END IF;

  -- Un caso cerrado no se reabre
  IF OLD.status IN ('resolved', 'dismissed') AND NEW.status IS DISTINCT FROM OLD.status THEN
    RAISE EXCEPTION 'Este caso ya está cerrado' USING ERRCODE = 'P0001';
  END IF;

  -- Primer contacto: se sella una sola vez con la hora del servidor
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
    NEW.resolved_by     := CASE WHEN NEW.status = 'dismissed' THEN auth.uid() ELSE NULL END;
    NEW.recovered_value := 0;
  END IF;

  NEW.resolution_note := left(NEW.resolution_note, 1000);
  NEW.message_sent    := left(NEW.message_sent, 4000);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rescue_cases_guard ON public.rescue_cases;
CREATE TRIGGER trg_rescue_cases_guard
  BEFORE UPDATE ON public.rescue_cases
  FOR EACH ROW EXECUTE FUNCTION public.tg_rescue_cases_guard();

-- Sincroniza el estado del contacto con el caso (para la vista de Resultados)
CREATE OR REPLACE FUNCTION public.tg_rescue_cases_sync_contact()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.contact_id IS NOT NULL AND NEW.status IS DISTINCT FROM OLD.status THEN
    UPDATE public.response_contacts
    SET status = CASE
                    WHEN NEW.status IN ('resolved', 'dismissed') THEN 'resolved'
                    WHEN NEW.status = 'contacted' THEN 'contacted'
                    ELSE 'pending'
                  END,
        handled_by = coalesce(auth.uid(), handled_by),
        handled_at = now(),
        resolution_note = coalesce(NEW.resolution_note, resolution_note)
    WHERE id = NEW.contact_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rescue_cases_sync_contact ON public.rescue_cases;
CREATE TRIGGER trg_rescue_cases_sync_contact
  AFTER UPDATE ON public.rescue_cases
  FOR EACH ROW EXECUTE FUNCTION public.tg_rescue_cases_sync_contact();

-- ------------------------------------------------------------------------------
-- 10. Realtime: el panel recibe casos y opiniones nuevas al instante
--     (Realtime respeta RLS: cada negocio solo recibe sus propios eventos)
-- ------------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'rescue_cases'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.rescue_cases;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'responses'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.responses;
    END IF;
  END IF;
END;
$$;

-- ------------------------------------------------------------------------------
-- 11. Permisos de ejecución
-- ------------------------------------------------------------------------------
-- Internas: nadie las llama desde la API
REVOKE EXECUTE ON FUNCTION public.generate_qr_token(text)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_rescue_cases_guard()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_rescue_cases_sync_contact()   FROM PUBLIC, anon, authenticated;

-- Públicas (cliente final que escanea el QR / NFC)
REVOKE EXECUTE ON FUNCTION public.get_business_by_token(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_business_by_token(text) TO anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.submit_feedback(text, integer, text[], text, text, text, text, text, boolean, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.submit_feedback(text, integer, text[], text, text, text, text, text, boolean, text) TO anon, authenticated;

-- Solo usuarios autenticados
REVOKE EXECUTE ON FUNCTION public.create_my_business(text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_my_business(text, text, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.create_branch_with_qr(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_branch_with_qr(text) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.set_qr_active(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_qr_active(uuid, boolean) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.get_business_stats(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_business_stats(integer) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.get_platform_overview() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_platform_overview() TO authenticated;
