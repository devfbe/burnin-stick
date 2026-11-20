{
  description = "burnin-stick: a bootable hardware burn-in ISO with a memtest-style status screen";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      burnin = nixpkgs.lib.nixosSystem {
        modules = [
          ./burnin.nix
          { nixpkgs.hostPlatform = system; }
        ];
      };
    in
    {
      # The NixOS module, to embed the burn-in into an image of your own.
      nixosModules.default = ./burnin.nix;

      nixosConfigurations.burnin = burnin;

      packages.${system} = {
        iso = burnin.config.system.build.isoImage;
        default = self.packages.${system}.iso;
      };
    };
}
