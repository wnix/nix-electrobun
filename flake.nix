{
  description = "Nix flake template for developing Electrobun desktop applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # ------------------------------------------------------------------ #
      #  Import helpers from nix/                                           #
      # ------------------------------------------------------------------ #

      # Version pins and SRI hashes for the pre-built tarballs.
      pinning = import ./nix/pinning.nix;
      inherit (pinning) electrobunVersion systemToPlatform coreHashes cliHashes;

      # Runtime library list for Linux (WebKitGTK, GTK3, X11, …).
      linuxRuntimeLibs = import ./nix/linux-libs.nix;

      # Pre-built binary derivations (download + autoPatchelf on Linux).
      prebuilt = import ./nix/prebuilt.nix {
        inherit electrobunVersion systemToPlatform coreHashes cliHashes
                linuxRuntimeLibs;
      };
      inherit (prebuilt) mkElectrobunCore mkElectrobunCli;

      # Source-build derivations (Zig + C++20 + bun, Linux only).
      fromSource = import ./nix/from-source.nix {
        inherit electrobunVersion systemToPlatform linuxRuntimeLibs
                mkElectrobunCore;
      };
      inherit (fromSource) mkElectrobunSource mkElectrobunSrcNpmDeps
                           mkElectrobunFromSource;

      # ------------------------------------------------------------------ #
      #  Plumbing                                                           #
      # ------------------------------------------------------------------ #
      supportedSystems = builtins.attrNames systemToPlatform;
      forAllSystems     = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; config = {}; };

      # Returns linuxRuntimeLibs only on Linux (empty list on Darwin/etc.).
      linuxLibs = pkgs:
        pkgs.lib.optionals pkgs.stdenv.isLinux (linuxRuntimeLibs pkgs);

    in
    {
      # ------------------------------------------------------------------ #
      #  Template                                                           #
      #  nix flake init -t github:wnix/nix-electrobun                      #
      # ------------------------------------------------------------------ #
      templates.default = {
        path = ./template;
        description = "Electrobun desktop application starter template";
        welcomeText = ''
          # Electrobun Template

          ## Quick Start

            nix develop          # get bun + all system deps + pre-built Electrobun binaries
            bun install          # install npm dependencies  (generates bun.lock)
            bun start            # build + launch the app

          ## Commands

            bun start            — dev build + launch
            bun run dev          — dev build + launch + watch mode
            bun run build        — create a distributable

          ## Nix Reproducible Build

          After running `bun install` (which generates bun.lock):

            # First attempt prints the expected FOD hash:
            nix build 2>&1 | grep "got:"

            # Paste that hash into flake.nix as outputHash, then:
            nix build
            nix run    # runs the Nix-built app

          ## Customising

          - electrobun.config.ts  — app name, version, identifier, build options
          - src/bun/index.ts      — main process (windows, native APIs, IPC)
          - src/mainview/         — renderer  (HTML / CSS / TypeScript)
        '';
      };

      # ------------------------------------------------------------------ #
      #  Dev shells                                                         #
      #  nix develop github:wnix/nix-electrobun                            #
      #                                                                     #
      #  On Linux: uses the from-source build so libNativeWrapper.so has   #
      #  correct Nix-store RPATHs and no libayatana-appindicator3 dep.     #
      # ------------------------------------------------------------------ #
      devShells = forAllSystems (system:
        let
          pkgs  = pkgsFor system;
          plat  = systemToPlatform.${system};
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);

          # Nix-store paths for dist binaries and the CLI binary.
          # On Linux we use the from-source build; on Darwin the pre-built core.
          electrobunDistSrc =
            if pkgs.stdenv.isLinux
            then "${mkElectrobunFromSource pkgs}/dist-${plat}"
            else "${mkElectrobunCore pkgs}";

          electrobunCliSrc =
            if pkgs.stdenv.isLinux
            then "${mkElectrobunFromSource pkgs}/bin/electrobun"
            else "${mkElectrobunCli pkgs}/electrobun";

          # Script users call (or is auto-called) after `bun install`
          # to place Electrobun binaries in the expected node_modules paths.
          electrobunPreflight = pkgs.writeShellScriptBin "electrobun-preflight" ''
            set -euo pipefail
            DIST="node_modules/electrobun/dist-${plat}"
            # electrobun.cjs checks this path before downloading the CLI
            CLI_CACHE="node_modules/electrobun/.cache"

            if [ ! -d "node_modules/electrobun" ]; then
              echo "[electrobun-preflight] node_modules/electrobun not found."
              echo "  Run 'bun install' first, then re-run this script."
              exit 0
            fi

            if [ ! -f "$DIST/.nix-installed" ]; then
              echo "[electrobun-preflight] Installing Electrobun dist binaries…"
              mkdir -p "$DIST"
              cp -r "${electrobunDistSrc}/." "$DIST/"
              chmod -R u+w "$DIST"
              touch "$DIST/.nix-installed"
            fi

            # Pre-place CLI to prevent the "Downloading electrobun CLI" network fetch.
            mkdir -p "$CLI_CACHE"
            if [ ! -f "$CLI_CACHE/.nix-electrobun-cli-installed" ]; then
              cp "${electrobunCliSrc}" "$CLI_CACHE/electrobun"
              chmod +x "$CLI_CACHE/electrobun"
              touch "$CLI_CACHE/.nix-electrobun-cli-installed"
            fi

            echo "[electrobun-preflight] Ready!"
          '';
        in
        {
          default = pkgs.mkShell {
            buildInputs = (linuxLibs pkgs)
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
                pkg-config cmake
              ]);

            packages = with pkgs; [
              bun git nodejs
              electrobunPreflight
            ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];

            shellHook = ''
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''}

              # Auto-run preflight if node_modules is already present
              if [ -d "node_modules/electrobun" ]; then
                electrobun-preflight 2>/dev/null || true
              fi

              echo ""
              echo "  Electrobun dev shell  (electrobun v${electrobunVersion}, nixpkgs unstable)"
              echo "  bun $(bun --version 2>/dev/null || echo 'not found')"
              echo ""
              echo "  Workflow:"
              echo "    bun install          — install npm deps"
              echo "    bun start            — run the app"
              echo "    electrobun-preflight — (re)install Electrobun binaries"
              echo ""
            '';
          };
        }
      );

      # ------------------------------------------------------------------ #
      #  Packages  (nix build)                                             #
      # ------------------------------------------------------------------ #
      packages = forAllSystems (system:
        let
          pkgs   = pkgsFor system;
          plat   = systemToPlatform.${system};
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);

          # On Linux: from-source build (correct RPATHs, -DNO_APPINDICATOR).
          # On Darwin: pre-built core (uses system WebKit.framework).
          electrobunBinaries =
            if pkgs.stdenv.isLinux then mkElectrobunFromSource pkgs
            else mkElectrobunCore pkgs;

          electrobunCliSrc =
            if pkgs.stdenv.isLinux
            then "${mkElectrobunFromSource pkgs}/bin/electrobun"
            else "${mkElectrobunCli pkgs}/electrobun";

          # ------------------------------------------------------------ #
          #  Fixed-output derivation: pre-fetch npm deps for the template #
          #  Compute hash: nix build .#node-modules 2>&1 | grep "got:"   #
          # ------------------------------------------------------------ #
          node-modules = pkgs.stdenv.mkDerivation {
            pname   = "electrobun-hello-node-modules";
            version = "0.1.0";
            src     = ./template;

            nativeBuildInputs = [ pkgs.bun ];

            impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars
              ++ [ "GIT_PROXY_COMMAND" "SOCKS_SERVER" ];

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              bun install --no-progress --no-save
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r node_modules "$out/"
              runHook postInstall
            '';

            outputHashAlgo = "sha256";
            outputHashMode = "recursive";
            outputHash     = "sha256-uhLjvB1EeELlN/hYT76kVhv7pZ/K3hv81V58rLO3rQk=";
          };

          electrobun-hello =
            let appSrc = ./template; in
            pkgs.writeShellApplication {
              name          = "electrobun-hello";
              runtimeInputs = [ pkgs.bun ];

              text = ''
                tmpdir=$(mktemp -d)
                # shellcheck disable=SC2064
                trap "rm -rf '$tmpdir'" EXIT

                cp -r "${appSrc}/." "$tmpdir/"
                chmod -R u+w "$tmpdir"

                # Pre-fetched node_modules (from FOD — no network needed)
                cp -r "${node-modules}/node_modules" "$tmpdir/node_modules"

                # Dist binaries: from-source on Linux (correct RPATHs),
                # pre-built on Darwin (system WebKit.framework).
                mkdir -p "$tmpdir/node_modules/electrobun/dist-${plat}"
                cp -r "${electrobunBinaries}/dist-${plat}/." \
                  "$tmpdir/node_modules/electrobun/dist-${plat}/"

                # Pre-place CLI where electrobun.cjs looks for it.
                # (checks node_modules/electrobun/.cache/electrobun before
                #  downloading from GitHub releases)
                mkdir -p "$tmpdir/node_modules/electrobun/.cache"
                cp "${electrobunCliSrc}" \
                  "$tmpdir/node_modules/electrobun/.cache/electrobun"
                chmod +x "$tmpdir/node_modules/electrobun/.cache/electrobun"

                ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                  export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                ''}

                cd "$tmpdir"
                exec bun start
              '';
            };

        in
        {
          default      = electrobun-hello;
          node-modules = node-modules;
          electrobun-core = mkElectrobunCore pkgs;
        }
        # From-source packages are Linux-only; expose only on Linux systems
        # to avoid evaluation errors on Darwin.
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          electrobun-source       = mkElectrobunSource pkgs;
          electrobun-src-npm-deps = mkElectrobunSrcNpmDeps pkgs (mkElectrobunSource pkgs);
          electrobun-from-source  = mkElectrobunFromSource pkgs;
        }
      );

      # ------------------------------------------------------------------ #
      #  Apps  (nix run github:wnix/nix-electrobun)                       #
      #                                                                     #
      #  Installs npm deps at runtime (needs internet once), then runs     #
      #  the hello-world template with Electrobun binaries from Nix.       #
      # ------------------------------------------------------------------ #
      apps = forAllSystems (system:
        let
          pkgs   = pkgsFor system;
          plat   = systemToPlatform.${system};
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);

          electrobunBinaries =
            if pkgs.stdenv.isLinux then mkElectrobunFromSource pkgs
            else mkElectrobunCore pkgs;

          electrobunCliSrc =
            if pkgs.stdenv.isLinux
            then "${mkElectrobunFromSource pkgs}/bin/electrobun"
            else "${mkElectrobunCli pkgs}/electrobun";

          runner = pkgs.writeShellApplication {
            name          = "electrobun-hello-run";
            runtimeInputs = [ pkgs.bun ];

            text = ''
              tmpdir=$(mktemp -d)
              # shellcheck disable=SC2064
              trap "rm -rf '$tmpdir'" EXIT

              cp -r "${./template}/." "$tmpdir/"
              chmod -R u+w "$tmpdir"

              cd "$tmpdir"

              echo "[nix-electrobun] Installing npm dependencies (requires internet)…"
              HOME="$tmpdir" bun install --no-progress

              # Dist binaries: from-source on Linux (correct RPATHs,
              # -DNO_APPINDICATOR), pre-built on Darwin.
              echo "[nix-electrobun] Setting up Electrobun binaries…"
              mkdir -p "node_modules/electrobun/dist-${plat}"
              cp -r "${electrobunBinaries}/dist-${plat}/." \
                "node_modules/electrobun/dist-${plat}/"

              # Pre-place CLI where electrobun.cjs looks for it before
              # downloading from GitHub releases.
              mkdir -p "node_modules/electrobun/.cache"
              cp "${electrobunCliSrc}" \
                "node_modules/electrobun/.cache/electrobun"
              chmod +x "node_modules/electrobun/.cache/electrobun"

              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''}

              echo "[nix-electrobun] Launching Electrobun hello-world…"
              exec bun start
            '';
          };
        in
        {
          default = {
            type    = "app";
            program = "${runner}/bin/electrobun-hello-run";
          };
        }
      );
    };
}
