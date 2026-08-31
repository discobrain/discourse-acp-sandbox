# mkAgent — shared flake logic to run ONE concrete Discourse ACP agent as a
# container via a Nix-installable runtime (colima on macOS; plain docker/k8s
# elsewhere). Each agent is a tiny flake calling launch.lib.mkAgent { ... }.
#
# `nix run .#up` starts the agent as a detached, auto-restarting container: the
# discourse-acp image runs the harness, which spawns the ACP agent (claude) and
# the discourse-mcp server. Non-secret identity is baked here; secrets are
# resolved at launch by secretspec and passed BY NAME (never in Nix or argv).
# The same image runs later in Kubernetes.
#
# Isolation: the container runs inside colima's Linux VM, off the macOS host
# filesystem. Requires `docker` + `colima` on PATH (install via nix-darwin) and
# `colima start`. No Docker Desktop, no msb.
{ nixpkgs }:

{ name ? ""                            # container name (default: the bot username)
, discourseUrl                        # https://forum.example.com
, username                            # the bot's Discourse account
, owners ? [ ]                        # usernames allowed to !shutdown/!cancel/!rotate
, allowlist ? [ ]                     # extra usernames when respondTo = "allowlist"
, respondTo ? "owner-only"            # owner-only | allowlist | anyone | nobody
, agents ? 1                          # 1..32 agent subprocesses
, persona ? ""                        # explicit persona; "" -> harness uses the bot's Discourse bio
, personaFromBio ? true               # when persona is "", derive it from the bot account's About Me
, agentCommand ? "claude-agent-acp"   # ACP agent runtime (goose / codex-acp also work)
, agentArgs ? [ ]                     # args for the ACP agent (e.g. [ "acp" ] for omp/goose)
, memory ? 2048                       # MiB (container --memory)
, cpus ? 2
, image ? "discourse-acp:latest"
, discourseAcpDir ? "../../discourse-acp"  # harness repo (for build-image)
, discourseMcpDir ? "../../discourse-mcp"  # our discourse-mcp fork (for build-image)
, overlay ? false                     # build/run a per-agent image overlay (this dir's Dockerfile)
}:

