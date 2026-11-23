# Documentación de Backend — LATIDO

Este directorio contiene la arquitectura de base de datos, políticas de seguridad, Edge Functions y bitácora técnica de **LATIDO**.

## Índice de Documentos

- [`BITACORA.md`](./BITACORA.md): Registro cronológico de migraciones (`001`–`012`), mejoras, incidentes y pruebas.
- [`ESQUEMA_BD.md`](./ESQUEMA_BD.md): Diagrama relacional, tablas, vistas, Storage (`business-logos`), funciones RPC y Edge Functions.
- [`POLITICAS_RLS.md`](./POLITICAS_RLS.md): Matriz vigente de permisos (doble capa: GRANTs mínimos + Row Level Security + Storage RLS) y aislamiento de datos personales.
- Verificación cloud (SQL solo lectura): [`../supabase/optional/verificar_estado_cloud.sql`](../supabase/optional/verificar_estado_cloud.sql).

> La suite automatizada de pruebas corre con `npm test` dentro de `Backend/` (**151 pruebas de migraciones y seguridad + 20 verificaciones de contrato + verificación UTF-8 + 8 pruebas de Edge Function y config**).
