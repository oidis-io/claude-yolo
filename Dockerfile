 #/* ********************************************************************************************************* *
 # *
 # * Copyright 2026 Oidis
 # *
 # * SPDX-License-Identifier: BSD-3-Clause
 # * The BSD-3-Clause license for this file can be found in the LICENSE.txt file included with this distribution
 # * or at https://spdx.org/licenses/BSD-3-Clause.html#licenseText
 # *
 # * ********************************************************************************************************* */

ARG BASE_IMAGE=ubuntu:24.04

FROM node:22-slim AS claude-builder

RUN npm install -g @anthropic-ai/claude-code
RUN mkdir -p /opt/claude-code && \
    cp -a /usr/local/lib/node_modules/@anthropic-ai/claude-code /opt/claude-code/package && \
    cp -a /usr/local/bin/node /opt/claude-code/node

RUN printf '#!/bin/sh\nexec /opt/claude-code/node /opt/claude-code/package/cli.js "$@"\n' \
    > /opt/claude-code/claude && chmod +x /opt/claude-code/claude

FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ripgrep \
    jq \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=claude-builder /opt/claude-code /opt/claude-code
ENV PATH="/opt/claude-code:${PATH}"

COPY <<'ENTRYPOINT' /usr/local/bin/entrypoint.sh
#!/bin/sh
mkdir -p /root/.claude

DEFAULTS='{"hasCompletedOnboarding":true,"theme":"dark","projects":{"/workspace":{"allowedTools":[],"hasTrustDialogAccepted":true}}}'
if [ ! -f /root/.claude.json ]; then
  echo "$DEFAULTS" > /root/.claude.json
else
  tmp=$(echo "$DEFAULTS" | jq -s '.[1] * .[0]' - /root/.claude.json) && \
  echo "$tmp" > /root/.claude.json
fi

SETTINGS='{"skipDangerousModePermissionPrompt":true}'
if [ ! -f /root/.claude/settings.json ]; then
  echo "$SETTINGS" > /root/.claude/settings.json
else
  tmp=$(echo "$SETTINGS" | jq -s '.[1] * .[0]' - /root/.claude/settings.json) && \
  echo "$tmp" > /root/.claude/settings.json
fi

exec claude --dangerously-skip-permissions "$@"
ENTRYPOINT
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENV TERM=xterm-256color
ENV COLORTERM=truecolor
ENV IS_SANDBOX=1
ENV DISABLE_AUTO_MIGRATE_TO_NATIVE=1

ENTRYPOINT ["entrypoint.sh"]
