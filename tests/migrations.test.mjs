// Banco de pruebas de migraciones LATIDO sobre Postgres (PGlite) con stubs de Supabase.
// Verifica: sintaxis, aislamiento multi-tenant, escalada de privilegios, RPCs, Modo Rescate y Storage RLS.
import { PGlite } from '@electric-sql/pglite';
import { uuid_ossp } from '@electric-sql/pglite/contrib/uuid_ossp';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MIG_DIR = fileURLToPath(new URL('../supabase/migrations', import.meta.url));
const db = new PGlite({ extensions: { uuid_ossp, pgcrypto } });

let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; console.log('  ✔', msg); } else { fail++; console.log('  ✘ FALLA:', msg); } };

async function as(role, uid, fn) {
  return db.transaction(async (tx) => {
    await tx.exec(`SET LOCAL ROLE ${role}`);
    await tx.query(`SELECT set_config('request.jwt.claim.sub', $1, true)`, [uid || '']);
    return fn(tx);
  });
}
async function expectError(promise, msg, includes) {
  try { await promise; ok(false, msg + ' (no lanzó error)'); }
  catch (e) { ok(!includes || e.message.includes(includes), `${msg} → "${e.message}"`); }
}

// ── Stubs mínimos del entorno Supabase ───────────────────────────────────────
await db.exec(`
  CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;
  CREATE SCHEMA auth;
  CREATE TABLE auth.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text, raw_user_meta_data jsonb DEFAULT '{}', last_sign_in_at timestamptz);
  CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
    $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  GRANT USAGE ON SCHEMA auth TO anon, authenticated;
  GRANT USAGE ON SCHEMA public TO service_role;
  GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated;
  CREATE PUBLICATION supabase_realtime;
  CREATE SCHEMA storage;
  CREATE TABLE storage.buckets (
    id text PRIMARY KEY,
    name text NOT NULL,
    public boolean DEFAULT false,
    file_size_limit bigint,
    allowed_mime_types text[]
  );
  CREATE TABLE storage.objects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id text NOT NULL REFERENCES storage.buckets(id),
    name text NOT NULL
  );
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS
    $$ SELECT CASE WHEN strpos(name, '/') > 0 THEN string_to_array(left(name, length(name) - length(split_part(reverse(name), '/', 1)) - 1), '/') ELSE ARRAY[]::text[] END $$;
  GRANT USAGE ON SCHEMA storage TO anon, authenticated, service_role;
  GRANT SELECT ON storage.buckets TO anon, authenticated;
  GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO anon, authenticated;
  GRANT USAGE ON SCHEMA public TO anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated;
`);

// ── Aplicar migraciones en orden ─────────────────────────────────────────────
console.log('\n[1] Aplicando migraciones');
for (const f of fs.readdirSync(MIG_DIR).filter(f => f.endsWith('.sql')).sort()) {
  try { await db.exec(fs.readFileSync(path.join(MIG_DIR, f), 'utf8')); ok(true, f); }
  catch (e) { ok(false, `${f}: ${e.message}`); console.log('\nAbortado.'); process.exit(1); }
}
for (const f of ['007_planes_soportes_y_privacidad.sql', '008_permisos_minimos.sql', '009_alta_de_negocios_por_super_admin.sql', '010_encuesta_y_gestion_completa.sql', '011_logos_negocios.sql', '012_super_admin_diagnostico.sql']) {
  try { await db.exec(fs.readFileSync(path.join(MIG_DIR, f), 'utf8')); ok(true, `${f} es idempotente`); }
  catch (e) { ok(false, `${f} re-ejecución: ${e.message}`); }
}

// ── Usuarios ─────────────────────────────────────────────────────────────────
console.log('\n[2] Registro y perfiles');
const { rows: [ua] } = await db.query(`INSERT INTO auth.users (email, raw_user_meta_data) VALUES ('sofia@sol.com', '{"full_name":"Sofía Pérez","role":"super_admin"}') RETURNING id`);
const { rows: [ub] } = await db.query(`INSERT INTO auth.users (email) VALUES ('gym@levels.com') RETURNING id`);
const { rows: [us] } = await db.query(`INSERT INTO auth.users (email) VALUES ('root@latido.app') RETURNING id`);
const A = ua.id, B = ub.id, S = us.id;
const { rows: [pa] } = await db.query(`SELECT role, full_name FROM public.profiles WHERE id = $1`, [A]);
ok(pa.role === 'admin', `Intento de registrarse como super_admin vía metadata → rol real: ${pa.role}`);
ok(pa.full_name === 'Sofía Pérez', 'full_name tomado del registro');
const { rows: [pb] } = await db.query(`SELECT full_name FROM public.profiles WHERE id = $1`, [B]);
ok(pb.full_name === 'gym', `Sin nombre → usa parte del email (${pb.full_name})`);

const prof = await as('authenticated', A, tx => tx.query(`SELECT * FROM public.profiles`));
ok(prof.rows.length === 1, 'Login: SELECT profiles sin recursión RLS y solo el propio');

