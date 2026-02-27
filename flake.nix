{
  description = "Nix flake template for developing Electrobun desktop applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: import nixpkgs {
        inherit system;
        config = { };
      };

      # Linux-specific runtime libraries needed by Electrobun / WebKit
      linuxLibs = pkgs: nixpkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
        webkitgtk_4_1
        gtk3
        glib
        pango
        cairo
        atk
        gdk-pixbuf
        harfbuzz
      ]);

      # Linux-specific build-time tools
      linuxBuildTools = pkgs: nixpkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
        pkg-config
        cmake
      ]);

    in
    {
      # ------------------------------------------------------------------ #
      #  Nix flake template                                                  #
      #  Usage: nix flake init -t github:wnix/nix-electrobun                #
      # ------------------------------------------------------------------ #
      templates.default = {
        path = ./template;
        description = "Electrobun desktop application starter template";
        welcomeText = ''
          # Electrobun Template

          ## Quick Start

            # Enter the Nix development shell (provides bun + all system deps)
            nix develop

            # Install JavaScript dependencies
            bun install

            # Start the application in development mode
            bun start

          ## Commands

            bun start          — dev build + launch
            bun run dev        — dev build + launch + watch mode
            bun run build      — create a distributable

          ## Nix Reproducible Build

          After running `bun install`, a `bun.lock` is generated. You can then
          build the app reproducibly with Nix:

            # First run fails and prints the expected hash:
            nix build 2>&1 | grep "got:"

            # Paste that hash into flake.nix as outputHash, then:
            nix build

          ## Customising

          - Edit `electrobun.config.ts` — set your app name, version, and identifier
          - Edit `src/bun/index.ts`     — main process (windows, native APIs)
          - Edit `src/mainview/`        — renderer (HTML / CSS / TypeScript)
        '';
      };

      # ------------------------------------------------------------------ #
      #  Development shells                                                  #
      #  Usage: nix develop github:wnix/nix-electrobun                      #
      # ------------------------------------------------------------------ #
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            # Runtime libraries must be on the build inputs so that
            # nix develop sets up PKG_CONFIG_PATH / LD_LIBRARY_PATH correctly.
            buildInputs = (linuxLibs pkgs) ++ (linuxBuildTools pkgs);

            packages = with pkgs; [
              bun
              git
              # nodejs is handy for some tooling that still expects it
              nodejs
            ];

            shellHook = ''
              echo ""
              echo "  Electrobun development environment (nixpkgs unstable)"
              echo ""
              echo "  bun $(bun --version)  ready"
              echo ""
              echo "  • bun install    — install / update dependencies"
              echo "  • bun start      — start the app in dev mode"
              echo "  • bun run build  — create a distributable"
              echo ""
            '';
          };
        }
      );

      # ------------------------------------------------------------------ #
      #  Packages                                                            #
      # ------------------------------------------------------------------ #
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          # -------------------------------------------------------------- #
          #  Fixed-output derivation: pre-fetch npm dependencies            #
          #                                                                  #
          #  After adding / changing dependencies:                          #
          #    1. Run: cd template && bun install                           #
          #    2. Run: nix build .#node-modules 2>&1 | grep "got:"          #
          #    3. Paste the printed hash into `outputHash` below.           #
          # -------------------------------------------------------------- #
          node-modules = pkgs.stdenv.mkDerivation {
            pname = "electrobun-hello-node-modules";
            version = "0.1.0";
            src = ./template;

            nativeBuildInputs = [ pkgs.bun ];

            # Allow proxy env-vars so corporate proxies work in sandboxed builds
            impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars
              ++ [ "GIT_PROXY_COMMAND" "SOCKS_SERVER" ];

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              # --no-save prevents bun from trying to write back to the (read-only) store
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
            # Replace with the real hash after running:
            #   nix build .#node-modules 2>&1 | grep "got:"
            # or bootstrap with:
            #   nix build .#node-modules --option sandbox false
            outputHash = nixpkgs.lib.fakeHash;
          };

          # App package: wraps source + pre-fetched node_modules in a runner script.
          # Electrobun's dev mode writes build artifacts at runtime, so we copy
          # everything to a writable temp directory before launching.
          electrobun-hello =
            let
              # Store path containing the template source files
              appSrc = ./template;
              ldPath = pkgs.lib.makeLibraryPath (linuxLibs pkgs);
            in
            pkgs.writeShellApplication {
              name = "electrobun-hello";
              runtimeInputs = [ pkgs.bun ] ++ (linuxLibs pkgs);

              text = ''
                tmpdir=$(mktemp -d)
                # shellcheck disable=SC2064
                trap "rm -rf '$tmpdir'" EXIT

                cp -r "${appSrc}/." "$tmpdir/"
                chmod -R u+w "$tmpdir"
                cp -r "${node-modules}/node_modules" "$tmpdir/node_modules"

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
          # Expose the node_modules derivation for easy hash-bootstrapping
          node-modules = node-modules;
        }
      );

      # ------------------------------------------------------------------ #
      #  Apps — nix run github:wnix/nix-electrobun                         #
      #                                                                      #
      #  This runner installs JavaScript dependencies at launch time,        #
      #  so it works without any pre-computed hash.  It requires an          #
      #  internet connection the first time.                                 #
      # ------------------------------------------------------------------ #
      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;

          runner = pkgs.writeShellApplication {
            name = "electrobun-hello-run";
            runtimeInputs = [ pkgs.bun ] ++ (linuxLibs pkgs);

            text = ''
              tmpdir=$(mktemp -d)
              # shellcheck disable=SC2064
              trap "rm -rf '$tmpdir'" EXIT

              # Copy the template source from the Nix store (read-only) to a
              # writable temp directory so bun can install node_modules there.
              cp -r "${./template}/." "$tmpdir/"
              chmod -R u+w "$tmpdir"

              ${nixpkgs.lib.optionalString pkgs.stdenv.isLinux ''
                export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (linuxLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              ''}

              cd "$tmpdir"

              if [ ! -d node_modules ]; then
                echo "[nix-electrobun] Installing dependencies (requires internet)…"
                HOME="$tmpdir" bun install --no-progress
              fi

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
