ARG PYTHON_IMAGE=python:3.12-slim

FROM ${PYTHON_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    awscli \
    unzip \
    build-essential \
    pkg-config \
    python3-dev \
    libfreetype6-dev \
    libpng-dev \
    curl \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (required for OSC CLI). Pinned to the 24.x line (not setup_lts.x)
# for CVE-2026-111497; the build fails below the fixed release 24.22.1.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && node -e 'const [M,m,p]=process.versions.node.split(".").map(Number); if (M!==24||m<22||(m===22&&p<1)) { console.error("Node "+process.versions.node+" is below 24.22.1 (CVE-2026-111497)"); process.exit(1) }' \
    && node --version \
    && rm -rf /var/lib/apt/lists/*

RUN pip install gradio

WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "auto" ]
