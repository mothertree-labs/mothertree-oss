FROM node:20-bookworm

ARG TARGETARCH

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl jq python3 less unzip gnupg ca-certificates rsync gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Terraform 1.14.4
RUN curl -fsSL "https://releases.hashicorp.com/terraform/1.14.4/terraform_1.14.4_linux_${TARGETARCH}.zip" -o /tmp/tf.zip \
    && unzip /tmp/tf.zip -d /usr/local/bin/ \
    && rm /tmp/tf.zip

## kubectl v1.34.1
RUN curl -fsSL "https://dl.k8s.io/release/v1.34.1/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# Helm v4.1.0
RUN curl -fsSL "https://get.helm.sh/helm-v4.1.0-linux-${TARGETARCH}.tar.gz" | tar xz -C /tmp \
    && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-${TARGETARCH}

# Helmfile v1.2.3
RUN curl -fsSL "https://github.com/helmfile/helmfile/releases/download/v1.2.3/helmfile_1.2.3_linux_${TARGETARCH}.tar.gz" | tar xz -C /tmp \
    && mv /tmp/helmfile /usr/local/bin/helmfile \
    && rm -f /tmp/LICENSE /tmp/README.md

# yq v4.52.1
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/v4.52.1/yq_linux_${TARGETARCH}" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# Docker CLI (uses host Docker daemon via socket mount)
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bookworm stable" \
    > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# gh CLI (latest from apt repo)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Helm plugins (shared location)
ENV HELM_PLUGINS=/usr/local/share/helm/plugins
RUN helm plugin install https://github.com/databus23/helm-diff --version v3.14.1 --verify=false

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

# Terraform plugin cache
ENV TF_PLUGIN_CACHE_DIR=/home/devuser/.terraform.d/plugin-cache

# Create symlink so hardcoded REPO paths in scripts work unmodified
# Replace /home/user/code with your local repo parent directory if needed
RUN mkdir -p /home/user/code && ln -s /workspace /home/user/code/mothertree

# Create devuser with macOS-compatible UID/GID
RUN groupadd -g 20 devgroup 2>/dev/null || true \
    && useradd -m -u 501 -g 20 -s /bin/bash devuser \
    && mkdir -p /workspace /home/devuser/.terraform.d/plugin-cache /home/devuser/.claude \
    && echo '{"statusLine":{"type":"command","command":"jq -r \"[\\(.model.display_name // \\\"?\\\")] \\(.context_window.used_percentage // 0)% context\""}}' > /home/devuser/.claude/settings.json \
    && echo '{"hasCompletedOnboarding":true,"theme":"dark","bypassPermissionsModeAccepted":true}' > /home/devuser/.claude.json \
    && chown -R 501:20 /home/devuser

ENV HOME=/home/devuser

WORKDIR /workspace

ENTRYPOINT ["claude", "--dangerously-skip-permissions"]
