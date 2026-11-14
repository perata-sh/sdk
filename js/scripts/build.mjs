// Builds both module formats with tsc: dist/esm (what `import` loads) and
// dist/cjs (what `require` loads). A package.json in dist/cjs tells Node that
// the folder is CommonJS although the package itself is "type": "module".
import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tscBin = join(root, "node_modules", ".bin", "tsc");

rmSync(join(root, "dist"), { recursive: true, force: true });
for (const config of ["tsconfig.json", "tsconfig.cjs.json"]) {
  execFileSync(tscBin, ["-p", join(root, config)], { stdio: "inherit", cwd: root });
}
mkdirSync(join(root, "dist", "cjs"), { recursive: true });
writeFileSync(join(root, "dist", "cjs", "package.json"), '{"type":"commonjs"}\n');
