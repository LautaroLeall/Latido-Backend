# Políticas de Seguridad, Permisos y RLS — LATIDO

> Modelo vigente tras las migraciones **`005`, `007`, `008`, `009`, `010` y `011`** (verificado con **142/142 pruebas automatizadas** en `npm test`).

---

## 1. Defensa en Profundidad (Doble Capa)

LATIDO aplica dos capas independientes de seguridad en PostgreSQL:

1. **Capa 1 — Permisos mínimos de tabla y función (`008` y `009`)**:
   - Se revocan todos los permisos heredados a `anon` y `authenticated`.
   - `anon` únicamente tiene `SELECT` sobre `public.plans` y `EXECUTE` sobre `get_business_by_token()` y `submit_feedback()`. Ninguna otra tabla ni RPC es accesible para `anon`.
   - `admin_provision_business()` solo es ejecutable por `service_role` (desde la Edge Function `create-business-account`).
   - `create_my_business()`, `generate_qr_token()`, `purge_expired_contacts()` y todos los triggers están revocados a `PUBLIC`, `anon` y `authenticated`.
2. **Capa 2 — Row Level Security (`005`, `007`, `011`)**:
   - **100% de las tablas en `public` tienen RLS habilitado.**
   - Funciones `SECURITY DEFINER` (`is_super_admin()`, `my_business_id()`, `is_business_admin()`) eliminan cualquier recursión RLS sobre `profiles`.
   - `business_id` en `responses` y `response_contacts` se asigna en triggers del servidor (`tg_responses_set_tenant`, `tg_contacts_set_tenant`), nunca desde el cliente.

---

## 2. Matriz de Acceso por Rol

| Recurso                     | Anónimo (`anon`)                        | Negocio (`admin` / `employee`)                                                 | Super Admin (`super_admin`)                                            |
| :-------------------------- | :-------------------------------------- | :----------------------------------------------------------------------------- | :--------------------------------------------------------------------- |
| `plans`                     | `SELECT` (solo activos)                 | `SELECT` (activos + propio)                                                    | `SELECT / INSERT / UPDATE / DELETE`                                    |
| `profiles`                  | **Sin permiso**                         | `SELECT` de su negocio; `UPDATE` solo `full_name` propio                       | `SELECT / UPDATE` todos                                                |
| `businesses`                | **Sin permiso** (vía RPC)               | `SELECT` propio; `admin` hace `UPDATE` de config/nombre/logo                   | `SELECT / INSERT / UPDATE / DELETE`                                    |
| `branches`                  | **Sin permiso**                         | `SELECT` propias; `admin` edita propias (alta vía RPC)                         | `SELECT` todas                                                         |
| `qr_codes`                  | **Sin permiso** (vía RPC)               | `SELECT` propios (alta/movimiento/estado vía RPC)                              | `SELECT` todos                                                         |
| `survey_questions`          | **Sin permiso** (vía RPC)               | `SELECT` propias; `admin` CRUD propio                                          | **Sin acceso**                                                         |
| `responses` _(anónima)_     | **Solo INSERT vía `submit_feedback()`** | `SELECT` solo de su negocio                                                    | **Sin acceso a comentarios** (agregados vía `get_platform_overview()`) |
| `response_contacts` _(PII)_ | **Solo INSERT vía `submit_feedback()`** | `SELECT / UPDATE` propios; `admin` puede `DELETE` (Ley 25.326)                 | **BLOQUEADO (0 filas)**                                                |
| `rescue_cases`              | **Solo INSERT vía `submit_feedback()`** | `SELECT / UPDATE` propios (con guardas de estado y snapshot)                   | **Sin acceso directo**                                                 |
| `rescue_templates`          | **Sin permiso**                         | `SELECT` globales + propias; `admin` CRUD propias                              | `SELECT` todas; CRUD globales                                          |
| `rescue_metrics` _(view)_   | **Sin permiso**                         | `SELECT` propio (`security_invoker = true`)                                    | **Sin acceso directo**                                                 |
| Storage `business-logos`    | `SELECT` público (para el ticket)       | `admin` `INSERT/UPDATE/DELETE` solo en `{business_id}/` (PNG/JPG/WebP, ≤ 2 MB) | `INSERT/UPDATE/DELETE`                                                 |

---

## 3. Guardas Anti-Escalada y Privacidad (Ley 25.326)

- **Escalada bloqueada por triggers**:
  - `handle_new_user()` crea todos los perfiles nuevos como `'admin'` (ignora cualquier rol en metadata).
  - `tg_profiles_protect()` impide que un usuario cambie su `role` o `business_id`.
  - `tg_businesses_protect()` impide que un admin de negocio cambie `owner_id`, `plan_id`, `supports_override` o `active`.
- **Integridad de Modo Rescate**:
  - `tg_rescue_cases_guard()` congela `avg_ticket_snapshot` y `sla_due_at`, sella `first_contacted_at` / `resolved_by` en el servidor y prohíbe reabrir casos cerrados.
- **Derecho de supresión y retención**:
  - Al borrar un contacto de `response_contacts` (manualmente o vía `purge_expired_contacts()` a los 12 meses de resuelto / tope 24 meses), `tg_rescue_cases_erase_message()` borra también `rescue_cases.message_sent`, conservando únicamente las métricas anónimas.
