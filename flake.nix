{
  description = "Embedded Real-Time Room EQ Correction — simulation environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python3.withPackages (ps: with ps; [
          numpy
          matplotlib
        ]);
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.iverilog
            pkgs.gtkwave
            python
          ];

          shellHook = ''
            echo "Room EQ dev shell ready"
            echo "  iverilog $(iverilog -V 2>&1 | head -1)"
            echo "  gtkwave, python3, numpy, matplotlib available"
            echo "  Run 'make all' to simulate"
          '';
        };
      });
}
