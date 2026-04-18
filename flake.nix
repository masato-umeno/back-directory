{
  description = "Flake for developing and building back-directory";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forEachSystem = f: lib.genAttrs supportedSystems (system: f system);
    in
    {
      packages = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.rustPlatform.buildRustPackage {
            pname = "bd-core";
            version = "0.1.2";
            src = self;
            cargoLock.lockFile = ./Cargo.lock;

            meta = with pkgs.lib; {
              description = "Rust core for back-directory";
              homepage = "https://github.com/01-mu/back-directory";
              license = licenses.mit;
              mainProgram = "bd-core";
              platforms = platforms.unix;
            };
          };

          bd-core = self.packages.${system}.default;
        });

      apps = forEachSystem (system: {
        default = self.apps.${system}.bd-core;
        bd-core = {
          type = "app";
          program = "${self.packages.${system}.bd-core}/bin/bd-core";
        };
      });

      devShells = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cargo
              rustc
              rustfmt
              clippy
              bash
              zsh
              sqlite
            ];
          };
        });
    };
}
