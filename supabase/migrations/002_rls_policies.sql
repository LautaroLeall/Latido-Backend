-- ==============================================================================
-- LATIDO - Migración 002: Políticas de Seguridad y RLS
-- ==============================================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qr_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.survey_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.response_contacts ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 1. PROFILES
-- ------------------------------------------------------------------------------
CREATE POLICY "Usuarios ven su propio perfil"
ON public.profiles FOR SELECT
TO authenticated
USING (id = auth.uid());

CREATE POLICY "Usuarios editan su propio perfil"
ON public.profiles FOR UPDATE
TO authenticated
USING (id = auth.uid());

CREATE POLICY "Super admin ve todos los perfiles"
ON public.profiles FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'super_admin'
    )
);

-- ------------------------------------------------------------------------------
-- 2. BUSINESSES
-- ------------------------------------------------------------------------------
CREATE POLICY "Admin ve su propio negocio"
ON public.businesses FOR SELECT
TO authenticated
USING (owner_id = auth.uid());

CREATE POLICY "Admin actualiza su propio negocio"
ON public.businesses FOR UPDATE
TO authenticated
USING (owner_id = auth.uid());

CREATE POLICY "Super admin gestiona todos los negocios"
ON public.businesses FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'super_admin'
    )
);

CREATE POLICY "Lectura pública de negocio para clientes"
ON public.businesses FOR SELECT
TO anon, authenticated
USING (true);

-- ------------------------------------------------------------------------------
-- 3. BRANCHES & QR_CODES
-- ------------------------------------------------------------------------------
CREATE POLICY "Admin gestiona sucursales de su negocio"
ON public.branches FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = branches.business_id AND b.owner_id = auth.uid()
    )
);

CREATE POLICY "Super admin gestiona todas las sucursales"
ON public.branches FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.profiles
        WHERE id = auth.uid() AND role = 'super_admin'
    )
);

CREATE POLICY "Admin gestiona QRs de su negocio"
ON public.qr_codes FOR ALL
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.businesses b
        WHERE b.id = qr_codes.business_id AND b.owner_id = auth.uid()
    )
);

CREATE POLICY "Cliente lee QR activo para responder"
ON public.qr_codes FOR SELECT
TO anon, authenticated
USING (active = true);

-- ------------------------------------------------------------------------------
-- 4. RESPONSES (Anónimas)
-- ------------------------------------------------------------------------------
-- Cualquiera puede insertar feedback (público sin login)
CREATE POLICY "Inserción pública de respuestas"
ON public.responses FOR INSERT
TO anon, authenticated
WITH CHECK (true);

-- Solo el dueño del negocio o Super Admin leen respuestas
CREATE POLICY "Admin o Super Admin lee respuestas de su negocio"
ON public.responses FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.qr_codes qc
        JOIN public.businesses b ON b.id = qc.business_id
        WHERE qc.id = responses.qr_code_id
        AND (
            b.owner_id = auth.uid()
            OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'super_admin')
        )
    )
);

-- ------------------------------------------------------------------------------
-- 5. RESPONSE_CONTACTS (Datos personales estrictamente aislados)
-- ------------------------------------------------------------------------------
-- Solo el dueño del negocio ve los contactos de SUS clientes
CREATE POLICY "Negocio lee sus contactos de clientes"
ON public.response_contacts FOR SELECT
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.responses r
        JOIN public.qr_codes qc ON qc.id = r.qr_code_id
        JOIN public.businesses b ON b.id = qc.business_id
        WHERE r.id = response_contacts.response_id
        AND b.owner_id = auth.uid()
    )
);

-- El negocio actualiza el estado de contacto y resolución
CREATE POLICY "Negocio gestiona estado de sus contactos"
ON public.response_contacts FOR UPDATE
TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.responses r
        JOIN public.qr_codes qc ON qc.id = r.qr_code_id
        JOIN public.businesses b ON b.id = qc.business_id
        WHERE r.id = response_contacts.response_id
        AND b.owner_id = auth.uid()
    )
);
-- NOTA DE SEGURIDAD: Super Admin NO tiene política de lectura directa sobre response_contacts.
