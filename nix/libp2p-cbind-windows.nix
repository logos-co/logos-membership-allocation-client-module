# nim-libp2p's cbind library cross-built for x86_64-w64-mingw32.
#
# Mirrors nim-libp2p's nix/cbind.nix, which only builds natively. `pkgs` is a
# MinGW cross package set (logos-nix's mkWindowsPkgs); `src` is nim-libp2p.
{ pkgs, src }:

let
  inherit (pkgs) lib;

  deps = import "${src}/nix/deps.nix" { inherit pkgs; };
  cbindDeps = import "${src}/nix/cbind-deps.nix" { inherit pkgs; };

  # nasm writes its objects beside the sources, so these need a writable copy.
  writableDeps = [ "boringssl" "lsquic" ];

  pathArgs = lib.concatMapStringsSep " " (p: "--path:${p}")
    (builtins.attrValues cbindDeps
     ++ builtins.attrValues (removeAttrs deps writableDeps));

  copyWritableDeps = lib.concatMapStrings (name: ''
    cp -r ${deps.${name}} $TMPDIR/${name}
    chmod -R u+w $TMPDIR/${name}
  '') writableDeps;

  tinycborVendor = "${cbindDeps.ffi}/ffi/codegen/templates/cpp/vendor/tinycbor";

  windowsLinkFlags =
    "-lws2_32 -lbcrypt -liphlpapi -luserenv -lntdll -ldbghelp -lwinpthread -lstdc++";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-cbind-windows";
  version = "dev";

  inherit src;

  # buildPackages: these run on the builder; nim's wrapper targets mingw.
  nativeBuildInputs = with pkgs.buildPackages; [ nim-2_2 git which nasm ];

  # mingw-w64 in nixpkgs is built against mcfgthread: no pthread.h otherwise.
  buildInputs = [ pkgs.windows.pthreads ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE
${copyWritableDeps}
    # nim calls a bare `ar` for --app:staticlib.
    mkdir -p $TMPDIR/arshim
    ln -sf "$(command -v $AR)" $TMPDIR/arshim/ar
    export PATH=$TMPDIR/arshim:$PATH

    commonArgs="--noNimblePath ${pathArgs} \
      ${lib.concatMapStringsSep " " (n: "--path:$TMPDIR/${n}") writableDeps} \
      --threads:on --opt:size --noMain --mm:refc --d:metrics \
      -d:chronicles_runtime_filtering=on \
      -d:ffiThreadExitTimeoutMs=5000 -d:chronicles_timestamps=RfcUtcTime \
      --passL:\"${windowsLinkFlags}\" \
      --nimMainPrefix:liblibp2p --nimcache:$NIMCACHE"

    echo "== Building FFI library (DLL + import library) =="
    eval nim c $commonArgs --app:lib \
      --passL:-Wl,--out-implib,build/liblibp2p.dll.a \
      --out:build/liblibp2p.dll cbind/libp2p.nim

    echo "== Building FFI library (static) =="
    eval nim c $commonArgs --app:staticlib --out:build/liblibp2p.a cbind/libp2p.nim

    echo "== Generating C bindings =="
    eval nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=cbind/c_bindings -d:ffiSrcPath=libp2p.nim \
      --out:$TMPDIR/bindings.dll cbind/libp2p.nim
    # nim-ffi joins with the target separator: files land as `cbind\c_bindings\x.h`.
    for f in cbind\\c_bindings\\*; do mv "$f" "cbind/c_bindings/''${f##*\\}"; done

    echo "== Building TinyCBOR (static) =="
    mkdir -p $TMPDIR/tinycbor
    for c in ${tinycborVendor}/*.c; do
      $CC -O2 -c "$c" -I${tinycborVendor} -o $TMPDIR/tinycbor/$(basename "$c" .c).o
    done
    $AR rcs build/libtinycbor.a $TMPDIR/tinycbor/*.o
  '';

  installPhase = ''
    test -f build/liblibp2p.dll.a || { echo "error: no import library" >&2; exit 1; }
    mkdir -p $out/lib $out/bin $out/include/tinycbor
    # The builder wants the DLL beside its import library; win-dll-link wants bin/.
    cp build/liblibp2p.dll build/liblibp2p.dll.a build/liblibp2p.a build/libtinycbor.a $out/lib/
    cp build/liblibp2p.dll $out/bin/
    cp cbind/c_bindings/*.h $out/include/
    cp ${tinycborVendor}/* $out/include/tinycbor/
  '';
}
