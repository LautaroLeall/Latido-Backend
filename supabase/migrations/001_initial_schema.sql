-- ==============================================================================
-- LATIDO - Migración 001: Esquema Base
-- ==============================================================================

-- 1. Extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. Perfiles de usuario (vinculados a Supabase Auth)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('super_admin', 'admin', 'employee')),
    business_id UUID, -- Se vincula a businesses más adelante
    full_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. Negocios clientes (comercios)
CREATE TABLE IF NOT EXISTS public.businesses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    plan TEXT NOT NULL DEFAULT 'free' CHECK (plan IN ('free', 'pro', 'enterprise')),
    logo_url TEXT,
    review_destination TEXT NOT NULL DEFAULT 'panel' CHECK (review_destination IN ('panel', 'google', 'both')),
    google_review_url TEXT,
    rescue_enabled BOOLEAN NOT NULL DEFAULT true,
    rescue_threshold INT NOT NULL DEFAULT 2 CHECK (rescue_threshold BETWEEN 1 AND 3),
    rescue_sla_minutes INT NOT NULL DEFAULT 60 CHECK (rescue_sla_minutes > 0),
    avg_ticket_value NUMERIC NOT NULL DEFAULT 0 CHECK (avg_ticket_value >= 0),
    currency TEXT NOT NULL DEFAULT 'ARS',
    manager_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Vincular clave foránea business_id en profiles
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS fk_profiles_business,
    ADD CONSTRAINT fk_profiles_business FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE SET NULL;

-- 4. Sucursales físicas
CREATE TABLE IF NOT EXISTS public.branches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 5. Puntos de entrada QR y NFC
CREATE TABLE IF NOT EXISTS public.qr_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    branch_id UUID NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
    token TEXT UNIQUE NOT NULL,
    nfc_status TEXT NOT NULL DEFAULT 'pending' CHECK (nfc_status IN ('pending', 'programmed', 'inactive')),
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_qr_codes_token ON public.qr_codes(token);

-- 6. Preguntas personalizables de encuesta
CREATE TABLE IF NOT EXISTS public.survey_questions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    question_text TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('stars', 'text', 'tags')),
    order_index INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. Respuestas de feedback (100% Anónimas por defecto)
CREATE TABLE IF NOT EXISTS public.responses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_code_id UUID NOT NULL REFERENCES public.qr_codes(id) ON DELETE CASCADE,
    stars INT NOT NULL CHECK (stars BETWEEN 1 AND 5),
    tags TEXT[] NOT NULL DEFAULT '{}',
    comment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_responses_qr ON public.responses(qr_code_id);
CREATE INDEX IF NOT EXISTS idx_responses_created ON public.responses(created_at DESC);

-- 8. Datos de contacto opcionales (Aislados bajo consentimiento - Ley 25.326)
CREATE TABLE IF NOT EXISTS public.response_contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    response_id UUID UNIQUE NOT NULL REFERENCES public.responses(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    preferred_channel TEXT NOT NULL DEFAULT 'whatsapp' CHECK (preferred_channel IN ('whatsapp', 'email', 'call')),
    consent_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'contacted', 'resolved')),
    handled_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    handled_at TIMESTAMPTZ,
    resolution_note TEXT,
    CONSTRAINT chk_contact_channel_provided CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_response_contacts_status ON public.response_contacts(status);
