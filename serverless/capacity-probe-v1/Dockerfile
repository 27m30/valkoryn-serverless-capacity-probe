# syntax=docker/dockerfile:1.7
ARG CUDA_BASE_IMAGE=nvidia/cuda:12.8.1-base-ubuntu22.04
FROM ${CUDA_BASE_IMAGE}

ARG RUNPOD_VERSION=1.7.13

LABEL org.opencontainers.image.title="SERVERLESS_CAPACITY_PROBE_V1" \
      org.opencontainers.image.version="1.0.0" \
      io.valkoryn.production-worker="false" \
      io.valkoryn.media-generation="disabled"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-minimal python3-pip ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m pip install --no-cache-dir "runpod==${RUNPOD_VERSION}"

WORKDIR /opt/capacity-probe
COPY capacity_probe ./capacity_probe

USER 65532:65532
CMD ["python3", "-m", "capacity_probe.entrypoint"]
