#!/usr/bin/env bash
# MARK: post-create — eugo toolchain dev container for eugo-inc forks.
# Tolerant by design: prints diagnostics, never fails the create.
set +e

echo "[devcontainer] $(clang --version 2>/dev/null | head -1)"
echo "[devcontainer] $(cmake --version 2>/dev/null | head -1)"

# eugo-kb MCP needs the in-container Docker CLI + the host socket (bind-mounted) + the
# eugo-kb-tools container running on the host.
if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then
  echo "[devcontainer] host Docker reachable (CLI + socket)"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx eugo-kb-tools \
    && echo "[devcontainer] eugo-kb MCP backend (eugo-kb-tools) reachable" \
    || echo "[devcontainer] note: 'eugo-kb-tools' not running on the host — start it for the eugo-kb MCP"
else
  echo "[devcontainer] note: docker CLI/socket not ready — eugo-kb MCP unavailable"
fi
command -v npx >/dev/null 2>&1 \
  && echo "[devcontainer] node/npx OK (GitHits MCP)" \
  || echo "[devcontainer] note: npx missing — GitHits MCP unavailable"
[ -d "$HOME/.claude" ] \
  && echo "[devcontainer] ~/.claude persisted at $HOME/.claude" \
  || echo "[devcontainer] note: run 'claude' once to log in (persists via the eugo-claude-config volume)"

true
