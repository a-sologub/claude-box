# claude-box — Claude Code in an isolated podman container.
# Source this from ~/.bashrc:   source ~/.config/claude-box/claude-box.sh
# Requires config.env, gitconfig and gh-token.env next to this file
# (see the .example files). None of the three is committed.

CLAUDE_BOX_DIR="${BASH_SOURCE[0]%/*}"
[[ $CLAUDE_BOX_DIR == "${BASH_SOURCE[0]}" ]] && CLAUDE_BOX_DIR=.
CLAUDE_BOX_DIR="$(cd "$CLAUDE_BOX_DIR" && pwd)"

_claude_box_load() {
  local f
  for f in config.env gitconfig gh-token.env; do
    if [[ ! -f "$CLAUDE_BOX_DIR/$f" ]]; then
      echo "claude-box: missing $CLAUDE_BOX_DIR/$f (see $f.example)" >&2
      return 1
    fi
  done
  # shellcheck source=/dev/null
  source "$CLAUDE_BOX_DIR/config.env"
  : "${CLAUDE_BOX_WORKSPACE:=$HOME/Work}"
  : "${CLAUDE_BOX_IMAGE:=claude-code}"
  : "${CLAUDE_BOX_DB_HOST:=host.containers.internal}"
  : "${CLAUDE_BOX_MEMORY:=8g}"
  : "${CLAUDE_BOX_CPUS:=4}"
}

# Common mounts and hardening shared by the normal and the rescue entry point.
_claude_box_common_args() {
  # Start in the project you are in, not at the mount root: with filesystem
  # isolation on, Bash can write cwd and below, so cwd=/workspace would make
  # every project writable.
  local wd=/workspace
  [[ $PWD == "$CLAUDE_BOX_WORKSPACE/"* ]] && wd=/workspace/${PWD#"$CLAUDE_BOX_WORKSPACE/"}
  printf '%s\n' \
    -w "$wd" \
    -v "$CLAUDE_BOX_WORKSPACE:/workspace:z" \
    -v claude-code-config:/home/claude/.claude \
    -v claude-cache:/home/claude/.cache \
    -v "$CLAUDE_BOX_DIR/gitconfig:/home/claude/.gitconfig:ro,z" \
    -e GIT_CONFIG_GLOBAL=/home/claude/.gitconfig \
    -e CLAUDE_CONFIG_DIR=/home/claude/.claude \
    -e "DB_HOST=$CLAUDE_BOX_DB_HOST" \
    -e TERM -e COLORTERM -e TERM_PROGRAM -e TERM_PROGRAM_VERSION -e TMUX \
    --env-file "$CLAUDE_BOX_DIR/gh-token.env" \
    --userns=keep-id \
    --security-opt no-new-privileges \
    --security-opt label=type:container_engine_t \
    --cap-drop=ALL
}

claude-box() {
  _claude_box_load || return 1
  local -a args
  mapfile -t args < <(_claude_box_common_args)
  podman run -it --rm "${args[@]}" \
    -v "$CLAUDE_BOX_DIR/user-settings.json:/home/claude/.claude/settings.json:ro,z" \
    --read-only \
    --tmpfs /tmp:rw,size=2g,mode=1777 \
    --tmpfs /home/claude/.config:rw,size=64m \
    --tmpfs /home/claude/.local:rw,size=256m \
    --memory="$CLAUDE_BOX_MEMORY" --cpus="$CLAUDE_BOX_CPUS" --pids-limit=2048 \
    "$CLAUDE_BOX_IMAGE" claude --setting-sources user "$@"
}

claude-box-update() {
  _claude_box_load || return 1
  podman build \
    --build-arg UID="$(id -u)" \
    --build-arg CACHE_BUST="$(date +%s)" \
    -t "$CLAUDE_BOX_IMAGE" "$CLAUDE_BOX_DIR"
}

# Rescue: neutralises the baked-in policy by mounting an empty object over it.
# For when the sandbox stops starting (podman/kernel/SELinux update) and
# failIfUnavailable makes every Bash command fail with no way out from inside.
# Runs WITHOUT egress filtering, WITHOUT --read-only and WITHOUT resource
# limits — diagnose, fix the Dockerfile, rebuild, stop using this.
claude-box-rescue() {
  _claude_box_load || return 1
  local -a args
  mapfile -t args < <(_claude_box_common_args)
  podman run -it --rm "${args[@]}" \
    -v "$CLAUDE_BOX_DIR/empty-policy.json:/etc/claude-code/managed-settings.json:ro,z" \
    "$CLAUDE_BOX_IMAGE" claude "$@"
}
