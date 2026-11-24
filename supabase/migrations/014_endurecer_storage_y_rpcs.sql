-- ==============================================================================
-- LATIDO - Migración 014: Endurecimiento de Storage (`business-logos`) y RPCs
-- ------------------------------------------------------------------------------
-- Resuelve los avisos accionables del Supabase Security Advisor (Database Linter):
--   1. `public_bucket_allows_listing` (lint 0025):
--      El bucket `business-logos` ya es `public = true`, por lo que las URLs
--      directas de los logos (`<img src=".../storage/v1/object/public/...">`)
--      se sirven sin necesitar una política `SELECT` abierta a `public`/`anon`.
--      Se elimina `logos_public_read` (que permitía listar todos los archivos
--      y enumerar UUIDs de negocios) y se reemplaza por `logos_business_select`,
--      acotada estrictamente a administradores `authenticated` dentro de su
--      propia carpeta `{business_id}/` (o Super Admin), manteniendo intacta la
--      limpieza de logos anteriores en `logoUpload.js`.
--   2. `authenticated_security_definer_function_executable` (lint 0029):
--      Se revoca `EXECUTE` sobre `public.check_recovery_account(text)` al rol
--      `authenticated` (el flujo `/recuperar` es solo para usuarios sin sesión),
--      manteniéndola habilitada exclusivamente para `anon`.
-- Es idempotente.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 1. Storage `business-logos`: eliminar listado público y acotar SELECT por tenant
-- ------------------------------------------------------------------------------
DROP POLICY IF EXISTS logos_public_read     ON storage.objects;
DROP POLICY IF EXISTS logos_business_select ON storage.objects;

CREATE POLICY logos_business_select ON storage.objects
  FOR SELECT TO authenticated
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
-- 2. RPC `check_recovery_account`: uso exclusivo de `anon` (flujo /recuperar)
-- ------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.check_recovery_account(text) FROM authenticated;