// ── Alta inicial de negocios (auto-alta cerrado; solo vía service_role) ──────
console.log('\n[3] Alta de negocios (auto-alta bloqueado)');
await expectError(as('authenticated', A, tx => tx.query(`SELECT public.create_my_business('Auto')`)), 'Authenticated NO puede auto-crear negocio (create_my_business revocada)', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT public.create_my_business('X')`)), 'Anon NO puede auto-crear negocio', 'permission denied');
const ra = await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Cafetería del Sol', 'Sucursal Centro', 'Sofía') AS r`, [A]));
const tokenA = ra.rows[0].r.token;
ok(/^cafeteria-del-sol-suc-?[a-z-]*-[0-9a-f]{12}$/.test(tokenA) || /-[0-9a-f]{12}$/.test(tokenA), `Token A seguro: ${tokenA}`);
const rb = await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Levels GYM') AS r`, [B]));
const tokenB = rb.rows[0].r.token;
ok(!!tokenB, `Token B: ${tokenB}`);
await expectError(as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Otro')`, [A])), 'No puede crear un 2º negocio para la misma cuenta', 'ya tiene');

// ── Público anónimo ──────────────────────────────────────────────────────────
console.log('\n[4] Cliente anónimo (QR / NFC)');
const biz = await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token($1) AS b`, [tokenA]));
ok(biz.rows[0].b.token_valid === true && biz.rows[0].b.business_name === 'Cafetería del Sol', 'get_business_by_token devuelve el negocio');
ok(!('owner_id' in biz.rows[0].b) && !('business_id' in biz.rows[0].b), 'No expone owner_id ni business_id');
const bad = await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token('sol-centro-01') AS b`));
ok(bad.rows[0].b.token_valid === false, 'Token adivinable → inválido');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.qr_codes`)), 'Anon NO puede listar tokens de qr_codes (sin permiso de tabla)', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.businesses`)), 'Anon NO puede listar negocios (sin permiso de tabla)', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.profiles`)), 'Anon NO puede leer perfiles', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.response_contacts`)), 'Anon NO puede leer contactos de clientes', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.rescue_cases`)), 'Anon NO puede leer casos de rescate', 'permission denied');
const { rows: [knownQr] } = await db.query(`SELECT id FROM public.qr_codes WHERE token = $1`, [tokenA]);
await expectError(as('anon', null, tx => tx.query(`INSERT INTO public.responses (qr_code_id, stars) VALUES ($1, 1)`, [knownQr.id])), 'Anon NO puede insertar respuestas salteando la RPC', 'permission denied');
await expectError(as('authenticated', B, tx => tx.query(`INSERT INTO public.responses (qr_code_id, stars) VALUES ($1, 1)`, [knownQr.id])), 'Otro negocio NO puede inyectar respuestas falsas', 'permission denied');
await expectError(as('authenticated', A, tx => tx.query(`SELECT public.generate_qr_token('x')`)), 'generate_qr_token no es invocable desde la API', 'permission');

const sub = (args) => as('anon', null, tx => tx.query(
  `SELECT public.submit_feedback($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) AS r`, args));
const r1 = await sub([tokenA, 2, ['Rapidez', 'Rapidez', ' '], 'Tardaron mucho', 'Martín Gómez', 'Martin@Mail.com', '+54 9 381 555-1234', 'whatsapp', true, null]);
ok(r1.rows[0].r.rescue === true, '2★ con contacto → abre caso de rescate');
const r2 = await sub([tokenA, 5, ['Atención'], 'Excelente', null, null, null, 'whatsapp', false, null]);
ok(r2.rows[0].r.rescue === false, '5★ anónima → sin rescate');
await sub([tokenA, 1, [], null, null, null, null, 'whatsapp', false, 'http://spam.bot']);
await expectError(sub([tokenA, 1, [], null, 'Juan Pérez', 'juan@x.com', null, 'email', false, null]), 'Contacto sin consentimiento rechazado', 'consentimiento');
await expectError(sub([tokenA, 1, [], null, 'Juan Pérez', 'no-es-mail', null, 'email', true, null]), 'Email inválido rechazado', 'email');
await expectError(sub([tokenA, 7, [], null, null, null, null, 'whatsapp', false, null]), 'Estrellas fuera de rango rechazadas');
await expectError(sub(['token-falso', 3, [], null, null, null, null, 'whatsapp', false, null]), 'Token falso rechazado', 'no válido');
const r3 = await sub([tokenB, 1, [], 'Máquinas rotas', 'Laura Díaz', null, '3815550000', 'email', true, null]);
ok(r3.rows[0].r.rescue === true, 'Negocio B recibe su propio caso');

const { rows: [cnt] } = await db.query(`SELECT count(*)::int n FROM public.responses`);
ok(cnt.n === 3, `Honeypot descartó el bot (respuestas guardadas: ${cnt.n})`);
const { rows: [ct] } = await db.query(`SELECT email, phone, preferred_channel FROM public.response_contacts WHERE full_name = 'Martín Gómez'`);
ok(ct.email === 'martin@mail.com' && ct.phone === '5493815551234', `Contacto normalizado (${ct.email}, ${ct.phone})`);
const { rows: [ctb] } = await db.query(`SELECT preferred_channel FROM public.response_contacts WHERE full_name = 'Laura Díaz'`);
ok(ctb.preferred_channel === 'whatsapp', 'Canal email sin email → se corrige a whatsapp');
const { rows: [tg] } = await db.query(`SELECT tags FROM public.responses WHERE comment = 'Tardaron mucho'`);
ok(tg.tags.length === 1, `Tags deduplicadas y saneadas (${tg.tags})`);

// ── Aislamiento entre negocios ───────────────────────────────────────────────
console.log('\n[5] Aislamiento multi-tenant');
const q = (uid, sql) => as('authenticated', uid, tx => tx.query(sql));
ok((await q(A, `SELECT * FROM public.responses`)).rows.length === 2, 'A ve solo sus 2 respuestas');
ok((await q(B, `SELECT * FROM public.responses`)).rows.length === 1, 'B ve solo su 1 respuesta');
ok((await q(B, `SELECT * FROM public.response_contacts`)).rows.every(r => r.full_name === 'Laura Díaz'), 'B no ve contactos de A');
ok((await q(B, `SELECT * FROM public.rescue_cases`)).rows.length === 1, 'B ve solo su caso de rescate');
ok((await q(B, `SELECT * FROM public.businesses`)).rows.length === 1, 'B ve solo su negocio');
ok((await q(B, `SELECT * FROM public.qr_codes`)).rows.length === 1, 'B ve solo su QR');
const upd = await q(B, `UPDATE public.businesses SET name = 'Hackeado' WHERE name = 'Cafetería del Sol' RETURNING id`);
ok(upd.rows.length === 0, 'B no puede modificar el negocio de A');
const updc = await q(B, `UPDATE public.rescue_cases SET status = 'dismissed' WHERE business_id <> public.my_business_id() RETURNING id`);
ok(updc.rows.length === 0, 'B no puede tocar casos de A');
const stats = await q(A, `SELECT public.get_business_stats(7) AS s`);
ok(stats.rows[0].s.total === 2 && Number(stats.rows[0].s.avg) === 3.5 && stats.rows[0].s.low === 1, `Stats de A: ${JSON.stringify(stats.rows[0].s)}`);
ok((await q(A, `SELECT * FROM public.rescue_templates`)).rows.length === 6, 'A lee las 6 plantillas globales');
const { rows: [tpl] } = await db.query(`SELECT body FROM public.rescue_templates WHERE channel='email' AND stars=1`);
ok(tpl.body.includes('\n') && !tpl.body.includes('\\n'), 'Plantillas con saltos de línea reales');

// ── Escalada de privilegios ──────────────────────────────────────────────────
console.log('\n[6] Escalada de privilegios');
await expectError(q(A, `UPDATE public.profiles SET role = 'super_admin' WHERE id = auth.uid()`), 'Admin no puede auto-ascenderse a super_admin', 'permiso');
await expectError(q(A, `UPDATE public.profiles SET business_id = (SELECT business_id FROM public.profiles WHERE id='${B}') WHERE id = auth.uid()`), 'Admin no puede mudarse al negocio de otro', 'permiso');
await expectError(q(A, `UPDATE public.businesses SET plan_id = (SELECT id FROM public.plans WHERE code = 'premium')`), 'Admin no puede auto-asignarse un plan superior', 'permiso');
await expectError(q(A, `UPDATE public.businesses SET supports_override = 99`), 'Admin no puede auto-asignarse soportes', 'permiso');
const okName = await q(A, `UPDATE public.profiles SET full_name = 'Sofía P.' WHERE id = auth.uid() RETURNING full_name`);
ok(okName.rows[0]?.full_name === 'Sofía P.', 'Admin sí puede editar su nombre');
const okCfg = await q(A, `UPDATE public.businesses SET avg_ticket_value = 8500, rescue_sla_minutes = 30 RETURNING avg_ticket_value`);
ok(Number(okCfg.rows[0]?.avg_ticket_value) === 8500, 'Admin sí puede editar su configuración');
await expectError(q(A, `UPDATE public.businesses SET google_review_url = 'javascript:alert(1)'`), 'URL de Google maliciosa rechazada');

// ── Modo Rescate ─────────────────────────────────────────────────────────────
console.log('\n[7] Modo Rescate: integridad');
const c1 = await q(A, `UPDATE public.rescue_cases SET status='contacted', message_sent='Hola Martín' RETURNING first_contacted_at, status`);
ok(c1.rows[0].first_contacted_at !== null, 'Al contactar se sella first_contacted_at en el servidor');
const c2 = await q(A, `UPDATE public.rescue_cases SET status='resolved', outcome='recovered', recovered_value=9999999, sla_due_at=now()+interval '9 days' RETURNING recovered_value, avg_ticket_snapshot, sla_due_at, resolved_by`);
ok(Number(c2.rows[0].recovered_value) === Number(c2.rows[0].avg_ticket_snapshot), `recovered_value forzado al snapshot (${c2.rows[0].recovered_value}), no al valor inventado`);
ok(Number(c2.rows[0].avg_ticket_snapshot) === 0, 'avg_ticket_snapshot se congeló al crear el caso (0), no al subir ticket promedio después (8500)');
ok(c2.rows[0].resolved_by === A, 'resolved_by = usuario que cerró');
await expectError(q(A, `UPDATE public.rescue_cases SET status='open'`), 'Un caso cerrado no se reabre', 'cerrado');
const { rows: [cs] } = await db.query(`SELECT status FROM public.response_contacts WHERE full_name='Martín Gómez'`);
ok(cs.status === 'resolved', 'Estado del contacto sincronizado con el caso');
const met = await q(A, `SELECT * FROM public.rescue_metrics`);
ok(met.rows.length === 1 && Number(met.rows[0].recovered) === 1, 'Vista rescue_metrics respeta RLS y calcula');
const del = await q(A, `DELETE FROM public.response_contacts RETURNING id`);
ok(del.rows.length === 1, 'Derecho de supresión: admin borra datos personales');
const { rows: [erased] } = await db.query(`SELECT message_sent, contact_id FROM public.rescue_cases WHERE business_id = (SELECT business_id FROM public.profiles WHERE id = $1)`, [A]);
ok(erased.contact_id === null && erased.message_sent === null, `PRIVACIDAD: al borrar el contacto también se borra el mensaje enviado (message_sent=${erased.message_sent})`);
ok((await q(A, `SELECT * FROM public.responses`)).rows.length === 2, '…y las respuestas anónimas se conservan');

// ── Super Admin ──────────────────────────────────────────────────────────────
console.log('\n[8] Super Admin');
ok((await q(A, `SELECT * FROM public.get_platform_overview()`)).rows.length === 0, 'Admin común no ve el libro mayor');
await db.query(`UPDATE public.profiles SET role='super_admin' WHERE id=$1`, [S]);
const ov = await q(S, `SELECT * FROM public.get_platform_overview()`);
ok(ov.rows.length === 2, `Super ve los 2 negocios en el libro mayor`);
ok((await q(S, `SELECT * FROM public.responses`)).rows.length === 0, 'Super NO lee comentarios de clientes');
ok((await q(S, `SELECT * FROM public.response_contacts`)).rows.length === 0, 'Super NO lee datos personales (Ley 25.326)');
const sus = await q(S, `UPDATE public.businesses SET active=false WHERE name='Levels GYM' RETURNING active`);
ok(sus.rows[0]?.active === false, 'Super puede suspender un negocio');
const susp = await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token($1) AS b`, [tokenB]));
ok(susp.rows[0].b.token_valid === false, 'QR de negocio suspendido deja de funcionar');

