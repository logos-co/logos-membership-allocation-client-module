{
  description = "Logos module: RLN membership allocation client over a libp2p node of its own";

  inputs = {
    logos-module-builder.url = "github:logos-co/logos-module-builder/0.3.1";
    libp2p_module.url = "git+https://github.com/logos-co/logos-libp2p-module?ref=refs/tags/v1.1.1";
  };

  outputs = inputs@{ logos-module-builder, libp2p_module, ... }:
    let
      nixpkgs = logos-module-builder.inputs.nixpkgs;
      meta = builtins.fromJSON (builtins.readFile ./metadata.json);
      devSystems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      systems = devSystems ++ [ "x86_64-windows" ];
      libp2p = libp2p_module.inputs.libp2p;
      libp2pInputs = {
        packages = nixpkgs.lib.genAttrs devSystems (system: {
          cbind = libp2p.packages.${system}.cbind.overrideAttrs (old: {
            buildPhase = builtins.replaceStrings
              [ "--threads:on --opt:size --noMain --mm:refc --d:metrics" ]
              [ "--threads:on --opt:size --noMain --mm:refc --d:metrics -d:chronicles_runtime_filtering=on" ]
              old.buildPhase;
          });
        } // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          cbind-windows-x86_64 = import ./nix/libp2p-cbind-windows.nix {
            pkgs = logos-module-builder.inputs.logos-nix.lib.mkWindowsPkgs { buildSystem = system; };
            src = libp2p;
          };
        });
      };
      module = logos-module-builder.lib.mkLogosModule {
        src = ./.;
        configFile = ./metadata.json;
        flakeInputs = inputs;
        inherit externalLibInputs;
      };
      externalLibInputs = {
        libp2p = {
          input = libp2pInputs;
          packages.default = "cbind";
          systems.x86_64-windows = {
            system = "x86_64-linux";
            packages.default = "cbind-windows-x86_64";
          };
        };
      };
      nodeTests = nixpkgs.lib.genAttrs devSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          withContract = pkgs.runCommand "${meta.name}-src-with-contract" { } ''
            cp -R --no-preserve=mode,ownership ${./.} $out
            mkdir -p $out/generated_code
            cp ${module.packages.${system}.lidl}/${meta.name}.lidl $out/generated_code/${meta.name}.lidl
          '';
        in
        (logos-module-builder.lib.mkLogosModuleTests {
          src = withContract;
          configFile = ./metadata.json;
          flakeInputs = inputs;
          inherit externalLibInputs;
          testDir = ./node-tests;
          extraCmakeFlags = [ "-DLIBP2P_MODULE_SRC=${libp2p_module}" ];
        }).${system}.unit-tests);
    in
    module // {
      packages = nixpkgs.lib.genAttrs systems (system:
        (module.packages.${system} or { })
        // nixpkgs.lib.optionalAttrs (nodeTests ? ${system}) { node-tests = nodeTests.${system}; }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          inherit (libp2pInputs.packages.${system}) cbind-windows-x86_64;
        });
      checks = nixpkgs.lib.genAttrs devSystems (system:
        (module.checks.${system} or { }) // { node-tests = nodeTests.${system}; });
      apps = nixpkgs.lib.genAttrs devSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          lidlGen = logos-module-builder.inputs.logos-rust-sdk.packages.${system}.lidl-gen;
          sdkSrc = logos-module-builder.packages.${system}.rust-sdk-src;
          protocolVersion =
            let
              header = builtins.readFile
                "${logos-module-builder.inputs.logos-protocol}/cpp/logos_protocol.h";
              parts = builtins.split "LOGOS_PROTOCOL_VERSION_STRING \"([^\"]*)\"" header;
            in
            if builtins.length parts < 2
            then throw "logos-protocol header carries no LOGOS_PROTOCOL_VERSION_STRING"
            else builtins.head (builtins.elemAt parts 1);
          generate = pkgs.writeShellApplication {
            name = "membership-allocation-client-module-generate";
            runtimeInputs = [ lidlGen pkgs.gitMinimal ];
            text = ''
              root="''${1:-$(git rev-parse --show-toplevel)}"
              gen="$root/rust-lib/generated"
              echo "generating rust-lib/generated/provider_gen.rs (protocol ${protocolVersion}) ..."
              mkdir -p "$gen"
              logos-lidl-gen --from-rust "$root/rust-lib/src/lib.rs" \
                --trait MembershipAllocationClientModule --module-name ${meta.name} --module-version ${meta.version} \
                -o "$gen/${meta.name}.lidl"
              logos-lidl-gen "$gen/${meta.name}.lidl" --provider --no-trait \
                --protocol-version ${protocolVersion} \
                -o "$gen/provider_gen.rs"
              echo "staging the SDK source at logos-rust-sdk-src/ ..."
              rm -rf "''${root:?}/logos-rust-sdk-src"
              cp -RL "${sdkSrc}" "$root/logos-rust-sdk-src"
              chmod -R u+w "$root/logos-rust-sdk-src"
              echo "done. bare 'cargo build' now works in rust-lib/"
            '';
          };
        in
        (module.apps.${system} or { }) // {
          generate = {
            type = "app";
            program = "${generate}/bin/membership-allocation-client-module-generate";
          };
        });
    };
}
