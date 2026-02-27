# ------------------------------------------------------------------ #
#  mkElectrobunCore / mkElectrobunCli                                  #
#                                                                      #
#  Download Electrobun pre-built binary tarballs from GitHub and       #
#  apply autoPatchelfHook on Linux so the ELF interpreter and RPATH   #
#  point into the Nix store.                                           #
# ------------------------------------------------------------------ #
{ electrobunVersion
, systemToPlatform
, coreHashes
, cliHashes
, linuxRuntimeLibs
}:

{
  # ---------------------------------------------------------------- #
  #  mkElectrobunCore — fetch + patch the runtime core               #
  #                                                                    #
  #  Contains: bun, launcher, libNativeWrapper.so, libasar.so,        #
  #            extractor, zig-asar, zig-zstd, bsdiff, bspatch         #
  # ---------------------------------------------------------------- #
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
        # autoPatchelfHook rewrites RPATH / interpreter to point to these.
        buildInputs = linuxRuntimeLibs pkgs;
        # Allow missing optional deps (e.g. libcef, libayatana-appindicator)
        autoPatchelfIgnoreMissingDeps = true;

        unpackPhase = ''
          mkdir dist
          tar xzf "$src" -C dist
        '';

        installPhase = ''
          mkdir -p "$out"
          cp -r dist/. "$out/"
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

  # ---------------------------------------------------------------- #
  #  mkElectrobunCli — fetch + patch the standalone CLI binary       #
  # ---------------------------------------------------------------- #
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
}
