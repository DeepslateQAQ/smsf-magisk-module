{ pkgs ? import <nixpkgs> { } }:
let
  r8Version = "9.4.24";
  r8 = pkgs.stdenv.mkDerivation {
    pname = "r8";
    version = r8Version;
    src = pkgs.fetchurl {
      url = "https://dl.google.com/dl/android/maven2/com/android/tools/r8/${r8Version}/r8-${r8Version}.jar";
      hash = "sha256-bv2drLCAAfNC2VSC7MFae2nGNLwmGuuIu8jmzVg38hI=";
    };
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/r8 $out/bin
      cp $src $out/share/r8/r8.jar
      makeWrapper ${pkgs.jdk}/bin/java $out/bin/d8 \
        --add-flags "-cp $out/share/r8/r8.jar com.android.tools.r8.D8"
      runHook postInstall
    '';
  };
in
pkgs.mkShell {
  packages = [
    pkgs.jdk
    pkgs.zip
    pkgs.unzip
    pkgs.curl
    pkgs.python3
    pkgs.shellcheck
    pkgs.mksh
    r8
  ];
  shellHook = ''
    echo "smsf-magisk-module dev shell"
    echo "  ./build.sh          build payload + module zip"
    echo "  ./build.sh test     build payload + run payload/daemon tests"
    echo "  d8 --version        $(d8 --version 2>/dev/null | head -n1)"
  '';
}
