#!/usr/bin/env bash
#
# start-daemon.sh - Start all DeerFlow development services in daemon mode
#
# This script starts DeerFlow services in the background without keeping
# the terminal connection. Logs are written to separate files.
#
# Must be run from the repo root directory.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Stop existing services ────────────────────────────────────────────────────

echo "Stopping existing services if any..."
pkill -f "langgraph dev" 2>/dev/null || true
pkill -f "uvicorn app.gateway.app:app" 2>/dev/null || true
pkill -f "next dev" 2>/dev/null || true
nginx -c "$REPO_ROOT/docker/nginx/nginx.local.conf" -p "$REPO_ROOT" -s quit 2>/dev/null || true
sleep 1
pkill -9 nginx 2>/dev/null || true
./scripts/cleanup-containers.sh deer-flow-sandbox 2>/dev/null || true
sleep 1

# ── Banner ────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo " Starting DeerFlow in Daemon Mode"
echo "=========================================="
echo ""

# ── Config check ─────────────────────────────────────────────────────────────

if ! { \
        [ -n "$DEER_FLOW_CONFIG_PATH" ] && [ -f "$DEER_FLOW_CONFIG_PATH" ] || \
        [ -f backend/config.yaml ] || \
        [ -f config.yaml ]; \
    }; then
    echo "✗ No DeerFlow config file found."
    echo "  Checked these locations:"
    echo "    - $DEER_FLOW_CONFIG_PATH (when DEER_FLOW_CONFIG_PATH is set)"
    echo "    - backend/config.yaml"
    echo "    - ./config.yaml"
    echo ""
    echo "  Run 'make config' from the repo root to generate ./config.yaml, then set required model API keys in .env or your config file."
    exit 1
fi

# ── Auto-upgrade config ──────────────────────────────────────────────────

"$REPO_ROOT/scripts/config-upgrade.sh"

# ── Cleanup on failure ───────────────────────────────────────────────────────

cleanup_on_failure() {
    echo "Failed to start services, cleaning up..."
    pkill -f "langgraph dev" 2>/dev/null || true
    pkill -f "uvicorn app.gateway.app:app" 2>/dev/null || true
    pkill -f "next dev" 2>/dev/null || true
    nginx -c "$REPO_ROOT/docker/nginx/nginx.local.conf" -p "$REPO_ROOT" -s quit 2>/dev/null || true
    sleep 1
    pkill -9 nginx 2>/dev/null || true
    echo "✓ Cleanup complete"
}

trap cleanup_on_failure INT TERM

is_port_listening() {
    local port="${1:?port is required}"

    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$port )" 2>/dev/null | tail -n +2 | grep -q .; then
            return 0
        fi
    fi

    if command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${port}$"; then
            return 0
        fi
    fi

    return 1
}

ensure_port_free() {
    local port="${1:?port is required}"
    local service="${2:-Service}"

    if ! is_port_listening "$port"; then
        return 0
    fi

    echo "✗ $service cannot start because port $port is already in use."
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN || true
    fi
    echo "  Stop the existing process on port $port, then retry."
    return 1
}

# ── Start services ────────────────────────────────────────────────────────────

mkdir -p logs

ensure_port_free 2024 "LangGraph" || exit 1
ensure_port_free 8001 "Gateway API" || exit 1
ensure_port_free 3000 "Frontend" || exit 1
ensure_port_free 2026 "Nginx" || exit 1

if [ ! -x "$REPO_ROOT/frontend/node_modules/.bin/next" ]; then
    echo "✗ Frontend dependencies are not installed."
    echo "  Run 'make install' or 'cd frontend && pnpm install', then retry."
    exit 1
fi

echo "Starting LangGraph server..."
nohup sh -c 'cd backend && NO_COLOR=1 uv run langgraph dev --no-browser --allow-blocking --no-reload > ../logs/langgraph.log 2>&1' &
./scripts/wait-for-port.sh 2024 60 "LangGraph" || {
    echo "✗ LangGraph failed to start. Last log output:"
    tail -60 logs/langgraph.log
    if grep -qE "config_version|outdated|Environment variable .* not found|KeyError|ValidationError|config\.yaml" logs/langgraph.log 2>/dev/null; then
        echo ""
        echo "  Hint: This may be a configuration issue. Try running 'make config-upgrade' to update your config.yaml."
    fi
    cleanup_on_failure
    exit 1
}
echo "✓ LangGraph server started on localhost:2024"

echo "Starting Gateway API..."
nohup sh -c 'cd backend && PYTHONPATH=. uv run uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001 > ../logs/gateway.log 2>&1' &
./scripts/wait-for-port.sh 8001 30 "Gateway API" || {
    echo "✗ Gateway API failed to start. Last log output:"
    tail -60 logs/gateway.log
    echo ""
    echo "  Hint: Try running 'make config-upgrade' to update your config.yaml with the latest fields."
    cleanup_on_failure
    exit 1
}
echo "✓ Gateway API started on localhost:8001"

echo "Starting Frontend..."
nohup sh -c 'cd frontend && pnpm exec next dev --turbo --hostname 127.0.0.1 > ../logs/frontend.log 2>&1' &
./scripts/wait-for-port.sh 3000 120 "Frontend" || {
    echo "✗ Frontend failed to start. Last log output:"
    tail -60 logs/frontend.log
    cleanup_on_failure
    exit 1
}
echo "✓ Frontend started on localhost:3000"

echo "Starting Nginx reverse proxy..."
nohup sh -c 'nginx -g "daemon off;" -c "$1/docker/nginx/nginx.local.conf" -p "$1" > logs/nginx.log 2>&1' _ "$REPO_ROOT" &
./scripts/wait-for-port.sh 2026 10 "Nginx" || {
    echo "✗ Nginx failed to start. Last log output:"
    tail -60 logs/nginx.log
    cleanup_on_failure
    exit 1
}
echo "✓ Nginx started on localhost:2026"

# ── Ready ─────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo " DeerFlow is running in daemon mode!"
echo "=========================================="
echo ""
echo " 🌐 Application: http://localhost:2026"
echo " 📡 API Gateway: http://localhost:2026/api/*"
echo " 🤖 LangGraph: http://localhost:2026/api/langgraph/*"
echo ""
echo " 📋 Logs:"
echo " - LangGraph: logs/langgraph.log"
echo " - Gateway: logs/gateway.log"
echo " - Frontend: logs/frontend.log"
echo " - Nginx: logs/nginx.log"
echo ""
echo " 🛑 Stop daemon: make stop"
echo ""