// ── QR / sucursales ──────────────────────────────────────────────────────────
console.log('\n[9] Sucursales y QR');
await expectError(q(A, `SELECT public.create_branch_with_qr('Sucursal Norte')`), 'Plan Base: no se puede usar un 2º soporte', 'soportes');
await q(S, `UPDATE public.businesses SET plan_id = (SELECT id FROM public.plans WHERE code='plus') WHERE name = 'Cafetería del Sol'`);
const br = await q(A, `SELECT public.create_branch_with_qr('Sucursal Norte') AS r`);
ok(!!br.rows[0].r.token, `Nueva sucursal con token ${br.rows[0].r.token}`);
const qrId = (await q(A, `SELECT id FROM public.qr_codes WHERE token = '${tokenA}'`)).rows[0].id;
await q(A, `SELECT public.set_qr_active('${qrId}', false)`);
ok((await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token($1) AS b`, [tokenA]))).rows[0].b.token_valid === false, 'QR desactivado deja de responder');
await q(A, `SELECT public.set_qr_active('${qrId}', true)`);
await expectError(q(B, `SELECT public.set_qr_active('${qrId}', false)`), 'B no puede desactivar el QR de A', 'no encontrado');

// ── Planes, soportes y retención ─────────────────────────────────────────────
console.log('\n[10] Planes, soportes y retención');
const pubPlans = await as('anon', null, tx => tx.query(`SELECT code, name, supports, price_monthly FROM public.plans ORDER BY sort_order`));
ok(pubPlans.rows.length === 4 && Number(pubPlans.rows[0].price_monthly) === 50000 && pubPlans.rows[1].supports === 3 && Number(pubPlans.rows[2].price_monthly) === 175000, 'Landing (anon) lee los 4 planes con sus precios');
await expectError(as('anon', null, tx => tx.query(`UPDATE public.plans SET price_monthly = 1 RETURNING id`)), 'Anon no puede modificar planes (sin permiso de escritura)', 'permission denied');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.rescue_metrics`)), 'Anon no puede leer métricas', 'permission denied');
const noW = await q(A, `UPDATE public.plans SET price_monthly = 1 RETURNING id`);
ok(noW.rows.length === 0, 'Admin de negocio no puede modificar planes');
await expectError(q(A, `INSERT INTO public.plans (code, name, supports, price_monthly) VALUES ('hack','Hack',1,1)`), 'Admin de negocio no puede crear planes', 'row-level security');
const sp = await q(S, `UPDATE public.plans SET price_monthly = 55000, name = 'Plan Inicial' WHERE code = 'base' RETURNING price_monthly, name`);
ok(Number(sp.rows[0]?.price_monthly) === 55000 && sp.rows[0]?.name === 'Plan Inicial', 'Super Admin edita nombre y precio de un plan');
await q(S, `UPDATE public.plans SET price_monthly = 50000, name = 'Plan Base' WHERE code = 'base'`);
await q(S, `UPDATE public.plans SET active = false WHERE code = 'custom'`);
ok((await as('anon', null, tx => tx.query(`SELECT 1 FROM public.plans`))).rows.length === 3, 'Plan desactivado desaparece de la landing');
await q(S, `UPDATE public.plans SET active = true WHERE code = 'custom'`);
await expectError(q(S, `INSERT INTO public.plans (code, name, supports, price_monthly) VALUES ('x1','X',NULL,NULL)`), 'Plan no personalizado exige soportes y precio', 'chk_plan_complete');

