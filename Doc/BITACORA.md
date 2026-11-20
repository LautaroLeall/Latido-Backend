# Bitácora de Desarrollo — Backend LATIDO

Registro cronológico de migraciones, configuración de Supabase, triggers y políticas de seguridad.

---

## [2026-10-13] — Fase 1: Inicialización y Esquema Relacional Base

- **Control de Versiones**:
  - Configuración y corrección del repositorio remoto `https://github.com/LautaroLeall/Latido-Backend.git` en rama `LautyGod`.
  - Creación del archivo `.gitignore` estricto para proteger secretos de servicio (`service_role_key`), dumps de base de datos y archivos temporales de Supabase CLI.
- **Diseño del Esquema de Base de Datos**:
  - Definición de tablas base: `profiles`, `businesses`, `branches`, `qr_codes`, `survey_questions`, `responses`.
  - Desacoplamiento de privacidad: Tabla independiente `response_contacts` vinculada a `responses` para blindar los datos personales bajo la Ley 25.326.
- **Módulo Modo Rescate**:
  - Esquema de `rescue_templates` con índice único para plantillas del sistema y personalizadas por negocio.
  - Esquema de `rescue_cases` con cálculo de SLA, congelamiento de ticket promedio (`avg_ticket_snapshot`) y campo preparado para IA futura (`message_source`).
  - Vista de analítica agregada `rescue_metrics` con `security_invoker = true`.
- **Políticas RLS**:
  - Inserción pública y anónima en `responses`.
  - Lectura y modificación restringida al dueño del negocio (`owner_id = auth.uid()`).
  - Exclusión deliberada del Super Admin del acceso a nombres, teléfonos y correos de clientes finales.

---

## [2026-10-21] — Fase 2: Seguridad multi-tenant y RPCs del producto

### Avances

- **Supabase CLI**: `supabase init` oficial (`project_id = "latido"`), `site_url` y redirects apuntando a Vite (`http://localhost:5173`), contraseñas mínimas de 8 caracteres.
- **Migración 005 — `005_seguridad_multitenant.sql`**:
  - Funciones `is_super_admin()`, `my_business_id()`, `is_business_admin()` (SECURITY DEFINER) → **eliminan la recursión infinita de RLS en `profiles`** que rompía el login.
  - `business_id` desnormalizado en `responses` y `response_contacts`, asignado por **triggers del servidor** (el cliente nunca decide a qué negocio pertenece un dato). RLS sin JOINs + índices por negocio → escala.
  - Reemplazo total de políticas: cada negocio ve solo lo suyo; el público anónimo **no lee ninguna tabla** (solo usa RPCs); inserciones de respuestas/casos solo vía `submit_feedback`.
  - Protección contra escalada de privilegios: nadie cambia su rol, negocio, plan, dueño ni estado desde la API.
  - `handle_new_user` crea el perfil **siempre como `admin`** (antes se podía registrar como `super_admin` vía metadata).
  - CHECKs: nombre de negocio, URL de Google `https://`, SLA 5–1440 min.
  - Corrección de plantillas semilla (`\n` literal → salto real) y `updated_at` automático.
- **Migración 006 — `006_rpc_panel_y_rescate.sql`**:
  - `generate_qr_token` (48 bits aleatorios, no enumerable), `get_business_by_token` (solo datos públicos), `submit_feedback` (validación, saneamiento, consentimiento, honeypot, anti-flood 20/min por QR, canal coherente), `create_my_business`, `create_branch_with_qr`, `set_qr_active`, `get_business_stats`, `get_platform_overview`.
  - Guardas del Modo Rescate: campos congelados, casos cerrados no se reabren, `first_contacted_at`/`recovered_value`/`resolved_by` calculados en el servidor, sincronización del estado del contacto.
  - Realtime habilitado para `responses` y `rescue_cases` (respeta RLS).
- **Banco de pruebas**: las 6 migraciones se aplicaron sobre Postgres (PGlite) con stubs de Supabase → **70/70 pruebas OK** (aislamiento, escalada, anon, rescate, super admin, anti-flood, idempotencia) + verificación del contrato de FKs usado por el frontend.

### Fallas corregidas

- Recursión infinita en la política “Super admin ve todos los perfiles”.
- `businesses` legible por cualquier anónimo (`USING (true)`) → exponía todos los negocios.
- `qr_codes` legible por anónimos → permitía listar todos los tokens.
- `responses` con `INSERT WITH CHECK (true)` → cualquiera podía inyectar opiniones falsas salteando la RPC.
- Escalada a `super_admin` desde el registro.
- Los empleados (`employee`) no tenían acceso a su negocio (las políticas usaban solo `owner_id`).

