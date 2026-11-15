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
      # PowerShell runs the bd.ps1 smoke test; nixpkgs does not build it for every system.
      powershellFor = pkgs:
        lib.optionals (lib.meta.availableOn pkgs.stdenv.hostPlatform pkgs.powershell) [ pkgs.powershell ];
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
              homepage = "https://github.com/masato-umeno/back-directory";
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

      checks = forEachSystem (system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = self.packages.${system}.default;
        in
        {
          inherit package;
          distribution = pkgs.runCommand "back-directory-distribution-check" {
            nativeBuildInputs = with pkgs; [
              actionlint
              bash
              ruby
              shellcheck
              zsh
            ] ++ powershellFor pkgs;
          } ''
            cp -R ${self} repo
            chmod -R u+w repo
            cd repo
            export BD_CORE_BIN=${package}/bin/bd-core
            shellcheck -e SC2016 scripts/*.sh scripts/*.bash examples/bd-demo/demo.sh examples/bd-demo/pv
            actionlint .github/workflows/*.yml
            sh scripts/e2e-smoke.sh
            sh scripts/test-homebrew-formula.sh
            sh scripts/test-package-lifecycle.sh
            # PowerShell needs a writable HOME, which the build sandbox does not provide.
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            export POWERSHELL_TELEMETRY_OPTOUT=1
            export DOTNET_CLI_TELEMETRY_OPTOUT=1
            sh scripts/test-windows-packages.sh
            if command -v pwsh >/dev/null 2>&1; then
              pwsh -NoProfile -File scripts/e2e-smoke.ps1 -CoreBin "$BD_CORE_BIN"
              pwsh -NoProfile -File scripts/e2e-smoke.ps1 -CoreBin "$BD_CORE_BIN" -Hook prompt
            fi
            sh scripts/demo-media.sh check
            touch "$out"
          '';
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
              shellcheck
              actionlint
              ruby
              asciinema
              asciinema-agg
            ] ++ powershellFor pkgs;
          };
        });
    };
}
