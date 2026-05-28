#!/bin/bash
# lab.sh — Gestió del laboratori DNS amb BIND9 i Containerlab
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Llegeix la fase activa del fitxer d'estat
get_active_fase() {
    if [ -f "$SCRIPT_DIR/.lab-fase" ]; then
        cat "$SCRIPT_DIR/.lab-fase"
    else
        echo ""
    fi
}

get_clab_name() {
    local fase=$1
    case "$fase" in
        fase1-primary)    echo "bind9-fase1" ;;
        fase2-secondary)  echo "bind9-fase2" ;;
        fase3-delegation) echo "bind9-fase3" ;;
        fase4-full)       echo "bind9-fase4" ;;
    esac
}

fase_to_dir() {
    case "$1" in
        1|primary)    echo "fase1-primary" ;;
        2|secondary)  echo "fase2-secondary" ;;
        3|delegation) echo "fase3-delegation" ;;
        4|full)       echo "fase4-full" ;;
        *)            echo "" ;;
    esac
}

usage() {
    cat <<EOF
Ús: $0 <comanda> [arguments]

Comandes:
  build              Construir la imatge Docker bind9-lab:latest
  deploy <N>         Desplegar fase N (1-4)
                       1 / primary    — DNS primari bàsic
                       2 / secondary  — + Servidor secundari (AXFR)
                       3 / delegation — + Delegació magatzem.demobind.test
                       4 / full       — + Nginx (www) + client Firefox noVNC
  destroy            Destruir la fase activa
  status             Mostrar estat del lab (fase activa i contenidors)
  shell [node]       Obrir shell al node (per defecte: dns1)
  logs  [node]       Mostrar query.log del node (per defecte: dns1)
  errors [node]      Mostrar error.log del node (per defecte: dns1)
  check              Verificar prerequisits (Docker, containerlab)

Exemples:
  $0 build
  $0 deploy 1
  $0 deploy 4
  $0 shell cl01
  $0 logs dns1
  $0 destroy

Accés al client gràfic (fase 4):
  http://localhost:6080
EOF
    exit 1
}

cmd_check() {
    echo "=== Verificant prerequisits ==="
    local ok=true

    echo -n "  Docker:       "
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo "OK ($(docker --version | cut -d' ' -f3 | tr -d ','))"
    else
        echo "ERROR — Docker no disponible o no actiu"
        ok=false
    fi

    echo -n "  Containerlab: "
    if command -v containerlab &>/dev/null; then
        echo "OK ($(containerlab version | grep 'Version:' | awk '{print $2}'))"
    else
        echo "ERROR — containerlab no instal·lat"
        ok=false
    fi

    echo -n "  Imatge bind9-lab: "
    if docker image inspect bind9-lab:latest &>/dev/null 2>&1; then
        echo "OK"
    else
        echo "No trobada (executar: $0 build)"
    fi

    if [ "$ok" = false ]; then
        echo ""
        echo "Alguns prerequisits no estan satisfets."
        exit 1
    fi
    echo ""
    echo "Tots els prerequisits OK."
}

cmd_build() {
    "$SCRIPT_DIR/scripts/build-images.sh"
}

cmd_deploy() {
    local fase_arg="$1"
    local fase_dir
    fase_dir=$(fase_to_dir "$fase_arg")

    if [ -z "$fase_dir" ]; then
        echo "Error: Fase desconeguda '$fase_arg'"
        usage
    fi

    # Destruir fase anterior si n'hi ha
    local active
    active=$(get_active_fase)
    if [ -n "$active" ] && [ "$active" != "$fase_dir" ]; then
        echo ">>> Destruint fase anterior ($active)..."
        "$SCRIPT_DIR/scripts/destroy.sh" "$active" 2>/dev/null || true
    fi

    "$SCRIPT_DIR/scripts/deploy.sh" "$fase_arg"
    echo "$fase_dir" > "$SCRIPT_DIR/.lab-fase"
}

cmd_destroy() {
    local active
    active=$(get_active_fase)
    if [ -z "$active" ]; then
        echo "Cap fase activa detectada. Provant destrucció de totes..."
        "$SCRIPT_DIR/scripts/destroy.sh" all
    else
        "$SCRIPT_DIR/scripts/destroy.sh" "$active"
        rm -f "$SCRIPT_DIR/.lab-fase"
    fi
}

cmd_status() {
    local active
    active=$(get_active_fase)
    echo "=== Estat del laboratori BIND9 DNS ==="
    if [ -z "$active" ]; then
        echo "  Cap fase activa"
    else
        echo "  Fase activa: $active"
        local clab_name
        clab_name=$(get_clab_name "$active")
        echo ""
        echo "  Contenidors:"
        docker ps --filter "name=clab-${clab_name}" \
            --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
    fi
}

cmd_shell() {
    local node="${1:-dns1}"
    local active
    active=$(get_active_fase)
    if [ -z "$active" ]; then
        echo "Error: Cap fase activa"
        exit 1
    fi
    local clab_name
    clab_name=$(get_clab_name "$active")
    docker exec -it "clab-${clab_name}-${node}" bash 2>/dev/null || \
    docker exec -it "clab-${clab_name}-${node}" sh
}

cmd_logs() {
    local node="${1:-dns1}"
    local active
    active=$(get_active_fase)
    if [ -z "$active" ]; then
        echo "Error: Cap fase activa"
        exit 1
    fi
    local clab_name
    clab_name=$(get_clab_name "$active")
    echo "=== Query log de ${node} (Ctrl+C per sortir) ==="
    docker exec "clab-${clab_name}-${node}" tail -f /var/log/bind/query.log
}

cmd_errors() {
    local node="${1:-dns1}"
    local active
    active=$(get_active_fase)
    if [ -z "$active" ]; then
        echo "Error: Cap fase activa"
        exit 1
    fi
    local clab_name
    clab_name=$(get_clab_name "$active")
    echo "=== Error log de ${node} ==="
    docker exec "clab-${clab_name}-${node}" cat /var/log/bind/error.log 2>/dev/null || \
        echo "(fitxer buit o no trobat)"
}

# ── Punt d'entrada ────────────────────────────────────────────────────────────
case "${1:-}" in
    check)      cmd_check ;;
    build)      cmd_build ;;
    deploy)     cmd_deploy "${2:-}" ;;
    destroy)    cmd_destroy ;;
    status)     cmd_status ;;
    shell)      cmd_shell "${2:-}" ;;
    logs)       cmd_logs "${2:-}" ;;
    errors)     cmd_errors "${2:-}" ;;
    *)          usage ;;
esac
