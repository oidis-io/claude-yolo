#!/usr/bin/env bash
# * ********************************************************************************************************* *
# *
# * Copyright 2026 Oidis
# *
# * SPDX-License-Identifier: BSD-3-Clause
# * The BSD-3-Clause license for this file can be found in the LICENSE.txt file included with this distribution
# * or at https://spdx.org/licenses/BSD-3-Clause.html#licenseText
# *
# * ********************************************************************************************************* *

set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

IMAGE_REPO="claude-yolo"
GLOBAL_DIR="$SCRIPT_DIR/.claude-cache"
PROJECT_DIR="$(pwd)/.claude-cache"
REGISTRY_DIR="$HOME/.claude-yolo"
REGISTRY_FILE="$REGISTRY_DIR/registry.json"
PROJECT_CONFIG="$PROJECT_DIR/config.json"
SILENT=false

DEFAULT_BASE_IMAGE="ubuntu:24.04"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [-- CLAUDE_ARGS...]

COMMANDS:
  build [--force] [IMAGE]  Build Docker image (--force disables cache)
  list                     List all built images
  select <number|tag>      Select image for the current project
  remove <number|tag>      Remove image from registry and optionally from Docker
  login                    Authenticate via OAuth using local Claude CLI and save token
  status                   Show container status for the current directory
  logs                     Show logs of a running container (--silent mode)
  stop                     Stop the container for the current directory

OPTIONS:
  --silent        Run the container in the background (detached), no console
  --              Everything after this separator is passed directly to Claude

EXAMPLES:
  $(basename "$0")                                  Interactive session
  $(basename "$0") -- "Write tests"                 Give Claude a task
  $(basename "$0") --silent -- "Refactor"           Run in the background
  $(basename "$0") build                            Build default image (${DEFAULT_BASE_IMAGE})
  $(basename "$0") build oidis/builder:latest       Build with custom base image
  $(basename "$0") list                             Show all available images
  $(basename "$0") select 2                         Use image #2 for this project
  $(basename "$0") status                           Container status
  $(basename "$0") logs                             Follow background output
  $(basename "$0") stop                             Stop the container
EOF
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "❌ 'docker' is not installed."
        case "$(uname -s)" in
            Darwin)
                echo "   Install Docker Desktop: https://docs.docker.com/desktop/install/mac-install/" ;;
            Linux)
                echo "   Install Docker Engine:  https://docs.docker.com/engine/install/" ;;
            *)
                echo "   Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/" ;;
        esac
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "❌ Docker is installed but not reachable."
        echo ""
        case "$(uname -s)" in
            Darwin)
                echo "   Docker Desktop is probably not running."
                echo "   Open Docker Desktop from Applications or run: open -a Docker" ;;
            Linux)
                echo "   Possible causes:"
                echo "   1. Docker daemon is not running: sudo systemctl start docker"
                echo "   2. Permission denied — add your user to the docker group:"
                echo "      sudo usermod -aG docker \$USER && newgrp docker"
                echo "   3. Rootless Docker — make sure DOCKER_HOST is set:"
                echo "      export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock" ;;
            *)
                echo "   Docker Desktop is probably not running."
                echo "   Start Docker Desktop from the Start menu or system tray." ;;
        esac
        exit 1
    fi
}

require_jq() {
    if command -v jq >/dev/null 2>&1; then
        return
    fi
    echo "❌ 'jq' is required but not found."
    case "$(uname -s)" in
        Darwin)
            echo "   Install it: brew install jq" ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                echo "   Install it: sudo apt-get install jq"
            elif command -v dnf >/dev/null 2>&1; then
                echo "   Install it: sudo dnf install jq"
            elif command -v yum >/dev/null 2>&1; then
                echo "   Install it: sudo yum install jq"
            elif command -v pacman >/dev/null 2>&1; then
                echo "   Install it: sudo pacman -S jq"
            elif command -v apk >/dev/null 2>&1; then
                echo "   Install it: apk add jq"
            else
                echo "   Install it via your package manager"
            fi ;;
        *)
            echo "   Install it: https://jqlang.github.io/jq/download/" ;;
    esac
    exit 1
}

image_slug() {
    local base="${1:-}"
    if [[ -z "$base" || "$base" == "$DEFAULT_BASE_IMAGE" ]]; then
        echo "default"
        return
    fi
    local name="${base##*/}"
    name="${name%:latest}"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-60
}

