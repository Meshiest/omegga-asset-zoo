// The host half of the dump, run in the plugin after the game part: the NDJSON
// merged into inventory_dump.json, everything combined into full_inventory.json,
// then the brick size and procedural gate variant tables that brdb and brs-js
// carry. All of it reads and writes `out` only.
import fs from 'fs';
import path from 'path';

type HalfSize = { X: number; Y: number; Z: number };
type Port = { name: string };
type Component = { componentType?: string; wireInputPorts?: Record<string, unknown>; wireOutputPorts?: Record<string, unknown> };
type GateVariant = { halfSize: HalfSize; physicalPorts?: Port[] };
/** One brick (or standalone component) record of the inventory dump. */
type DumpRecord = {
  assetName?: string;
  halfSize?: HalfSize;
  standalone?: boolean;
  procedural?: boolean;
  components: Component[] | Record<string, never>;
  gateVariants?: GateVariant[];
};
type Shape = { assetName?: string; halfSize?: HalfSize };
type Catalog = {
  assets?: Record<string, { count?: number }>;
  counts?: { assets?: Record<string, number>; materials?: number; shapes?: number };
  materials?: unknown[];
  shapes?: Shape[];
  errors?: unknown;
};
type Merged = { errors: string[]; counts: { total: number; ok: number; err: number }; results: DumpRecord[] };
type FullInventory = { components: DumpRecord[]; shapes: Shape[] };

const read = <T>(file: string): T => JSON.parse(fs.readFileSync(file, 'utf8')) as T;
const components = (r: DumpRecord): Component[] => (Array.isArray(r.components) ? r.components : []);

/**
 * inventory_dump.ndjson -> inventory_dump.json, shaped like wirescript's
 * logic_gate_inventory.full.json: { errors, counts, results }.
 */
export function mergeDump(out: string): string {
  const lines = fs.readFileSync(path.join(out, 'inventory_dump.ndjson'), 'utf8').split(/\r?\n/).filter(l => l.trim().length > 0);
  const results: DumpRecord[] = [];
  const errors: string[] = [];
  lines.forEach((line, i) => {
    try {
      results.push(JSON.parse(line) as DumpRecord);
    } catch (e) {
      errors.push(`line ${i + 1}: ${(e as Error).message}`);
    }
  });
  // de-dupe by assetName (re-runs, overlapping chunks); the last write wins
  const byName = new Map<string, DumpRecord>();
  for (const r of results) byName.set(r.assetName ?? JSON.stringify(r), r);
  const deduped = [...byName.values()];
  const doc: Merged = { errors, counts: { total: deduped.length, ok: deduped.length, err: errors.length }, results: deduped };
  fs.writeFileSync(path.join(out, 'inventory_dump.json'), JSON.stringify(doc, null, 2));
  return `merged ${results.length} records (${deduped.length} unique) -> inventory_dump.json${errors.length ? `, ${errors.length} parse errors` : ''}`;
}

/** inventory_dump.json + catalog_dump.json -> full_inventory.json. */
export function combineFull(out: string): string {
  const comp = read<Merged>(path.join(out, 'inventory_dump.json'));
  const cat = read<Catalog>(path.join(out, 'catalog_dump.json'));
  const results = comp.results ?? [];
  // Lua encodes an empty table as {}; a record with no probed components arrives as {}
  for (const r of results) if (!Array.isArray(r.components)) r.components = [];
  const standalone = results.filter(r => r.standalone);
  const totalPorts = results.reduce(
    (n, r) => components(r).reduce((m, c) => m + Object.keys(c.wireInputPorts ?? {}).length + Object.keys(c.wireOutputPorts ?? {}).length, n),
    0,
  );
  const assetTotal = Object.values(cat.assets ?? {}).reduce((n, a) => n + (a.count ?? 0), 0);
  const doc = {
    counts: {
      components: { records: results.length, catalogBricks: results.length - standalone.length, standalone: standalone.length, ports: totalPorts },
      assets: { total: assetTotal, byType: cat.counts?.assets ?? {} },
      materials: cat.counts?.materials ?? (cat.materials?.length ?? 0),
      shapes: cat.counts?.shapes ?? (cat.shapes?.length ?? 0),
    },
    // gates, components and bricks with wire ports (inventory_dump.lua)
    components: results,
    // selectable asset reference targets per type (catalog_dump.lua)
    assets: cat.assets ?? {},
    materials: cat.materials ?? [],
    // every basic brick shape with its BrickType metadata
    shapes: cat.shapes ?? [],
    errors: { components: comp.errors ?? [], catalog: cat.errors ?? [] },
  };
  const file = path.join(out, 'full_inventory.json');
  fs.writeFileSync(file, JSON.stringify(doc, null, 2));
  return `wrote full_inventory.json (${(fs.statSync(file).size / 1024).toFixed(0)} KB)`;
}

