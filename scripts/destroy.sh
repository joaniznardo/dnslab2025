#!/bin/bash
# Destrueix una fase del laboratori BIND9 DNS
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    echo "Ús: $0 <fase|all>"
    echo ""
    echo "Fases disponibles:"
    echo "  1, primary    - Fase 1"
    echo "  2, secondary  - Fase 2"
    echo "  3, delegation - Fase 3"
    echo "  4, full       - Fase 4"
    echo "  all           - Totes les fases"
    echo ""
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

destroy_fase() {
    local fase=$1
    local fase_dir="$BASE_DIR/$fase"
    local topology_file="$fase_dir/topology.clab.yml"

    if [ -f "$topology_file" ]; then
        echo ">>> Destruint $fase..."
        cd "$fase_dir"
        sudo containerlab destroy --topo topology.clab.yml --cleanup 2>/dev/null || true
        echo "    $fase destruït"
    else
        echo "    $fase: topologia no trobada, saltant"
    fi
}

case "$1" in
    1|primary)    destroy_fase "fase1-primary" ;;
    2|secondary)  destroy_fase "fase2-secondary" ;;
    3|delegation) destroy_fase "fase3-delegation" ;;
    4|full)       destroy_fase "fase4-full" ;;
    all)
        echo "=== Destruint totes les fases ==="
        destroy_fase "fase1-primary"
        destroy_fase "fase2-secondary"
        destroy_fase "fase3-delegation"
        destroy_fase "fase4-full"
        ;;
    *)
        echo "Error: Fase desconeguda '$1'"
        usage
        ;;
esac

echo ""
echo ">>> Eliminant bridge Linux br-dns..."
if ip link show br-dns &>/dev/null 2>&1; then
    sudo ip link set br-dns down 2>/dev/null || true
    sudo ip link delete br-dns type bridge 2>/dev/null || true
    echo "    Bridge br-dns eliminat"
fi

echo ""
echo "=== Destrucció completada ==="
