-- ==============================================================================
-- LATIDO - Migración 011: Logos de negocios (Supabase Storage + seguridad)
-- ------------------------------------------------------------------------------
--   1. Valida `businesses.logo_url` (solo https:// o NULL).
--   2. Crea el bucket público `business-logos` (máx. 2 MB, solo PNG/JPG/WebP;
--      SVG bloqueado por seguridad XSS).
--   3. Políticas RLS en `storage.objects`:
--        · Lectura pública (los clientes anónimos ven el logo en el ticket).
--        · Subir / actualizar / borrar: SOLO el admin del propio negocio y
--          únicamente dentro de su carpeta `{business_id}/...` (o Super Admin).
--   4. Suma `logo_url` a `get_platform_overview()` para el panel Super Admin.
-- Es idempotente.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Validación de URL de logo en businesses
-- ------------------------------------------------------------------------------
ALTER TABLE public.businesses DROP CONSTRAINT IF EXISTS chk_logo_url;
ALTER TABLE public.businesses ADD CONSTRAINT chk_logo_url
  CHECK (logo_url IS NULL OR logo_url ~* '^https://');

-- ------------------------------------------------------------------------------
-- 2. Bucket público `business-logos` (solo imágenes raster seguras, máx 2 MB)
-- ------------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'business-logos',
  'business-logos',
  true,
  2097152,
  ARRAY['image/png', 'image/jpeg', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ------------------------------------------------------------------------------
-- 3. Políticas RLS multi-tenant en storage.objects
--    (No ejecutar ALTER TABLE storage.objects: Supabase ya tiene RLS activo allí.)
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS logos_public_read     ON storage.objects;
DROP POLICY IF EXISTS logos_business_insert ON storage.objects;
DROP POLICY IF EXISTS logos_business_update ON storage.objects;
DROP POLICY IF EXISTS logos_business_delete ON storage.objects;

CREATE POLICY logos_public_read ON storage.objects
  FOR SELECT TO public
  USING (bucket_id = 'business-logos');

CREATE POLICY logos_business_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'business-logos'
    AND array_length(storage.foldername(name), 1) = 1
    AND (
      (
        (storage.foldername(name))[1] = (SELECT public.my_business_id())::text
        AND (SELECT public.is_business_admin())
      )
      OR (SELECT public.is_super_admin())
    )
  );

CREATE POLICY logos_business_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'business-logos'
    AND array_length(storage.foldername(name), 1) = 1
    AND (
      (
        (storage.foldername(name))[1] = (SELECT public.my_business_id())::text
        AND (SELECT public.is_business_admin())
      )
      OR (SELECT public.is_super_admin())
    )
  )
  WITH CHECK (
    bucket_id = 'business-logos'
    AND array_length(storage.foldername(name), 1) = 1
    AND (
      (
        (storage.foldername(name))[1] = (SELECT public.my_business_id())::text
        AND (SELECT public.is_business_admin())
      )
      OR (SELECT public.is_super_admin())
    )
  );

CREATE POLICY logos_business_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'business-logos'
    AND array_length(storage.foldername(name), 1) = 1
    AND (
      (
        (storage.foldername(name))[1] = (SELECT public.my_business_id())::text
        AND (SELECT public.is_business_admin())
      )
      OR (SELECT public.is_super_admin())
    )
  );

-- ------------------------------------------------------------------------------
-- 4. Libro mayor del Super Admin: incluir `logo_url`
-- ------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_platform_overview();

CREATE OR REPLACE FUNCTION public.get_platform_overview()
RETURNS TABLE (
  business_id     UUID,
  name            TEXT,
  logo_url        TEXT,
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
    b.logo_url,
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
