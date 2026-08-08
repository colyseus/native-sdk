#!/usr/bin/env node
// gen-bindings.mjs — the GameMaker extension's binding manifest tool.
//
// The C sources are the single source of truth: every `GM_EXPORT` in
// src/gamemaker_export.c + src/gamemaker_predict.c must be registered in
// FOUR places (C, wasm shim, Colyseus_SDK.yy function list, Colyseus.gml).
// Missing the .yy silently unbinds a function; missing the shim makes HTML5
// return silent 0s. This tool makes both impossible:
//
//   node gen-bindings.mjs           # regenerate the shim region + .yy entries
//   node gen-bindings.mjs --check   # CI parity audit (no writes, exit 1 on drift)
//
// Hand-written shim functions (JS fetch HTTP, is_ready) live outside the
// generated region and are excluded from emission.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const C_SOURCES = [
  path.join(ROOT, "src/gamemaker_export.c"),
  path.join(ROOT, "src/gamemaker_predict.c"),
];
const SHIM = path.join(ROOT, "src/gamemaker_wasm_shim.js");
const YY = path.join(
  ROOT,
  "example/BlankProject/extensions/Colyseus_SDK/Colyseus_SDK.yy"
);
const GML_DIR = path.join(ROOT, "example/BlankProject/scripts");

// Implemented BY HAND in the shim (JS fetch / module-state) — never generated.
const SHIM_HANDWRITTEN = new Set([
  "colyseus_gm_is_ready",
  "colyseus_gm_http_get",
  "colyseus_gm_http_post",
  "colyseus_gm_http_put",
  "colyseus_gm_http_delete",
  "colyseus_gm_http_patch",
]);

const GEN_BEGIN = "// === GENERATED BINDINGS BEGIN (gen-bindings.mjs) ===";
const GEN_END = "// === GENERATED BINDINGS END ===";

// ── parse C exports ──────────────────────────────────────────────────────

function parseCExports() {
  const exports = [];
  const seen = new Set();
  const re =
    /GM_EXPORT\s+((?:const\s+)?[a-zA-Z_][\w]*\s*\**)\s*(colyseus_gm_\w+)\s*\(([^)]*)\)/g;
  for (const file of C_SOURCES) {
    const src = fs.readFileSync(file, "utf8");
    for (const m of src.matchAll(re)) {
      const [, retRaw, name, argsRaw] = m;
      if (seen.has(name)) {
        console.error(`DUPLICATE C export: ${name}`);
        process.exitCode = 1;
        continue;
      }
      seen.add(name);
      const ret = normType(retRaw);
      const args = argsRaw
        .split(",")
        .map((a) => a.trim())
        .filter((a) => a && a !== "void")
        .map((a) => {
          const type = normType(a.replace(/\w+$/, ""));
          const argName = (a.match(/(\w+)$/) || [, "arg"])[1];
          return { type, name: argName };
        });
      exports.push({ name, ret, args, file: path.basename(file) });
    }
  }
  return exports;
}

function normType(t) {
  t = t.replace(/\s+/g, " ").trim();
  if (t === "double") return "number";
  if (t === "void") return "void";
  if (/^const char\s*\*$/.test(t)) return "string";
  return "ptr"; // const uint8_t* and friends — crosses as a number
}

// ── shim emission ────────────────────────────────────────────────────────

function shimWrapper(exp) {
  const argNames = exp.args.map((a) => a.name).join(", ");
  const argTypes = exp.args
    .map((a) => (a.type === "string" ? "'string'" : "'number'"))
    .join(", ");
  const call =
    exp.ret === "void" ? "_callV" : exp.ret === "string" ? "_callS" : "_callN";
  const retKw = exp.ret === "void" ? "" : "return ";
  return (
    `    window.${exp.name} = function(${argNames}) {\n` +
    `        ${retKw}${call}('${exp.name}', [${argTypes}], [${argNames}]);\n` +
    `    };\n`
  );
}

function emitShim(exports) {
  const src = fs.readFileSync(SHIM, "utf8");
  const begin = src.indexOf(GEN_BEGIN);
  const end = src.indexOf(GEN_END);
  if (begin < 0 || end < 0) {
    console.error(
      `shim is missing the generated-region markers:\n  ${GEN_BEGIN}\n  ${GEN_END}`
    );
    process.exit(1);
  }
  const body = exports
    .filter((e) => !SHIM_HANDWRITTEN.has(e.name))
    .map(shimWrapper)
    .join("\n");
  const next =
    src.slice(0, begin + GEN_BEGIN.length) +
    "\n\n" +
    body +
    "\n    " +
    src.slice(end);
  fs.writeFileSync(SHIM, next);
  return body;
}

// ── .yy emission ─────────────────────────────────────────────────────────

function yyTypeCode(t) {
  return t === "string" ? 1 : t === "ptr" ? 3 : 2;
}

function makeYyEntry(exp) {
  const gmlName = "__" + exp.name;
  return {
    $GMExtensionFunction: "",
    "%Name": gmlName,
    argCount: exp.args.length,
    args: exp.args.map((a) => yyTypeCode(a.type)),
    documentation: "",
    externalName: exp.name,
    help: `(internal) ${exp.name.replace(/^colyseus_gm_/, "").replace(/_/g, " ")}`,
    hidden: true,
    kind: 1,
    name: gmlName,
    resourceType: "GMExtensionFunction",
    resourceVersion: "2.0",
    returnType: exp.ret === "string" ? 1 : 2,
  };
}

