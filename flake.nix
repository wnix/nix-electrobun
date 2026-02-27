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

      # ------------------------------------------------------------------ #
      #  Build Electrobun from source (EXPERIMENTAL — Linux only)          #
      #                                                                     #
      #  Compiles the key native components directly against the            #
      #  Nix-store WebKitGTK, eliminating the need for autoPatchelf or     #
      #  LD_LIBRARY_PATH hacks.                                             #
      #                                                                     #
      #  What is built from source:                                         #
      #    launcher            — Zig binary (entry-point / signal handler)  #
      #    libNativeWrapper.so — C++20 bridge to WebKitGTK (GTK-only)       #
      #    main.js / npmbin.js — TypeScript bundles compiled with bun       #
      #    electrobun (CLI)    — bun --compile self-contained binary         #
      #                                                                     #
      #  What is borrowed from the pre-built core tarball (pure-Zig,       #
      #  no system lib dependencies — no patching required):               #
      #    libasar.so, zig-asar, zig-zstd, extractor                       #
      #    TODO: build these from source once zig-asar is a standalone     #
      #          Nix derivation                                             #
      #                                                                     #
      #  What is replaced from nixpkgs:                                    #
      #    bun (JS runtime), bsdiff, bspatch                               #
      #                                                                     #
      #  Getting started (two hashes need computing before first build):   #
      #                                                                     #
      #    Step 1 — pin the source hash:                                   #
      #      nix build .#packages.x86_64-linux.electrobun-source 2>&1 \   #
      #        | grep "got:"                                                #
      #      Paste the hash into mkElectrobunSource below.                 #
      #                                                                     #
      #    Step 2 — pin the npm-deps hash:                                 #
      #      nix build .#packages.x86_64-linux.electrobun-src-npm-deps \  #
      #        2>&1 | grep "got:"                                           #
      #      Paste into mkElectrobunSrcNpmDeps below.                      #
      #                                                                     #
      #    Step 3 — build:                                                  #
      #      nix build .#packages.x86_64-linux.electrobun-from-source     #
      # ------------------------------------------------------------------ #

      # Fixed-output derivation: fetch the upstream source tree.
      # The only submodule (package/src/bsdiff/zstd) is replaced by nixpkgs
      # bsdiff, so fetchSubmodules = false (the default) is fine.
      mkElectrobunSource = pkgs:
        pkgs.fetchFromGitHub {
          owner = "blackboardsh";
          repo  = "electrobun";
          rev   = "v${electrobunVersion}";
          # Compute with:
          #   nix build .#packages.x86_64-linux.electrobun-source 2>&1 | grep "got:"
          hash  = nixpkgs.lib.fakeHash;
        };

      # Fixed-output derivation: npm dependencies of the electrobun package.
      # Required to build the TypeScript CLI and JS bundle (main.js).
      # Compute after pinning mkElectrobunSource.hash:
      #   nix build .#packages.x86_64-linux.electrobun-src-npm-deps 2>&1 | grep "got:"
      mkElectrobunSrcNpmDeps = pkgs: electrobunSrc:
        pkgs.stdenv.mkDerivation {
          pname   = "electrobun-src-npm-deps";
          version = electrobunVersion;
          src     = electrobunSrc;

          nativeBuildInputs = [ pkgs.bun ];

          impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars
            ++ [ "GIT_PROXY_COMMAND" "SOCKS_SERVER" ];

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            pushd package
            bun install --no-progress --frozen-lockfile
            popd
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -r package/node_modules "$out/"
            runHook postInstall
          '';

          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          # Compute with:
          #   nix build .#packages.x86_64-linux.electrobun-src-npm-deps 2>&1 | grep "got:"
          outputHash = nixpkgs.lib.fakeHash;
        };

      mkElectrobunFromSource = pkgs:
        let
          plat = systemToPlatform.${pkgs.stdenv.hostPlatform.system};

          # Zig cross-target string for the launcher binary.
          zigTarget = {
            "x86_64-linux"  = "x86_64-linux-gnu";
            "aarch64-linux" = "aarch64-linux-gnu";
          }.${pkgs.stdenv.hostPlatform.system} or
            (throw "electrobun-from-source: unsupported system ${pkgs.stdenv.hostPlatform.system}");

          # Pre-built core is used only for the pure-Zig tools (libasar.so,
          # zig-asar, zig-zstd, extractor) that have no GTK/WebKit deps.
          electrobunCore    = mkElectrobunCore pkgs;
          electrobunSrc     = mkElectrobunSource pkgs;
          electrobunNpmDeps = mkElectrobunSrcNpmDeps pkgs electrobunSrc;
        in

        if !pkgs.stdenv.isLinux then
          throw "electrobun-from-source: Linux only (Darwin build requires Objective-C++ / Cocoa — not yet implemented)"
        else

        pkgs.stdenv.mkDerivation {
          pname   = "electrobun-from-source";
          version = electrobunVersion;
          src     = electrobunSrc;

          nativeBuildInputs = with pkgs; [
            zig_0_13    # builds the launcher binary
            bun         # bundles TypeScript → JS and compiles the CLI
            pkg-config  # provides WebKitGTK / GTK3 compile+link flags
          ];

          # These become -I and -L search paths for the g++ invocation below.
          buildInputs = linuxRuntimeLibs pkgs;

          buildPhase = ''
            runHook preBuild

            export HOME="$TMPDIR"
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"

            # All electrobun source lives under package/ in the repo root.
            # pushd/popd keeps the working directory clean for installPhase.
            pushd package

            # -------------------------------------------------------------- #
            # 1. launcher — pure Zig, links only libc                         #
            #    The launcher is the OS-level entry point that starts bun,    #
            #    forwards signals, and waits for the child process to exit.   #
            # -------------------------------------------------------------- #
            (
              cd src/launcher
              zig build \
                -Doptimize=ReleaseSafe \
                -Dtarget=${zigTarget} \
                --prefix "$TMPDIR/launcher-out"
            )

            # -------------------------------------------------------------- #
            # 2. libNativeWrapper.so — C++20, WebKitGTK + GTK3 (GTK-only)    #
            #                                                                  #
            #    This shared library is the native bridge between the Bun JS  #
            #    runtime and the system windowing / rendering layer.           #
            #                                                                  #
            #    IMPORTANT: because we compile against the Nix-store           #
            #    WebKitGTK, the linker automatically embeds correct RPATHs    #
            #    pointing into /nix/store.  No autoPatchelf or               #
            #    LD_LIBRARY_PATH hacks are needed at runtime!                 #
            #                                                                  #
            #    Also links libasar.so (pure-Zig ASAR library borrowed from  #
            #    the pre-built core tarball; it has no GTK deps so the RPATH  #
            #    $ORIGIN trick is sufficient).                                 #
            #                                                                  #
            #    NOTE: if the build fails with missing CEF SDK headers, add   #
            #    a cefHeaders FOD (the CEF include/ dir from Spotify's CDN)   #
            #    and pass -I''${cefHeaders} to the g++ compile step.          #
            # -------------------------------------------------------------- #
            mkdir -p src/native/linux/build src/native/build

            LIBASAR="${electrobunCore}/libasar.so"
            PKG_CFLAGS="$(pkg-config --cflags webkit2gtk-4.1 gtk+-3.0)"
            PKG_LIBS="$(pkg-config --libs   webkit2gtk-4.1 gtk+-3.0)"

            # Compile the C++20 translation unit.
            # -Isrc/native/linux  exposes the local cef_loader.h header which
            #   guards conditional CEF code paths in nativeWrapper.cpp.
            # -DNO_APPINDICATOR   disables optional libappindicator tray support.
            g++ -c -std=c++20 -fPIC \
              $PKG_CFLAGS \
              -Isrc/native/linux \
              -DNO_APPINDICATOR \
              -o src/native/linux/build/nativeWrapper.o \
              src/native/linux/nativeWrapper.cpp

            # Link the GTK-only shared library.
            # -Wl,-rpath,'$ORIGIN'  instructs the runtime linker to search the
            #   directory containing libNativeWrapper.so itself for libasar.so.
            #   Both files are installed to dist-<plat>/ so this resolves.
            g++ -shared \
              -Wl,-rpath,'$ORIGIN' \
              -o src/native/build/libNativeWrapper.so \
              src/native/linux/build/nativeWrapper.o \
              "$LIBASAR" \
              $PKG_LIBS \
              -ldl -lpthread

            # -------------------------------------------------------------- #
            # 3. TypeScript bundles and standalone CLI via bun                #
            # -------------------------------------------------------------- #

            # Wire in the pre-fetched node_modules (no network needed here).
            cp -r "${electrobunNpmDeps}/node_modules" ./node_modules

            # Framework main-process bundle — loaded by bun at app start.
            bun build \
              ./src/bun/index.ts \
              --target=bun \
              --outfile="$TMPDIR/main.js"

            # npm-bin shim — the thin wrapper invoked as `electrobun` via npm.
            bun build \
              ./src/npmbin/index.ts \
              --target=bun \
              --outfile="$TMPDIR/npmbin.js"

            # Standalone CLI binary.  `bun build --compile` embeds a bun
            # runtime inside the CLI executable itself (separate from the
            # app's runtime bun binary in dist-<plat>/bun).
            bun build --compile \
              ./src/cli/index.ts \
              --outfile="$TMPDIR/electrobun-cli"

            popd
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            DIST="$out/dist-${plat}"
            mkdir -p "$DIST" "$out/bin"

            # ---- Built from source ----------------------------------------
            install -m 755 "$TMPDIR/launcher-out/bin/launcher"           "$DIST/launcher"
            install -m 755 package/src/native/build/libNativeWrapper.so   "$DIST/libNativeWrapper.so"
            cp             "$TMPDIR/main.js"                              "$DIST/main.js"
            cp             "$TMPDIR/npmbin.js"                            "$DIST/npmbin.js"
            install -m 755 "$TMPDIR/electrobun-cli"                      "$out/bin/electrobun"

            # ---- Pure-Zig tools — reused from pre-built core tarball ------
            # These binaries (libasar.so, zig-asar, zig-zstd, extractor) are
            # statically linked or link only libc; they have no WebKit/GTK
            # dependencies and require no patching on NixOS.
            # TODO: build from source once zig-asar is a standalone input.
            cp             "${electrobunCore}/libasar.so"  "$DIST/libasar.so"
            install -m 755 "${electrobunCore}/zig-asar"    "$DIST/zig-asar"
            install -m 755 "${electrobunCore}/zig-zstd"    "$DIST/zig-zstd"
            install -m 755 "${electrobunCore}/extractor"   "$DIST/extractor"

            # ---- Replaced from nixpkgs ------------------------------------
            # bun: JS runtime that executes main.js and the user's app code.
            cp             "${pkgs.bun}/bin/bun"           "$DIST/bun"
            # bsdiff / bspatch: nixpkgs provides a C implementation compatible
            # with the zig-bsdiff variant used in the upstream pre-built release.
            install -m 755 "${pkgs.bsdiff}/bin/bsdiff"     "$DIST/bsdiff"
            install -m 755 "${pkgs.bsdiff}/bin/bspatch"    "$DIST/bspatch"

            # process_helper is the CEF subprocess helper; not needed for the
            # GTK-only (bundleCEF = false) build target — intentionally omitted.

            runHook postInstall
          '';

          meta = with nixpkgs.lib; {
            description = "Electrobun desktop framework native components built from source";
            longDescription = ''
              Builds the core Electrobun native components from the upstream
              v${electrobunVersion} source rather than using pre-built binary blobs:

                launcher            — Zig binary (entry-point / process manager)
                libNativeWrapper.so — C++20, compiled against Nix-store WebKitGTK
                main.js / npmbin.js — bun TypeScript bundles
                electrobun (CLI)    — bun compiled self-contained binary

              Because libNativeWrapper.so is compiled against the Nix-store
              WebKitGTK the linker embeds the correct RPATH automatically —
              no autoPatchelfHook or LD_LIBRARY_PATH hacks needed.

              The remaining distribution items (libasar.so, zig-asar, zig-zstd,
              extractor) are pure-Zig binaries with no system library dependencies
              and are reused from the upstream pre-built tarball until zig-asar
              is exposed as a standalone Nix derivation.  bun and bsdiff/bspatch
              come from nixpkgs.

              Status: EXPERIMENTAL — Linux only.
              Two FOD hashes must be computed before first build; see comments
              on mkElectrobunSource and mkElectrobunSrcNpmDeps.
            '';
            homepage  = "https://github.com/blackboardsh/electrobun";
            license   = licenses.mit;
            platforms = platforms.linux;
          };
        };

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

          # ---- Experimental: build Electrobun native components from source ----
          # These three bindings expose the from-source build pipeline so
          # hashes can be computed step by step (see comments on
          # mkElectrobunSource and mkElectrobunSrcNpmDeps above).
          electrobun-source       = mkElectrobunSource pkgs;
          electrobun-src-npm-deps = mkElectrobunSrcNpmDeps pkgs (mkElectrobunSource pkgs);
          electrobun-from-source  = mkElectrobunFromSource pkgs;

        in
        {
          default = electrobun-hello;
          node-modules = node-modules;
          electrobun-core = mkElectrobunCore pkgs;
          inherit electrobun-source electrobun-src-npm-deps electrobun-from-source;
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
