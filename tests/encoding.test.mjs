// Verifica que no existan caracteres con doble codificación UTF-8 (mojibake) en supabase/.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../supabase', import.meta.url));
const MOJIBAKE_RE = /Ã[¡©­³º±¼ÁÉÍÓÚÑ€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ]|Â[·¡¿°ªº]|â€|â†|âœ|â˜|ï¸|ðŸ|\uFFFD/;

let bad = 0;
function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name.startsWith('.')) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (/\.(sql|ts|toml|json)$/i.test(e.name)) {
      const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
      lines.forEach((l, i) => {
        if (MOJIBAKE_RE.test(l)) {
          bad++;
          console.log(`  ✘ Mojibake en ${path.relative(ROOT, p)}:${i + 1}: ${l.trim().slice(0, 100)}`);
        }
      });
    }
  }
}

walk(ROOT);
console.log(bad ? `\n✘ ${bad} líneas con codificación rota en Backend` : '✔ Codificación UTF-8 de Backend OK (0 errores)');
process.exit(bad ? 1 : 0);
