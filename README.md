# discourse-acp-sandbox

The **Nix launch solution** for running [discourse-acp](../discourse-acp) agents
inside [microsandbox](https://github.com/microsandbox/microsandbox) microVMs —
hardware-isolated, local-first, one dedicated kernel per agent.

This is deliberately **separate** from the harness. `discourse-acp` is the
buzz-style product that anyone runs with `pip`/`docker` (no Nix). *This* repo is
the opinionated Nix way to launch it: one reusable flake, one tiny flake per
agent.

## Model

- **Shared flake** (`lib.mkAgent`): given an agent's identity, it produces that
  agent's flake outputs (`nix run .#{up,down,logs,build-image}`, a dev shell,
  and `packages.sandboxfile`).
- **A concrete agent** = a directory (see [`../agents/example`](../agents/example))
  whose whole `flake.nix` is one `launch.lib.mkAgent { ... }` call, plus a
  `secretspec.toml`. Its display name and persona come from the bot's Discourse
  profile (account name + "About Me" bio), not from files here.
- `nix run .#up` renders a `Sandboxfile` from the params and boots it with
  `secretspec run -- msb run …`. Inside the microVM the **discourse-acp image**
  runs the harness, which spawns the ACP agent (**claude**) and the
  **discourse-mcp** server (our Python fork).
- **Secrets never touch Nix or git.** They are declared in `secretspec.toml` and
  resolved at launch from your secretspec provider (system keyring by default),
  then injected by msb scoped to the exact host allowed to use them.

## Define a new agent

```sh
cp -r agents/example agents/mybot
$EDITOR agents/mybot/flake.nix          # forum URL, bot account, owner
rm -rf agents/mybot/.git                # if copied; a fresh agent, not example's history
```

## Launch (from the agent's directory)

```sh
cd agents/mybot
nix run .#build-image                   # docker build the harness image + msb image load (once)
claude setup-token                      # Claude headless token
secretspec set CLAUDE_CODE_OAUTH_TOKEN  # store it (keyring)
secretspec set DISCOURSE_API_KEY        # the bot's Discourse API key
nix run .#up                            # secretspec run -> Sandboxfile -> boot the microVM
nix run .#logs    #  ·  nix run .#down
nix build .#sandboxfile && cat result   # inspect the generated manifest
```

## Why microsandbox

The agent runs a shell and edits files for forum users. microsandbox boots the
image in a Firecracker/libkrun microVM with its own kernel, an egress allowlist
(forum + LLM provider only), and host-scoped secrets a compromised agent can't
exfiltrate. Images run from msb's own cache, so no registry: `build-image` does
`docker build` → `docker save` → `msb image load`.

## Status / caveats

- Requires **Nix**, **docker** (to build the image), and **msb**
  (`curl -fsSL https://install.microsandbox.dev | sh`) on a host with hardware
  virt (macOS Apple Silicon / Linux KVM / Windows WHP).
- microsandbox is beta and this machine had no container/virt runtime, so the
  `msb`/`docker` calls were written against microsandbox's current CLI source,
  not run end to end. The stable shapes (image-cache load, `--env`, host-scoped
  `--secret`, `network.allow`) are correct; if your `msb` differs, adjust the
  `msb run` line in [`lib/agent.nix`](./lib/agent.nix).
- **Secret model:** msb's host-scoped secrets are designed to never enter the VM
  (substituted into outbound requests to the allowed host). Both the harness's
  own Discourse polling and discourse-mcp send the key in a header to the forum
  host, so this fits; if your msb build instead needs the literal value at rest,
  switch those two `--secret` flags to `--env` in `lib/agent.nix`.
