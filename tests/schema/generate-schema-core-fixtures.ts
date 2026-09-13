//
// Byte fixtures + expected callback logs for tests/test_schema_core.zig.
//
// Every patch is produced by the real 5.0 Encoder/StateView (the same
// encodeAll → encodeAllView → encode → encodeView sequence a room runs), and
// the expected log is what @colyseus/schema's own Callbacks produce when the
// same bytes are decoded by a reflection-built Decoder — the C side must match
// it line for line. Self-verifying: the scenario asserts the wire shape it
// depends on (e.g. the fog re-add really carries each field twice).
//
// Needs the sibling schema-5.0 checkout. From the native-sdk root:
//   npx tsx --tsconfig tests/schema/tsconfig.json \
//     tests/schema/generate-schema-core-fixtures.ts > tests/schema/schema_core_fixtures.zig
//
// Wire-compatible C headers: tests/schema/core_state.h + core_ent.h.
//
import * as assert from "assert";
import { Schema, type, view, MapSchema, Encoder, Decoder, StateView, Reflection, Callbacks } from "../../../schema-5.0/src";
import type { DataChange } from "../../../schema-5.0/src";

class CoreEnt extends Schema {
    @type("number") x: number;
    @type("number") z: number;
    @type("string") label: string;
}

class CoreState extends Schema {
    @view() @type({ map: CoreEnt }) ents = new MapSchema<CoreEnt>();
    @type("string") title: string;
    @type("number") tick: number;
}

const fmt = (v: any) => (v === undefined || v === null) ? "undefined" : String(v);

const state = new CoreState();
const encoder = new Encoder(state);
const clientView = new StateView();

const ent = (x: number, z: number, label: string) => new CoreEnt().assign({ x, z, label });

state.title = "hello";
state.tick = 1;
state.ents.set("e1", ent(1, 2, "aaaa"));
state.ents.set("e2", ent(3, 4, "cccc"));
clientView.add(state.ents.get("e1")!);
clientView.add(state.ents.get("e2")!);

const reflection = Array.from(Reflection.encode(encoder));

//
// The client under test, and a raw-change probe decoding the same bytes.
//
const client: Decoder = Reflection.decode(Uint8Array.from(reflection));
const probe: Decoder = Reflection.decode(Uint8Array.from(reflection));
let rawChanges: DataChange[] = [];
probe.triggerChanges = (changes) => { rawChanges = changes; };

let log: string[] = [];
const cb = Callbacks.get(client);

// registered BEFORE the first full state arrives (a room's onJoin)
cb.listen("title", (v: any, p: any) => log.push(`title ${fmt(v)} ${fmt(p)}`));
cb.onAdd("ents", (e: any, k: string) => {
    log.push(`add ${k}`);
    cb.listen(e, "x", (v: any, p: any) => log.push(`x ${k} ${fmt(v)} ${fmt(p)}`));
    cb.listen(e, "label", (v: any, p: any) => log.push(`label ${k} ${fmt(v)} ${fmt(p)}`));
});
let registeredInRemove = false;
cb.onRemove("ents", (_e: any, k: string) => {
    log.push(`remove ${k}`);
    // an immediate listen from inside a trigger pass must not fire now
    if (!registeredInRemove) {
        registeredInRemove = true;
        cb.listen("title", (v: any, p: any) => log.push(`title2 ${fmt(v)} ${fmt(p)}`), true);
    }
});

type Step = { name: string, patches: number[][], log: string[], notes: string[] };
const steps: Step[] = [];

function deliver(name: string, patches: Uint8Array[], verify?: () => void) {
    log = [];
    const notes: string[] = [];
    const copies = patches.map((p) => Array.from(p));
    for (const bytes of copies) {
        client.decode(Uint8Array.from(bytes));
        probe.decode(Uint8Array.from(bytes));
    }
    verify?.();
    steps.push({ name, patches: copies, log, notes });
    console.error(`✔ ${name}`);
}

function tick(): Uint8Array {
    const it = { offset: 0 };
    encoder.encode(it);
    const sharedOffset = it.offset;
    const bytes = encoder.encodeView(clientView, sharedOffset, it);
    encoder.discardChanges();
    return bytes.slice();
}

function fieldSets(refId: number, field: string) {
    return rawChanges.filter((c) => c.refId === refId && c.field === field).length;
}

