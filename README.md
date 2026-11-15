# zoo (omegga plugin)

brickadia-zoo's inventory pipeline on a headless Brickadia server, through the
omegga-ue4ss plugin, with no game client. The in-game scripts are in `lua/zoo`
(ported from cake/brickadia-zoo, on omegga-ue4ss's `BR` through
`lua/zoo/zoo.lua`); `mods/Zoo` is the UE4SS mod that runs them. `omegga.plugin.ts`
(a safe plugin; `access.json` grants `fs`, `path`, `zlib` and `node:sqlite`)
drives them, writes what the game reports, and turns it into the tables and
maps (`src/`).

Console commands while the server runs:

| | |
|--|--|
| `/zoo run` | the dump, then `full_inventory.json` and the brick size and gate variant tables |
| `/zoo dump` | just the dump (once per game process) |
| `/zoo world` | build the zoo, save it as `out/zoo-<time>.brdb`, dump the property options, write `property_map.json` |
| `/zoo build [phase]`, `/zoo save <name>`, `/zoo props` | the parts of `world` |
| `/zoo compare <out dir> [all]` | what changed from another run's results to these |
| `/zoo ping`, `/zoo file <script.lua> <GLOBAL> <json>` | checks and development |

Plugin config: `brdb-dir` and `brs-js-dir`, checkouts that are only read. Their
tables seed `out/tables`, so the generators merge onto them as they would in
place, and brdb's schemas give the property map its component types.

Two scripts run outside the game:

    bin/run-pipeline.js [run|dump|world] [omegga dir]
        a fresh server (omegga loaded as a library), the action, then stop; a
        second dump in one game process is wrong, so unattended runs use this
    bin/update-repos.js --wirescript <dir> --brdb <dir> --brs-js <dir> [--write]
        what a run changes in those repos; --write applies it (release builds
        only, never commits). Outside the plugin because it runs their own
        tooling, and a safe plugin can't start processes

`npm run typecheck` checks the plugin against `omegga.d.ts`, which omegga writes on its
first build of the plugin. `ZOO_OUT` points a run at another results folder. The server must be unlisted
(`publiclyListed: false`); a run clears the world.

Results in `out/`: `inventory_dump.ndjson`, `inventory_dump.json`,
`catalog_dump.json`, `full_inventory.json`, `zoo-<time>.brdb`,
`property_env_dump.json`, `property_options_dump.json`, `property_map.json`,
`tables/`, `build.json` (the game build), `dump_summary.json`,
`build_summary.json`, `status.json`, `run.log`.

## License

CC0 1.0 Universal (public domain dedication); see `LICENSE`.
