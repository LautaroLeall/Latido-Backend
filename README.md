# LATIDO — Backend (PostgreSQL / Supabase)

> Base de datos multi-tenant, seguridad de doble capa (GRANTs mínimos + Row Level Security), RPCs transaccionales, Supabase Storage y Edge Functions de **LATIDO**.

- **App en producción:** https://latido-opinion.vercel.app/
- **Frontend:** https://github.com/LautaroLeall/Latido-Front

---

## Arquitectura de Seguridad y Privacidad (Ley 25.326)

- **Doble capa de seguridad:** `REVOKE ALL` + permisos mínimos (`anon` solo accede a `SELECT` en `plans` y 2 RPCs públicas: `get_business_by_token` y `submit_feedback`) + **100% de las tablas con RLS activo**.
- **Desacople de datos personales:** las opiniones anónimas (`responses`) viven separadas de los datos de contacto (`response_contacts`). El Super Admin nunca puede leer nombres, teléfonos, emails ni comentarios escritos por clientes finales.
- **Sin registro público:** `enable_signup = false` y `create_my_business()` revocada. Las cuentas de negocios las aprovisiona exclusivamente el Super Admin mediante la Edge Function `create-business-account` con validación estricta, CORS allowlist, límite de payload y rollback automático.
- **Logos multi-tenant (`011`):** bucket `business-logos` (máx. 2 MB, solo PNG/JPG/WebP, SVG bloqueado por XSS) con políticas RLS acotadas a `{business_id}/`.
- **Diagnóstico Super Admin (`012`):** RPC de solo lectura `get_business_diagnostics(p_business_id)` para acompañar a cada comercio con métricas agregadas y actividad estrictamente anonimizada.

---

## Migraciones (`supabase/migrations/`)

Ejecutables en orden (`001` a `012`); las migraciones `007`–`012` son idempotentes:

- `001`–`004`: esquema base, RLS inicial, Modo Rescate y plantillas semilla.
- `005`–`008`: seguridad multi-tenant, RPCs con anti-flood/honeypot, planes por soportes, purga de retención (12/24 meses) y permisos mínimos.
- `009`: provisión exclusiva por Super Admin (`admin_provision_business`).
- `010`: preguntas editables por negocio y libro mayor ampliado.
- `011`: Storage multi-tenant `business-logos`.
- `012`: diagnóstico detallado de solo lectura para Super Admin (`get_business_diagnostics`).

---

## Pruebas automatizadas

Corre sobre Postgres embebido (**PGlite**) sin necesidad de levantar Docker ni tocar la nube:

```bash
npm install
npm test
```

Valida automáticamente:

- **151 aserciones** de migraciones, idempotencia, RLS multi-tenant, antiescalada, Modo Rescate, Storage RLS, diagnóstico 0-PII y auditoría de catálogos Postgres.
- **20 verificaciones** de contrato de columnas y FKs con el Frontend.
- Auditoría de codificación **UTF-8** sin mojibake.
- Auditoría de seguridad de **Edge Functions** y `config.toml`.

## Documentación técnica

- [Índice de documentación](./Doc/README.md)
- [Esquema de Base de Datos y RPCs](./Doc/ESQUEMA_BD.md)
- [Políticas RLS y Seguridad](./Doc/POLITICAS_RLS.md)
- [Bitácora de migraciones](./Doc/BITACORA.md)
- [Diagnóstico de solo lectura en Supabase Cloud](./supabase/optional/verificar_estado_cloud.sql)
