# Esquema de Base de Datos — LATIDO (PostgreSQL / Supabase)

> Vigente al estado de las migraciones **`001` a `016`**.

## 1. Diagrama Entidad-Relación

```text
auth.users
    │
    ▼
profiles ──(business_id)──► businesses ◄──(plan_id)── plans
                                │
                                ├───────► branches ◄──────────┐
                                ├───────► qr_codes ───────────┘
                                ├───────► survey_questions
                                ├───────► responses ──► response_contacts (Ley 25.326)
                                ├───────► rescue_cases (──► rescue_metrics view)
                                └───────► rescue_templates

storage.buckets: "business-logos" (público, máx 2 MB, PNG/JPG/WebP, carpeta {business_id}/; sin listado público)
recovery_check_log (auxiliar efímera con hash MD5 para anti-abuso de /recuperar; RLS activo, REVOKE ALL)
```

---

## 2. Tablas Principales (`public`)

### `plans` _(migración 007)_

- `id`: `uuid PK`
- `code`: `text UNIQUE` (`base`, `plus`, `premium`, `custom`)
- `name`: `text` (2–40 caracteres)
- `supports`: `int` (1–1000, NULL en planes a medida)
- `price_monthly`: `numeric` (≥ 0, NULL en planes a medida)
- `currency`: `text DEFAULT 'ARS'`
- `is_custom`, `highlighted`, `active`: `boolean`
- `sort_order`: `int`
- `created_at`, `updated_at`: `timestamptz`

### `profiles`

- `id`: `uuid PK REFERENCES auth.users(id) ON DELETE CASCADE`
- `role`: `text CHECK (role IN ('super_admin', 'admin', 'employee'))` (alta automática siempre en `'admin'`)
- `business_id`: `uuid REFERENCES businesses(id) ON DELETE SET NULL` (`fk_profiles_business`)
- `full_name`: `text NOT NULL`
- `created_at`, `updated_at`: `timestamptz`

### `businesses`

- `id`: `uuid PK`
- `owner_id`: `uuid REFERENCES profiles(id) ON DELETE RESTRICT`
- `name`: `text NOT NULL` (2–80 caracteres)
- `plan_id`: `uuid NOT NULL REFERENCES plans(id) ON DELETE RESTRICT`
- `supports_override`: `int` (1–1000, usado en planes `is_custom`)
- `active`: `boolean NOT NULL DEFAULT true`
- `logo_url`: `text` (`CHECK` `https://` o `NULL`)
- `review_destination`: `text NOT NULL DEFAULT 'panel'` (`panel` | `google` | `both`)
- `google_review_url`: `text` (`CHECK` `https://` o `NULL`)
- `rescue_enabled`: `boolean NOT NULL DEFAULT true`
- `rescue_threshold`: `int NOT NULL DEFAULT 2` (1–3)
- `rescue_sla_minutes`: `int NOT NULL DEFAULT 60` (5–1440)
- `avg_ticket_value`: `numeric NOT NULL DEFAULT 0`
- `currency`: `text NOT NULL DEFAULT 'ARS'`
- `manager_name`: `text`
- `created_at`, `updated_at`: `timestamptz`

### `branches` y `qr_codes`

- `branches`: `id`, `business_id`, `name` _(2–60 chars, `chk_branch_name` + trigger `tg_branches_protect` en `016`; editable por Admin propio y Super Admin)_, `created_at`.
- `qr_codes`: `id`, `business_id`, `branch_id`, `token UNIQUE` (slug + 48 bits aleatorios), `nfc_status` (`pending`|`programmed`|`inactive`), `active`, `delivered_at` _(015)_, `kit_notes` _(015, ≤ 300 chars)_, `created_at`.

### `survey_questions` _(extendida en 010)_

- `id`, `business_id`, `question_text` (2–160 chars), `type` (`stars`|`tags`|`text`), `options TEXT[]` (hasta 12 aspectos), `placeholder` (≤ 160 chars), `active`, `order_index`, `created_at`, `updated_at`.

### `responses` y `response_contacts`

- `responses` _(anónima)_: `id`, `qr_code_id`, `business_id` _(asignado por trigger)_, `branch_id` _(asignado por trigger)_, `stars` (1–5), `tags TEXT[]`, `comment`, `created_at`.
- `response_contacts` _(aislada bajo Ley 25.326)_: `id`, `response_id UNIQUE`, `business_id` _(trigger)_, `full_name`, `email`, `phone`, `preferred_channel` (`whatsapp`|`email`|`call`), `consent_at`, `status` (`pending`|`contacted`|`resolved`), `handled_by`, `handled_at`, `resolution_note`.

