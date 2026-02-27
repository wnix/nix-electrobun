# ------------------------------------------------------------------ #
#  Linux runtime libraries required by Electrobun / WebKit2GTK        #
#  Usage: linuxRuntimeLibs pkgs                                        #
# ------------------------------------------------------------------ #
pkgs: with pkgs; [
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
  libx11          # formerly xorg.libX11
  libxcomposite   # formerly xorg.libXcomposite
  libxcursor      # formerly xorg.libXcursor
  libxdamage      # formerly xorg.libXdamage
  libxext         # formerly xorg.libXext
  libxfixes       # formerly xorg.libXfixes
  libxi           # formerly xorg.libXi
  libxrandr       # formerly xorg.libXrandr
  libxrender      # formerly xorg.libXrender
  libxtst         # formerly xorg.libXtst
  libxcb          # formerly xorg.libxcb
  libGL
  libxkbcommon
  # C++ runtime — some electrobun binaries link libstdc++
  stdenv.cc.cc.lib
]
