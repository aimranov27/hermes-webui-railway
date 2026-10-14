# Hermes Agent + Hermes WebUI for Railway, in one service with one volume.
#
# The base is the official Hermes Agent image, pinned by tag and digest. On top
# of it we add Hermes WebUI at a pinned commit. The WebUI runs the agent
# in-process from the agent's own Python environment, and the Hermes gateway
# (cron, messaging apps, loopback API) runs next to it in the same container.
#
# Versions are pinned so every deploy is reproducible. The update workflow
# (.github/workflows/update.yml) bumps them after a smoke test passes.
ARG HERMES_AGENT_TAG=v0.22.0
ARG HERMES_AGENT_DIGEST=sha256:c69536a39e885b8943329bda68cdf44492458b96aa74a212239bde9d2aeb406a
FROM nousresearch/hermes-agent:${HERMES_AGENT_TAG}@${HERMES_AGENT_DIGEST}

ARG HERMES_AGENT_VERSION=v0.22.0
ARG HERMES_WEBUI_VERSION=exp-v0.52.486
ARG HERMES_WEBUI_COMMIT=adc5dad97621be4e3b76facd5e2f8c49bf4a41b5

USER root

# Hermes WebUI is plain Python and static files. It runs on the agent's own
# Python environment (it reads YAML through ruamel.yaml when PyYAML is
# missing), so nothing else is installed. The import check at the end of this
# step proves that at build time.
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/webui.tar.gz \
      "https://codeload.github.com/nesquena/hermes-webui/tar.gz/${HERMES_WEBUI_COMMIT}"; \
    mkdir -p /opt/hermes-webui; \
    tar -xzf /tmp/webui.tar.gz -C /opt/hermes-webui --strip-components=1; \
    rm /tmp/webui.tar.gz; \
    printf "__version__ = '%s'\n" "${HERMES_WEBUI_VERSION}" > /opt/hermes-webui/api/_version.py; \
    rm -rf /opt/hermes-webui/tests /opt/hermes-webui/.github; \
    chmod -R a+rX,go-w /opt/hermes-webui; \
    cd /opt/hermes-webui; \
    HERMES_HOME=/tmp/hermes-check /opt/hermes/.venv/bin/python -c "import api.yaml_compat, cryptography, run_agent"; \
    rm -rf /tmp/hermes-check

COPY --chmod=0755 railway/start.sh /opt/railway/start.sh

# HERMES_HOME (/opt/data) is where the Railway volume is mounted. Config,
# sessions, memory, skills, cron jobs and WebUI state all live there.
ENV HERMES_WEBUI_AGENT_DIR=/opt/hermes \
    HERMES_WEBUI_PYTHON=/opt/hermes/.venv/bin/python \
    HERMES_WEBUI_STATE_DIR=/opt/data/webui \
    HERMES_WEBUI_DEFAULT_WORKSPACE=/opt/data/workspace \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_AGENT_VERSION=${HERMES_AGENT_VERSION} \
    HERMES_WEBUI_VERSION=${HERMES_WEBUI_VERSION} \
    PORT=8080

EXPOSE 8080

# The upstream entrypoint prepares the volume as root and then runs this
# command as the unprivileged hermes user.
CMD ["/opt/railway/start.sh"]
