#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="claude-sandbox"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="$HOME/.claude/docker-sessions"
DOCKERFILE_HASH_FILE="$HOME/.claude/docker-image-hash"

# --- Usage ---
usage() {
    cat <<'EOF'
Usage: claude.sh [OPTIONS] [FOLDERS...] [-- CLAUDE_ARGS...]

Options:
  --memory SIZE    Set container memory limit (e.g. 8g, 4096m)
  --gpu            Enable GPU passthrough (--gpus all)
  --no-network     Disable network access inside the container
  --worktree NAME  Run in a git worktree (isolated branch + working dir)
  --worktree-base DIR  Base directory for worktrees (default: parent of project)
  --sessions       List and manage saved sessions
  --rebuild        Force rebuild the Docker image
  -h, --help       Show this help message

Examples:
  ./claude.sh                              # Current dir, default settings
  ./claude.sh --memory 8g /path/to/project
  ./claude.sh --gpu --memory 16g .
  ./claude.sh --no-network .               # Fully offline/sandboxed
  ./claude.sh --worktree feature-auth      # Isolated worktree session
  ./claude.sh --sessions                   # Manage saved sessions
  ./claude.sh /path/to/project -- -p "fix the tests"
EOF
    exit 0
}

# --- Session management subcommand ---
manage_sessions() {
    mkdir -p "$SESSION_DIR"
    files=("$SESSION_DIR"/*)
    if [ ! -e "${files[0]}" ]; then
        echo "No saved sessions."
        exit 0
    fi

    echo "Saved sessions:"
    echo ""
    i=1
    session_files=()
    for f in "$SESSION_DIR"/*; do
        [ -f "$f" ] || continue
        session_id=$(cat "$f")
        # Try to find the directory from the hash by checking the session metadata
        # We store hash -> session_id, but not the reverse. Show the hash + session_id + age.
        age=$(( ( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) ) ))
        if [ "$age" -lt 3600 ]; then
            age_str="$(( age / 60 ))m ago"
        elif [ "$age" -lt 86400 ]; then
            age_str="$(( age / 3600 ))h ago"
        else
            age_str="$(( age / 86400 ))d ago"
        fi
        echo "  $i) $session_id  ($age_str)"
        session_files+=("$f")
        i=$((i + 1))
    done

    echo ""
    echo -n "Delete sessions? [enter numbers, 'all', or empty to cancel] "
    read -r choice </dev/tty || choice=""

    if [ -z "$choice" ]; then
        echo "Cancelled."
        exit 0
    fi

    if [ "$choice" = "all" ]; then
        rm -f "$SESSION_DIR"/*
        echo "All sessions deleted."
        exit 0
    fi

    for num in $choice; do
        idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#session_files[@]}" ]; then
            rm -f "${session_files[$idx]}"
            echo "Deleted session $num."
        fi
    done
    exit 0
}

# --- Parse script-level flags (before folders and --) ---
memory_limit=""
gpu_flag=false
no_network=false
force_rebuild=false
worktree_name=""
worktree_base=""
positional=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --sessions)
            manage_sessions
            ;;
        --memory)
            memory_limit="$2"
            shift 2
            ;;
        --gpu)
            gpu_flag=true
            shift
            ;;
        --no-network)
            no_network=true
            shift
            ;;
        --worktree)
            worktree_name="${2:-}"
            if [ -n "$worktree_name" ] && [[ "$worktree_name" != --* ]]; then
                shift 2
            else
                # --worktree without a name: auto-generate one
                worktree_name="__auto__"
                shift
            fi
            ;;
        --worktree-base)
            worktree_base="$2"
            shift 2
            ;;
        --rebuild)
            force_rebuild=true
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done
set -- "${positional[@]+"${positional[@]}"}"

# --- Separate folder arguments from claude arguments (split on --) ---
folders=()
claude_args=()
past_separator=false

for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        past_separator=true
        continue
    fi
    if $past_separator; then
        claude_args+=("$arg")
    else
        folders+=("$arg")
    fi
done

# Default to current directory if no folders specified
if [ ${#folders[@]} -eq 0 ]; then
    folders=("$(pwd)")
fi

# --- Auto-rebuild stale image ---
current_hash=$(shasum "$SCRIPT_DIR/Dockerfile" | cut -d' ' -f1)
needs_build=false

if $force_rebuild; then
    needs_build=true
elif ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    needs_build=true
elif [ -f "$DOCKERFILE_HASH_FILE" ]; then
    saved_hash=$(cat "$DOCKERFILE_HASH_FILE")
    if [ "$current_hash" != "$saved_hash" ]; then
        echo "Dockerfile changed since last build. Rebuilding..."
        needs_build=true
    fi
else
    # Image exists but no hash saved — save current hash, skip rebuild
    echo "$current_hash" > "$DOCKERFILE_HASH_FILE"
fi

if $needs_build; then
    echo "Building image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
    echo "$current_hash" > "$DOCKERFILE_HASH_FILE"
fi

# --- Build mount arguments ---
mount_args=()
workdir="/workspace"
if [ ${#folders[@]} -eq 1 ]; then
    folder="$(cd "${folders[0]}" && pwd)"
    mount_args+=(-v "$folder:/workspace")
else
    for folder in "${folders[@]}"; do
        abs="$(cd "$folder" && pwd)"
        base="$(basename "$abs")"
        mount_args+=(-v "$abs:/workspace/$base")
    done
    first_abs="$(cd "${folders[0]}" && pwd)"
    workdir="/workspace/$(basename "$first_abs")"
fi

# --- Shared drop folder for images/files ---
DROPS_DIR="$HOME/claude-drops"
if [ -d "$DROPS_DIR" ]; then
    mount_args+=(-v "$DROPS_DIR:$DROPS_DIR:ro")
fi

# --- Environment ---
env_args=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    env_args+=(-e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY")
fi

mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"
mkdir -p "$SESSION_DIR"

# --- Auto-resume: check for a saved session for this directory ---
abs_workdir="$(cd "${folders[0]}" && pwd)"
session_hash=$(echo -n "$abs_workdir" | shasum | cut -d' ' -f1)
session_file="$SESSION_DIR/$session_hash"

# --- Worktree: create a real git worktree and mount it instead ---
if [ -n "$worktree_name" ]; then
    repo_dir="$(cd "${folders[0]}" && pwd)"

    if [ "$worktree_name" = "__auto__" ]; then
        worktree_name="claude-$(date +%Y%m%d-%H%M%S)"
    fi

    repo_basename=$(basename "$repo_dir")
    if [ -n "$worktree_base" ]; then
        mkdir -p "$worktree_base"
        wt_path="$(cd "$worktree_base" && pwd)/${repo_basename}--${worktree_name}"
    else
        wt_path="$(cd "$repo_dir/.." && pwd)/${repo_basename}--${worktree_name}"
    fi

    if [ ! -d "$wt_path" ]; then
        echo "Creating git worktree: $wt_path (branch: $worktree_name)"
        git -C "$repo_dir" worktree add "$wt_path" -b "$worktree_name"
    else
        echo "Using existing worktree: $wt_path"
    fi

    # Replace the folder with the worktree path
    folders=("$wt_path")
    abs_workdir="$wt_path"

    # Mount worktree and main repo as siblings under /projects/
    # so relative .git paths (e.g. submodules) resolve correctly.
    # Main repo is read-only to prevent accidental modifications.
    wt_basename="$(basename "$wt_path")"
    main_repo_basename="$(basename "$repo_dir")"
    mount_args=(
        -v "$wt_path:/projects/$wt_basename"
        -v "$repo_dir:/projects/$main_repo_basename:ro"
        -v "$repo_dir/.git:/projects/$main_repo_basename/.git"
    )
    workdir="/projects/$wt_basename"

    # Recalculate session hash for the worktree path
    session_hash=$(echo -n "$abs_workdir" | shasum | cut -d' ' -f1)
    session_file="$SESSION_DIR/$session_hash"
fi

# --- Run post-worktree hook if it exists ---
if [ -n "$worktree_name" ]; then
    hook="$wt_path/.claude-docker/post-worktree.sh"
    if [ -x "$hook" ]; then
        echo ""
        echo -e "\033[1;33m=========================================\033[0m"
        echo -e "\033[1;33m  POST-WORKTREE HOOK DETECTED\033[0m"
        echo -e "\033[1;33m=========================================\033[0m"
        echo -e "  File: \033[36m$hook\033[0m"
        echo ""
        echo -e "\033[90m--- Contents: ---\033[0m"
        echo -e "\033[37m$(cat "$hook")\033[0m"
        echo -e "\033[90m-----------------\033[0m"
        echo ""
        echo -e "\033[1;31m⚠  This script will run on your HOST machine\033[0m"
        echo -e "\033[1;31m   with your user's full permissions.\033[0m"
        echo ""
        echo -en "Run this hook? [\033[1my\033[0m/\033[1mN\033[0m] "
        read -r run_hook </dev/tty || run_hook=""
        if [ "$run_hook" = "y" ] || [ "$run_hook" = "Y" ]; then
            echo "Running post-worktree hook..."
            (cd "$wt_path" && bash "$hook")
        else
            echo "Skipping post-worktree hook."
        fi
    fi
fi

if [ ${#claude_args[@]} -eq 0 ] && [ -f "$session_file" ]; then
    saved_session=$(cat "$session_file")
    echo "Found previous session for $abs_workdir"
    echo "Session: $saved_session"
    echo -n "Resume? [Y/n] "
    read -r answer </dev/tty || answer=""
    if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
        claude_args=("--resume" "$saved_session")
    fi
fi

# --- Build docker run flags ---
run_args=(-it)

# Memory limit
if [ -n "$memory_limit" ]; then
    run_args+=(--memory "$memory_limit")
fi

# GPU passthrough
if $gpu_flag; then
    run_args+=(--gpus all)
fi

# Network isolation
if $no_network; then
    run_args+=(--network none)
fi

# Container name based on directory
dir_basename=$(basename "$abs_workdir" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g')
CONTAINER_NAME="claude-${dir_basename}-$$"

# --- Print session info ---
echo ""
echo -e "\033[1;34m=========================================\033[0m"
echo -e "\033[1;34m  CLAUDE DOCKER\033[0m"
echo -e "\033[1;34m=========================================\033[0m"
echo -e "  Container: \033[36m$CONTAINER_NAME\033[0m"
echo -e "  Image:     \033[36m$IMAGE_NAME\033[0m"
echo -e "  Workdir:   \033[36m$workdir\033[0m"
if [ -n "$worktree_name" ]; then
echo -e "  Worktree:  \033[33m$worktree_name\033[0m"
echo -e "  Host path: \033[33m$wt_path\033[0m"
fi
if [ -n "$memory_limit" ]; then
echo -e "  Memory:    \033[36m$memory_limit\033[0m"
fi
if $gpu_flag; then
echo -e "  GPU:       \033[32menabled\033[0m"
fi
if $no_network; then
echo -e "  Network:   \033[31mdisabled\033[0m"
fi
echo -e "\033[1;34m=========================================\033[0m"
echo ""

# --- Run ---
docker run \
    "${run_args[@]}" \
    --name "$CONTAINER_NAME" \
    -w "$workdir" \
    --tmpfs /tmp:size=2G \
    -e TERM="$TERM" \
    ${env_args[@]+"${env_args[@]}"} \
    -v "$HOME/.claude:/home/node/.claude" \
    -v "$HOME/.claude.json:/home/node/.claude.json" \
    "${mount_args[@]}" \
    "$IMAGE_NAME" \
    ${claude_args[@]+"${claude_args[@]}"}

EXIT_CODE=$?

# --- Post-mortem: check why the container exited ---
if docker inspect "$CONTAINER_NAME" &>/dev/null; then
    OOM=$(docker inspect --format='{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    REAL_EXIT=$(docker inspect --format='{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")

    if [ "$OOM" = "true" ]; then
        echo ""
        echo "========================================="
        echo " CONTAINER WAS OOM-KILLED"
        echo " Docker ran out of memory."
        if [ -n "$memory_limit" ]; then
            echo " Current limit: $memory_limit"
            echo " Try a higher --memory value."
        else
            echo " Try: ./claude.sh --memory 8g"
            echo " Or increase in Docker Desktop settings"
            echo " (Settings > Resources > Memory)"
        fi
        echo "========================================="
    elif [ "$REAL_EXIT" != "0" ] && [ "$REAL_EXIT" != "unknown" ]; then
        echo ""
        echo "Container exited with code: $REAL_EXIT"
    fi

    # --- Extract session ID from container logs ---
    SESSION_ID=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -oE 'claude --resume [a-f0-9-]+' | tail -1 | awk '{print $3}' || true)
    if [ -n "$SESSION_ID" ]; then
        echo "$SESSION_ID" > "$session_file"
        echo "Session saved for $abs_workdir — will auto-resume next time."
    fi

    # Clean up container
    docker rm "$CONTAINER_NAME" &>/dev/null || true
fi

exit "$EXIT_CODE"