### Pendiente / futuro

- Edge Function `rescue-overdue-check` + `pg_cron` (aviso por email de SLA vencido con Resend).
- Invitación de empleados (Edge Function con service role).
- Tabla de auditoría de eventos de plataforma.

---

## [2026-11-16] — Migración 007: planes por soportes, retención y privacidad

### Avances

- **Tabla `plans`** editable por el Super Admin (nombre, soportes, precio mensual, a medida, destacado, orden, visible). Seeds: Base (1 · \$50.000), Plus (3 · \$100.000), Premium (5 · \$175.000), Personalizado. La landing (anónimo) lee solo los planes activos; un negocio ve además su propio plan aunque esté oculto.
- **`businesses.plan_id`** reemplaza al campo viejo `plan` (free/pro/enterprise, migrado a Base/Plus/Premium). `supports_override` para el plan personalizado. Los negocios nuevos arrancan en el Plan Base. Solo el Super Admin cambia plan o soportes.
- **Soportes**: `business_supports()`, `get_my_supports()`, `create_branch_with_qr(nombre, con_qr)`, `add_qr_to_branch()`, `move_qr_to_branch()` y `set_qr_active()` respetan el límite del plan. `get_platform_overview()` incluye plan y soportes.
- **Bug de privacidad corregido**: al borrar los datos del cliente se borra también `rescue_cases.message_sent` (contenía su nombre). Además el guard ya no pisa `resolved_by` de un caso descartado.
- **Retención**: `purge_expired_contacts()` borra contactos resueltos hace más de 12 meses (tope 24 meses) y se programa a diario con `pg_cron` si está disponible. No es invocable desde la API.
- **Pruebas**: 94/94 OK (se agregaron planes, límites de soportes, mover entre sucursales, aislamiento entre negocios, retención y borrado del mensaje).

### Decisiones

- Ticket promedio: se congela **al crear el caso** (ver `/doc/08-decisiones.md`).

### Para aplicar

```powershell
cd "F:\LLDP\VISUAL CODE STUDIO\QR-NFC\Backend"
supabase.cmd db push
```

Si `pg_cron` no está activo, habilitarlo en Dashboard → Database → Extensions y ejecutar de nuevo la migración, o programar `SELECT public.purge_expired_contacts();` a mano.

### Pendiente

- Avisos por email (Resend) y job de SLA vencido.
- Actualizar `ESQUEMA_BD.md` y `POLITICAS_RLS.md` con las migraciones 005–007.

---

## [2026-11-19] — Migración de proyecto Supabase y permisos mínimos

### Incidente

El proyecto `uzcmiuqjugsovhlwcarr` quedó indefinidamente en “Coming up…” (Database, Realtime y Storage). Logs: `password authentication failed for user "supabase_admin"/"postgres"` (930 errores/24 h), Realtime `MigrationsFailedToRun … connection not available`, Storage `[Migrations] failed`. La API de datos devolvía 404 incluso para tablas existentes. Diagnóstico: los servicios internos de la plataforma no podían autenticarse en la base; nada indicó que el SQL del proyecto fuera la causa.

### Acciones

- Nuevo proyecto: `pocsdftehmjdwzvjcfcw`. `.env` de Frontend y Backend actualizados (el `.env` del Backend ya no guarda la vieja `service_role`; ahora `SUPABASE_SECRET_KEY`, solo si hace falta).
- **Migración 008 — permisos mínimos**: se quitan todos los permisos de tabla a `anon` y `authenticated` y se otorgan solo los necesarios (`anon` únicamente lee `plans`). Defensa en profundidad: antes solo RLS frenaba el acceso.
- La programación de `pg_cron` salió de la migración 007 (no se tocan extensiones del sistema desde un script) y pasó a `supabase/optional/programar_purga_contactos.sql`, opcional y manual.
- `supabase/bootstrap/bootstrap_completo.sql` (001–008 en un archivo, para proyecto vacío).
- Pruebas: **99/99 OK** (ahora verifican también el rechazo por falta de permiso de tabla).
- `PUESTA_EN_MARCHA.md` reescrita con pasos exactos y sección de prevención.

### Pendiente

- Pasar a plan Pro antes de tener clientes pagos (copias de seguridad, sin pausa automática).
- SMTP propio (Resend) y activar “Confirm email” en producción.

