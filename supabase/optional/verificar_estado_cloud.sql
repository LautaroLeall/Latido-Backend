-- ==============================================================================
-- LATIDO - Verificación de solo lectura del estado en Supabase Cloud
-- Pegar en Supabase Dashboard → SQL Editor para confirmar que 001–016 están OK.
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

-- 4. Funciones clave presentes (009/010/011/012/013/015)
SELECT p.proname AS funcion, pg_get_function_identity_arguments(p.oid) AS firma
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('admin_provision_business', 'check_recovery_account', 'get_business_by_token', 'get_platform_overview', 'get_business_diagnostics', 'super_list_kits', 'super_update_kit', 'super_create_kit', 'submit_feedback', 'purge_expired_contacts')
ORDER BY p.proname;

-- 5. Columnas de encuesta editable (010)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'survey_questions'
ORDER BY ordinal_position;

-- 6. Bucket de logos y políticas endurecidas (011 + 014)
SELECT id, public, file_size_limit, allowed_mime_types
FROM storage.buckets
WHERE id = 'business-logos';

SELECT policyname, cmd, roles
FROM pg_policies
WHERE schemaname = 'storage' AND tablename = 'objects'
  AND policyname LIKE 'logos_%'
ORDER BY policyname;

-- 7. Permisos de check_recovery_account (013 + 014: anon=true, authenticated=false)
SELECT
  has_function_privilege('anon', 'public.check_recovery_account(text)', 'EXECUTE') AS anon_puede,
  has_function_privilege('authenticated', 'public.check_recovery_account(text)', 'EXECUTE') AS auth_puede;

-- 8. Columnas de kits (015) y política de edición de sucursales (016)
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'qr_codes'
  AND column_name IN ('delivered_at', 'kit_notes')
ORDER BY column_name;

SELECT policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'branches' AND policyname = 'branches_update';

-- 9. Cuentas Super Admin activas
SELECT u.email, p.role, p.full_name, p.business_id
FROM public.profiles p
JOIN auth.users u ON u.id = p.id
WHERE p.role = 'super_admin';
