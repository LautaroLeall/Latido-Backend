// Auditoría automatizada de seguridad de Edge Functions y configuración Supabase.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const FN_PATH = path.join(ROOT, 'supabase', 'functions', 'create-business-account', 'index.ts');
const CFG_PATH = path.join(ROOT, 'supabase', 'config.toml');

let passed = 0;
let failed = 0;

function check(name, fn) {
  try {
    fn();
    passed++;
  } catch (err) {
    failed++;
    console.log(`  ✘ ${name}: ${err.message}`);
  }
}

const fnSrc = fs.readFileSync(FN_PATH, 'utf8');
const cfgSrc = fs.readFileSync(CFG_PATH, 'utf8');

check('Edge Function no usa wildcard CORS "*"', () => {
  assert.ok(!/"Access-Control-Allow-Origin"\s*:\s*"\*"/.test(fnSrc), 'Se detectó Access-Control-Allow-Origin: *');
});

check('Edge Function incluye allowlist de producción y Vary: Origin', () => {
  assert.ok(fnSrc.includes('https://latido-opinion.vercel.app'));
  assert.ok(fnSrc.includes('Vary: "Origin"') || fnSrc.includes('"Vary": "Origin"'));
});

check('Edge Function fija Cache-Control: no-store y X-Content-Type-Options: nosniff', () => {
  assert.ok(fnSrc.includes('"Cache-Control": "no-store"'));
  assert.ok(fnSrc.includes('"X-Content-Type-Options": "nosniff"'));
});

check('Edge Function valida JWT con auth.getUser y rol super_admin', () => {
  assert.ok(fnSrc.includes('admin.auth.getUser('));
  assert.ok(fnSrc.includes('callerProfile?.role !== "super_admin"'));
});

check('Edge Function limita tamaño de body (DoS) y hace rollback si falla RPC', () => {
  assert.ok(fnSrc.includes('MAX_BODY_BYTES'));
  assert.ok(fnSrc.includes('admin.auth.admin.deleteUser('));
});

check('Edge Function no contiene secretos embebidos', () => {
  assert.ok(!/sb_secret_[a-zA-Z0-9_-]{10,}/.test(fnSrc));
  assert.ok(!/eyJhbGciOi/.test(fnSrc));
});

check('config.toml desactiva signup público y exige letras + números en contraseñas', () => {
  assert.ok(/\[auth\][\s\S]*?enable_signup\s*=\s*false/.test(cfgSrc));
  assert.ok(/\[auth\.email\][\s\S]*?enable_signup\s*=\s*false/.test(cfgSrc));
  assert.ok(/password_requirements\s*=\s*"letters_digits"/.test(cfgSrc));
});

check('config.toml incluye URL de producción en site_url y redirects', () => {
  assert.ok(cfgSrc.includes('https://latido-opinion.vercel.app'));
  assert.ok(cfgSrc.includes('https://latido-opinion.vercel.app/reset-password'));
});

if (failed > 0) {
  console.log(`\n✘ ${failed} fallos / ${passed} OK en auditoría Edge Function & config`);
  process.exit(1);
}
console.log(`✔ Edge Function & Supabase config OK (${passed}/${passed})`);
