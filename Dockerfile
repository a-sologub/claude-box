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
# here removes the need for `php -d memory_limit=...` prefixes, which would
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
    && npm install -g @anthropic-ai/sandbox-runtime
