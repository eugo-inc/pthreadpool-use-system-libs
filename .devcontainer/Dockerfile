# eugo toolchain dev container for eugo-inc forks — develop/build the fork with the eugo
# toolchain (clang/cmake/meson/cuda) + GPU + Claude Code/MCP. Image coords are ARGs; override
# via devcontainer.json build.args.
#
# EUGO_ECR_ACCOUNT is deliberately DEFAULT-LESS (2026-07-27). This file is PUBLISHED VERBATIM into
# eugo-inc forks by `open-fork-prs.sh`, several of which are (or were) public — a baked-in default
# put our AWS account id in 7 public repos across 13 branches before anyone noticed. Supply it from
# your environment: `export EUGO_ECR_ACCOUNT=…`, which devcontainer.json forwards via
# `${localEnv:EUGO_ECR_ACCOUNT}`. An unset value fails the build loudly at the FROM line, which is
# the intended behaviour — a missing account is an operator setup error, not something to guess.
#
# 2026-08-06: EUGO_IMAGE_REPO / _TAG / _DIGEST are now DEFAULT-LESS for the same reason. They used to
# hardcode one internal repository and tag by name, which (a) is exactly what `build.sh`'s identifier gate
# refuses to publish, and (b) went stale the moment the fleet repinned onto a different registry account,
# so `open-fork-prs.sh` would have pushed the OLD base back over forks that had already moved. Supply all
# four from your environment; an unset value fails loudly at FROM, which is the intended behaviour.
ARG EUGO_ECR_ACCOUNT
ARG EUGO_ECR_REGION=us-east-1
ARG EUGO_IMAGE_REPO
ARG EUGO_IMAGE_TAG
ARG EUGO_IMAGE_DIGEST
FROM ${EUGO_ECR_ACCOUNT}.dkr.ecr.${EUGO_ECR_REGION}.amazonaws.com/${EUGO_IMAGE_REPO}:${EUGO_IMAGE_TAG}@${EUGO_IMAGE_DIGEST}

# The base already ships node/npm (for the GitHits MCP) but not the Docker CLI — add the static
# Docker CLI (for the eugo-kb MCP's `docker exec` against the host socket bind-mounted in
# devcontainer.json). Also no-op the base's BASH_ENV helper, which is absent in forks.
ARG DOCKER_CLI_VERSION=29.5.3
RUN <<EOT
set -eux
curl -fsSL "https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_CLI_VERSION}.tgz" \
  | tar xz -C /usr/local/bin --strip-components=1 docker/docker
# The base's BASH_ENV sources /usr/local/bin/eugo_shared.inc. On some bases that is a DANGLING symlink
# (the eugo scripts aren't present in a fork) and every non-interactive shell warns; on the umbrella
# images it is a REAL ~70 KB helper library, so blanking it unconditionally destroys a shipped file.
# No-op it ONLY in the dangling case (`-L` and not `-e` == symlink with no target).
if [ -L /usr/local/bin/eugo_shared.inc ] && [ ! -e /usr/local/bin/eugo_shared.inc ]; then
  rm -f /usr/local/bin/eugo_shared.inc
  : > /usr/local/bin/eugo_shared.inc
fi
docker --version
node --version
EOT
