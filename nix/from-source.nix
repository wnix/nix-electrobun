# ------------------------------------------------------------------ #
#  Build Electrobun from source (EXPERIMENTAL — Linux only)           #
#                                                                      #
#  Compiles the key native components directly against the            #
#  Nix-store WebKitGTK, eliminating the need for autoPatchelf or     #
#  LD_LIBRARY_PATH hacks at runtime.                                  #
#                                                                      #
#  Built from source:                                                  #
#    launcher            — Zig binary (entry-point / signal handler)   #
#    libNativeWrapper.so — C++20 bridge to WebKitGTK (GTK-only,       #
#                          compiled with -DNO_APPINDICATOR)            #
#    main.js / npmbin.js — TypeScript bundles compiled with bun        #
#    electrobun (CLI)    — bun --compile self-contained binary         #
#                                                                      #
#  Borrowed from the pre-built core tarball (pure-Zig, no system lib  #
#  dependencies — no patching required):                               #
#    libasar.so, zig-asar, zig-zstd, extractor                        #
#    TODO: build these from source once zig-asar is standalone         #
#                                                                      #
#  Replaced from nixpkgs:                                              #
#    bun (JS runtime), bsdiff, bspatch                                 #
# ------------------------------------------------------------------ #
{ electrobunVersion
, systemToPlatform
, linuxRuntimeLibs
, mkElectrobunCore
}:

