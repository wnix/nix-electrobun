{
  description = "An Electrobun desktop application";

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

      # Linux runtime libraries required by Electrobun (WebKit2GTK)
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

    in
    {
      # ------------------------------------------------------------------ #
      #  Development shell                                                   #
      #  nix develop                                                         #
      # ------------------------------------------------------------------ #
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            buildInputs = (linuxLibs pkgs)
              ++ nixpkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
                pkg-config
                cmake
              ]);

            packages = with pkgs; [
              bun
              git
              nodejs
            ];

            shellHook = ''
              echo ""
              echo "  Electrobun dev shell (nixpkgs unstable · bun $(bun --version))"
              echo ""
              echo "  • bun install    — install dependencies"
              echo "  • bun start      — start app in dev mode"
              echo "  • bun run dev    — start with hot-reload"
              echo "  • bun run build  — create distributable"
              echo ""
            '';
          };
        }
      );

      # ------------------------------------------------------------------ #
      #  Packages                                                            #
      #  nix build                                                           #
      #                                                                      #
      #  How to get the correct outputHash:                                  #
      #  1. Run `bun install` once locally to generate bun.lock             #
      #  2. Build with fake hash → Nix prints the expected hash:            #
      #       nix build 2>&1 | grep "got:"                                  #
      #  3. Replace outputHash below with the printed value                 #
      #  4. Run `nix build` again — it should succeed                       #
      # ------------------------------------------------------------------ #
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          inherit (nixpkgs) lib;

          # -------------------------------------------------------------- #
          #  Fixed-output derivation: pre-fetch npm dependencies via bun    #
          # -------------------------------------------------------------- #
          node-modules = pkgs.stdenv.mkDerivation {
            pname = "app-node-modules";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.bun ];

            # Forward proxy env-vars into the sandbox so corporate proxies work
            impureEnvVars = pkgs.lib.fetchers.proxyImpureEnvVars
              ++ [ "GIT_PROXY_COMMAND" "SOCKS_SERVER" ];

            buildPhase = ''
              runHook preBuild
              export HOME="$TMPDIR"
              bun install --no-progress --frozen-lockfile
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
            # ------------------------------------------------------------ #
            # Replace with the hash printed by:                             #
            #   nix build .#node-modules 2>&1 | grep "got:"                #
            # ------------------------------------------------------------ #
            outputHash = lib.fakeHash;
          };

          # -------------------------------------------------------------- #
          #  Application derivation                                          #
          #                                                                  #
          #  Electrobun's dev mode writes build artefacts at runtime, so we  #
          #  copy everything to a writable temp directory before launching.  #
          # -------------------------------------------------------------- #
          app =
            let
              appSrc = ./.;
              ldPath = pkgs.lib.makeLibraryPath (linuxLibs pkgs);
            in
            pkgs.writeShellApplication {
              name = "my-electrobun-app";
              runtimeInputs = [ pkgs.bun ] ++ (linuxLibs pkgs);

              text = ''
                tmpdir=$(mktemp -d)
                # shellcheck disable=SC2064
                trap "rm -rf '$tmpdir'" EXIT

                cp -r "${appSrc}/." "$tmpdir/"
                chmod -R u+w "$tmpdir"
                cp -r "${node-modules}/node_modules" "$tmpdir/node_modules"

                ${lib.optionalString pkgs.stdenv.isLinux ''
                  export LD_LIBRARY_PATH="${ldPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                ''}

                cd "$tmpdir"
                exec bun start
              '';
            };

        in
        {
          default = app;
          node-modules = node-modules;
        }
      );

      # ------------------------------------------------------------------ #
      #  Apps                                                                #
      #  nix run                                                             #
      # ------------------------------------------------------------------ #
      apps = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/my-electrobun-app";
          };
        }
      );
    };
}
