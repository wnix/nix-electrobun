# nix-electrobun

A Nix flake for developing and packaging
[Electrobun](https://blackboard.sh/electrobun/) desktop applications.

## TL;DR

```bash
# Instant demo – opens a hello-world desktop window
nix run github:wnix/nix-electrobun

# Start a new Electrobun project from the template
nix flake init -t github:wnix/nix-electrobun
nix develop          # enter the dev shell (provides bun + system deps)
bun install          # install JavaScript dependencies
bun start            # launch the app
```

## What this flake provides

| Output | Purpose |
|---|---|
| `templates.default` | Starter template for new Electrobun projects |
| `devShells.default` | Dev shell with bun, git, and all system libraries |
| `packages.default` | Reproducible app build (FOD-based, see below) |
| `apps.default` | `nix run` entry point – downloads deps at first launch |

All outputs are available for `x86_64-linux`, `aarch64-linux`,
`x86_64-darwin`, and `aarch64-darwin`.

## Using the template (recommended workflow)

### 1. Bootstrap from the template

```bash
mkdir my-app && cd my-app
nix flake init -t github:wnix/nix-electrobun
```

This copies the hello-world skeleton into your directory:

```
my-app/
├── flake.nix            ← project flake (devShell + package + app)
├── flake.lock           ← pinned nixpkgs
├── package.json
├── electrobun.config.ts ← app name / identifier / build config
├── tsconfig.json
└── src/
    ├── bun/
    │   └── index.ts     ← main process (windows, native APIs, IPC)
    └── mainview/
        ├── index.html
        ├── index.css
        └── index.ts     ← renderer (frontend TypeScript)
```

### 2. Enter the dev shell

```bash
nix develop
```

Provides: `bun`, `git`, `node`, and (on Linux) `webkitgtk_4_1`, `gtk3`,
and all libraries required by Electrobun.

### 3. Install and run

```bash
bun install   # generates bun.lock (text format, commit this!)
bun start     # dev build + launch
```

### 4. Customise

- **`electrobun.config.ts`** – set your app name, bundle identifier, and version
- **`src/bun/index.ts`** – main process: create windows, use native APIs, set up IPC
- **`src/mainview/`** – renderer: write HTML / CSS / TypeScript as usual

### 5. Reproducible Nix build (optional)

After generating `bun.lock` you can build the app reproducibly with Nix.
The first `nix build` will fail and print the expected hash:

```bash
nix build 2>&1 | grep "got:"
# got:  sha256-XXXXXXXXXX...
```

Copy that hash into `flake.nix` as the `outputHash` for the `node-modules`
derivation, then:

```bash
nix build         # produces ./result/bin/my-electrobun-app
nix run           # runs the built app
```

Update the hash whenever you add or remove npm dependencies.

## `nix run github:wnix/nix-electrobun`

The `apps.default` target is a helper script that:

1. Copies the hello-world template to a temporary directory
2. Runs `bun install` (requires internet access on first run)
3. Launches `bun start` → `electrobun dev`

On Linux, `LD_LIBRARY_PATH` is set automatically so that WebKit2GTK
and GTK3 are found without needing a global system install.

> **Note** – This requires internet access because `bun install` fetches
> npm packages at launch time.  For an air-gapped / reproducible build
> use `nix build` with a computed FOD hash (see above).

## Linux system dependencies

Electrobun uses [WebKit2GTK](https://webkitgtk.org/) on Linux.
The dev shell and the app wrapper both set up the correct library paths
automatically via Nix.

If you use the app outside of the Nix shell (e.g., a plain `bun start`),
make sure the following libraries are available on your system:

```
libwebkit2gtk-4.1
libgtk-3
```

On Ubuntu/Debian: `sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev`

## Packaging notes

Electrobun's Nix story is evolving.  The current state (early 2026):

- **No `buildBunPackage` in nixpkgs** – nixpkgs PR #376299 is pending.
- **This flake uses the FOD pattern** – a fixed-output derivation runs
  `bun install` with network access to pre-fetch all npm packages, then a
  pure build step assembles the application.  The hash is stored in
  `flake.nix` and must be updated when dependencies change.
- **bun2nix** (`github:nix-community/bun2nix`) is an alternative that
  fetches each package individually for better reproducibility.  Adding it
  as a flake input is straightforward if you prefer that approach.

## License

GPL-3.0 – see [LICENSE](./LICENSE).

Electrobun itself is MIT licensed.
