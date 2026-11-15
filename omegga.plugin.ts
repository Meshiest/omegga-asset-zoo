// brickadia-zoo on omegga: drives the zoo's in-game scripts (mods/Zoo, lua/zoo)
// through the ue4ss plugin, writes what the game reports to out/, and turns it
// into the tables and maps brdb, brs-js and wirescript use (src/). A safe plugin:
// access.json grants fs, path, and zlib and node:sqlite for reading a saved world.
//
//   /zoo ping            the mod answers
//   /zoo run             dump, then full_inventory.json and the size and gate variant tables
//   /zoo dump            inventory_dump.ndjson + catalog_dump.json (once per game process)
//   /zoo build [phase]   build the in-world zoo (clears the world)
//   /zoo save <name>     save the world as out/<name>.brdb
//   /zoo props           the property option dumps (clears the world)
//   /zoo world           build, save as out/zoo-<time>.brdb, props, then property_map.json
//   /zoo compare <out dir> [all]   what changed from another run's results to these
//   /zoo file <script.lua> <GLOBAL> <json>   development: one script, result in out/last.json
import fs from 'fs';
import path from 'path';
import OmeggaPlugin, { OL, PC, PS } from 'omegga';
import { compare } from './src/compare';
import { brickSizes, combineFull, gateVariants, mergeDump, seedTables } from './src/inventory';
import { propertyMap } from './src/properties';

/** Checkouts that are only read: their tables seed out/tables, brdb's schemas feed the property map. */
type Config = { 'brdb-dir': string; 'brs-js-dir': string };
type Storage = Record<string, never>;

/** What bin/run-pipeline.js leaves in <plugin>/.autorun.json for an unattended run. */
type Autorun = { action: string; out?: string };

type Summary = Record<string, unknown> & {
  total?: number;
  processedRange?: { last: number };
  range?: { last: number };
  error?: string;
  errors?: unknown;
};

type Interop = { emitPlugin(event: string, ...args: unknown[]): Promise<unknown> };

// the built plugin runs from <plugin>/.build/plugin.js
const PLUGIN = path.resolve(__dirname, '..');
const AUTORUN = path.join(PLUGIN, '.autorun.json');
const PHASES = ['components', 'standalone', 'assetrefs', 'shapes', 'procedural', 'materials', 'wheels', 'dynamicgrid'];
// Particle has no reference gate in the game any more; the desktop skipped it too
const ASSET_TYPES = ['Audio', 'OneShotAudio', 'WheelEngineAudio', 'Font', 'Item', 'Pickup', 'Projectile'];

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const list = (v: unknown): Summary[] => (Array.isArray(v) ? v : v ? [v as Summary] : []);
const sum = (v: unknown, key: string) => list(v).reduce((n, r) => n + (typeof r[key] === 'number' ? (r[key] as number) : 0), 0);

export default class Zoo implements OmeggaPlugin<Config, Storage> {
  omegga: OL;
  config: PC<Config>;
  store: PS<Storage>;
  ue4ss: Interop | null = null;
  out = path.join(PLUGIN, 'out');
  busy = false;
  lastError = '';

  constructor(omegga: OL, config: PC<Config>, store: PS<Storage>) {
    this.omegga = omegga;
    this.config = config;
    this.store = store;
  }

  async init() {
    this.ue4ss = (await this.omegga.getPlugin('ue4ss')) as Interop | null;
    this.omegga.on('consolecmd:zoo', this.onCommand);
    if (fs.existsSync(AUTORUN)) {
      const run = JSON.parse(fs.readFileSync(AUTORUN, 'utf8')) as Autorun;
      fs.rmSync(AUTORUN, { force: true });
      void this.autorun(run);
    }
    return { registeredCommands: [] };
  }

  onCommand = (action: string, ...args: string[]) => void this.command(action, args);

  async stop() {
    this.omegga.off('consolecmd:zoo', this.onCommand);
  }

