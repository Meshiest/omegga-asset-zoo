// The option map for the gates whose output type follows a picked setting: Get/Set
// Environment Property (Environment + PropertyName) and Get/Set Component Property
// (ComponentType + PropertyName), each property with its value type. Reads
//   out/property_env_dump.json      property_map_dump.lua: spawnable component types and
//                                   each BR*Environment class's UPROPERTYs
//   out/property_options_dump.json  property_options_dump.lua: the game's own PropertyName
//                                   picker per Environment and Component Type; authoritative
//   the saved zoo world             its Environment.bp preset: the property names the game's
//                                   reflection serializes (TimeOfDay, CloudCoverage, ... are
//                                   not UPROPERTYs)
//   a brdb checkout (only read)     each component type's data struct and field types
// and writes out/property_map.json.
import fs from 'fs';
import path from 'path';
import { zstdDecompressSync } from 'zlib';
import { DatabaseSync } from 'node:sqlite';

type ValueType = { type: string; [k: string]: unknown };
type ClassProp = { name?: string; kind: string; enum?: string; class?: string; inner?: string; struct?: string };
type EnvClass = { properties: ClassProp[]; displayName?: string; class?: string };
type EnvDump = {
  environments: Record<string, EnvClass>;
  pickers?: { environment?: { option: string; label: string }[]; componentType?: { option: string; label: string }[] };
  spawnable: { name: string; displayName: string; category: string }[];
};
type Picker = { options?: string[] | Record<string, never>; labels?: string[] | Record<string, never>; types?: Record<string, ClassProp> };
type OptionsDump = { environments?: Record<string, Picker>; components?: Record<string, Picker> };
type Property = { name: string; label?: string; [k: string]: unknown };
type Environment = { presetGroup: string | null; env?: EnvClass; properties: Property[]; option?: string | null; label?: string; class?: string | null };
type Preset = { data?: { groups?: Record<string, Record<string, unknown>> } };

// Lua encodes an empty table as {}; the pickers' lists are arrays
const list = <T>(x: T[] | Record<string, never> | undefined): T[] => (Array.isArray(x) ? x : []);

function readEnvironmentPreset(brdb: string): Preset {
  const db = new DatabaseSync(brdb, { readOnly: true });
  const row = db
    .prepare(
      `select b.compression, b.content from files f join blobs b on b.blob_id = f.content_id
       where f.name = 'Environment.bp' and f.deleted_at is null order by f.file_id desc limit 1`,
    )
    .get() as { compression: number; content: Uint8Array } | undefined;
  db.close();
  if (!row) throw new Error(`${brdb} has no Environment.bp`);
  const buf = Buffer.from(row.content);
  return JSON.parse((row.compression ? zstdDecompressSync(buf) : buf).toString('utf8')) as Preset;
}

function structType(s?: string): ValueType {
  if (s === 'LinearColor' || s === 'Color') return { type: 'color', struct: s };
  if (s === 'Vector' || s === 'Vector3f') return { type: 'vector', struct: s };
  if (s === 'Rotator' || s === 'Rotator3f') return { type: 'rotator', struct: s };
  if (s === 'WireGraphString') return { type: 'string', struct: s };
  if (s === 'Quat') return { type: 'quat' };
  return { type: 'struct', struct: s };
}

/** An FProperty from the Lua dumps as a value type. */
function classPropType(p: ClassProp): ValueType {
  switch (p.kind) {
    case 'FloatProperty':
    case 'DoubleProperty':
      return { type: 'float' };
    case 'IntProperty':
    case 'Int64Property':
    case 'ByteProperty':
      return { type: 'int' };
    case 'BoolProperty':
      return { type: 'bool' };
    case 'StrProperty':
    case 'NameProperty':
    case 'TextProperty':
      return { type: 'string' };
    case 'EnumProperty':
      return { type: 'enum', enum: p.enum };
    case 'ClassProperty':
      return { type: 'class', class: p.class };
    case 'ObjectProperty':
    case 'WeakObjectProperty':
      return { type: 'object', class: p.class };
    case 'ArrayProperty':
      return { type: 'array', inner: p.inner };
    case 'StructProperty':
      return structType(p.struct);
    default:
      return { type: 'unknown', kind: p.kind };
  }
}

