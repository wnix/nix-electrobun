{
  description = "Nix flake template for developing Electrobun desktop applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # ------------------------------------------------------------------ #
      #  Electrobun release pinning                                          #
      #  Update these when electrobun releases a new version.               #
      #  To get new hashes: nix-prefetch-url <url>                          #
      # ------------------------------------------------------------------ #
      electrobunVersion = "1.14.4";

      # Nix system string → electrobun platform-arch string
      systemToPlatform = {
        "x86_64-linux"  = "linux-x64";
        "aarch64-linux" = "linux-arm64";
        "x86_64-darwin" = "darwin-x64";
        "aarch64-darwin" = "darwin-arm64";
      };

      # SRI hashes for electrobun-core-<platform>.tar.gz
      coreHashes = {
        "linux-x64"    = "sha256-OVzJvrHq8asW5LamJeycVPSJwTdxT7Ev8H/hELPIWko=";
        "linux-arm64"  = "sha256-db85PGYISqM8o41BZe5+8l6kLV7KomkrgRkIPovYhL4=";
        "darwin-x64"   = "sha256-QI05JSRRvNPyPhh5J32ar4Uq4z7sBi0Pz1r+9tqeqhY=";
        "darwin-arm64" = "sha256-KudbjQFqzyFbxUWWAAW4uP6mAEQTG3sCW8v5AtRZBr8=";
      };

      # SRI hashes for electrobun-cli-<platform>.tar.gz
      cliHashes = {
        "linux-x64"    = "sha256-JsyJpmsO3m9jR4+EDkjBjFvjAx64+pRSRph1Sz4Snmk=";
        "linux-arm64"  = "sha256-Zdlj5sntYLgj4TOshSc/wt7QWKP6Nplj8XIxEftNHH0=";
        "darwin-x64"   = "sha256-fm4eZ8Pt9oMOZDj9tPFyjXY3aZZZR5dF+m3sJYaLUc0=";
        "darwin-arm64" = "sha256-0xqmukGwb2bhXySnBJ8YP+sFrh6TRJUsUbWUfcmb7go=";
      };

      supportedSystems = builtins.attrNames systemToPlatform;
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; config = { }; };

      # ------------------------------------------------------------------ #
      #  Linux runtime libraries required by Electrobun / WebKit2GTK        #
      # ------------------------------------------------------------------ #
      linuxRuntimeLibs = pkgs: with pkgs; [
        webkitgtk_4_1   # WebKit2GTK 4.1 — required by libNativeWrapper.so
        gtk3
        glib
        pango
        cairo
        atk
        gdk-pixbuf
        harfbuzz
        libsoup_3       # libsoup used by WebKit
        at-spi2-atk
        dbus
        xorg.libX11
        xorg.libXcomposite
        xorg.libXcursor
        xorg.libXdamage
        xorg.libXext
        xorg.libXfixes
        xorg.libXi
        xorg.libXrandr
        xorg.libXrender
        xorg.libXtst
        xorg.libxcb
        libGL
        libxkbcommon
        # C++ runtime — some electrobun binaries link libstdc++
        stdenv.cc.cc.lib
      ];

      linuxLibs = pkgs: nixpkgs.lib.optionals pkgs.stdenv.isLinux (linuxRuntimeLibs pkgs);

      # ------------------------------------------------------------------ #
      #  mkElectrobunCore — download + patchelf the core binaries           #
      #                                                                      #
      #  Electrobun downloads its own pre-built bun runtime, launcher, and  #
      #  libNativeWrapper.so at runtime.  On NixOS (and nix-on-Linux) those #
      #  binaries ship with hard-coded interpreter/RPATH paths that don't   #
      #  exist in the Nix store.  We pre-fetch them here and apply          #
      #  autoPatchelfHook so they work out of the box.                      #
      # ------------------------------------------------------------------ #
      mkElectrobunCore = pkgs:
        let
          plat = systemToPlatform.${pkgs.stdenv.hostPlatform.system};
          src = pkgs.fetchurl {
            url = "https://github.com/blackboardsh/electrobun/releases/download/v${electrobunVersion}/electrobun-core-${plat}.tar.gz";
            hash = coreHashes.${plat};
          };
        in
        if pkgs.stdenv.isLinux then
          pkgs.stdenv.mkDerivation {
            pname = "electrobun-core-patched";
            version = electrobunVersion;
            inherit src;

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            # autoPatchelfHook scans every ELF file and rewrites RPATH /
            # interpreter to point to the Nix-store paths of these libs.
            buildInputs = linuxRuntimeLibs pkgs;

            # Allow missing optional deps (e.g. libcef, ALSA on headless)
            autoPatchelfIgnoreMissingDeps = true;

            unpackPhase = ''
              mkdir dist
              tar xzf "$src" -C dist
            '';

            installPhase = ''
              mkdir -p "$out"
              cp -r dist/. "$out/"
              # Mark executables
              for f in bun launcher process_helper bsdiff bspatch \
                        extractor zig-asar zig-zstd; do
                [ -f "$out/$f" ] && chmod +x "$out/$f" || true
              done
            '';
          }
        else
          # Darwin: unpack only — system WebKit.framework is used, no patching
          pkgs.runCommand "electrobun-core-${plat}" { inherit src; } ''
            mkdir -p "$out"
            tar xzf "$src" -C "$out"
          '';

      # mkElectrobunCli — download + patchelf the standalone electrobun CLI
      mkElectrobunCli = pkgs:
        let
          plat = systemToPlatform.${pkgs.stdenv.hostPlatform.system};
          src = pkgs.fetchurl {
            url = "https://github.com/blackboardsh/electrobun/releases/download/v${electrobunVersion}/electrobun-cli-${plat}.tar.gz";
            hash = cliHashes.${plat};
          };
        in
        if pkgs.stdenv.isLinux then
          pkgs.stdenv.mkDerivation {
            pname = "electrobun-cli-patched";
            version = electrobunVersion;
            inherit src;

            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = linuxRuntimeLibs pkgs;
            autoPatchelfIgnoreMissingDeps = true;

            unpackPhase = ''
              tar xzf "$src"
            '';

            installPhase = ''
              mkdir -p "$out"
              install -m 755 electrobun "$out/electrobun"
            '';
          }
        else
          pkgs.runCommand "electrobun-cli-${plat}" { inherit src; } ''
            mkdir -p "$out"
            tar xzf "$src" -C "$out"
            chmod +x "$out/electrobun"
          '';

    in
    {
      # ------------------------------------------------------------------ #
      #  Nix flake template                                                  #
      #  nix flake init -t github:wnix/nix-electrobun                       #
      # ------------------------------------------------------------------ #
      templates.default = {
        path = ./template;
        description = "Electrobun desktop application starter template";
        welcomeText = ''
          # Electrobun Template

          ## Quick Start

            nix develop          # get bun + all system deps + pre-patched Electrobun binaries
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
      #  Development shells                                                  #
      #  nix develop github:wnix/nix-electrobun                             #
      # ------------------------------------------------------------------ #
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          plat = systemToPlatform.${system};
          electrobunCore = mkElectrobunCore pkgs;
          electrobunCli = mkElectrobunCli pkgs;
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);

          # Script users call (or is auto-called) after `bun install`
          # to place pre-patched binaries in the expected node_modules path.
          electrobunPreflight = pkgs.writeShellScriptBin "electrobun-preflight" ''
            set -euo pipefail
            DIST="node_modules/electrobun/dist-${plat}"
            CACHE=".cache"

            if [ ! -d "node_modules/electrobun" ]; then
              echo "[electrobun-preflight] node_modules/electrobun not found."
              echo "  Run 'bun install' first, then re-run this script."
              exit 0
            fi

            if [ ! -f "$DIST/.nix-installed" ]; then
              echo "[electrobun-preflight] Linking pre-patched Electrobun core binaries…"
              mkdir -p "$DIST"
              cp -r "${electrobunCore}/." "$DIST/"
              chmod -R u+w "$DIST"
              touch "$DIST/.nix-installed"
            fi

            # CLI binary — prevents the "Downloading electrobun CLI" network fetch
            mkdir -p "$CACHE"
            if [ ! -f "$CACHE/.nix-electrobun-cli-installed" ]; then
              cp "${electrobunCli}/electrobun" "$CACHE/electrobun"
              chmod +x "$CACHE/electrobun"
              touch "$CACHE/.nix-electrobun-cli-installed"
            fi

            echo "[electrobun-preflight] Ready!"
          '';
        in
        {
          default = pkgs.mkShell {
            # Put libs on buildInputs so pkg-config / compilation works too
            buildInputs = (linuxLibs pkgs)
              ++ nixpkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
                pkg-config cmake
              ]);

            packages = with pkgs; [
              bun git nodejs
              electrobunPreflight
            ] ++ nixpkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];

            shellHook = ''
              ${nixpkgs.lib.optionalString pkgs.stdenv.isLinux ''
                # Make Nix-store WebKit / GTK libs visible to pre-built
                # electrobun binaries (bun, launcher, libNativeWrapper.so …)
                export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''}

              # Auto-run preflight if node_modules already exists
              # (e.g. re-entering the shell after bun install)
              if [ -d "node_modules/electrobun" ]; then
                electrobun-preflight 2>/dev/null || true
              fi

              echo ""
              echo "  Electrobun dev shell  (electrobun v${electrobunVersion}, nixpkgs unstable)"
              echo "  bun $(bun --version 2>/dev/null || echo 'not found')"
              echo ""
              echo "  Workflow:"
              echo "    bun install          — install npm deps (generates bun.lock)"
              echo "    bun start            — run the app"
              echo "    electrobun-preflight — (re)install patched core binaries"
              echo ""
            '';
          };
        }
      );

      # ------------------------------------------------------------------ #
      #  Packages  (nix build)                                              #
      #                                                                      #
      #  packages.default       — the hello-world app (requires FOD hash)   #
      #  packages.node-modules  — standalone node_modules FOD derivation    #
      #  packages.electrobun-core — pre-patched core binaries               #
      # ------------------------------------------------------------------ #
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          plat = systemToPlatform.${system};
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);
          electrobunCore = mkElectrobunCore pkgs;

          # -------------------------------------------------------------- #
          #  Fixed-output derivation: pre-fetch npm dependencies            #
          #  To compute the hash:                                           #
          #    cd template && bun install                                   #
          #    nix build .#node-modules 2>&1 | grep "got:"                 #
          # -------------------------------------------------------------- #
          node-modules = pkgs.stdenv.mkDerivation {
            pname = "electrobun-hello-node-modules";
            version = "0.1.0";
            src = ./template;

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
            # Replace with: nix build .#node-modules 2>&1 | grep "got:"
            outputHash = nixpkgs.lib.fakeHash;
          };

          electrobun-hello =
            let appSrc = ./template; in
            pkgs.writeShellApplication {
              name = "electrobun-hello";
              runtimeInputs = [ pkgs.bun ] ++ (linuxLibs pkgs);

              text = ''
                tmpdir=$(mktemp -d)
                # shellcheck disable=SC2064
                trap "rm -rf '$tmpdir'" EXIT

                cp -r "${appSrc}/." "$tmpdir/"
                chmod -R u+w "$tmpdir"

                # Pre-fetched node_modules (from FOD)
                cp -r "${node-modules}/node_modules" "$tmpdir/node_modules"

                # Pre-patched core binaries → electrobun won't try to download
                mkdir -p "$tmpdir/node_modules/electrobun/dist-${plat}"
                cp -r "${electrobunCore}/." \
                  "$tmpdir/node_modules/electrobun/dist-${plat}/"

                ${nixpkgs.lib.optionalString pkgs.stdenv.isLinux ''
                  export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                ''}

                cd "$tmpdir"
                exec bun start
              '';
            };

        in
        {
          default = electrobun-hello;
          node-modules = node-modules;
          electrobun-core = mkElectrobunCore pkgs;
        }
      );

      # ------------------------------------------------------------------ #
      #  Apps  (nix run github:wnix/nix-electrobun)                        #
      #                                                                      #
      #  Installs npm deps at runtime (needs internet once), but uses       #
      #  pre-patched core binaries from the Nix store — no download of      #
      #  the large electrobun binary tarball at runtime.                    #
      # ------------------------------------------------------------------ #
      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          plat = systemToPlatform.${system};
          ldPath = pkgs.lib.makeLibraryPath (linuxRuntimeLibs pkgs);
          electrobunCore = mkElectrobunCore pkgs;
          electrobunCli = mkElectrobunCli pkgs;

          runner = pkgs.writeShellApplication {
            name = "electrobun-hello-run";
            runtimeInputs = [ pkgs.bun ] ++ (linuxLibs pkgs);

            text = ''
              tmpdir=$(mktemp -d)
              # shellcheck disable=SC2064
              trap "rm -rf '$tmpdir'" EXIT

              cp -r "${./template}/." "$tmpdir/"
              chmod -R u+w "$tmpdir"

              ${nixpkgs.lib.optionalString pkgs.stdenv.isLinux ''
                export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''}

              cd "$tmpdir"

              echo "[nix-electrobun] Installing npm dependencies (requires internet)…"
              HOME="$tmpdir" bun install --no-progress

              # Place pre-patched core binaries so electrobun skips the download
              echo "[nix-electrobun] Setting up pre-patched core binaries…"
              mkdir -p "node_modules/electrobun/dist-${plat}"
              cp -r "${electrobunCore}/." "node_modules/electrobun/dist-${plat}/"

              # Pre-place CLI binary to avoid the "Downloading electrobun CLI" step
              mkdir -p ".cache"
              cp "${electrobunCli}/electrobun" ".cache/electrobun"
              chmod +x ".cache/electrobun"

              echo "[nix-electrobun] Launching Electrobun hello-world…"
              exec bun start
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${runner}/bin/electrobun-hello-run";
          };
        }
      );
    };
}