### `rescue_templates`, `rescue_cases` y vista `rescue_metrics`

- `rescue_templates`: `id`, `business_id` (`NULL` = plantilla global), `stars` (1–3), `channel` (`whatsapp`|`email`), `subject`, `body`, `updated_at`.
- `rescue_cases`: `id`, `business_id`, `response_id UNIQUE`, `contact_id` (`ON DELETE SET NULL`), `stars_snapshot`, `sla_due_at`, `status` (`open`|`contacted`|`resolved`|`dismissed`), `first_contacted_at`, `contact_channel`, `message_sent` _(borrado automáticamente por trigger si se elimina el contacto)_, `outcome` (`recovered`|`no_response`|`declined`), `resolved_at`, `resolved_by`, `avg_ticket_snapshot` _(congelado al crear el caso)_, `recovered_value`, `resolution_note`, `overdue_notified_at`.
- `rescue_metrics`: vista con `security_invoker = true` (respeta RLS por negocio).

---

## 3. Funciones RPC y Edge Functions Vigentes

| Función                                           | Rol habilitado                  | Propósito                                                                                                                                                                             |
| :------------------------------------------------ | :------------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `get_business_by_token(p_token)`                  | `anon`, `authenticated`         | Datos públicos del negocio, destino y `survey_questions` para `/f/:token`.                                                                                                            |
| `submit_feedback(...)`                            | `anon`, `authenticated`         | Alta atómica de opinión + contacto opcional + caso de rescate (honeypot, anti-flood 20/min, consentimiento).                                                                          |
| `check_recovery_account(p_email)`                 | `anon`                          | Verifica antes de `/recuperar` si existe un negocio activo o Super Admin con ese email (sin PII, con límite anti-abuso en `recovery_check_log`; revocada a `authenticated` en `014`). |
| `get_business_stats(p_days)`                      | `authenticated`                 | Métricas agregadas del panel del negocio (promedio, distribución, top tags).                                                                                                          |
| `get_my_supports()`                               | `authenticated`                 | Uso actual de soportes (`used`, `limit`, `plan_name`).                                                                                                                                |
| `create_branch_with_qr(p_branch_name, p_with_qr)` | `authenticated` (admin)         | Crea sucursal con o sin soporte respetando límite del plan.                                                                                                                           |
| `add_qr_to_branch(p_branch_id)`                   | `authenticated` (admin)         | Asigna un soporte libre a una sucursal propia.                                                                                                                                        |
| `move_qr_to_branch(p_qr_id, p_branch_id)`         | `authenticated` (admin)         | Reasigna un soporte existente a otra sucursal del mismo negocio sin cambiar el token NFC/QR.                                                                                          |
| `set_qr_active(p_qr_id, p_active)`                | `authenticated` (admin)         | Activa o desactiva un QR respetando límite de soportes.                                                                                                                               |
| `get_platform_overview()`                         | `authenticated` (`super_admin`) | Libro mayor agregado con datos del dueño B2B, `logo_url`, sucursales y primer token (0 datos de clientes finales).                                                                    |
| `get_business_diagnostics(p_business_id)`         | `authenticated` (`super_admin`) | Diagnóstico de solo lectura por negocio: onboarding, tendencia 7d/30d, top tags, Modo Rescate, sucursales y actividad reciente anonimizada (0 PII / 0 texto libre).                   |
| `super_list_kits()`                               | `authenticated` (`super_admin`) | Cola global de soportes físicos QR + NFC priorizando los pendientes de grabar/entregar, con uso agregado (0 PII).                                                                     |
| `super_update_kit(...)`                           | `authenticated` (`super_admin`) | Actualiza `nfc_status`, fecha de entrega (`delivered_at`), estado `active` (validando cupo del plan) y `kit_notes` de un soporte.                                                     |
| `super_create_kit(...)`                           | `authenticated` (`super_admin`) | Emite un soporte QR + NFC extra para un negocio existente (sucursal existente o nueva) respetando el cupo del plan.                                                                   |
| `admin_provision_business(...)`                   | **Solo `service_role`**         | Invocada por la Edge Function `create-business-account`: crea negocio + sucursal + primer QR + vínculo en `profiles`.                                                                 |
| `purge_expired_contacts(p_months)`                | **Solo SQL / `pg_cron`**        | Purga contactos resueltos > 12 meses (tope 24 meses) y limpia `rescue_cases.message_sent`.                                                                                            |

> `create_my_business()` fue revocada en la migración `009`: no existe auto-alta pública de negocios.
