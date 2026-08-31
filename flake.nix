{
  description = "discourse-acp-sandbox — shared Nix launcher: describe a Discourse ACP agent, run it as a container (colima/docker)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      # The reusable launcher. Each concrete agent is a tiny flake that calls
      # this with its own identity:
      #
      #   inputs.launch.url = "path:../../discourse-acp-sandbox";
      #   outputs = { launch, ... }:
      #     launch.lib.mkAgent { name = "honey"; discourseUrl = "..."; ... };
      #
      # mkAgent returns that agent's flake outputs, so `nix run .#up` in the
      # agent's directory runs the discourse-acp image as a detached container
      # (harness + claude + discourse-mcp) and injects its secrets via secretspec.
      lib.mkAgent = import ./lib/agent.nix { inherit nixpkgs; };

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.jq pkgs.nixpkgs-fmt ];
          shellHook = ''echo "discourse-acp-sandbox launcher lib — see ../agents/example for a concrete agent"'';
        };
      });
    };
}