  /** omegga's log file doesn't keep a plugin's console output, so runs keep their own */
  log(...args: unknown[]) {
    console.log(...args);
    const line = args.map(a => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ');
    try {
      fs.mkdirSync(this.out, { recursive: true });
      fs.appendFileSync(path.join(this.out, 'run.log'), `${new Date().toISOString()} ${line}\n`);
    } catch {
      // logging must never break a run
    }
  }

  write(file: string, value: unknown) {
    fs.writeFileSync(path.join(this.out, file), JSON.stringify(value, null, 2));
  }

  /** Call a handler in the Zoo mod; throws the Lua error. */
  async call<T = unknown>(name: string, ...args: unknown[]): Promise<T> {
    if (!this.ue4ss) throw new Error('the ue4ss plugin is not loaded');
    const r = (await this.ue4ss.emitPlugin('call', name, ...args)) as { ok: boolean; result?: T; error?: string } | undefined;
    if (!r?.ok) throw new Error(r?.error ?? `no reply from ${name}`);
    return r.result as T;
  }

  runFile<T = Summary>(name: string, global?: string, config?: Record<string, unknown>) {
    return this.call<T>('run_file', name, global ?? null, config ?? null);
  }

  /**
   * Run an offset/limit script to the end in chunks. Each call runs on the game
   * thread, and the bridge's watchdog stops a callback after 5 s.
   */
  async chunked(name: string, global: string, config: Record<string, unknown>, limit = 80) {
    const summaries: Summary[] = [];
    for (let offset = 0; ; offset += limit) {
      const r = await this.runFile(name, global, { ...config, offset, limit, clearFirst: config.clearFirst === true && offset === 0 });
      if (r?.error) throw new Error(`${name}: ${r.error}`);
      summaries.push(r);
      const range = r?.processedRange ?? r?.range;
      const last = range?.last ?? 0;
      const what = config.mode ?? config.type ?? (config.standalone ? 'standalone' : config.procedural ? 'procedural' : '');
      this.log(`${name} ${what} ${last}/${r?.total ?? '?'}`);
      if (!range || last >= (r.total ?? 0)) return summaries;
    }
  }

  async dump() {
    // the game's procedural brick types are GC'd behind its cache once a dump deletes
    // their bricks, and a map reload doesn't clear it: a second dump reads dead types
    if (await this.call<boolean>('dumped'))
      throw new Error('this game process already ran a dump and its procedural brick types are stale; restart the server (bin/run-pipeline.js does)');
    await this.call('mark_dumped');
    const ndjson = path.join(this.out, 'inventory_dump.ndjson');
    const summary = {
      catalog: await this.chunked('inventory_dump.lua', 'DUMP', { clearFirst: true, outFile: ndjson }),
      standalone: await this.chunked('inventory_dump.lua', 'DUMP', { standalone: true, outFile: ndjson }),
      procedural: await this.chunked('inventory_dump.lua', 'DUMP', { procedural: true, outFile: ndjson }),
      assets: await this.runFile('catalog_dump.lua', 'CAT', { outFile: path.join(this.out, 'catalog_dump.json') }),
    };
    this.write('dump_summary.json', summary);
    const parts = [...summary.catalog, ...summary.standalone, ...summary.procedural];
    const errors = parts.flatMap(r => (Array.isArray(r.errors) ? r.errors : []));
    this.log(`dump: ${sum(parts, 'written')} records, ${sum(parts, 'components')} components, ${sum(parts, 'ports')} ports, ` +
      `${sum(parts, 'placeFail')} placement failures, ${sum(parts, 'probeErrors')} probe errors, ${errors.length} errors; out/dump_summary.json`);
  }

  /**
   * Clear every brick and entity (br.World.ClearAll through omegga). The console
   * command applies on a later tick and doesn't answer, so wait until the bricks
   * are gone and the entity count stops falling, then destroy what it left (see
   * destroy_entities in the mod).
   */
  async clearWorld() {
    this.omegga.clearAllBricks({ quiet: true, bricks: true, entities: true });
    let last = Infinity, steady = 0;
    for (let i = 0; i < 100; i++) {
      await sleep(100);
      const c = await this.call<{ bricks: number; entities: number }>('world_counts');
      steady = c.entities === last ? steady + 1 : 0;
      last = c.entities;
      if (c.bricks === 0 && (c.entities === 0 || steady >= 5)) {
        if (c.entities > 0) this.log(`destroyed ${await this.call<number>('destroy_entities')} entity actor(s) the clear left`);
        return;
      }
    }
    throw new Error('the world was not empty 10 s after clearing it');
  }

  /** Build the in-world zoo, phase by phase as the desktop CLI did; the world is cleared first. */
  async build(phase = 'all') {
    if (phase !== 'all' && !PHASES.includes(phase)) throw new Error(`no phase ${phase}: all, ${PHASES.join(', ')}`);
    const want = (p: string) => phase === 'all' || phase === p;
    const s: Record<string, unknown> = {};
    await this.clearWorld();
    if (want('components')) s.components = await this.chunked('inventory.lua', 'INV', { doRerouters: true }, 24);
    if (want('standalone')) s.standalone = await this.chunked('inventory.lua', 'INV', { standalone: true, baseY: 800, doRerouters: true }, 24);
    if (want('assetrefs')) {
      const refs: Record<string, Summary[]> = {};
      for (const type of ASSET_TYPES) refs[type] = await this.chunked('asset_reference.lua', 'INVA', { type }, 100);
      s.assetrefs = refs;
      this.log(`asset references set and read back: ${Object.entries(refs).map(([k, l]) => `${k} ${sum(l, 'sent')}/${l[0]?.total ?? '?'}`).join(', ')}`);
    }
    if (want('shapes')) s.shapes = await this.chunked('every_brick.lua', 'EB', {}, 172);
    if (want('procedural')) s.procedural = await this.chunked('every_procedural_brick.lua', 'EPB', {}, 24);
    if (want('materials')) s.materials = await this.runFile('extras.lua', 'EX', { mode: 'materials' });
    if (want('wheels')) s.wheels = await this.chunked('extras.lua', 'EX', { mode: 'wheels' }, 16);
    if (want('dynamicgrid')) s.dynamicgrid = await this.runFile('extras.lua', 'EX', { mode: 'dynamicgrid' });
    s.bricks = await this.call<number>('brick_count');
    this.write('build_summary.json', s);
    this.log(`build: ${s.bricks} bricks; components ${sum(s.components, 'placed')} placed, ${sum(s.components, 'placeFail')} placement failures; ` +
      `shapes ${sum(s.shapes, 'placed')}/${list(s.shapes)[0]?.total ?? '?'}; procedural ${sum(s.procedural, 'placed')}/${list(s.procedural)[0]?.total ?? '?'}; ` +
      `wheels ${sum(s.wheels, 'spawned')}/${list(s.wheels)[0]?.total ?? '?'}; out/build_summary.json`);
  }

  /** Save the world as data/Saved/Worlds/<name>.brdb and copy it to out/. */
  async save(name: string | undefined) {
    if (!name || !/^[\w.-]+$/.test(name)) throw new Error('usage: /zoo save <name> (letters, digits, _ . -)');
    if (!(await this.omegga.saveWorldAs(name))) throw new Error(`saving ${name} failed (does data/Saved/Worlds/${name}.brdb exist already?)`);
    const from = await this.omegga.getWorldPath(name);
    if (!from) throw new Error(`omegga saved ${name} but can't find its file`);
    // the game keeps the world open for a moment after saving; copy it once its
    // write-ahead log is folded back in, or the copy can miss the last writes
    for (let i = 0; i < 50 && fs.existsSync(`${from}-wal`); i++) await sleep(200);
    fs.copyFileSync(from, path.join(this.out, `${name}.brdb`));
    this.log(`saved ${name}; out/${name}.brdb`);
  }

  /** The property option dumps; the options pass places gates, so it clears the world. */
  async props() {
    const env = await this.runFile('property_map_dump.lua');
    this.write('property_env_dump.json', env);
    this.log(`property_map_dump.lua: ${Object.keys(env ?? {}).join(', ')}`);
    this.log('property_options_dump.lua set:', await this.runFile('property_options_dump.lua', 'PO', { phase: 'set' }));
    // the gate edits apply on a later tick
    await sleep(2000);
    this.write('property_options_dump.json', await this.runFile('property_options_dump.lua', 'PO', { phase: 'read' }));
  }

  /** Merge, combine, and the brick size and gate variant tables, from out/'s dump. */
  tables() {
    seedTables(this.out, this.config['brdb-dir'], this.config['brs-js-dir']);
    for (const step of [mergeDump, combineFull, brickSizes, gateVariants]) this.log(step(this.out));
  }

  /**
   * The game build these results come from: omegga's version (the changelist),
   * and the build name ("Release-EA3-CL-16507") from BR, whose branch
   * bin/update-repos.js checks.
   */
  async buildInfo() {
    const r = (await this.ue4ss?.emitPlugin('exec', 'return BR.server.build()')) as { ok: boolean; result?: string } | undefined;
    return { buildVersion: r?.ok ? r.result : null, cl: this.omegga.version };
  }

  /** Run one console action; false (with lastError) when it failed. */
  async command(action: string, args: string[]): Promise<boolean> {
    if (this.busy) {
      this.log('busy with another command');
      return false;
    }
    this.busy = true;
    try {
      fs.mkdirSync(this.out, { recursive: true });
      if (action !== 'ping' && action !== 'compare') this.write('build.json', { ...(await this.buildInfo()), action, at: new Date().toISOString() });
      switch (action) {
        case 'ping':
          this.log(await this.call('ping'));
          break;
        case 'run':
          await this.dump();
          this.tables();
          break;
        case 'dump':
          await this.dump();
          break;
        case 'build':
          await this.build(args[0]);
          break;
        case 'save':
          await this.save(args[0]);
          break;
        case 'props':
          await this.props();
          break;
        case 'world': {
          await this.build('all');
          const name = `zoo-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}`;
          await this.save(name);
          await this.props();
          if (!this.config['brdb-dir']) throw new Error('set the plugin config brdb-dir for the property map');
          for (const note of propertyMap(this.out, path.join(this.out, `${name}.brdb`), this.config['brdb-dir'])) this.log(note);
          break;
        }
        case 'compare':
          if (!args[0]) throw new Error('usage: /zoo compare <out dir> [all]');
          for (const line of compare(path.resolve(args[0]), this.out, args[1] === 'all' ? Infinity : 40)) this.log(line);
          break;
        case 'file': {
          const [name, global, ...rest] = args;
          const started = Date.now();
          const result = await this.runFile(name, global, rest.length ? JSON.parse(rest.join(' ')) : undefined);
          this.write('last.json', result);
          this.log(`${name} done in ${Date.now() - started} ms; out/last.json`);
          break;
        }
        default:
          throw new Error('usage: /zoo ping | run | dump | build [phase] | save <name> | props | world | compare <out dir>');
      }
      return true;
    } catch (e) {
      this.lastError = (e as Error).message;
      this.log('failed:', this.lastError);
      return false;
    } finally {
      this.busy = false;
    }
  }

  /**
   * Unattended runs (bin/run-pipeline.js): wait for the world, run the action,
   * and leave out/status.json, which tells the runner to stop the server.
   */
  async autorun(run: Autorun) {
    if (run.out) this.out = path.resolve(run.out);
    const status = path.join(this.out, 'status.json');
    fs.mkdirSync(this.out, { recursive: true });
    fs.rmSync(status, { force: true });
    const finish = (s: object) => fs.writeFileSync(status, JSON.stringify({ action: run.action, ...s, finished: new Date().toISOString() }, null, 2));
    try {
      let why = 'not loaded';
      for (let i = 0; ; i++) {
        const ready = await this.call<boolean>('ready').catch((e: Error) => ((why = e.message), false));
        if (ready) break;
        if (i % 30 === 29) this.log(`waiting for the world (${why})`);
        if (i >= 300) throw new Error(`the world was not ready after 5 minutes (${why})`);
        await sleep(1000);
      }
      const ok = await this.command(run.action, []);
      finish(ok ? { ok: true } : { ok: false, error: this.lastError });
    } catch (e) {
      finish({ ok: false, error: (e as Error).message });
    }
  }
}