const sup = await q(A, `SELECT public.get_my_supports() AS s`);
ok(sup.rows[0].s.limit === 3 && sup.rows[0].s.used === 2 && sup.rows[0].s.plan_name === 'Plan Plus', `Uso de soportes de A: ${JSON.stringify(sup.rows[0].s)}`);
await q(A, `SELECT public.create_branch_with_qr('Sucursal Sur')`);
ok((await q(A, `SELECT public.get_my_supports() AS s`)).rows[0].s.used === 3, 'Se usa el 3º soporte del Plan Plus (3/3)');
await expectError(q(A, `SELECT public.create_branch_with_qr('Sucursal Este')`), 'Con 3/3 soportes en uso no se crea otro QR', 'soportes');
const noQr = await q(A, `SELECT public.create_branch_with_qr('Sucursal Oeste', false) AS r`);
ok(noQr.rows[0].r.token === null, 'Se puede crear una sucursal SIN soporte');
const brOeste = (await q(A, `SELECT id FROM public.branches WHERE name = 'Sucursal Oeste'`)).rows[0].id;
await expectError(q(A, `SELECT public.add_qr_to_branch('${brOeste}')`), 'Sin soportes libres no se asigna otro', 'soportes');
const qrNorte = (await q(A, `SELECT q.id FROM public.qr_codes q JOIN public.branches b ON b.id=q.branch_id WHERE b.name='Sucursal Norte'`)).rows[0].id;
await q(A, `SELECT public.move_qr_to_branch('${qrNorte}', '${brOeste}')`);
ok((await q(A, `SELECT 1 FROM public.qr_codes WHERE id='${qrNorte}' AND branch_id='${brOeste}'`)).rows.length === 1, 'Un soporte se mueve a otra sucursal del mismo negocio');
const brB = (await q(B, `SELECT id FROM public.branches LIMIT 1`)).rows[0]?.id;
await expectError(q(A, `SELECT public.move_qr_to_branch('${qrNorte}', '${brB}')`), 'No se puede mover un soporte a una sucursal de OTRO negocio', 'no encontrada');
await expectError(q(B, `SELECT public.move_qr_to_branch('${qrNorte}', '${brB}')`), 'B no puede mover el soporte de A', 'no encontrado');
await q(S, `UPDATE public.businesses SET plan_id = (SELECT id FROM public.plans WHERE code='custom'), supports_override = 7 WHERE name = 'Cafetería del Sol'`);
ok((await q(A, `SELECT public.get_my_supports() AS s`)).rows[0].s.limit === 7, 'Plan personalizado: el Super fija 7 soportes a mano');
await q(S, `UPDATE public.businesses SET plan_id = (SELECT id FROM public.plans WHERE code='base'), supports_override = NULL WHERE name = 'Cafetería del Sol'`);
await expectError(q(S, `DELETE FROM public.plans WHERE code = 'base'`), 'No se puede borrar un plan en uso', 'foreign key');
ok((await q(S, `SELECT * FROM public.get_platform_overview()`)).rows.every(r => r.plan_name && r.supports_limit >= 0), 'Libro mayor incluye plan y soportes');

