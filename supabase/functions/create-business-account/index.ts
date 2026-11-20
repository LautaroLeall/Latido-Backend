// ==============================================================================
// LATIDO - Edge Function: create-business-account
// ------------------------------------------------------------------------------
// Da de alta un negocio completo desde el panel del Super Admin:
//   1. Verifica el JWT y que el solicitante tenga rol `super_admin`.
//   2. Crea la cuenta del dueño en Supabase Auth (confirmada, lista para /login).
//   3. Llama a la RPC `admin_provision_business` (negocio + sucursal + primer QR).
//   4. Si algo falla en el paso 3, borra la cuenta recién creada (rollback).
//
// Despliegue:
//   supabase.cmd functions deploy create-business-account --no-verify-jwt
// (La verificación real del JWT se hace acá adentro con auth.getUser().)
// ==============================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const EMAIL_RE =
  /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/i;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PERSON_NAME_RE = /^[\p{L}][\p{L}\s'.-]*[\p{L}.]$/u;
const HTML_TAG_RE = /<[^>]*>/;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function cleanText(value: unknown, maxLen: number): string {
  if (typeof value !== "string") return "";
  return value.trim().slice(0, maxLen);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Método no permitido." }, 405);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey =
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
    Deno.env.get("SUPABASE_SECRET_KEY");
  if (!supabaseUrl || !serviceKey) {
    return json(
      { error: "Falta configurar las credenciales internas de la función." },
      500,
    );
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── 1. Autenticación y autorización (solo Super Admin) ───────────────────────
  const authHeader = req.headers.get("Authorization") || "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return json({ error: "Falta el token de sesión. Volvé a ingresar." }, 401);
  }

  const { data: userData, error: authErr } = await admin.auth.getUser(match[1]);
  if (authErr || !userData?.user) {
    return json(
      { error: "Tu sesión venció o no es válida. Volvé a ingresar." },
      401,
    );
  }

  const { data: callerProfile, error: profErr } = await admin
    .from("profiles")
    .select("role")
    .eq("id", userData.user.id)
    .maybeSingle();

  if (profErr || callerProfile?.role !== "super_admin") {
    return json(
      { error: "Solo el Super Admin puede crear cuentas de negocios." },
      403,
    );
  }

  // ── 2. Validar entrada ───────────────────────────────────────────────────────
  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json(
      { error: "El cuerpo de la solicitud no es un JSON válido." },
      400,
    );
  }

  const ownerName = cleanText(payload.ownerName, 80);
  const email = cleanText(payload.email, 160).toLowerCase();
  const password = typeof payload.password === "string" ? payload.password : "";
  const businessName = cleanText(payload.businessName, 80);
  const branchName = cleanText(payload.branchName, 60) || "Casa central";
  const managerName = cleanText(payload.managerName, 60) || null;
  const planId = cleanText(payload.planId, 40) || null;
  const rawSupports = payload.supportsOverride;

  if (
    ownerName.length < 2 ||
    /\d/.test(ownerName) ||
    !PERSON_NAME_RE.test(ownerName)
  ) {
    return json(
      {
        error:
          "Ingresá un nombre real del responsable (solo letras, mínimo 2 caracteres).",
      },
      400,
    );
  }
  if (!EMAIL_RE.test(email) || email.includes("..")) {
    return json(
      { error: "Ingresá un email válido para la cuenta del negocio." },
      400,
    );
  }
  if (
    password.length < 8 ||
    password.length > 72 ||
    password !== password.trim() ||
    !/[a-zA-Z]/.test(password) ||
    !/\d/.test(password)
  ) {
    return json(
      {
        error:
          "La contraseña inicial debe tener entre 8 y 72 caracteres, con al menos una letra y un número.",
      },
      400,
    );
  }
  const bizLetters = (businessName.match(/\p{L}/gu) || []).length;
  if (
    businessName.length < 2 ||
    bizLetters < 2 ||
    HTML_TAG_RE.test(businessName)
  ) {
    return json(
      {
        error:
          "Ingresá un nombre válido para el negocio (al menos 2 letras, sin HTML).",
      },
      400,
    );
  }
  if (
    managerName &&
    (/\d/.test(managerName) || !PERSON_NAME_RE.test(managerName))
  ) {
    return json(
      { error: "La firma de Modo Rescate debe contener solo letras." },
      400,
    );
  }
  if (planId && !UUID_RE.test(planId)) {
    return json({ error: "El plan seleccionado no es válido." }, 400);
  }

  let supportsOverride: number | null = null;
  if (rawSupports !== undefined && rawSupports !== null && rawSupports !== "") {
    const parsed = Number(rawSupports);
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 1000) {
      return json(
        { error: "Los soportes deben ser un número entero entre 1 y 1000." },
        400,
      );
    }
    supportsOverride = parsed;
  }

  // Validar que el plan exista antes de crear la cuenta en Auth
  let selectedPlan: { id: string; is_custom: boolean } | null = null;
  if (planId) {
    const { data: plan, error: planErr } = await admin
      .from("plans")
      .select("id, is_custom")
      .eq("id", planId)
      .maybeSingle();

    if (planErr || !plan) {
      return json({ error: "El plan elegido no existe." }, 400);
    }
    selectedPlan = plan;
  }

  // ── 3. Crear usuario en Supabase Auth (ya confirmado) ────────────────────────
  const { data: created, error: createErr } = await admin.auth.admin.createUser(
    {
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: ownerName },
    },
  );

  if (createErr || !created?.user) {
    const msg = createErr?.message || "";
    const code = (createErr as { code?: string } | null)?.code || "";
    if (
      code === "email_exists" ||
      /already been registered|already exists/i.test(msg)
    ) {
      return json(
        { error: "Ya existe una cuenta registrada con ese email." },
        409,
      );
    }
    if (/password/i.test(msg)) {
      return json(
        {
          error:
            "La contraseña no cumple los requisitos mínimos (al menos 8 caracteres).",
        },
        400,
      );
    }
    return json(
      { error: msg || "No pudimos crear la cuenta de usuario." },
      400,
    );
  }

  // ── 4. Crear negocio + sucursal + primer QR en una transacción ───────────────
  const { data: provisioned, error: rpcErr } = await admin.rpc(
    "admin_provision_business",
    {
      p_owner_id: created.user.id,
      p_business_name: businessName,
      p_branch_name: branchName,
      p_manager_name: managerName,
      p_plan_id: selectedPlan?.id ?? null,
      p_supports_override: selectedPlan?.is_custom ? supportsOverride : null,
    },
  );

  if (rpcErr || !provisioned) {
    // Rollback para no dejar cuentas huérfanas sin negocio
    const { error: delErr } = await admin.auth.admin.deleteUser(
      created.user.id,
    );
    if (delErr) {
      console.error(
        "[LATIDO] Error al revertir usuario huérfano:",
        created.user.id,
        delErr,
      );
    }
    return json(
      {
        error:
          rpcErr?.message ||
          "No pudimos configurar el negocio. Se canceló el alta.",
      },
      400,
    );
  }

  return json(
    {
      user_id: created.user.id,
      email,
      business_id: provisioned.business_id,
      branch_id: provisioned.branch_id,
      token: provisioned.token,
    },
    201,
  );
});
