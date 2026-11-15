#!/usr/bin/env node
// Run the zoo pipeline unattended in a fresh game process, with omegga as a
// library in this process (no terminal or tmux):
//
//   bin/run-pipeline.js [run|dump|world] [omegga dir]
//
// Starts the server, has the zoo plugin run that console action (/zoo run, ...)
// once the world is up, and stops the server when the plugin writes
// out/status.json. The omegga dir defaults to the one this plugin is installed
// in. A fresh process each time, because a second dump in one game process reads
// dead procedural brick types. Exits 0 only when the action succeeded.
//
// Env: ZOO_OUT  results folder (default <plugin>/out)
//      ZOO_TIMEOUT  seconds to wait for the action (default 1800)
//      OMEGGA_DIR  the omegga package to load (default: the `omegga` on PATH)
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const plugin = path.resolve(__dirname, '..');
const argv = process.argv.slice(2);
const action = argv[0] ?? 'run';
const dir = path.resolve(argv[1] ?? path.join(plugin, '..', '..'));
const out = path.resolve(process.env.ZOO_OUT ?? path.join(plugin, 'out'));
const status = path.join(out, 'status.json');
const timeoutMs = Number(process.env.ZOO_TIMEOUT ?? 1800) * 1000;
const ACTIONS = ['run', 'dump', 'world'];

function fail(message, code = 1) {
  console.error(`run-pipeline: ${message}`);
  process.exit(code);
}

/** The omegga package root: OMEGGA_DIR, or the package of the `omegga` command on PATH. */
function omeggaRoot() {
  if (process.env.OMEGGA_DIR) return path.resolve(process.env.OMEGGA_DIR);
  for (const p of (process.env.PATH ?? '').split(path.delimiter)) {
    const bin = path.join(p, 'omegga');
    // <root>/bin/omegga, usually reached through a symlink in a global bin folder
    if (fs.existsSync(bin)) return path.resolve(fs.realpathSync(bin), '..', '..');
  }
  fail('no omegga on PATH; set OMEGGA_DIR');
}

/** KEY=VALUE lines of the omegga dir's .env, as omegga's CLI loads them; set values win. */
function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);
    if (!m || process.env[m[1]] !== undefined) continue;
    process.env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
}

/** The game half: start the server, let the plugin run, stop it. Returns the plugin's status. */
async function game() {
  if (!fs.existsSync(path.join(dir, 'omegga-config.yml'))) fail(`no omegga-config.yml in ${dir}`, 2);
  const cwd = process.cwd();
  // omegga reads its environment (STEAM_INSTALLS_DIR, ...) when it is loaded
  process.chdir(dir);
  loadEnv(path.join(dir, '.env'));
  const { Omegga, config } = require(omeggaRoot());

  const conf = config.read(config.find(dir));
  // the pipeline clears the world and places thousands of bricks: never on a listed server
  if (conf.server?.publiclyListed !== false) fail(`${dir}/omegga-config.yml must set server.publiclyListed: false`, 2);
  // what omegga's CLI sets for a Steam install that is already downloaded
  conf.__STEAM = true;

  fs.mkdirSync(out, { recursive: true });
  fs.rmSync(status, { force: true });
  fs.writeFileSync(path.join(plugin, '.autorun.json'), JSON.stringify({ action, out }));
  const server = new Omegga(dir, conf, { noweb: true, https: false, debug: false });
  let exited = false;
  server.on('exit', () => (exited = true));
  console.log(`run-pipeline: starting ${dir} for "${action}", results in ${out}`);
  await server.start();

  const started = Date.now();
  while (!fs.existsSync(status) && !exited && Date.now() - started < timeoutMs) await new Promise(r => setTimeout(r, 1000));
  const result = fs.existsSync(status) ? JSON.parse(fs.readFileSync(status, 'utf8')) : null;
  await server.stop();
  fs.rmSync(path.join(plugin, '.autorun.json'), { force: true });
  process.chdir(cwd);
  if (!result) fail(exited ? 'the game exited before the run finished' : `timed out after ${timeoutMs / 1000} s`);
  return result;
}

async function main() {
  if (!ACTIONS.includes(action)) fail(`no action ${action}: ${ACTIONS.join(', ')}`, 2);
  const result = await game();
  console.log(JSON.stringify(result, null, 2));
  process.exit(result.ok ? 0 : 1);
}

main().catch(e => fail(e.stack ?? String(e)));