let
  # ---------------------------------------------------------------- #
  #  mkElectrobunSource — FOD: fetch upstream source tarball         #
  # ---------------------------------------------------------------- #
  mkElectrobunSource = pkgs:
    pkgs.fetchFromGitHub {
      owner = "blackboardsh";
      repo   = "electrobun";
      rev    = "v${electrobunVersion}";
      hash   = "sha256-5V/1PaVS4VW/WL36QRZk92Lt6omzEW7KaQRQdzV6ohc=";
    };

  # ---------------------------------------------------------------- #
  #  mkElectrobunSrcNpmDeps — FOD: npm dependencies of the package  #
  #                                                                    #
  #  Compute hash after pinning mkElectrobunSource.hash:             #
  #    nix build .#packages.x86_64-linux.electrobun-src-npm-deps \   #
  #      2>&1 | grep "got:"                                           #
  # ---------------------------------------------------------------- #
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
      outputHash     = "sha256-ig4C2W784VJi6NVo8Cwlnn7Cxm3ShBuU82cV74TUUIQ=";
    };

  # ---------------------------------------------------------------- #
  #  mkElectrobunFromSource — main derivation                        #
  # ---------------------------------------------------------------- #
  mkElectrobunFromSource = pkgs:
    let
      plat = systemToPlatform.${pkgs.stdenv.hostPlatform.system};

      # Zig cross-target string for the launcher binary.
      zigTarget = {
        "x86_64-linux"  = "x86_64-linux-gnu";
        "aarch64-linux" = "aarch64-linux-gnu";
      }.${pkgs.stdenv.hostPlatform.system} or
        (throw "electrobun-from-source: unsupported system ${pkgs.stdenv.hostPlatform.system}");

      # Pre-built core supplies pure-Zig tools (libasar.so, zig-asar, etc.)
      # that have no GTK/WebKit deps and need no patching.
      electrobunCore    = mkElectrobunCore pkgs;
      electrobunSrc     = mkElectrobunSource pkgs;
      electrobunNpmDeps = mkElectrobunSrcNpmDeps pkgs electrobunSrc;

      # ---- CEF SDK headers ----------------------------------------
      # nativeWrapper.cpp includes CEF headers via src/shared/chromium_flags.h
      # even in the GTK-only build. We need include/ from the CEF minimal
      # tarball at compile time; the CEF binaries are NOT linked.
      cefVersion = "145.0.23+g3e7fe1c+chromium-145.0.7632.68";
      cefHeaders = pkgs.runCommand "cef-headers-${cefVersion}" {
        src = pkgs.fetchurl {
          url  = "https://cef-builds.spotifycdn.com/cef_binary_${cefVersion}_linux64_minimal.tar.bz2";
          hash = "sha256-YthgLVIcc3UeqHR010mZjNsB/t27bx0paDDhqYpxSsA=";
        };
      } ''
        mkdir -p "$out"
        # Extract only the include/ dir; name the member explicitly to
        # avoid --wildcards portability issues.
        tar xjf "$src" \
          --strip-components=1 \
          -C "$out" \
          "cef_binary_${cefVersion}_linux64_minimal/include"
      '';

      # ---- Code-gen scripts ---------------------------------------
      # build.ts generates these at build time; we replicate the logic
      # as Nix-store text files that bun runs during the build phase.

      # Mirrors generatePreloadScript() — compiles webview injection
      # scripts and writes their JS as exported string constants.
      # Uses string concatenation (not JS template literals) to avoid
      # conflicting with Nix ${...} interpolation.
      preloadGenScript = pkgs.writeText "gen-electrobun-preload.ts" ''
        import { build } from "bun";
        import { mkdirSync, writeFileSync } from "fs";
        import { join } from "path";

        const preloadDir = join(process.cwd(), "src", "bun", "preload");
        const outputDir  = join(preloadDir, ".generated");
        mkdirSync(outputDir, { recursive: true });

        const [fullResult, sandboxedResult] = await Promise.all([
          build({ entrypoints: [join(preloadDir, "index.ts")],
                  target: "browser", format: "iife", minify: false }),
          build({ entrypoints: [join(preloadDir, "index-sandboxed.ts")],
                  target: "browser", format: "iife", minify: false }),
        ]);

        if (!fullResult.success) {
          console.error(fullResult.logs);
          throw new Error("Full preload build failed");
        }
        if (!sandboxedResult.success) {
          console.error(sandboxedResult.logs);
          throw new Error("Sandboxed preload build failed");
        }

        const fullJs      = await fullResult.outputs[0].text();
        const sandboxedJs = await sandboxedResult.outputs[0].text();

        const outputContent =
          "// Auto-generated file. Do not edit directly.\n" +
          "// Run \"bun build.ts\" from the package folder to regenerate.\n\n" +
          "export const preloadScript = " + JSON.stringify(fullJs) + ";\n\n" +
          "export const preloadScriptSandboxed = " + JSON.stringify(sandboxedJs) + ";\n";

        writeFileSync(join(outputDir, "compiled.ts"), outputContent);
        console.log("[gen-preload] Done.");
      '';

      # Stub for src/cli/templates/embedded.ts.
      # build.ts generates this from a templates/ dir not in the source
      # tarball. We provide the same empty-object skeleton.
      embeddedTemplatesStub = pkgs.writeText "electrobun-embedded-templates.ts" ''
        // Auto-generated file. Do not edit directly.
        // Generated from templates/ directory

        export interface Template {
          name: string;
          files: Record<string, string>;
        }

        export const templates: Record<string, Template> = {};

        export function getTemplateNames(): string[] {
          return Object.keys(templates);
        }

        export function getTemplate(name: string): Template | undefined {
          return templates[name];
        }
      '';
    in

    if !pkgs.stdenv.isLinux then
      throw "electrobun-from-source: Linux only (Darwin requires Objective-C++ / Cocoa — not yet implemented)"
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

      # These become -I and -L search paths for the g++ invocation.
      buildInputs = linuxRuntimeLibs pkgs;

      buildPhase = ''
        runHook preBuild

        export HOME="$TMPDIR"
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"

        # All source lives under package/ in the repo root.
        pushd package

        # ---------------------------------------------------------- #
        # 1. launcher — pure Zig, links only libc                     #
        # ---------------------------------------------------------- #
        (
          cd src/launcher
          zig build \
            -Doptimize=ReleaseSafe \
            -Dtarget=${zigTarget} \
            --prefix "$TMPDIR/launcher-out"
        )

        # ---------------------------------------------------------- #
        # 2. libNativeWrapper.so — C++20, WebKitGTK + GTK3           #
        #                                                              #
        #    Compiled against Nix-store WebKitGTK so the linker       #
        #    embeds correct RPATHs automatically — no autoPatchelf    #
        #    or LD_LIBRARY_PATH hacks needed at runtime.             #
        #                                                              #
        #    -DNO_APPINDICATOR  disables libayatana-appindicator3     #
        #    dependency present in the upstream pre-built binary.     #
        # ---------------------------------------------------------- #
        mkdir -p src/native/linux/build src/native/build

        LIBASAR="${electrobunCore}/libasar.so"
        PKG_CFLAGS="$(pkg-config --cflags webkit2gtk-4.1 gtk+-3.0)"
        PKG_LIBS="$(pkg-config --libs   webkit2gtk-4.1 gtk+-3.0)"

        g++ -c -std=c++20 -fPIC \
          $PKG_CFLAGS \
          -Isrc/native/linux \
          -I${cefHeaders} \
          -DNO_APPINDICATOR \
          -o src/native/linux/build/nativeWrapper.o \
          src/native/linux/nativeWrapper.cpp

        # -Wl,-rpath,'$ORIGIN' makes the runtime linker search the
        # directory containing libNativeWrapper.so for libasar.so.
        g++ -shared \
          -Wl,-rpath,'$ORIGIN' \
          -o src/native/build/libNativeWrapper.so \
          src/native/linux/build/nativeWrapper.o \
          "$LIBASAR" \
          $PKG_LIBS \
          -ldl -lpthread

        # ---------------------------------------------------------- #
        # 3. TypeScript bundles and standalone CLI via bun            #
        # ---------------------------------------------------------- #

        cp -r "${electrobunNpmDeps}/node_modules" ./node_modules

        # 3a. Generate src/bun/preload/.generated/compiled.ts
        #     (native.ts imports this; mirrors generatePreloadScript()
        #     in build.ts)
        bun "${preloadGenScript}"

        # 3b. Stub src/cli/templates/embedded.ts
        #     (build.ts generates this from a templates/ dir not
        #     present in the upstream source tarball)
        mkdir -p src/cli/templates
        cp "${embeddedTemplatesStub}" src/cli/templates/embedded.ts

        # Framework main-process bundle (loaded by bun at app start).
        bun build \
          ./src/bun/index.ts \
          --target=bun \
          --outfile="$TMPDIR/main.js"

        # npm-bin shim (note: entry point is plain JS, not TypeScript).
        bun build \
          ./src/npmbin/index.js \
          --target=bun \
          --outfile="$TMPDIR/npmbin.js"

        # Standalone CLI binary with embedded bun runtime.
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

        # ---- Built from source ------------------------------------
        install -m 755 "$TMPDIR/launcher-out/bin/launcher"           "$DIST/launcher"
        install -m 755 package/src/native/build/libNativeWrapper.so   "$DIST/libNativeWrapper.so"
        cp             "$TMPDIR/main.js"                              "$DIST/main.js"
        cp             "$TMPDIR/npmbin.js"                            "$DIST/npmbin.js"
        install -m 755 "$TMPDIR/electrobun-cli"                      "$out/bin/electrobun"

        # ---- Pure-Zig tools from pre-built core tarball ----------
        # (statically linked or libc-only; no WebKit/GTK deps)
        cp             "${electrobunCore}/libasar.so"  "$DIST/libasar.so"
        install -m 755 "${electrobunCore}/zig-asar"    "$DIST/zig-asar"
        install -m 755 "${electrobunCore}/zig-zstd"    "$DIST/zig-zstd"
        install -m 755 "${electrobunCore}/extractor"   "$DIST/extractor"

        # ---- Replaced from nixpkgs --------------------------------
        cp             "${pkgs.bun}/bin/bun"           "$DIST/bun"
        install -m 755 "${pkgs.bsdiff}/bin/bsdiff"     "$DIST/bsdiff"
        install -m 755 "${pkgs.bsdiff}/bin/bspatch"    "$DIST/bspatch"

        runHook postInstall
      '';

      meta = with pkgs.lib; {
        description = "Electrobun desktop framework native components built from source";
        longDescription = ''
          Builds the core Electrobun native components from the upstream
          v${electrobunVersion} source rather than using pre-built binary blobs:

            launcher            — Zig binary (entry-point / process manager)
            libNativeWrapper.so — C++20, compiled against Nix-store WebKitGTK
                                  (-DNO_APPINDICATOR — no ayatana dependency)
            main.js / npmbin.js — bun TypeScript bundles
            electrobun (CLI)    — bun compiled self-contained binary

          Because libNativeWrapper.so is compiled against the Nix-store
          WebKitGTK, the linker embeds the correct RPATH automatically —
          no autoPatchelfHook or LD_LIBRARY_PATH hacks needed at runtime.

          Status: EXPERIMENTAL — Linux only.
        '';
        homepage  = "https://github.com/blackboardsh/electrobun";
        license   = licenses.mit;
        platforms = platforms.linux;
      };
    };

in {
  inherit mkElectrobunSource mkElectrobunSrcNpmDeps mkElectrobunFromSource;
}
