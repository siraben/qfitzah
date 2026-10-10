{
  description = "Qfitzah, a tiny i386 term-rewriting language interpreter";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          qfitzah = pkgs.stdenvNoCC.mkDerivation {
            pname = "qfitzah";
            version = "0-unstable";

            # Build Stage 0 from its assembly source.
            src = ./qfitzah.s;

            nativeBuildInputs = [ pkgs.binutils ];

            dontUnpack = true;
            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              cp ${./bootstrap/seed-gc.s} seed-gc.s
              as --32 "$src" -o qfitzah.o
              ld -m elf_i386 -static -z noseparate-code -o qfitzah.bloated qfitzah.o
              objcopy -S -R .note.gnu.build-id -R .note.gnu.property qfitzah.bloated qfitzah

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              install -Dm755 qfitzah "$out/bin/qfitzah"

              runHook postInstall
            '';

            meta = {
              description = "Tiny i386 term-rewriting language interpreter";
              mainProgram = "qfitzah";
              platforms = [ "x86_64-linux" ];
            };
          };
        in
        {
          default = qfitzah;
          qfitzah = qfitzah;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/qfitzah";
          meta.description = "Run the Qfitzah interpreter";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          seed-memory = pkgs.runCommand "qfitzah-seed-memory-tests"
            { nativeBuildInputs = [ pkgs.binutils ]; } ''
            cp ${./qfitzah.s} qfitzah.s
            cp ${./bootstrap/seed-gc.s} seed-gc.s
            as --32 --defsym SEED_CELL_BYTES=262144 --defsym SEED_GC_TRACE=1 qfitzah.s -o tiny.o
            ld -m elf_i386 -static -z noseparate-code tiny.o -o tiny
            ${pkgs.bash}/bin/bash ${./tests/seed-memory.sh} ./tiny
            touch "$out"
          '';
          blynn-audit = pkgs.runCommand "qfitzah-blynn-audit-tests"
            { nativeBuildInputs = [ pkgs.python3 ]; } ''
            mkdir -p source/bootstrap/blynn source/tests
            cp ${./bootstrap/blynn/audit-build.py} source/bootstrap/blynn/audit-build.py
            cp ${./tests/blynn-audit.py} source/tests/blynn-audit.py
            python3 -B source/tests/blynn-audit.py
            python3 -B -O source/tests/blynn-audit.py
            touch "$out"
          '';
          blynn-sources = pkgs.runCommand "qfitzah-blynn-source-tests"
            { nativeBuildInputs = [ pkgs.git ]; } ''
            mkdir -p source/bootstrap source/tests
            cp -R ${./bootstrap/blynn} source/bootstrap/blynn
            cp ${./tests/blynn-sources.sh} source/tests/blynn-sources.sh
            ${pkgs.bash}/bin/bash source/tests/blynn-sources.sh
            touch "$out"
          '';
          default = pkgs.runCommand "qfitzah-tests" { } ''
            # Run checks with the seed and source files.
            mkdir source
            cp -R ${./bootstrap} source/bootstrap
            cp -R ${./examples} source/examples
            cp -R ${./tests} source/tests
            ${pkgs.bash}/bin/bash source/tests/run.sh ${self.packages.${system}.default}/bin/qfitzah
            touch "$out"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.binutils ];
          };
        }
      );
    };
}
