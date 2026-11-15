#!/usr/bin/env node
// Bring wirescript, brdb and brs-js up to date with a pipeline run:
//
//   bin/update-repos.js --wirescript <dir> --brdb <dir> --brs-js <dir> [--out <dir>] [--write]
//
// Without --write it only reports, per file, whether the run would change it.
// With --write it updates the working trees and leaves the changes for you to
// review and commit; it never commits. Any repo flag can be left out to skip it.
//
//   wirescript  data/inventory_dump.ndjson and data/asset_dump.json (its ignored
//               inputs), then its own scripts/gen_inventory.mjs and gen_assets.mjs,
//               which write the tracked logic_gate_inventory.simple.json and
//               asset_inventory.simple.json
//   brdb        crates/brdb/src/assets/brick_sizes.rs and gate_variants.rs
//   brs-js      src/brdb/brickSizes.ts and gateVariants.ts, formatted with its prettier
//
// These repos are public, so only results from a release build are accepted:
// out/build.json must name a Release-* build.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const args = process.argv.slice(2);
const flag = name => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? path.resolve(args[i + 1]) : null;
};
const write = args.includes('--write');
const out = flag('--out') ?? path.resolve(__dirname, '..', 'out');
const repos = { wirescript: flag('--wirescript'), brdb: flag('--brdb'), 'brs-js': flag('--brs-js') };
if (!Object.values(repos).some(Boolean)) {
  console.error('usage: update-repos.js --wirescript <dir> --brdb <dir> --brs-js <dir> [--out <dir>] [--write]');
  process.exit(2);
}

const build = fs.existsSync(path.join(out, 'build.json')) ? JSON.parse(fs.readFileSync(path.join(out, 'build.json'), 'utf8')) : null;
if (!build?.buildVersion) {
  console.error(`no build.json in ${out}; run the pipeline first`);
  process.exit(2);
}
if (!/^Release-/.test(build.buildVersion)) {
  console.error(`refusing: ${out} is from ${build.buildVersion}, not a release build, and these repos are public`);
  process.exit(2);
}
for (const f of ['inventory_dump.ndjson', 'catalog_dump.json', 'tables/brickSizes.ts', 'tables/gateVariants.ts', 'tables/brick_sizes.rs', 'tables/gate_variants.rs']) {
  if (!fs.existsSync(path.join(out, f))) {
    console.error(`missing ${f} in ${out}; run bin/run-pipeline.js run first`);
    process.exit(2);
  }
}
console.log(`${write ? 'updating' : 'would update (dry run; --write to apply)'} from ${build.buildVersion}, run ${build.at}`);

const changes = [];
/** Put `text` at `file`, or in a dry run only report whether it would change. */
function put(file, text) {
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if (before === text) return console.log(`  unchanged  ${file}`);
  const a = (before ?? '').split('\n'), b = text.split('\n');
  let differ = Math.abs(a.length - b.length);
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) differ++;
  console.log(`  ${before === null ? 'new' : 'changed'}    ${file} (${differ} lines)`);
  changes.push(file);
  if (write) fs.writeFileSync(file, text);
}

if (repos.wirescript) {
  console.log('wirescript');
  const ws = path.join(repos.wirescript, 'crates', 'wirescript');
  // the generators read data/ next to them; a dry run gives them a copy of it
  const scratch = path.resolve(__dirname, '..', '.scratch', 'update-wirescript');
  const root = write ? ws : scratch;
  if (!write) {
    fs.rmSync(scratch, { recursive: true, force: true });
    fs.mkdirSync(path.join(scratch, 'scripts'), { recursive: true });
    fs.cpSync(path.join(ws, 'data'), path.join(scratch, 'data'), { recursive: true });
    for (const s of ['gen_inventory.mjs', 'gen_assets.mjs']) fs.copyFileSync(path.join(ws, 'scripts', s), path.join(scratch, 'scripts', s));
  }
  fs.copyFileSync(path.join(out, 'inventory_dump.ndjson'), path.join(root, 'data', 'inventory_dump.ndjson'));
  fs.copyFileSync(path.join(out, 'catalog_dump.json'), path.join(root, 'data', 'asset_dump.json'));
  for (const s of ['gen_inventory.mjs', 'gen_assets.mjs']) execFileSync(process.execPath, [path.join(root, 'scripts', s)], { cwd: root, stdio: 'ignore' });
  for (const f of ['logic_gate_inventory.simple.json', 'asset_inventory.simple.json']) {
    const tracked = path.join(ws, 'data', f);
    const generated = fs.readFileSync(path.join(root, 'data', f), 'utf8');
    if (write) {
      // already written by the generator; report against git's copy
      const head = execFileSync('git', ['-C', repos.wirescript, 'show', `HEAD:crates/wirescript/data/${f}`], { encoding: 'utf8' });
      if (head === generated) console.log(`  unchanged  ${tracked}`);
      else { console.log(`  changed    ${tracked}`); changes.push(tracked); }
    } else put(tracked, generated);
  }
}

if (repos.brdb) {
  console.log('brdb');
  for (const f of ['brick_sizes.rs', 'gate_variants.rs'])
    put(path.join(repos.brdb, 'crates', 'brdb', 'src', 'assets', f), fs.readFileSync(path.join(out, 'tables', f), 'utf8'));
}

if (repos['brs-js']) {
  console.log('brs-js');
  const prettier = path.join(repos['brs-js'], 'node_modules', '.bin', 'prettier');
  for (const f of ['brickSizes.ts', 'gateVariants.ts']) {
    const formatted = execFileSync(prettier, ['--config', path.join(repos['brs-js'], '.prettierrc'), path.join(out, 'tables', f)], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    });
    put(path.join(repos['brs-js'], 'src', 'brdb', f), formatted);
  }
}

console.log(changes.length ? `${changes.length} file(s) ${write ? 'changed; review and commit them yourself' : 'would change'}` : 'everything is up to date');
