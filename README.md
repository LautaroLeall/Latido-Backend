# LATIDO — Backend (PostgreSQL / Supabase)

> Base de datos multi-tenant, seguridad de doble capa (GRANTs mínimos + Row Level Security), RPCs transaccionales, Supabase Storage y Edge Functions de **LATIDO**.

- **App en producción:** https://latido-opinion.vercel.app/
- **Frontend:** https://github.com/LautaroLeall/Latido-Front

---

## Arquitectura de Seguridad y Privacidad (Ley 25.326)

- **Doble capa de seguridad:** `REVOKE ALL` + permisos mínimos (`anon` solo accede a `SELECT` en `plans` y 3 RPCs públicas: `get_business_by_token`, `submit_feedback` y `check_recovery_account`) + **100% de las tablas con RLS activo**.
- **Desacople de datos personales:** las opiniones anónimas (`responses`) viven separadas de los datos de contacto (`response_contacts`). El Super Admin nunca puede leer nombres, teléfonos, emails ni comentarios escritos por clientes finales.
- **Sin registro público:** `enable_signup = false` y `create_my_business()` revocada. Las cuentas de negocios las aprovisiona exclusivamente el Super Admin mediante la Edge Function `create-business-account` con validación estricta, CORS allowlist, límite de payload y rollback automático.
- **Logos multi-tenant (`011` + `014`):** bucket `business-logos` (máx. 2 MB, solo PNG/JPG/WebP, SVG bloqueado por XSS) sin listado público; `SELECT/INSERT/UPDATE/DELETE` acotados a `{business_id}/` (o Super Admin).
- **Diagnóstico y gestión operativa Super Admin (`012`, `015`, `016`):** diagnóstico de solo lectura 0-PII (`get_business_diagnostics`), ciclo completo de armado/grabación NFC/entrega de kits físicos (`super_list_kits`, `super_update_kit`, `super_create_kit`) y edición de nombres de sucursales por Admin y Super Admin (`tg_branches_protect`).

---

## Migraciones (`supabase/migrations/`)

Ejecutables en orden (`001` a `016`); las migraciones `007`–`016` son idempotentes:

- `001`–`004`: esquema base, RLS inicial, Modo Rescate y plantillas semilla.
- `005`–`008`: seguridad multi-tenant, RPCs con anti-flood/honeypot, planes por soportes, purga de retención (12/24 meses) y permisos mínimos.
- `009`: provisión exclusiva por Super Admin (`admin_provision_business`).
- `010`: preguntas editables por negocio y libro mayor ampliado.
- `011`: Storage multi-tenant `business-logos`.
- `012`: diagnóstico detallado de solo lectura para Super Admin (`get_business_diagnostics`).
- `013`: verificación segura de cuenta antes de enviar recuperación de contraseña (`check_recovery_account`).
- `014`: endurecimiento de Storage `business-logos` (sin listado público; `SELECT` acotado por tenant) y `check_recovery_account` revocada a `authenticated`.
- `015`: gestión operativa de kits físicos QR + NFC por Super Admin (`delivered_at`, `kit_notes`, `super_list_kits`, `super_update_kit`, `super_create_kit`).
- `016`: edición del nombre de sucursales por Admin del negocio y Super Admin (`branches_update` + `tg_branches_protect`).

---

## Pruebas automatizadas

Corre sobre Postgres embebido (**PGlite**) sin necesidad de levantar Docker ni tocar la nube:

```bash
npm install
npm test
```

Valida automáticamente:

- **188 aserciones** de migraciones, idempotencia, RLS multi-tenant, antiescalada, Modo Rescate, Storage RLS, diagnóstico 0-PII, recuperación verificada, gestión de kits, renombrado de sucursales y auditoría de catálogos Postgres.
- **23 verificaciones** de contrato de columnas y FKs con el Frontend.
- Auditoría de codificación **UTF-8** sin mojibake.
- Auditoría de seguridad de **Edge Functions** y `config.toml`.

## Documentación técnica

- [Índice de documentación](./Doc/README.md)
- [Esquema de Base de Datos y RPCs](./Doc/ESQUEMA_BD.md)
- [Políticas RLS y Seguridad](./Doc/POLITICAS_RLS.md)
- [Bitácora de migraciones](./Doc/BITACORA.md)
- [Diagnóstico de solo lectura en Supabase Cloud](./supabase/optional/verificar_estado_cloud.sql)