/** A preset value's JSON shape, for the properties that are not UPROPERTYs. */
function presetValueType(v: unknown): ValueType {
  if (typeof v === 'number') return { type: 'float' };
  if (typeof v === 'boolean') return { type: 'bool' };
  if (typeof v === 'string') return { type: 'string' };
  if (v && typeof v === 'object' && 'R' in v && 'A' in v) return { type: 'color', struct: 'LinearColor' };
  if (v && typeof v === 'object' && 'X' in v && 'Z' in v) return { type: 'vector' };
  return { type: 'unknown' };
}

const INTS = new Set(['i8', 'i16', 'i32', 'i64', 'u8', 'u16', 'u32', 'u64']);
/** A brdb schema field type as a value type. */
function schemaType(t: string, enums: Set<string>): ValueType {
  if (t.endsWith('[]')) return { type: 'array', inner: schemaType(t.slice(0, -2), enums) };
  if (t === 'bool') return { type: 'bool' };
  if (t === 'f32' || t === 'f64') return { type: 'float' };
  if (INTS.has(t)) return { type: 'int' };
  if (t === 'str') return { type: 'string' };
  if (t === 'object') return { type: 'object' };
  if (t === 'class') return { type: 'class' };
  if (enums.has(t)) return { type: 'enum', enum: t };
  return structType(t);
}

function parseSchema(text: string) {
  const structs = new Map<string, [string, string][]>();
  const enums = new Set<string>();
  for (const m of text.matchAll(/^(struct|enum) (\w+) \{\n([\s\S]*?)^\}/gm)) {
    if (m[1] === 'enum') {
      enums.add(m[2]);
      continue;
    }
    const fields: [string, string][] = [];
    for (const line of m[3].split('\n')) {
      const f = /^\s+(\w+): ([^,]+),?\s*$/.exec(line);
      if (f) fields.push([f[1], f[2].trim()]);
    }
    structs.set(m[2], fields);
  }
  return { structs, enums };
}

// preset group key -> environment class suffix. Space ("Universe") and Studio ("Lighting")
// are absent from a plate world's preset, so they come from their class properties alone.
const GROUP_CLASS: Record<string, string> = { sky: 'Sky', groundPlate: 'Ground', water: 'Water', ambience: 'Ambience' };

