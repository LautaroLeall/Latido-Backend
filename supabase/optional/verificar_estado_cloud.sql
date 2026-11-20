-- ==============================================================================
-- LATIDO - Verificación de solo lectura del estado en Supabase Cloud
-- Pegar en Supabase Dashboard → SQL Editor para confirmar que 001–011 están OK.
-- ==============================================================================

-- 1. Tablas en `public` y estado de RLS (todas deben tener rls_activo = true)
SELECT c.relname AS tabla, c.relrowsecurity AS rls_activo
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY c.relname;

-- 2. Permisos de tabla otorgados a `anon` (DEBE aparecer solo `plans` con SELECT)
SELECT table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'anon' AND table_schema = 'public'
ORDER BY table_name;

-- 3. Planes cargados (007)
SELECT code, name, supports, price_monthly, is_custom, active
FROM public.plans
ORDER BY sort_order;

-- 4. Funciones clave presentes (009/010/011)
SELECT p.proname AS funcion, pg_get_function_identity_arguments(p.oid) AS firma
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('admin_provision_business', 'get_business_by_token', 'get_platform_overview', 'submit_feedback', 'purge_expired_contacts')
ORDER BY p.proname;

-- 5. Columnas de encuesta editable (010)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'survey_questions'
ORDER BY ordinal_position;

-- 6. Bucket de logos (011)
SELECT id, public, file_size_limit, allowed_mime_types
FROM storage.buckets
WHERE id = 'business-logos';

-- 7. Cuentas Super Admin activas
SELECT u.email, p.role, p.full_name, p.business_id
FROM public.profiles p
JOIN auth.users u ON u.id = p.id
WHERE p.role = 'super_admin';