let
  lib = nixpkgs.lib;
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  forAll = f: lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});

  hostOf = url:
    let m = builtins.match "[a-z]+://([^/:]+).*" url;
    in if m == null then url else builtins.head m;

  forumHost = hostOf discourseUrl;
  sandboxName = if name == "" then username else name;
  ownersCsv = lib.concatStringsSep "," owners;
  allowlistCsv = lib.concatStringsSep "," allowlist;
  agentArgsCsv = lib.concatStringsSep "," agentArgs;
  # A per-agent overlay image (this agent's Dockerfile FROM the shared base) so
  # the shared image stays agent-agnostic and agent-specific runtimes live here.
  agentImage = "${sandboxName}-agent:latest";
  runImage = if overlay then agentImage else image;
  overlayBuild = lib.optionalString overlay ''
    [ -f "$PWD/Dockerfile" ] || { echo "overlay = true but no Dockerfile in $PWD" >&2; exit 1; }
    echo ">> docker build ${agentImage} (overlay: $PWD on ${image})"
    docker build --build-arg BASE=${image} -t ${agentImage} "$PWD"
  '';

  needDocker = ''command -v docker >/dev/null 2>&1 || { echo "error: 'docker' not on PATH — add colima+docker to nix-darwin and run 'colima start'" >&2; exit 1; }'';

  mkBuild = pkgs: pkgs.writeShellApplication {
    name = "build-image";
    runtimeInputs = [ pkgs.bash pkgs.coreutils ];
    text = ''
      src="''${DISCOURSE_ACP_DIR:-${discourseAcpDir}}"
      mcpsrc="''${DISCOURSE_MCP_DIR:-${discourseMcpDir}}"
      [ -f "$src/Dockerfile" ] || { echo "no Dockerfile at '$src' (set DISCOURSE_ACP_DIR)" >&2; exit 1; }
      [ -f "$mcpsrc/pyproject.toml" ] || { echo "no discourse-mcp at '$mcpsrc' (set DISCOURSE_MCP_DIR)" >&2; exit 1; }
      ${needDocker}
      echo ">> docker build ${image} (context: $src, mcp: $mcpsrc)"
      docker build -t ${image} --build-context mcp="$mcpsrc" "$src"
      ${overlayBuild}
    '';
  };

  mkUp = pkgs: pkgs.writeShellApplication {
    name = "up";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.secretspec ];
    text = ''
      ${needDocker}
      command -v secretspec >/dev/null 2>&1 || { echo "error: 'secretspec' not on PATH (see secretspec.toml)" >&2; exit 1; }
      mkdir -p "$PWD/workspace"
      echo ">> starting '${sandboxName}' as @${username} (forum ${forumHost}) — detached, auto-restart"
      docker rm -f ${sandboxName} >/dev/null 2>&1 || true
      # secretspec resolves the declared secrets into the environment; docker
      # forwards them BY NAME (-e VAR with no value), so values never hit argv.
      secretspec run --reason "boot the ${sandboxName} Discourse ACP agent" -- docker run -d --restart unless-stopped \
        --name ${sandboxName} \
        --memory ${toString memory}m --cpus ${toString cpus} \
        -v "$PWD/workspace:/workspace" \
        -e DISCOURSE_URL=${lib.escapeShellArg discourseUrl} \
        -e DISCOURSE_API_USERNAME=${lib.escapeShellArg username} \
        -e DISCOURSE_ACP_AGENT_OWNER=${lib.escapeShellArg ownersCsv} \
        -e DISCOURSE_ACP_RESPOND_TO=${lib.escapeShellArg respondTo} \
        -e DISCOURSE_ACP_RESPOND_TO_ALLOWLIST=${lib.escapeShellArg allowlistCsv} \
        -e DISCOURSE_ACP_AGENTS=${toString agents} \
        -e DISCOURSE_ACP_AGENT_COMMAND=${lib.escapeShellArg agentCommand} \
        -e DISCOURSE_ACP_AGENT_ARGS=${lib.escapeShellArg agentArgsCsv} \
        -e DISCOURSE_ACP_SYSTEM_PROMPT=${lib.escapeShellArg persona} \
        -e DISCOURSE_ACP_PERSONA_FROM_BIO=${if personaFromBio then "true" else "false"} \
        -e PYTHONUNBUFFERED=1 \
        -e DISCOURSE_API_KEY -e CLAUDE_CODE_OAUTH_TOKEN \
        ${runImage}
      echo "started '${sandboxName}'. logs: nix run .#logs   ·   stop: nix run .#down"
    '';
  };

  mkSimple = pkgs: appName: body: pkgs.writeShellApplication {
    name = appName; runtimeInputs = [ pkgs.bash ];
    text = ''${needDocker}; ${body}'';
  };

  mkDevShell = pkgs: pkgs.mkShell {
    packages = [ pkgs.jq pkgs.secretspec ];
    shellHook = ''
      echo "agent '${sandboxName}' — @${username} on ${forumHost}"
      echo "  runtime on PATH (via nix-darwin): docker + colima (run 'colima start'); secretspec is provided here"
      echo "  secrets: declared in secretspec.toml; set them with 'secretspec set <NAME>'"
      echo "  nix run .#build-image   ·   nix run .#up   ·   nix run .#logs   ·   nix run .#down"
    '';
  };

  app = program: { type = "app"; inherit program; };
in
{
  apps = forAll (pkgs: {
    build-image = app "${mkBuild pkgs}/bin/build-image";
    up = app "${mkUp pkgs}/bin/up";
    down = app "${mkSimple pkgs "down" "exec docker rm -f ${sandboxName}"}/bin/down";
    logs = app "${mkSimple pkgs "logs" "exec docker logs -f ${sandboxName}"}/bin/logs";
    default = app "${mkUp pkgs}/bin/up";
  });
  devShells = forAll (pkgs: { default = mkDevShell pkgs; });
}
