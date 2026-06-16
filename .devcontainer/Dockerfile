# eugo toolchain dev container for eugo-inc forks — develop/build the fork with the eugo
# toolchain (clang/cmake/meson/cuda) + GPU + Claude Code/MCP. Image coords are ARGs; override
# via devcontainer.json build.args. Pulling this image needs ECR access to account 411727469413.
ARG EUGO_ECR_ACCOUNT=411727469413
ARG EUGO_ECR_REGION=us-east-1
ARG EUGO_IMAGE_REPO=slava_mega_test
ARG EUGO_IMAGE_TAG=ray-meson-perf-debug
ARG EUGO_IMAGE_DIGEST=sha256:c2b359973236d8ccf042f69abf60324cc7a26a51e1bdb93b5ccb3cf4cc95fff7
FROM ${EUGO_ECR_ACCOUNT}.dkr.ecr.${EUGO_ECR_REGION}.amazonaws.com/${EUGO_IMAGE_REPO}:${EUGO_IMAGE_TAG}@${EUGO_IMAGE_DIGEST}

# The base already ships node/npm (for the GitHits MCP) but not the Docker CLI — add the static
# Docker CLI (for the eugo-kb MCP's `docker exec` against the host socket bind-mounted in
# devcontainer.json). Also no-op the base's BASH_ENV helper, which is absent in forks.
ARG DOCKER_CLI_VERSION=29.5.3
RUN <<EOT
set -eux
curl -fsSL "https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_CLI_VERSION}.tgz" \
  | tar xz -C /usr/local/bin --strip-components=1 docker/docker
# The base's BASH_ENV sources /usr/local/bin/eugo_shared.inc, which is a DANGLING symlink in a
# fork (the eugo scripts aren't present) — every non-interactive shell warns. Replace it with an
# empty no-op file (rm the dangling link first; writing through it would ENOENT).
rm -f /usr/local/bin/eugo_shared.inc
: > /usr/local/bin/eugo_shared.inc
docker --version
node --version
EOT