/** Write out/property_map.json from the dumps, the saved zoo `world` and the brdb checkout. Returns notes. */
export function propertyMap(out: string, world: string, brdb: string): string[] {
  const notes: string[] = [];
  const schemaFile = path.join(brdb, 'crates/brdb/schemas/BRSavedComponentChunkSoA_max.schema');
  const componentDb = path.join(brdb, 'crates/brdb/src/wrapper/component_db.rs');
  const dump = JSON.parse(fs.readFileSync(path.join(out, 'property_env_dump.json'), 'utf8')) as EnvDump;
  const probeFile = path.join(out, 'property_options_dump.json');
  const probe = fs.existsSync(probeFile) ? (JSON.parse(fs.readFileSync(probeFile, 'utf8')) as OptionsDump) : null;
  const preset = readEnvironmentPreset(world);

  const environments: Environment[] = [];
  const covered = new Set<string>();
  for (const [group, values] of Object.entries(preset.data?.groups ?? {})) {
    const env = dump.environments[GROUP_CLASS[group]];
    const byName = new Map((env?.properties ?? []).map(p => [p.name, p]));
    const properties = Object.entries(values).map(([name, v]): Property => {
      const cp = byName.get(name);
      return cp ? { name, ...classPropType(cp), source: 'preset+class' } : { name, ...presetValueType(v), source: 'preset' };
    });
    if (env) covered.add(GROUP_CLASS[group]);
    environments.push({ presetGroup: group, env, properties });
  }
  for (const [suffix, env] of Object.entries(dump.environments)) {
    if (covered.has(suffix)) continue;
    environments.push({
      presetGroup: null,
      env,
      properties: env.properties.map(p => ({ name: p.name ?? '', ...classPropType(p), source: 'class' })),
    });
  }
  // The gate stores the picker's option string (GroundPlate, Studio, Universe, ...), which is
  // neither the preset group key nor the class name; the picker label is the class's display name.
  const envPicker = dump.pickers?.environment ?? [];
  for (const e of environments) {
    const pick = envPicker.find(p => p.label === e.env?.displayName);
    e.option = pick?.option ?? null;
    e.label = pick?.label ?? e.env?.displayName ?? '';
    e.class = e.env?.class ?? null;
    delete e.env;
  }
  environments.sort((a, b) => (a.option ?? '~').localeCompare(b.option ?? '~'));
  for (const p of envPicker)
    if (!environments.some(e => e.option === p.option)) notes.push(`picker environment with no property source: ${p.option} (${p.label})`);
  // with the probe, the gate's own PropertyName picker decides which properties exist,
  // their order and labels; the passes above only supply their types
  if (probe)
    for (const e of environments) {
      const pick = e.option ? probe.environments?.[e.option] : undefined;
      if (!pick) continue;
      const labels = list(pick.labels);
      const byName = new Map(e.properties.map(p => [p.name, p]));
      e.properties = list(pick.options).map((name, i) => ({ ...(byName.get(name) ?? { name, type: 'unknown' }), label: labels[i] ?? '' }));
    }

  const { structs, enums } = parseSchema(fs.readFileSync(schemaFile, 'utf8'));
  const pairs = new Map([...fs.readFileSync(componentDb, 'utf8').matchAll(/\("([\w]+)", "([\w]+)"\)/g)].map(m => [m[1], m[2]]));
  // the Component Type picker's own list (player-spawnable types minus Input Splitter)
  const typePicker = dump.pickers?.componentType ?? dump.spawnable.filter(c => c.category !== '').map(c => ({ option: c.name, label: c.displayName }));
  const components = typePicker.map(c => {
    const struct = pairs.get(c.option) ?? null;
    const fields = struct ? structs.get(struct) : undefined;
    const pick = probe?.components?.[c.option];
    if (!pick)
      return { option: c.option, label: c.label, struct, properties: (fields ?? []).map(([name, t]) => ({ name, ...schemaType(t, enums), source: 'schema' })) };
    // the picker also lists struct members ("Color.R") and runtime-only fields a save
    // never stores (Button bHeld, PressCount); `saved` says which the save carries
    const savedNames = new Set((fields ?? []).map(([name]) => name));
    const labels = list(pick.labels);
    return {
      option: c.option,
      label: c.label,
      struct,
      properties: list(pick.options).map((name, i) => ({
        name,
        label: labels[i] ?? '',
        ...classPropType(pick.types?.[name] ?? { kind: 'unresolved' }),
        saved: savedNames.has(name.split('.')[0]),
      })),
    };
  });

  const doc = {
    // the same relative names the desktop pipeline recorded
    source: { schema: schemaFile, probe: probe ? 'out/property_options_dump.json' : null },
    // How the gates store their settings (confirmed from a saved zoo):
    //   Environment, PropertyName: plain strings (the picker option / property name)
    //   ComponentType: an external asset reference of asset type BrickComponentTypeBase,
    //                  named by the component type (BrickComponentTypeBase/Component_PointLight)
    encoding: { componentTypeAssetType: 'BrickComponentTypeBase' },
    environments,
    components,
  };
  fs.writeFileSync(path.join(out, 'property_map.json'), JSON.stringify(doc, null, 2) + '\n');
  const envProps = environments.reduce((n, e) => n + e.properties.length, 0);
  const compProps = components.reduce((n, c) => n + c.properties.length, 0);
  notes.unshift(`property map: ${environments.length} environments (${envProps} properties), ${components.length} component types (${compProps} properties)`);
  for (const c of components.filter(c => !c.struct || !structs.has(c.struct))) notes.push(`no data struct for ${c.option}`);
  for (const e of environments) for (const p of e.properties.filter(p => p.type === 'unknown')) notes.push(`unknown type: ${e.label}.${p.name}`);
  return notes;
}