// Retención: contactos resueltos > 12 meses se purgan y borran message_sent; los recientes no
await sub([tokenA, 1, [], 'Retención 1', 'Ana Vieja', 'ana@x.com', null, 'email', true, null]);
await sub([tokenA, 1, [], 'Retención 2', 'Beto Nuevo', 'beto@x.com', null, 'email', true, null]);
await db.query(`UPDATE public.rescue_cases SET message_sent = 'Hola Ana Vieja' WHERE contact_id = (SELECT id FROM public.response_contacts WHERE full_name = 'Ana Vieja')`);
await db.query(`UPDATE public.response_contacts SET status='resolved', handled_at = now() - interval '13 months' WHERE full_name = 'Ana Vieja'`);
await db.query(`UPDATE public.response_contacts SET status='resolved', handled_at = now() - interval '2 months' WHERE full_name = 'Beto Nuevo'`);
const purged = (await db.query(`SELECT public.purge_expired_contacts() AS n`)).rows[0].n;
const left = (await db.query(`SELECT full_name FROM public.response_contacts WHERE full_name IN ('Ana Vieja','Beto Nuevo')`)).rows.map(r => r.full_name);
ok(purged >= 1 && !left.includes('Ana Vieja') && left.includes('Beto Nuevo'), `Retención 12 meses: purgó ${purged}, conserva al reciente (${left})`);
const { rows: [purgedMsg] } = await db.query(`SELECT message_sent FROM public.rescue_cases WHERE response_id = (SELECT id FROM public.responses WHERE comment = 'Retención 1')`);
ok(purgedMsg.message_sent === null, 'Purga 12 meses también limpia rescue_cases.message_sent');
await expectError(q(A, `SELECT public.purge_expired_contacts()`), 'La purga no es invocable desde la API', 'permission');
const { rows: [stillAnon] } = await db.query(`SELECT count(*)::int n FROM public.responses WHERE comment = 'Retención 1'`);
ok(stillAnon.n === 1, 'La opinión anónima se conserva tras purgar el contacto');