---

## [2026-11-19] — Migración 009 y Edge Function: alta de negocios solo por Super Admin

### Decisiones

- Se cierra el registro público (`/registro` y `/onboarding`). Las cuentas de negocios las da de alta exclusivamente el Super Admin desde su panel; los clientes solo ingresan en `/login`.

### Avances

- **Migración 009 (`009_alta_de_negocios_por_super_admin.sql`)**:
  - Nueva RPC `public.admin_provision_business(p_owner_id, p_business_name, p_branch_name, p_manager_name, p_plan_id, p_supports_override)` ejecutable únicamente por `service_role` (revocada a `PUBLIC`, `anon` y `authenticated`). Crea negocio + primera sucursal + primer QR y vincula el perfil en una sola transacción.
  - Revocado `EXECUTE` sobre `public.create_my_business` para impedir auto-alta de negocios desde la API.
- **Edge Function `create-business-account`** (`supabase/functions/create-business-account/index.ts`):
  - Valida JWT con `auth.getUser()` y comprueba `profiles.role = 'super_admin'`.
  - Valida payload y existencia del plan antes de crear el usuario.
  - Crea la cuenta del dueño confirmada (`email_confirm: true`), ejecuta `admin_provision_business` y hace rollback (`deleteUser`) si algo falla para no dejar cuentas huérfanas.
- **`supabase/config.toml`**: `enable_signup = false` en `[auth]` y `[auth.email]`, y `[functions.create-business-account] verify_jwt = false`.
- **Pruebas**: **118/118 OK** en PGlite (incluye bloqueo de `create_my_business`, idempotencia de `007`–`009`, `p_supports_override` en planes a medida y validación de permisos de `admin_provision_business`) + contrato de FKs OK.
- **`PUESTA_EN_MARCHA.md`**: creada con el paso a paso completo (migraciones `001`–`010`, alta de primer Super Admin, cierre de signups y despliegue de la Edge Function).
- **Migración 010 (`010_encuesta_y_gestion_completa.sql`)**:
  - `survey_questions`: nuevas columnas `options TEXT[]` (hasta 12 aspectos), `placeholder`, `active` y `updated_at` con CHECKs e índice por negocio/orden.
  - `get_business_by_token()`: incluye `survey_questions` para que el ticket público muestre las preguntas personalizadas de cada negocio.
  - `get_platform_overview()`: suma `owner_name`, `owner_email`, `branches_count` y `primary_token` para gestión completa desde Super Admin (sin exponer jamás datos ni comentarios de clientes finales).
  - Pruebas actualizadas: **126/126 OK** + contrato de FKs OK.
- **Edge Function `create-business-account`**: alineadas validaciones estrictas de servidor (email con dominio real, nombre del dueño y firma solo letras sin números, nombre del negocio sin HTML y con al menos 2 letras, contraseña 8–72 caracteres con letra y número).
- **Migración 011 (`011_logos_negocios.sql`)**:
  - `chk_logo_url` en `businesses` (solo `https://` o `NULL`).
  - Bucket público `business-logos` en Supabase Storage (límite 2 MB, solo `image/png`, `image/jpeg`, `image/webp`; SVG bloqueado por XSS).
  - Políticas RLS multi-tenant en `storage.objects`: lectura pública para el ticket y escritura/borrado restringidos a la carpeta `{business_id}/` del admin de ese negocio (o Super Admin).
  - `get_platform_overview()` incluye `logo_url` para el libro mayor del Super Admin.
  - Pruebas actualizadas: **137/137 OK** + contrato de FKs OK.
- **Auditoría Integral (Fases 1, 2 y 5)**:
  - Pruebas versionadas en el repositorio: `package.json` + `tests/migrations.test.mjs` (**142/142 OK**, suma verificación de congelamiento de `avg_ticket_snapshot`, borrado de `message_sent` en purga de 12 meses y auditoría de catálogos Postgres: 100% RLS activo, `anon` limitado a `plans:SELECT` + 2 RPCs), `tests/contract.test.mjs` y `tests/encoding.test.mjs` ejecutables con `npm test`.
  - Script de solo lectura `supabase/optional/verificar_estado_cloud.sql` para auditar el proyecto Supabase Cloud en un clic.
  - Documentación técnica sincronizada al 100% con migraciones `001`–`011`: `ESQUEMA_BD.md`, `POLITICAS_RLS.md` y `Doc/README.md` (sin enlaces locales `file:///`).