// ── join: full state for the view, then the first tick ─────────────────────
{
    const buf = new Uint8Array(4096);
    const it = { offset: 0 };
    encoder.encodeAll(it, buf);
    const full = encoder.encodeAllView(clientView, it.offset, it, buf).slice();
    deliver("join", [full, tick()], () => {
        assert.strictEqual(client.state.ents.size, 2);
        assert.strictEqual(client.state.title, "hello");
    });
}

// ── move: plain delta ───────────────────────────────────────────────────────
state.title = "world";
state.tick = 2;
state.ents.get("e1")!.x = 10;
deliver("move", [tick()]);

// ── fog_out: the view drops e1 ──────────────────────────────────────────────
state.tick = 3;
clientView.remove(state.ents.get("e1")!);
deliver("fog_out", [tick()], () => {
    assert.strictEqual(client.state.ents.has("e1"), false);
});

// ── fog_in: e1 re-enters the view on a tick it also moves ───────────────────
// The re-add tick alone already writes every e1 field TWICE (the view's full
// encode, then the tick's filtered delta) with identical values — the shape
// that left a dangling change record on the C side. TS drops the repeat by
// value, so it never shows in its change list. The next tick's delta is
// appended to the same patch so the fields also change within one decode.
{
    const e1 = state.ents.get("e1")!;
    state.tick = 4;
    e1.x = 11;
    e1.z = 21;
    e1.label = "bbbb";
    clientView.add(e1);
    const readd = tick();
    e1.x = 12;
    e1.z = 22;
    e1.label = "bbbb2";
    const delta = tick();
    assert.strictEqual(delta[0], 255); // opens with SWITCH_TO_STRUCTURE — safe to append

    const merged = new Uint8Array(readd.length + delta.length);
    merged.set(readd, 0);
    merged.set(delta, readd.length);

    deliver("fog_in", [merged], () => {
        const e1Ref = rawChanges.find((c) => c.field === "x" && c.value === 11)!.refId;
        const switches = readd.filter((b, i) => b === 255 && readd[i + 1] === e1Ref).length;
        assert.strictEqual(switches, 2); // full encode + delta, same tick
        assert.strictEqual(fieldSets(e1Ref, "x"), 2);
        assert.strictEqual(fieldSets(e1Ref, "label"), 2);
        const ce1 = client.state.ents.get("e1");
        assert.deepStrictEqual([ce1.x, ce1.z, ce1.label], [12, 22, "bbbb2"]);
    });
}

// ── churn: add + field change + delete in one patch ─────────────────────────
{
    state.tick = 5;
    const e3 = ent(5, 6, "dddd");
    state.ents.set("e3", e3);
    clientView.add(e3);
    state.ents.get("e1")!.x = 12;
    state.ents.delete("e2");
    deliver("churn", [tick()], () => {
        assert.deepStrictEqual(Array.from(client.state.ents.keys()).sort(), ["e1", "e3"]);
    });
}

// ── retitle: both root listeners see it, most recent first ──────────────────
state.title = "again";
state.tick = 6;
deliver("retitle", [tick()]);

// ── replace_ents: the collection field itself is swapped for a new one ──────
state.tick = 7;
state.ents = new MapSchema<CoreEnt>();
deliver("replace_ents", [tick()], () => {
    assert.strictEqual(client.state.ents.size, 0);
});

//
// Output: a Zig module the test imports.
//
const zigBytes = (bytes: number[]) => `&[_]u8{ ${bytes.join(", ")} }`;
const zigStr = (s: string) => JSON.stringify(s);

const lines: string[] = [];
lines.push("// GENERATED by tests/schema/generate-schema-core-fixtures.ts — do not edit.");
lines.push("// Bytes: @colyseus/schema 5.0 Encoder + StateView. Logs: its Callbacks.");
lines.push("");
lines.push("pub const Step = struct { name: []const u8, patches: []const []const u8, log: []const []const u8 };");
lines.push("");
lines.push(`pub const reflection = ${zigBytes(reflection)};`);
lines.push("");
lines.push("pub const steps = [_]Step{");
for (const step of steps) {
    lines.push(`    .{`);
    lines.push(`        .name = ${zigStr(step.name)},`);
    lines.push(`        .patches = &[_][]const u8{`);
    for (const p of step.patches) { lines.push(`            ${zigBytes(p)},`); }
    lines.push(`        },`);
    lines.push(`        .log = &[_][]const u8{`);
    for (const l of step.log) { lines.push(`            ${zigStr(l)},`); }
    lines.push(`        },`);
    lines.push(`    },`);
}
lines.push("};");
console.log(lines.join("\n"));
