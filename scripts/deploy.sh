#!/bin/bash
# Desplega una fase del laboratori BIND9 DNS
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Ús: $0 <fase>"
    echo ""
    echo "Fases disponibles:"
    echo "  1, primary    - Fase 1: DNS primari bàsic"
    echo "  2, secondary  - Fase 2: Primari + secundari (AXFR)"
    echo "  3, delegation - Fase 3: + Delegació magatzem.demobind.test"
    echo "  4, full       - Fase 4: + Nginx + client Firefox noVNC"
    echo ""
    echo "Exemples:"
    echo "  $0 1"
    echo "  $0 delegation"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

case "$1" in
    1|primary)    FASE="fase1-primary" ;;
    2|secondary)  FASE="fase2-secondary" ;;
    3|delegation) FASE="fase3-delegation" ;;
    4|full)       FASE="fase4-full" ;;
    *)
        echo "Error: Fase desconeguda '$1'"
        usage
        ;;
esac

FASE_DIR="$BASE_DIR/$FASE"
TOPOLOGY_FILE="$FASE_DIR/topology.clab.yml"

if [ ! -f "$TOPOLOGY_FILE" ]; then
    echo "Error: No s'ha trobat $TOPOLOGY_FILE"
    exit 1
fi

echo "=== Desplegant $FASE ==="
echo ""

echo ">>> Verificant imatge bind9-lab:latest..."
if ! docker image inspect bind9-lab:latest &>/dev/null; then
    echo "    Imatge no trobada. Construint..."
    "$SCRIPT_DIR/build-images.sh"
else
    echo "    bind9-lab:latest OK"
fi
echo ""

echo ">>> Preparant bridge Linux br-dns..."
if ! ip link show br-dns &>/dev/null; then
    sudo ip link add name br-dns type bridge
    sudo ip link set br-dns up
    echo "    Bridge br-dns creat"
else
    echo "    Bridge br-dns ja existeix"
fi
echo ""

echo ">>> Desplegant topologia amb containerlab..."
cd "$FASE_DIR"
sudo containerlab deploy --topo topology.clab.yml

echo ""
echo "=== Desplegament completat ==="
echo ""

CLAB_NAME=$(grep "^name:" "$TOPOLOGY_FILE" | awk '{print $2}')

echo "Nodes desplegats:"
sudo containerlab inspect --topo "$TOPOLOGY_FILE" 2>/dev/null || true

echo ""
echo "Comandes útils:"
echo "  Obrir shell:   docker exec -it clab-${CLAB_NAME}-dns1 bash"
echo "  Veure logs:    docker exec clab-${CLAB_NAME}-dns1 tail -f /var/log/bind/query.log"
echo "  Consulta DNS:  docker exec clab-${CLAB_NAME}-cl01 dig demobind.test SOA"
if [ "$FASE" = "fase4-full" ]; then
    echo "  Client gràfic: http://localhost:6080"
fi
echo "  Destruir:      $SCRIPT_DIR/destroy.sh $1"
