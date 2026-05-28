#!/bin/bash
# Construeix la imatge Docker personalitzada bind9-lab:latest
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$BASE_DIR/docker"

echo "=== Construint imatge bind9-lab:latest ==="
echo ""

if [ ! -f "$DOCKER_DIR/Dockerfile.bind9" ]; then
    echo "Error: No s'ha trobat $DOCKER_DIR/Dockerfile.bind9"
    exit 1
fi

docker build -t bind9-lab:latest -f "$DOCKER_DIR/Dockerfile.bind9" "$DOCKER_DIR"

echo ""
echo "=== Imatge construïda correctament ==="
echo ""
docker images bind9-lab:latest
