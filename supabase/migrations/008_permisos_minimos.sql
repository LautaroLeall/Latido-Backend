-- ==============================================================================
-- LATIDO - Migración 008: Permisos mínimos (defensa en profundidad)
-- ------------------------------------------------------------------------------
-- Hasta ahora `anon` y `authenticated` heredaban permisos amplios sobre las tablas
-- y solo RLS los frenaba. Acá se quitan TODOS y se otorgan únicamente los necesarios:
--   · Capa 1: permisos de tabla (esta migración)
--   · Capa 2: políticas RLS (migraciones 002/005/007)
-- Un error en una capa ya no alcanza para exponer datos.
--
-- ⚠️ Regla para el futuro: toda tabla o vista nueva en `public` necesita su GRANT
--    explícito (y su RLS). Sin GRANT, la API no puede usarla: es lo esperado.
-- Es idempotente.
-- ==============================================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

-- Punto de partida: nada
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;

-- ── Público (sin login): solo los planes visibles en la landing ───────────────
-- Todo lo demás (ticket, datos del negocio) pasa por funciones controladas.
GRANT SELECT ON public.plans TO anon;

-- ── Usuarios con sesión: lo mínimo que usa el panel (RLS decide las filas) ────
GRANT SELECT, UPDATE                 ON public.profiles          TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.businesses        TO authenticated;  -- insert/delete: solo Super (RLS)
GRANT SELECT, UPDATE                 ON public.branches          TO authenticated;
GRANT SELECT                         ON public.qr_codes          TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.survey_questions  TO authenticated;
GRANT SELECT                         ON public.responses         TO authenticated;
GRANT SELECT, UPDATE, DELETE         ON public.response_contacts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rescue_templates  TO authenticated;
GRANT SELECT, UPDATE                 ON public.rescue_cases      TO authenticated;
GRANT SELECT                         ON public.rescue_metrics    TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.plans             TO authenticated;  -- escritura: solo Super (RLS)

-- Secuencias: no se usan (todas las claves son UUID)
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;

-- Las funciones públicas ya tienen su GRANT EXECUTE explícito (migraciones 006/007):
--   anon:          get_business_by_token, submit_feedback
--   authenticated: el resto de las RPC del panel
