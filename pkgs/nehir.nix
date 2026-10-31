{ stdenvNoCC, fetchurl, unzip }:

stdenvNoCC.mkDerivation rec {
  pname = "nehir";
  version = "0.5.1";

  src = fetchurl {
    url = "https://github.com/guria/nehir/releases/download/v${version}/Nehir-${version}.zip";
    sha256 = "72108b300491439653b4269b61a5d6deefad579aa7fd4d23f1ffe2645bf0cd42";
  };

  nativeBuildInputs = [ unzip ];
  sourceRoot = ".";
  dontFixup = true;

  installPhase = ''
    mkdir -p $out/Applications $out/bin
    cp -R Nehir.app $out/Applications/
    ln -s $out/Applications/Nehir.app/Contents/MacOS/nehirctl $out/bin/nehirctl
  '';
}
