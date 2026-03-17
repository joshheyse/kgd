{
  description = "kgd - Kitty Graphics Daemon";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
  };

  outputs = {
    nixpkgs,
    self,
    ...
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forEachSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          pkgs = import nixpkgs {inherit system;};
          inherit system;
        });
  in {
    packages = forEachSystem ({pkgs, ...}: {
      default = pkgs.buildGoModule {
        pname = "kgd";
        version = "0.1.0";
        src = ./.;
        vendorHash = null; # update after first `go mod tidy`
      };
    });

    overlays.default = final: _: {
      kgd = self.packages.${final.system}.default;
    };

    devShells = forEachSystem ({pkgs, ...}: {
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          go
          gopls
          gotools
          just
          git
          python3
        ];
      };
    });
  };
}