// .yy files carry 64-bit target bitmasks (copyToTargets) that overflow
// JS number precision — shield long integer literals through parse/stringify.
const BIGINT_SENTINEL = "___yy_bigint___";
function yyParse(text) {
  return JSON.parse(
    text.replace(/:(\s*)(\d{16,})/g, `:$1"${BIGINT_SENTINEL}$2"`)
  );
}
function yyStringify(data) {
  return (
    JSON.stringify(data, null, 2).replace(
      new RegExp(`"${BIGINT_SENTINEL}(\\d+)"`, "g"),
      "$1"
    ) + "\n"
  );
}

function emitYy(exports) {
  const data = yyParse(fs.readFileSync(YY, "utf8"));
  const existing = new Map(
    data.files[0].functions.map((f) => [f.externalName, f])
  );
  const list = [];
  for (const exp of exports) {
    const entry = existing.get(exp.name);
    if (entry) {
      // keep name/help/docs; the C signature is the authority on the rest
      entry.argCount = exp.args.length;
      entry.args = exp.args.map((a) => yyTypeCode(a.type));
      entry.returnType = exp.ret === "string" ? 1 : 2;
      list.push(entry);
    } else {
      list.push(makeYyEntry(exp));
    }
  }
  const stale = data.files[0].functions.filter(
    (f) => !exports.some((e) => e.name === f.externalName)
  );
  if (stale.length) {
    console.error(
      "removed stale .yy entries (no C export):",
      stale.map((f) => f.externalName).join(", ")
    );
  }
  // the packaging rule: every file entry carries the FULL function list
  for (const fileEntry of data.files) {
    fileEntry.functions = list;
  }
  fs.writeFileSync(YY, yyStringify(data));
  return list;
}

// ── check mode ───────────────────────────────────────────────────────────

function collectGmlFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...collectGmlFiles(p));
    else if (entry.name.endsWith(".gml")) out.push(p);
  }
  return out;
}

function check(exports) {
  let failures = 0;
  const fail = (msg) => {
    console.error("PARITY FAIL:", msg);
    failures++;
  };

  const exportNames = new Set(exports.map((e) => e.name));

  // shim: every C export has a window.* binding (generated or hand-written)
  const shimSrc = fs.readFileSync(SHIM, "utf8");
  const shimNames = new Set(
    [...shimSrc.matchAll(/window\.(colyseus_gm_\w+)\s*=/g)].map((m) => m[1])
  );
  for (const e of exports) {
    if (!shimNames.has(e.name)) fail(`shim missing: ${e.name}`);
  }
  for (const n of shimNames) {
    if (!exportNames.has(n) && !SHIM_HANDWRITTEN.has(n))
      fail(`shim binds nonexistent C export: ${n}`);
  }

  // .yy: every C export declared; no stale entries; file entries identical
  const yy = yyParse(fs.readFileSync(YY, "utf8"));
  const yyByExternal = new Map(
    yy.files[0].functions.map((f) => [f.externalName, f])
  );
  for (const e of exports) {
    const entry = yyByExternal.get(e.name);
    if (!entry) {
      fail(`.yy missing declaration: ${e.name}`);
      continue;
    }
    if (entry.argCount !== e.args.length)
      fail(
        `.yy argCount mismatch for ${e.name}: declared ${entry.argCount}, C has ${e.args.length}`
      );
  }
  for (const [ext] of yyByExternal) {
    if (!exportNames.has(ext)) fail(`.yy declares nonexistent C export: ${ext}`);
  }
  const first = JSON.stringify(yy.files[0].functions);
  for (let i = 1; i < yy.files.length; i++) {
    if (JSON.stringify(yy.files[i].functions) !== first)
      fail(
        `.yy files[${i}] (${yy.files[i].filename}) function list differs from files[0] — GameMaker binds nothing from an entry with a stale list`
      );
  }

  // GML: every extension identifier used in scripts is declared in the .yy
  const yyNames = new Set(yy.files[0].functions.map((f) => f.name));
  for (const gmlFile of collectGmlFiles(GML_DIR)) {
    const src = fs.readFileSync(gmlFile, "utf8");
    for (const m of src.matchAll(/(?<![\w.])(__colyseus_gm_\w+)/g)) {
      if (!yyNames.has(m[1]))
        fail(`${path.basename(gmlFile)} calls undeclared: ${m[1]}`);
    }
  }

  if (failures) {
    console.error(`\n${failures} parity failure(s).`);
    process.exit(1);
  }
  console.log(
    `parity OK: ${exports.length} C exports ↔ shim ↔ .yy (${yy.files.length} file entries) ↔ GML`
  );
}

// ── main ─────────────────────────────────────────────────────────────────

const exports_ = parseCExports();
if (process.argv.includes("--check")) {
  check(exports_);
} else {
  emitShim(exports_);
  const list = emitYy(exports_);
  console.log(
    `emitted: ${exports_.length} exports → shim region + ${list.length} .yy entries`
  );
  check(exports_);
}