image_tag() {
    echo "${IMAGE_REPO}:${1}"
}

registry_init() {
    mkdir -p "$REGISTRY_DIR"
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo '{"images":[]}' > "$REGISTRY_FILE"
    fi
}

REGISTRY_LOCK="$REGISTRY_DIR/.registry.lock"
LOCK_TIMEOUT=30
LOCK_INTERVAL=1

registry_lock() {
    local waited=0
    while ! mkdir "$REGISTRY_LOCK" 2>/dev/null; do
        if [[ $waited -ge $LOCK_TIMEOUT ]]; then
            echo "❌ Registry is locked by another process (timeout after ${LOCK_TIMEOUT}s)."
            echo "   Lock file: $REGISTRY_LOCK"
            echo "   If no other instance is running, remove it manually:"
            echo "   rm -rf $REGISTRY_LOCK"
            exit 1
        fi
        sleep "$LOCK_INTERVAL"
        waited=$((waited + LOCK_INTERVAL))
    done
}

registry_unlock() {
    rm -rf "$REGISTRY_LOCK"
}

registry_add() {
    local slug="$1"
    local base="$2"
    local built
    built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    registry_init
    registry_lock
    trap 'registry_unlock' EXIT
    local tmp
    tmp=$(jq --arg tag "$slug" --arg base "$base" --arg built "$built" --arg full "$(image_tag "$slug")" \
        '(.images | map(select(.tag != $tag))) as $filtered |
         .images = ($filtered + [{"tag": $tag, "base_image": $base, "full_tag": $full, "built_at": $built}])' \
        "$REGISTRY_FILE")
    echo "$tmp" > "$REGISTRY_FILE"
    registry_unlock
    trap - EXIT
}

resolve_image() {
    if [[ -f "$PROJECT_CONFIG" ]]; then
        local img
        img=$(jq -r '.image // empty' "$PROJECT_CONFIG" 2>/dev/null)
        if [[ -n "$img" ]]; then
            echo "$img"
            return
        fi
    fi
    echo "$(image_tag "default")"
}

require_image() {
    local img="$1"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        echo "❌ Docker image '${img}' does not exist. Build it first:"
        local base_hint=""
        if [[ -f "$REGISTRY_FILE" ]]; then
            local tag="${img#*:}"
            base_hint=$(jq -r --arg t "$tag" '.images[] | select(.tag == $t) | .base_image // empty' "$REGISTRY_FILE" 2>/dev/null)
        fi
        if [[ -n "$base_hint" && "$base_hint" != "$DEFAULT_BASE_IMAGE" ]]; then
            echo "   $(basename "$0") build $base_hint"
        elif [[ "$img" != "$(image_tag "default")" ]]; then
            echo "   $(basename "$0") build <base-image>"
        else
            echo "   $(basename "$0") build"
        fi
        exit 1
    fi
}

project_set_image() {
    local full_tag="$1"
    mkdir -p "$PROJECT_DIR"
    echo "{\"image\":\"$full_tag\"}" > "$PROJECT_CONFIG"
}

container_name() {
    local dir
    dir="$(pwd)"
    local hash
    hash="$(echo -n "$dir" | md5 -q 2>/dev/null || echo -n "$dir" | md5sum | cut -c1-8)"
    hash="${hash:0:8}"
    local slug
    slug="$(basename "$dir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-20)"
    echo "claude-yolo-${slug}-${hash}"
}

load_env() {
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi
}

TOKEN_FILE="$GLOBAL_DIR/.claude-oauth-token"

check_auth() {
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        return
    fi

    if [[ -f "$TOKEN_FILE" ]]; then
        CLAUDE_CODE_OAUTH_TOKEN="$(cat "$TOKEN_FILE")"
        export CLAUDE_CODE_OAUTH_TOKEN
        return
    fi

    if [[ "$SILENT" == true ]]; then
        echo "❌ --silent requires authentication"
        echo "   Set ANTHROPIC_API_KEY in $SCRIPT_DIR/.env or run: $(basename "$0") login"
        exit 1
    fi

    echo "❌ No authentication found."
    echo "   Run '$(basename "$0") login' first to set up OAuth token."
    exit 1
}

