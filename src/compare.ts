// What changed between two runs (two game builds, or one build before and after a
// patch): bricks, components, ports, assets, shapes, brick sizes, gate variants and
// property options added, removed or changed. Reads full_inventory.json,
// property_map.json and build.json from each results folder.
import fs from 'fs';
import path from 'path';

type Port = { type?: string };
type Ports = Record<string, Port>;
type Component = { componentType: string; wireInputPorts?: Ports; wireOutputPorts?: Ports };
type HalfSize = { X: unknown; Y: unknown; Z: unknown };
type Brick = {
  assetName: string;
  components?: Component[] | Record<string, never>;
  halfSize?: HalfSize;
  gateVariants?: { halfSize: HalfSize; physicalPorts?: unknown[] }[];
};
type Inventory = { components?: Brick[]; assets?: Record<string, { entries?: { name: string }[] }>; shapes?: Brick[] };
type PropertyMap = Record<'environments' | 'components', { option: string; properties?: { name: string; type?: string }[] }[]>;
type Run = { inv: Inventory; props: PropertyMap | null; build: { buildVersion?: string } | null };

const arr = <T>(v: T[] | Record<string, never> | undefined): T[] => (Array.isArray(v) ? v : []);

function load(dir: string): Run {
  const json = <T>(f: string): T | null => (fs.existsSync(path.join(dir, f)) ? (JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8')) as T) : null);
  const inv = json<Inventory>('full_inventory.json');
  if (!inv) throw new Error(`${dir} has no full_inventory.json (run the pipeline there first)`);
  return { inv, props: json<PropertyMap>('property_map.json'), build: json('build.json') };
}

/** The differences from results folder `a` to `b`, as report lines. `max` caps each list. */
export function compare(a: string, b: string, max = 40): string[] {
  const A = load(a), B = load(b);
  const lines: string[] = [];
  const out = (s = '') => lines.push(s);
  const list = (label: string, items: string[]) => {
    if (items.length) out(`  ${label} (${items.length}): ${items.slice(0, max).join(', ')}${items.length > max ? `, +${items.length - max} more` : ''}`);
  };
  const diffSets = <T>(x: Set<T>, y: Set<T>): [T[], T[]] => [[...y].filter(k => !x.has(k)).sort(), [...x].filter(k => !y.has(k)).sort()];

  out(`old: ${A.build?.buildVersion ?? a}`);
  out(`new: ${B.build?.buildVersion ?? b}`);
  out();

  const recs = (inv: Inventory) => new Map(arr(inv.components).map(r => [r.assetName, r]));
  const ra = recs(A.inv), rb = recs(B.inv);
  const [addedBricks, removedBricks] = diffSets(new Set(ra.keys()), new Set(rb.keys()));
  const portChanges: string[] = [], renamed: string[] = [];
  for (const [name, r] of rb) {
    const o = ra.get(name);
    if (!o) continue;
    const comps = (rec: Brick) => new Map(arr(rec.components).map(c => [c.componentType, c]));
    const ca = comps(o), cb = comps(r);
    const [newTypes, oldTypes] = diffSets(new Set(ca.keys()), new Set(cb.keys()));
    if (newTypes.length || oldTypes.length) renamed.push(`${name}: ${oldTypes.join('+') || '-'} -> ${newTypes.join('+') || '-'}`);
    for (const [type, c] of cb) {
      const oc = ca.get(type);
      if (!oc) continue;
      for (const dir of ['wireInputPorts', 'wireOutputPorts'] as const) {
        const before = oc[dir] ?? {}, after = c[dir] ?? {};
        const [add, rem] = diffSets(new Set(Object.keys(before)), new Set(Object.keys(after)));
        const d = dir === 'wireInputPorts' ? 'in' : 'out';
        if (add.length) portChanges.push(`${type} ${d} +${add.join(' +')}`);
        if (rem.length) portChanges.push(`${type} ${d} -${rem.join(' -')}`);
        for (const p of Object.keys(after)) if (before[p] && before[p].type !== after[p].type) portChanges.push(`${type} ${d} ${p}: ${before[p].type} -> ${after[p].type}`);
      }
    }
  }
  out(`bricks with components: ${ra.size} -> ${rb.size}`);
  list('added', addedBricks);
  list('removed', removedBricks);
  list('component type changed', renamed);
  list('port changes', portChanges);
  out();

  out('assets:');
  for (const type of [...new Set([...Object.keys(A.inv.assets ?? {}), ...Object.keys(B.inv.assets ?? {})])].sort()) {
    const names = (inv: Inventory) => new Set(arr(inv.assets?.[type]?.entries).map(e => e.name));
    const na = names(A.inv), nb = names(B.inv);
    const [add, rem] = diffSets(na, nb);
    out(`  ${type}: ${na.size} -> ${nb.size}`);
    list('  added', add);
    list('  removed', rem);
  }
  out();

  const shapes = (inv: Inventory) => new Map(arr(inv.shapes).map(s => [s.assetName, s]));
  const sa = shapes(A.inv), sb = shapes(B.inv);
  const [addShapes, remShapes] = diffSets(new Set(sa.keys()), new Set(sb.keys()));
  // a record whose size didn't read comes back with object strings in halfSize
  const size = (s?: Brick) => (typeof s?.halfSize?.X === 'number' ? `${s.halfSize.X}x${s.halfSize.Y}x${s.halfSize.Z}` : '?');
  const resized = [...sb.keys()]
    .filter(k => sa.has(k) && size(sa.get(k)) !== '?' && size(sa.get(k)) !== size(sb.get(k)))
    .map(k => `${k} ${size(sa.get(k))} -> ${size(sb.get(k))}`);
  out(`brick shapes: ${sa.size} -> ${sb.size}`);
  list('added', addShapes.map(k => `${k} ${size(sb.get(k))}`));
  list('removed', remShapes);
  list('resized', resized);
  out();

  const variants = (inv: Inventory) =>
    new Map(
      arr(inv.components)
        .filter(r => arr(r.gateVariants).length)
        .map(r => [r.assetName, arr(r.gateVariants).map(v => `${v.halfSize.X}x${v.halfSize.Y}x${v.halfSize.Z}/${arr(v.physicalPorts).length}p`).sort().join(' ')]),
    );
  const va = variants(A.inv), vb = variants(B.inv);
  const [addV, remV] = diffSets(new Set(va.keys()), new Set(vb.keys()));
  out(`gate size variants: ${va.size} -> ${vb.size} gates`);
  list('added', addV);
  list('removed', remV);
  list('changed', [...vb.keys()].filter(k => va.has(k) && va.get(k) !== vb.get(k)).map(k => `${k}: ${va.get(k)} -> ${vb.get(k)}`));
  out();

  if (A.props && B.props) {
    for (const key of ['environments', 'components'] as const) {
      const props = (p: PropertyMap) => new Map(arr(p[key]).map(e => [e.option, new Set(arr(e.properties).map(x => `${x.name}:${x.type ?? '?'}`))]));
      const pa = props(A.props), pb = props(B.props);
      const [add, rem] = diffSets(new Set(pa.keys()), new Set(pb.keys()));
      const changed: string[] = [];
      for (const [k, s] of pb) {
        const before = pa.get(k);
        if (!before) continue;
        const [pAdd, pRem] = diffSets(before, s);
        if (pAdd.length || pRem.length) changed.push(`${k}: ${[...pAdd.map(x => `+${x}`), ...pRem.map(x => `-${x}`)].join(' ')}`);
      }
      out(`property options, ${key}: ${pa.size} -> ${pb.size}`);
      list('added', add);
      list('removed', rem);
      list('changed', changed);
    }
  }
  return lines;
}
