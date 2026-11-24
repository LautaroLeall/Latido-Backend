// Verificación del contrato de Claves Foráneas (FK) y columnas entre Frontend y PostgreSQL.
import { PGlite } from '@electric-sql/pglite';
import { uuid_ossp } from '@electric-sql/pglite/contrib/uuid_ossp';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MIG_DIR = fileURLToPath(new URL('../supabase/migrations', import.meta.url));
const db = new PGlite({ extensions: { uuid_ossp, pgcrypto } });

await db.exec(`
  CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text, raw_user_meta_data jsonb DEFAULT '{}');
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  CREATE PUBLICATION supabase_realtime;
  CREATE SCHEMA storage;
  CREATE TABLE storage.buckets (id text PRIMARY KEY, name text NOT NULL, public boolean DEFAULT false, file_size_limit bigint, allowed_mime_types text[]);
  CREATE TABLE storage.objects (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), bucket_id text NOT NULL REFERENCES storage.buckets(id), name text NOT NULL);
  CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY[]::text[] $$;
`);

for (const f of fs.readdirSync(MIG_DIR).filter(f => f.endsWith('.sql')).sort()) {
  await db.exec(fs.readFileSync(path.join(MIG_DIR, f), 'utf8'));
}

const expectedFks = [
  'fk_profiles_business',
  'responses_branch_id_fkey',
  'response_contacts_response_id_fkey',
  'rescue_cases_response_id_fkey',
  'rescue_cases_contact_id_fkey',
  'rescue_cases_resolved_by_fkey'
];

const { rows } = await db.query(`SELECT conname FROM pg_constraint WHERE contype = 'f'`);
const names = new Set(rows.map(r => r.conname));
let fail = 0;

for (const n of expectedFks) {
  const ok = names.has(n);
  if (!ok) fail++;
  console.log(ok ? '  ✔' : '  ✘ FALTA', n);
}

const { rows: [q] } = await db.query(`SELECT count(*)::int n FROM pg_constraint WHERE contype='f' AND conrelid='public.qr_codes'::regclass AND confrelid='public.branches'::regclass`);
if (q.n !== 1) fail++;
console.log(q.n === 1 ? '  ✔' : '  ✘', `qr_codes→branches FKs: ${q.n}`);

const { rows: cols } = await db.query(`SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='public'`);
const has = (t, c) => cols.some(r => r.table_name === t && r.column_name === c);
const expectedCols = [
  ['businesses', 'active'],
  ['businesses', 'updated_at'],
  ['businesses', 'currency'],
  ['businesses', 'manager_name'],
  ['businesses', 'plan_id'],
  ['businesses', 'supports_override'],
  ['businesses', 'logo_url'],
  ['responses', 'business_id'],
  ['responses', 'branch_id'],
  ['rescue_cases', 'contact_channel'],
  ['rescue_metrics', 'within_sla'],
  ['survey_questions', 'options'],
  ['survey_questions', 'placeholder'],
  ['survey_questions', 'active'],
  ['qr_codes', 'delivered_at'],
  ['qr_codes', 'kit_notes']
];

for (const [t, c] of expectedCols) {
  const ok = has(t, c);
  if (!ok) fail++;
  console.log(ok ? '  ✔' : '  ✘ FALTA', `${t}.${c}`);
}

console.log(fail ? '\n✘ FALLA EN CONTRATO FRONTEND ↔ BASE' : '\n✔ Contrato frontend ↔ base OK');
process.exit(fail ? 1 : 0);