cmd_login() {
    if ! command -v claude >/dev/null 2>&1; then
        echo "❌ 'claude' CLI not found on this machine."
        echo "   Install it first: npm install -g @anthropic-ai/claude-code"
        exit 1
    fi

    mkdir -p "$GLOBAL_DIR"
    echo "🔑 Starting OAuth login via local Claude CLI..."
    echo ""

    local tmpfile
    tmpfile="$(mktemp)"
    trap 'rm -f "$tmpfile"' EXIT

    script -q "$tmpfile" claude setup-token

    local token
    token="$(grep -oE 'sk-ant-[A-Za-z0-9_-]+' "$tmpfile" | head -1)"
    rm -f "$tmpfile"

    if [[ -z "$token" ]]; then
        echo "❌ Failed to capture token from output."
        echo "   Run 'claude setup-token' manually and save the token to: $TOKEN_FILE"
        exit 1
    fi

    echo "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo ""
    echo "✅ Token saved to $TOKEN_FILE"
}

build() {
    local base_image=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            *)       base_image="$1"; shift ;;
        esac
    done

    local slug
    slug="$(image_slug "$base_image")"
    local full_tag
    full_tag="$(image_tag "$slug")"
    local actual_base="${base_image:-$DEFAULT_BASE_IMAGE}"

    local build_args=()
    if [[ -n "$base_image" ]]; then
        build_args+=(--build-arg "BASE_IMAGE=$base_image")
    fi
    echo "🔨 Building ${full_tag} (base: ${actual_base})..."
    if [[ "$force" == true ]]; then
        build_args+=(--no-cache)
        echo "   (no-cache)"
    fi
    docker build "${build_args[@]+"${build_args[@]}"}" -t "$full_tag" "$SCRIPT_DIR"
    registry_add "$slug" "$actual_base"
    echo "✅ Image built and registered: ${full_tag}"
}

