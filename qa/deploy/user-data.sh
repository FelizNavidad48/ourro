#!/usr/bin/env bash
# EC2 user-data for the cloud QA loop box (qa/docs/plan-cloud-qa.md).
#
# Instance shape: t4g.large or larger (arm64/Graviton — the image is built
# and suite-verified on debian/arm64), 30GB+ gp3 root, a dedicated EBS
# volume for /data, an IAM role with ssm:GetParameter on /ourro-loop/* and
# the CloudWatch agent policy. Supports Ubuntu 24.04 and Amazon Linux 2023
# arm64 AMIs.
set -euo pipefail

if command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker.io docker-compose-v2 git awscli curl
elif command -v dnf >/dev/null 2>&1; then
  # Amazon Linux 2023: Docker is in the AL2023 repository, while Compose is
  # either packaged separately or installed as Docker's official CLI plugin.
  # AL2023 includes curl-minimal, which provides curl but conflicts with the
  # separate curl RPM; do not request the full curl package here.
  dnf install -y docker git awscli
  if ! docker compose version >/dev/null 2>&1; then
    dnf install -y docker-compose-plugin || true
  fi
  if ! docker compose version >/dev/null 2>&1; then
    case "$(uname -m)" in
      aarch64|arm64) COMPOSE_ARCH="aarch64" ;;
      x86_64|amd64) COMPOSE_ARCH="x86_64" ;;
      *) echo "unsupported architecture for Docker Compose: $(uname -m)" >&2; exit 1 ;;
    esac
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    curl --fail --location \
      "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" \
      --output /usr/local/lib/docker/cli-plugins/docker-compose
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  docker compose version
  # AL2023 currently ships Buildx 0.12, while Compose requires >= 0.17.
  # Install a pinned current official Buildx ARM/x86 plugin in the higher-
  # priority local plugin directory rather than relying on an unavailable RPM.
  BUILDX_VERSION="v0.34.1"
  case "$(uname -m)" in
    aarch64|arm64) BUILDX_ARCH="arm64" ;;
    x86_64|amd64) BUILDX_ARCH="amd64" ;;
    *) echo "unsupported architecture for Docker Buildx: $(uname -m)" >&2; exit 1 ;;
  esac
  install -d -m 0755 /usr/local/lib/docker/cli-plugins
  curl --fail --location \
    "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${BUILDX_ARCH}" \
    --output /usr/local/lib/docker/cli-plugins/docker-buildx
  chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx
  docker buildx version
else
  echo "unsupported Linux distribution: no apt-get or dnf package manager" >&2
  exit 1
fi

systemctl enable --now docker

# /data — the durable volume (loop state, ledgers, clones, evidence).
if ! mountpoint -q /data; then
  mkdir -p /data
  DEV=$(lsblk -dnro NAME,MOUNTPOINT | awk '$2=="" && $1!~"loop" {print "/dev/"$1; exit}')
  blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -L ourrodata "$DEV"
  echo "LABEL=ourrodata /data ext4 defaults,nofail 0 2" >> /etc/fstab
  mount /data
fi

# The repo clone the container is built from (public — no credentials needed).
OURRO_REPO_URL="${OURRO_REPO_URL:-https://github.com/FelizNavidad48/ourro.git}"
if [ ! -d /data/ourro ]; then
  git clone "$OURRO_REPO_URL" /data/ourro
fi

/data/ourro/qa/deploy/fetch-secrets.sh /data/ourro-loop.env

cd /data/ourro
docker compose -f qa/deploy/docker-compose.yml up -d --build