// Rust `("Name", [x, y, z]),` and TS `['Name', [x, y, z]],` rows, either quote style
const ROW_RE = /^\s*[([]\s*["']([^"']+)["']\s*,\s*\[\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\]/gm;
const byteCmp = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/**
 * The per-brick half-extent tables (brdb's brick_sizes.rs, brs-js's
 * brickSizes.ts) in out/tables. Basic brick extents are asset-defined and not in
 * saves, so the dump is the only source. Additive: every entry already in either
 * table is kept even when the dump lacks it, so a partial dump never drops a size.
 * Rows are in byte order (brdb looks them up with a binary search). The headers
 * name the original generator, so a regenerated table matches the checked-in one.
 */
export function brickSizes(out: string): string {
  const doc = read<FullInventory>(path.join(out, 'full_inventory.json'));
  const rsFile = path.join(out, 'tables', 'brick_sizes.rs');
  const tsFile = path.join(out, 'tables', 'brickSizes.ts');
  fs.mkdirSync(path.dirname(rsFile), { recursive: true });

  const existing = new Map<string, number[]>();
  for (const file of [tsFile, rsFile]) {
    if (!fs.existsSync(file)) continue;
    const text = fs.readFileSync(file, 'utf8');
    let n = 0;
    for (const m of text.matchAll(ROW_RE)) {
      existing.set(m[1], [+m[2], +m[3], +m[4]]);
      n++;
    }
    if (n === 0 && text.includes('BRICK_HALF_EXTENTS')) throw new Error(`parsed 0 rows from ${file}; refusing to regenerate (would drop entries)`);
  }

  const sizes = new Map<string, number[]>();
  const add = (name?: string, h?: HalfSize) => {
    if (name && h) sizes.set(name, [h.X | 0, h.Y | 0, h.Z | 0]);
  };
  for (const s of doc.shapes ?? []) add(s.assetName, s.halfSize);
  // standalone records name a component type and carry the host brick's size;
  // procedural sizes are per brick and stored in saves
  for (const r of doc.components ?? []) if (!r.standalone && !r.procedural) add(r.assetName, r.halfSize);

  const added = [...sizes.keys()].filter(n => !existing.has(n));
  const changed = [...sizes.entries()].filter(([n, v]) => existing.has(n) && existing.get(n)!.join() !== v.join());
  const kept = [...existing.keys()].filter(n => !sizes.has(n));
  const rows = [...new Map([...existing, ...sizes]).entries()].sort(([a], [b]) => byteCmp(a, b));

  let rs = '// Autogenerated from the inventory dump:\n';
  rs += '//   node scripts/gen_brick_sizes.mjs   (in brickadia-zoo)\n';
  rs += '// Do not edit by hand.\n\n';
  rs += '/// Authored half-extent `[x, y, z]` (grid brick units) for every basic\n';
  rs += '/// brick asset. Basic-brick extents are asset-defined and not carried in\n';
  rs += '/// saves, so these come from the in-game reflection dump. Sorted by name.\n';
  rs += 'pub static BRICK_HALF_EXTENTS: &[(&str, [i32; 3])] = &[\n';
  for (const [name, [x, y, z]] of rows) rs += `    (${JSON.stringify(name)}, [${x}, ${y}, ${z}]),\n`;
  rs += '];\n\n';
  rs += '/// Authored half-extent of a basic brick by asset name, if known.\n';
  rs += 'pub fn brick_half_extent(name: &str) -> Option<[i32; 3]> {\n';
  rs += '    BRICK_HALF_EXTENTS\n';
  rs += '        .binary_search_by(|(n, _)| n.cmp(&name))\n';
  rs += '        .ok()\n';
  rs += '        .map(|i| BRICK_HALF_EXTENTS[i].1)\n';
  rs += '}\n';
  fs.writeFileSync(rsFile, rs);

  let ts = '// GENERATED by brickadia-zoo scripts/gen_brick_sizes.mjs. Do not edit by hand.\n\n';
  ts += '/** Authored half-extent `[x, y, z]` (brick units) per basic brick asset,\n';
  ts += ' * from the in-game reflection dump (basic extents are asset-defined and not\n';
  ts += ' * carried in saves). Used for prefab-bounds computation. */\n';
  ts += 'export const BRICK_HALF_EXTENTS: ReadonlyMap<\n';
  ts += '  string,\n';
  ts += '  readonly [number, number, number]\n';
  ts += '> = new Map([\n';
  // single quotes, as brs-js's prettier config has them
  const tsStr = (s: string) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
  for (const [name, [x, y, z]] of rows) ts += `  [${tsStr(name)}, [${x}, ${y}, ${z}]],\n`;
  ts += ']);\n';
  fs.writeFileSync(tsFile, ts);

  return `brick sizes: ${rows.length} bricks (${added.length} added, ${changed.length} changed, ${kept.length} kept from the previous tables but absent from this dump)`;
}

/**
 * The procedural gate size variant tables (brdb's gate_variants.rs, brs-js's
 * gateVariants.ts) in out/tables. A gate placed as a procedural brick takes one
 * of a fixed list of sizes, each with its own physical ports, and nothing in a
 * save lists them, so the dump's procedural pass is the only source.
 */
export function gateVariants(out: string): string {
  const doc = read<FullInventory>(path.join(out, 'full_inventory.json'));
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  const gates = (doc.components ?? [])
    .filter(r => r.gateVariants?.length && components(r)[0]?.componentType)
    .map(r => ({
      asset: r.assetName ?? '',
      component: components(r)[0].componentType ?? '',
      variants: (r.gateVariants ?? [])
        .map(v => ({ half: [v.halfSize.X | 0, v.halfSize.Y | 0, v.halfSize.Z | 0], ports: (v.physicalPorts ?? []).map(p => p.name) }))
        .sort((a, b) => a.half[0] - b.half[0] || a.half[1] - b.half[1] || a.half[2] - b.half[2]),
    }))
    .sort((a, b) => cmp(a.asset, b.asset));
  if (!gates.length) throw new Error('no gateVariants in the dump; was the procedural pass run?');
  const q = JSON.stringify;
  const strs = (l: string[]) => l.map(s => q(s)).join(', ');

  let rs = '// Autogenerated from the inventory dump:\n';
  rs += '//   node scripts/gen_gate_variants.mjs   (in brickadia-zoo)\n';
  rs += '// Do not edit by hand.\n\n';
  rs += '/// One size of a procedural gate brick.\n';
  rs += '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\n';
  rs += 'pub struct GateVariant {\n';
  rs += "    /// Procedural half-extent `[x, y, z]` (the brick's `size`) that selects this variant.\n";
  rs += '    pub half_size: [i32; 3],\n';
  rs += "    /// Physical (on-brick) wire ports at this size, in brick order. The component's\n";
  rs += '    /// other ports still exist and are reachable through the omniport.\n';
  rs += "    pub ports: &'static [&'static str],\n";
  rs += '}\n\n';
  rs += '/// A gate brick asset (`PB_Gate_*`) placed as a procedural brick at one of a fixed\n';
  rs += '/// list of sizes; the game rejects any other size for it.\n';
  rs += '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\n';
  rs += 'pub struct ProceduralGate {\n';
  rs += '    /// Procedural brick asset name, e.g. "PB_Gate_QueueTicks".\n';
  rs += "    pub asset: &'static str,\n";
  rs += '    /// Component type the brick carries, e.g. "BrickComponentType_QueueTicks".\n';
  rs += "    pub component: &'static str,\n";
  rs += '    /// Size variants, smallest first.\n';
  rs += "    pub variants: &'static [GateVariant],\n";
  rs += '}\n\n';
  rs += 'impl ProceduralGate {\n';
  rs += "    /// The variant placed at `half_size`, if it is one of this gate's valid sizes.\n";
  rs += "    pub fn variant(&self, half_size: [i32; 3]) -> Option<&'static GateVariant> {\n";
  rs += "        let variants: &'static [GateVariant] = self.variants;\n";
  rs += '        variants.iter().find(|v| v.half_size == half_size)\n';
  rs += '    }\n\n';
  rs += '    /// The smallest variant that physically exposes every port in `ports`.\n';
  rs += "    pub fn smallest_with_ports(&self, ports: &[&str]) -> Option<&'static GateVariant> {\n";
  rs += "        let variants: &'static [GateVariant] = self.variants;\n";
  rs += '        variants\n';
  rs += '            .iter()\n';
  rs += '            .find(|v| ports.iter().all(|p| v.ports.contains(p)))\n';
  rs += '    }\n';
  rs += '}\n\n';
  rs += '/// Every procedural gate brick, sorted by `asset`.\n';
  rs += 'pub static PROCEDURAL_GATES: &[ProceduralGate] = &[\n';
  for (const g of gates) {
    rs += `    ProceduralGate {\n`;
    rs += `        asset: ${q(g.asset)},\n`;
    rs += `        component: ${q(g.component)},\n`;
    rs += `        variants: &[\n`;
    for (const v of g.variants) rs += `            GateVariant { half_size: [${v.half.join(', ')}], ports: &[${strs(v.ports)}] },\n`;
    rs += `        ],\n`;
    rs += `    },\n`;
  }
  rs += '];\n\n';
  rs += '/// A procedural gate by brick asset name.\n';
  rs += "pub fn procedural_gate(asset: &str) -> Option<&'static ProceduralGate> {\n";
  rs += '    PROCEDURAL_GATES\n';
  rs += '        .binary_search_by(|g| g.asset.cmp(asset))\n';
  rs += '        .ok()\n';
  rs += '        .map(|i| &PROCEDURAL_GATES[i])\n';
  rs += '}\n\n';
  rs += '/// The procedural gate brick that carries `component`, if any.\n';
  rs += "pub fn procedural_gate_for_component(component: &str) -> Option<&'static ProceduralGate> {\n";
  rs += '    PROCEDURAL_GATES.iter().find(|g| g.component == component)\n';
  rs += '}\n';
  fs.mkdirSync(path.join(out, 'tables'), { recursive: true });
  fs.writeFileSync(path.join(out, 'tables', 'gate_variants.rs'), rs);

  let ts = '// GENERATED by brickadia-zoo scripts/gen_gate_variants.mjs. Do not edit by hand.\n\n';
  ts += '/** One size of a procedural gate brick. */\n';
  ts += 'export interface GateVariant {\n';
  ts += "  /** Procedural half-extent `[x, y, z]` (the brick's `size`) that selects this variant. */\n";
  ts += '  readonly halfSize: readonly [number, number, number];\n';
  ts += "  /** Physical (on-brick) wire ports at this size, in brick order. The component's\n";
  ts += '   * other ports still exist and are reachable through the omniport. */\n';
  ts += '  readonly ports: readonly string[];\n';
  ts += '}\n\n';
  ts += '/** A gate brick asset (`PB_Gate_*`) placed as a procedural brick at one of a fixed\n';
  ts += ' * list of sizes; the game rejects any other size for it. */\n';
  ts += 'export interface ProceduralGate {\n';
  ts += '  readonly asset: string;\n';
  ts += '  readonly component: string;\n';
  ts += '  /** Size variants, smallest first. */\n';
  ts += '  readonly variants: readonly GateVariant[];\n';
  ts += '}\n\n';
  ts += '/** Every procedural gate brick, keyed by asset name. */\n';
  ts += 'export const PROCEDURAL_GATES: ReadonlyMap<string, ProceduralGate> = new Map([\n';
  for (const g of gates) {
    ts += `  [\n    ${q(g.asset)},\n    {\n      asset: ${q(g.asset)},\n      component: ${q(g.component)},\n      variants: [\n`;
    for (const v of g.variants) ts += `        { halfSize: [${v.half.join(', ')}], ports: [${strs(v.ports)}] },\n`;
    ts += `      ],\n    },\n  ],\n`;
  }
  ts += ']);\n\n';
  ts += '/** The procedural gate brick that carries `component`, if any. */\n';
  ts += 'export function proceduralGateForComponent(\n  component: string,\n): ProceduralGate | undefined {\n';
  ts += '  for (const g of PROCEDURAL_GATES.values()) if (g.component === component) return g;\n';
  ts += '  return undefined;\n';
  ts += '}\n\n';
  ts += '/** The smallest variant of `asset` that physically exposes every port in `ports`. */\n';
  ts += 'export function smallestGateVariant(\n  asset: string,\n  ports: readonly string[],\n): GateVariant | undefined {\n';
  ts += '  return PROCEDURAL_GATES.get(asset)?.variants.find((v) =>\n    ports.every((p) => v.ports.includes(p)),\n  );\n';
  ts += '}\n';
  fs.writeFileSync(path.join(out, 'tables', 'gateVariants.ts'), ts);

  return `gate variants: ${gates.length} gates, ${gates.reduce((n, g) => n + g.variants.length, 0)} sizes`;
}

/**
 * Copy the checked-in tables from the brdb and brs-js checkouts (only read) into
 * out/tables, so the generators merge onto them as they would in place.
 */
export function seedTables(out: string, brdb: string, brsjs: string) {
  const tables = path.join(out, 'tables');
  fs.mkdirSync(tables, { recursive: true });
  const seeds: [string, string][] = [
    [brdb, 'crates/brdb/src/assets/brick_sizes.rs'],
    [brdb, 'crates/brdb/src/assets/gate_variants.rs'],
    [brsjs, 'src/brdb/brickSizes.ts'],
    [brsjs, 'src/brdb/gateVariants.ts'],
  ];
  for (const [repo, rel] of seeds) {
    const from = repo && path.join(repo, rel);
    if (from && fs.existsSync(from)) fs.copyFileSync(from, path.join(tables, path.basename(rel)));
  }
}
