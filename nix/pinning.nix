# ------------------------------------------------------------------ #
#  Electrobun release pinning                                          #
#  Update these when electrobun releases a new version.               #
#  To recompute hashes after a version bump:                          #
#    nix build .#packages.x86_64-linux.electrobun-source 2>&1 \      #
#      | grep "got:"                                                   #
# ------------------------------------------------------------------ #
{
  electrobunVersion = "1.14.4";

  # Nix system string → electrobun platform-arch string
  systemToPlatform = {
    "x86_64-linux"   = "linux-x64";
    "aarch64-linux"  = "linux-arm64";
    "x86_64-darwin"  = "darwin-x64";
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
}