cmd_list() {
    registry_init
    local count
    count=$(jq '.images | length' "$REGISTRY_FILE")

    if [[ "$count" -eq 0 ]]; then
        echo "No images built yet. Run '$(basename "$0") build' first."
        return
    fi

    local -a stale=()
    local i
    for i in $(seq 0 $((count - 1))); do
        local ft
        ft="$(jq -r ".images[$i].full_tag" "$REGISTRY_FILE")"
        if ! docker image inspect "$ft" >/dev/null 2>&1; then
            stale+=("$(jq -r ".images[$i].tag" "$REGISTRY_FILE")")
        fi
    done

    if [[ ${#stale[@]} -gt 0 ]]; then
        registry_lock
        trap 'registry_unlock' EXIT
        local tmp
        for tag in "${stale[@]}"; do
            tmp=$(jq --arg t "$tag" '.images = [.images[] | select(.tag != $t)]' "$REGISTRY_FILE")
            echo "$tmp" > "$REGISTRY_FILE"
            echo "  🗑  Removed stale entry: $tag (Docker image no longer exists)"
        done
        registry_unlock
        trap - EXIT
        count=$(jq '.images | length' "$REGISTRY_FILE")
        if [[ "$count" -eq 0 ]]; then
            echo ""
            echo "No images left. Run '$(basename "$0") build' first."
            return
        fi
        echo ""
    fi

    local current=""
    if [[ -f "$PROJECT_CONFIG" ]]; then
        current=$(jq -r '.image // empty' "$PROJECT_CONFIG" 2>/dev/null)
    fi

    local -a tags=() bases=() builts=() full_tags=()
    local max_tag=3 max_base=10
    for i in $(seq 0 $((count - 1))); do
        local t b
        t="$(jq -r ".images[$i].tag" "$REGISTRY_FILE")"
        b="$(jq -r ".images[$i].base_image" "$REGISTRY_FILE")"
        tags+=("$t")
        bases+=("$b")
        builts+=("$(jq -r ".images[$i].built_at" "$REGISTRY_FILE" | sed 's/T/ /; s/Z//')")
        full_tags+=("$(jq -r ".images[$i].full_tag" "$REGISTRY_FILE")")
        (( ${#t} > max_tag )) && max_tag=${#t}
        (( ${#b} > max_base )) && max_base=${#b}
    done

    printf "  %-2s%-4s  %-${max_tag}s  %-${max_base}s  %s\n" " " "#" "TAG" "BASE IMAGE" "BUILT"
    printf "  %-2s%-4s  %-${max_tag}s  %-${max_base}s  %s\n" " " "---" "$(printf '%*s' "$max_tag" '' | tr ' ' '─')" "$(printf '%*s' "$max_base" '' | tr ' ' '─')" "───────────────────"

    for i in $(seq 0 $((count - 1))); do
        local prefix=" "
        if [[ "${full_tags[$i]}" == "$current" ]]; then
            prefix="*"
        fi
        printf "  %-2s%-4s  %-${max_tag}s  %-${max_base}s  %s\n" "$prefix" "$((i + 1))" "${tags[$i]}" "${bases[$i]}" "${builts[$i]}"
    done

    echo ""
    if [[ -n "$current" ]]; then
        echo "  * = current project image"
    else
        echo "  No image selected for this project (will use claude-yolo:default)"
    fi
}

cmd_select() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $(basename "$0") select <number|tag>"
        echo "   Run '$(basename "$0") list' to see available images."
        exit 1
    fi

    registry_init
    local selector="$1"
    local full_tag=""
    local tag=""

    local base_image=""

    if [[ "$selector" =~ ^[0-9]+$ ]]; then
        local count
        count=$(jq '.images | length' "$REGISTRY_FILE")
        local idx=$((selector - 1))
        if [[ $idx -lt 0 || $idx -ge $count ]]; then
            echo "❌ Invalid number: $selector (have $count images)"
            exit 1
        fi
        full_tag=$(jq -r ".images[$idx].full_tag" "$REGISTRY_FILE")
        tag=$(jq -r ".images[$idx].tag" "$REGISTRY_FILE")
        base_image=$(jq -r ".images[$idx].base_image" "$REGISTRY_FILE")
    else
        local match
        match=$(jq -r --arg t "$selector" '.images[] | select(.tag == $t) | .full_tag' "$REGISTRY_FILE")
        if [[ -z "$match" ]]; then
            echo "❌ No image with tag '$selector' found."
            echo "   Run '$(basename "$0") list' to see available images."
            exit 1
        fi
        full_tag="$match"
        tag="$selector"
        base_image=$(jq -r --arg t "$selector" '.images[] | select(.tag == $t) | .base_image' "$REGISTRY_FILE")
    fi

    require_image "$full_tag"

    project_set_image "$full_tag"
    echo "✅ Project now uses: ${full_tag} (base: ${base_image})"
}

cmd_remove() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $(basename "$0") remove <number|tag>"
        echo "   Run '$(basename "$0") list' to see available images."
        exit 1
    fi

    registry_init
    local selector="$1"
    local full_tag=""
    local tag=""

    if [[ "$selector" =~ ^[0-9]+$ ]]; then
        local count
        count=$(jq '.images | length' "$REGISTRY_FILE")
        local idx=$((selector - 1))
        if [[ $idx -lt 0 || $idx -ge $count ]]; then
            echo "❌ Invalid number: $selector (have $count images)"
            exit 1
        fi
        full_tag=$(jq -r ".images[$idx].full_tag" "$REGISTRY_FILE")
        tag=$(jq -r ".images[$idx].tag" "$REGISTRY_FILE")
    else
        local match
        match=$(jq -r --arg t "$selector" '.images[] | select(.tag == $t) | .full_tag' "$REGISTRY_FILE")
        if [[ -z "$match" ]]; then
            echo "❌ No image with tag '$selector' found."
            echo "   Run '$(basename "$0") list' to see available images."
            exit 1
        fi
        full_tag="$match"
        tag="$selector"
    fi

    registry_lock
    trap 'registry_unlock' EXIT
    local tmp
    tmp=$(jq --arg t "$tag" '.images = [.images[] | select(.tag != $t)]' "$REGISTRY_FILE")
    echo "$tmp" > "$REGISTRY_FILE"
    registry_unlock
    trap - EXIT
    echo "✅ Removed '${tag}' from registry"

    if docker image inspect "$full_tag" >/dev/null 2>&1; then
        echo -n "   Docker image ${full_tag} exists. Remove it too? [y/N] "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            docker rmi "$full_tag"
            echo "✅ Docker image removed"
        fi
    fi
}

cmd_status() {
    local name
    name="$(container_name)"
    local dir
    dir="$(pwd)"
    local img
    img="$(resolve_image)"

    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        local started
        started="$(docker inspect --format '{{.State.StartedAt}}' "$name" 2>/dev/null | cut -c1-19 | tr 'T' ' ')"
        echo "✅ Container is running"
        echo "   Directory: $dir"
        echo "   Name:      $name"
        echo "   Image:     $img"
        echo "   Started:   $started"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        local status
        status="$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)"
        echo "⚠️  Container exists but is not running (status: $status)"
        echo "   Directory: $dir"
        echo "   Name:      $name"
        echo "   Image:     $img"
    else
        echo "💤 No container for this directory"
        echo "   Directory: $dir"
        echo "   Image:     $img"
    fi
}

cmd_logs() {
    local name
    name="$(container_name)"
    if ! docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo "❌ No container is running for this directory"
        cmd_status
        exit 1
    fi
    echo "📋 Logs for container ${name} (Ctrl+C to quit):"
    docker logs -f "$name"
}

cmd_stop() {
    local name
    name="$(container_name)"
    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo "🛑 Stopping container ${name}..."
        docker stop "$name"
        echo "✅ Stopped"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        echo "🗑  Removing stopped container ${name}..."
        docker rm "$name"
        echo "✅ Removed"
    else
        echo "💤 No container for this directory"
    fi
}

run() {
    local name
    name="$(container_name)"
    local claude_args=("$@")

    if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
        echo "⚠️  A container is already running for this directory: ${name}"
        echo "   Use '$(basename "$0") status' or '$(basename "$0") stop'"
        exit 1
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^${name}$"; then
        docker rm "$name" >/dev/null
    fi

    local img
    img="$(resolve_image)"

    require_image "$img"

    if [[ ! -f "$PROJECT_CONFIG" ]]; then
        project_set_image "$img"
    fi

    mkdir -p "$PROJECT_DIR"
    [[ -s "$PROJECT_DIR/.claude.json" ]] || echo '{}' > "$PROJECT_DIR/.claude.json"

    local base_args=(
        --name "$name"
        -v "$(pwd):/workspace"
        -v "${PROJECT_DIR}:/root/.claude"
        -v "${PROJECT_DIR}/.claude.json:/root/.claude.json"
        -w /workspace
    )

    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        base_args+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        base_args+=(-e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN")
    fi

    if [[ "$SILENT" == true ]]; then
        echo "🚀 Starting in the background..."
        echo "   Directory: $(pwd)"
        echo "   Name:      ${name}"
        echo "   Image:     ${img}"
        docker run -d \
            "${base_args[@]}" \
            "$img" \
            "${claude_args[@]+"${claude_args[@]}"}"
        echo ""
        echo "📋 Follow output: $(basename "$0") logs"
        echo "🛑 Stop:          $(basename "$0") stop"
        echo "📊 Status:        $(basename "$0") status"
    else
        docker run -it --rm \
            "${base_args[@]}" \
            "$img" \
            "${claude_args[@]+"${claude_args[@]}"}"
    fi
}

main() {
    if [[ "${1:-}" =~ ^(help|-h|--help)$ ]]; then
        usage
        return
    fi

    require_jq
    require_docker

    local claude_args=()

    if [[ $# -eq 0 ]]; then
        load_env
        check_auth
        run
        return
    fi

    local -a KNOWN_COMMANDS=(build list select remove login status logs stop)

    case "$1" in
        build)   shift; registry_init; build "$@"; return ;;
        list)    cmd_list; return ;;
        select)  shift; cmd_select "$@"; return ;;
        remove)  shift; cmd_remove "$@"; return ;;
        login)   cmd_login; return ;;
        status)  cmd_status; return ;;
        logs)    cmd_logs; return ;;
        stop)    cmd_stop; return ;;
    esac

    if [[ "$1" != "--"* ]]; then
        local input="$1"
        local best=""
        for cmd in "${KNOWN_COMMANDS[@]}"; do
            if [[ "$cmd" == "$input"* || "$input" == "$cmd"* ]]; then
                best="$cmd"
                break
            fi
        done
        if [[ -n "$best" ]]; then
            echo "❌ Unknown command: $input"
            echo "   Did you mean: $(basename "$0") $best"
        else
            echo "❌ Unknown command: $input"
            echo "   Run '$(basename "$0") help' to see available commands."
        fi
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --silent) SILENT=true; shift ;;
            --)       shift; claude_args=("$@"); break ;;
            *)        echo "❌ Unknown option: $1"; echo "   Run '$(basename "$0") help' for usage."; exit 1 ;;
        esac
    done

    load_env
    check_auth
    run "${claude_args[@]+"${claude_args[@]}"}"
}

main "$@"