console.log('\n[11] Alta de negocios por el Super Admin');
const { rows: [uc] } = await db.query(`INSERT INTO auth.users (email, raw_user_meta_data) VALUES ('nuevo@cliente.com', '{"full_name":"Carla Nuevo"}') RETURNING id`);
const C = uc.id;
await expectError(as('anon', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Hack')`, [C])), 'Anon NO puede dar de alta negocios', 'permission denied');
await expectError(q(A, `SELECT public.admin_provision_business('${C}', 'Hack')`), 'Un admin de negocio NO puede dar de alta negocios', 'permission denied');
await expectError(q(S, `SELECT public.admin_provision_business('${C}', 'Hack')`), 'Ni el Super desde la API: solo la Edge Function (service_role)', 'permission denied');
const planPlus = (await db.query(`SELECT id FROM public.plans WHERE code = 'plus'`)).rows[0].id;
const prov = await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Panadería Luna', 'Sucursal Sur', NULL, $2) AS r`, [C, planPlus]));
ok(!!prov.rows[0].r.token && !!prov.rows[0].r.business_id, `service_role crea negocio + sucursal + QR (token ${prov.rows[0].r.token})`);
const { rows: [pc] } = await db.query(`SELECT business_id, role FROM public.profiles WHERE id = $1`, [C]);
ok(pc.business_id === prov.rows[0].r.business_id && pc.role === 'admin', 'La cuenta queda vinculada a su negocio como admin');
const mine = await q(C, `SELECT b.name, p.name AS plan, b.manager_name FROM public.businesses b JOIN public.plans p ON p.id = b.plan_id`);
ok(mine.rows.length === 1 && mine.rows[0].name === 'Panadería Luna' && mine.rows[0].plan === 'Plan Plus' && mine.rows[0].manager_name === 'Carla', `El dueño ve SOLO su negocio con el plan elegido (${mine.rows[0]?.plan}, firma ${mine.rows[0]?.manager_name})`);
ok((await q(C, `SELECT public.get_my_supports() AS s`)).rows[0].s.limit === 3, 'Plan Plus = 3 soportes');
await expectError(as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Otra vez')`, [C])), 'No se puede dar un 2º negocio a la misma cuenta', 'ya tiene');
await expectError(as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Fantasma')`, [crypto.randomUUID()])), 'Cuenta inexistente rechazada', 'no existe');
await expectError(as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'X')`, [S])), 'No se le crea negocio a un Super Admin', 'administrador de negocio');
const { rows: [ud] } = await db.query(`INSERT INTO auth.users (email) VALUES ('base@cliente.com') RETURNING id`);
const provBase = await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Kiosco Sol') AS r`, [ud.id]));
const planOfBase = (await db.query(`SELECT p.code FROM public.businesses b JOIN public.plans p ON p.id=b.plan_id WHERE b.id = $1`, [provBase.rows[0].r.business_id])).rows[0].code;
ok(planOfBase === 'base', 'Sin plan indicado → Plan Base');
const { rows: [ue] } = await db.query(`INSERT INTO auth.users (email) VALUES ('custom@cliente.com') RETURNING id`);
const planCustom = (await db.query(`SELECT id FROM public.plans WHERE code = 'custom'`)).rows[0].id;
await expectError(as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Cadena Inválida', 'Centro', 'Ana', $2, 0)`, [ue.id, planCustom])), 'Plan personalizado rechaza 0 soportes', 'soportes');
await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Cadena Grande', 'Centro', 'Ana', $2, 8)`, [ue.id, planCustom]));
ok((await q(ue.id, `SELECT public.get_my_supports() AS s`)).rows[0].s.limit === 8, 'Plan personalizado toma p_supports_override (8 soportes)');
const { rows: [uf] } = await db.query(`INSERT INTO auth.users (email) VALUES ('custom-default@cliente.com') RETURNING id`);
await as('service_role', null, tx => tx.query(`SELECT public.admin_provision_business($1, 'Cadena Default', 'Centro', 'Ana', $2)`, [uf.id, planCustom]));
ok((await q(uf.id, `SELECT public.get_my_supports() AS s`)).rows[0].s.limit === 1, 'Plan personalizado sin override arranca con 1 soporte');
const isolation = await q(C, `SELECT count(*)::int n FROM public.responses`);
ok(isolation.rows[0].n === 0, 'El negocio nuevo no ve opiniones de otros');

console.log('\n[12] Preguntas editables del formulario y libro mayor ampliado (010)');
await expectError(as('anon', null, tx => tx.query(`SELECT * FROM public.survey_questions`)), 'Anon NO puede leer survey_questions directo', 'permission denied');
const bizAId = (await q(A, `SELECT public.my_business_id() AS id`)).rows[0].id;
await q(A, `INSERT INTO public.survey_questions (business_id, type, question_text, options, placeholder, active, order_index) VALUES
  ('${bizAId}', 'stars', '¿Qué te pareció nuestro café hoy?', '{}', NULL, true, 1),
  ('${bizAId}', 'tags',  '¿Qué aspecto querés destacar?', ARRAY['Café','Atención','Ambiente'], NULL, true, 2),
  ('${bizAId}', 'text',  'Dejanos una sugerencia', '{}', 'Escribí acá...', true, 3)`);
const qA = await q(A, `SELECT type, question_text, options FROM public.survey_questions ORDER BY order_index`);
ok(qA.rows.length === 3 && qA.rows[1].options.length === 3, 'Admin A crea y lee sus 3 preguntas personalizadas');
ok((await q(B, `SELECT * FROM public.survey_questions`)).rows.length === 0, 'Negocio B NO ve las preguntas de A');
await expectError(q(B, `INSERT INTO public.survey_questions (business_id, type, question_text) VALUES ('${bizAId}', 'text', 'Hack')`), 'Negocio B NO puede insertar preguntas en A', 'row-level security');
const tokWithQ = await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token($1) AS b`, [tokenA]));
const sq = tokWithQ.rows[0].b.survey_questions;
ok(Array.isArray(sq) && sq.length === 3 && sq[0].question_text === '¿Qué te pareció nuestro café hoy?' && sq[1].options[0] === 'Café', 'get_business_by_token devuelve las preguntas personalizadas en orden');
const ov10 = await q(S, `SELECT * FROM public.get_platform_overview()`);
const rowA = ov10.rows.find(r => r.name === 'Cafetería del Sol');
ok(rowA && rowA.owner_email === 'sofia@sol.com' && rowA.owner_name === 'Sofía P.' && Number(rowA.branches_count) >= 1 && !!rowA.primary_token, `Libro mayor incluye dueño (${rowA?.owner_email}), sucursales (${rowA?.branches_count}) y token principal`);

console.log('\n[13] Logos de negocios y aislamiento en Storage (011)');
const { rows: [bkt] } = await db.query(`SELECT public, file_size_limit, allowed_mime_types FROM storage.buckets WHERE id = 'business-logos'`);
ok(bkt && bkt.public === true && Number(bkt.file_size_limit) === 2097152 && !bkt.allowed_mime_types.includes('image/svg+xml'), 'Bucket business-logos público, 2MB, sin SVG');
await expectError(q(A, `UPDATE public.businesses SET logo_url = 'javascript:alert(1)'`), 'logo_url maliciosa rechazada', 'chk_logo_url');
await q(A, `UPDATE public.businesses SET logo_url = 'https://pocsdftehmjdwzvjcfcw.supabase.co/storage/v1/object/public/business-logos/${bizAId}/logo.png'`);
const tokLogo = await as('anon', null, tx => tx.query(`SELECT public.get_business_by_token($1) AS b`, [tokenA]));
ok(tokLogo.rows[0].b.logo_url.includes(bizAId), 'get_business_by_token devuelve el logo_url guardado');
await q(A, `INSERT INTO storage.objects (bucket_id, name) VALUES ('business-logos', '${bizAId}/logo-1.png')`);
ok((await as('anon', null, tx => tx.query(`SELECT name FROM storage.objects WHERE bucket_id = 'business-logos'`))).rows.length === 1, 'Anon puede leer el logo público en el ticket');
await expectError(q(B, `INSERT INTO storage.objects (bucket_id, name) VALUES ('business-logos', '${bizAId}/hack.png')`), 'Negocio B NO puede subir logo en la carpeta de A', 'row-level security');
await expectError(as('anon', null, tx => tx.query(`INSERT INTO storage.objects (bucket_id, name) VALUES ('business-logos', '${bizAId}/anon.png')`)), 'Anon NO puede subir logos', 'row-level security');
const delByB = await q(B, `DELETE FROM storage.objects WHERE name = '${bizAId}/logo-1.png' RETURNING id`);
ok(delByB.rows.length === 0, 'Negocio B NO puede borrar el logo de A');
const delByA = await q(A, `DELETE FROM storage.objects WHERE name = '${bizAId}/logo-1.png' RETURNING id`);
ok(delByA.rows.length === 1, 'Negocio A sí puede borrar su propio logo');
const ov11 = await q(S, `SELECT name, logo_url FROM public.get_platform_overview()`);
ok(ov11.rows.find(r => r.name === 'Cafetería del Sol')?.logo_url?.includes(bizAId), 'Libro mayor del Super Admin incluye logo_url');

console.log('\n[13b] Diagnóstico detallado por negocio para Super Admin (012)');
await expectError(as('anon', null, tx => tx.query(`SELECT public.get_business_diagnostics($1)`, [bizAId])), 'Anon NO puede consultar diagnóstico', 'permission denied');
await expectError(q(A, `SELECT public.get_business_diagnostics('${bizAId}')`), 'Admin de negocio NO puede consultar diagnóstico Super Admin', 'Solo el Super Admin');
await expectError(q(B, `SELECT public.get_business_diagnostics('${bizAId}')`), 'Otro negocio NO puede consultar diagnóstico', 'Solo el Super Admin');
const diagRes = await q(S, `SELECT public.get_business_diagnostics('${bizAId}') AS d`);
const diag = diagRes.rows[0].d;
ok(diag && diag.business?.name === 'Cafetería del Sol' && diag.business?.has_custom_survey === true && diag.business?.owner_email === 'sofia@sol.com', 'Super Admin obtiene configuración y salud de onboarding');
ok(Number(diag.metrics?.responses_total) >= 2 && diag.metrics?.distribution && Array.isArray(diag.metrics?.top_tags), 'Super Admin obtiene métricas, distribución y top etiquetas');
ok(diag.rescue && typeof diag.rescue.cases_total === 'number' && Array.isArray(diag.branches) && diag.branches.length >= 1, 'Super Admin obtiene salud del Modo Rescate y desglose por sucursal');
const diagJson = JSON.stringify(diag.recent_activity || []);
ok(
  Array.isArray(diag.recent_activity) &&
  diag.recent_activity.length >= 1 &&
  !diagJson.includes('comment') === false && // has_comment boolean permitido
  !diagJson.includes('martin@mail.com') &&
  !diagJson.includes('5493815551234') &&
  !diagJson.includes('Martín') &&
  diag.recent_activity.every(item => !('comment' in item) && !('full_name' in item) && !('email' in item) && !('phone' in item)),
  'Actividad reciente del diagnóstico 100% anonimizada (0 PII y 0 texto libre)'
);

console.log('\n[14] Anti-flood');
let floodErr = null;
for (let i = 0; i < 25 && !floodErr; i++) {
  try { await sub([tokenA, 4, [], null, null, null, null, 'whatsapp', false, null]); }
  catch (e) { floodErr = e.message; }
}
ok(floodErr && floodErr.includes('muchas opiniones'), `Límite por QR activado: "${floodErr}"`);

console.log('\n[15] Auditoría de catálogos Postgres (RLS + privilegios mínimos)');
const { rows: noRls } = await db.query(`
  SELECT c.relname FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity
`);
ok(noRls.length === 0, `100% de las tablas en public tienen RLS habilitado (sin RLS: ${noRls.map(r => r.relname).join(', ') || 'ninguna'})`);

const { rows: anonTabs } = await db.query(`
  SELECT table_name, privilege_type FROM information_schema.role_table_grants
  WHERE grantee = 'anon' AND table_schema = 'public'
`);
ok(anonTabs.length === 1 && anonTabs[0].table_name === 'plans' && anonTabs[0].privilege_type === 'SELECT',
  `anon solo tiene SELECT en plans (${anonTabs.map(r => `${r.table_name}:${r.privilege_type}`).join(', ')})`);

const { rows: anonFns } = await db.query(`
  SELECT DISTINCT p.proname AS routine_name
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'
    )
  ORDER BY p.proname
`);
const anonFnNames = anonFns.map(r => r.routine_name);
ok(anonFnNames.length === 2 && anonFnNames.includes('get_business_by_token') && anonFnNames.includes('submit_feedback'),
  `anon solo puede ejecutar 2 RPCs (${anonFnNames.join(', ')})`);

console.log(`\n══════ RESULTADO MIGRACIONES: ${pass} OK · ${fail} FALLAS ══════\n`);
process.exit(fail ? 1 : 0);
