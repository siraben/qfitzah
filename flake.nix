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

            src = ./.;

            nativeBuildInputs = [ pkgs.binutils ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              as --32 qfitzah.s -o qfitzah.o
              ld -m elf_i386 -static -z noseparate-code -o qfitzah.bloated qfitzah.o
              objcopy -S -R .note.gnu.build-id qfitzah.bloated qfitzah

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
          default = pkgs.runCommand "qfitzah-tests" { } ''
            ${pkgs.bash}/bin/bash ${./.}/tests/run.sh ${self.packages.${system}.default}/bin/qfitzah
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
