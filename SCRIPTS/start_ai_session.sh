#!/bin/bash
# =============================================================================
# start_ai_session.sh — bring up Ollama + VS Code inside an allocated session
#
# Run this first thing in every new virtual desktop session on a GPU node.
# Idempotent: if Ollama is already serving, it is left alone.
#
#   start_ai_session.sh                     default model from config.yaml
#   start_ai_session.sh qwen2.5-coder:32b   a specific model
#   start_ai_session.sh --no-code           Ollama only, no editor
#   start_ai_session.sh --status            report and exit
#
# All settings come from ../config.yaml. Any OLLAMA_* variable already set in
# the environment overrides the config, so one-off changes work:
#   OLLAMA_KEEP_ALIVE=5m start_ai_session.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "${SCRIPT_DIR}/lib_config.sh" || { echo "cannot source lib_config.sh" >&2; exit 1; }

aa_init "${SCRIPT_DIR}" || exit 1

MODEL="$(aa_cfg default_model 'qwen3-coder:latest')"
LAUNCH_CODE=true
aa_is_true "$(aa_cfg launch_vscode true)" || LAUNCH_CODE=false
STATUS_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-code) LAUNCH_CODE=false; shift ;;
        --status)  STATUS_ONLY=true; shift ;;
        -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
        -*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)         MODEL="$1"; shift ;;
    esac
done

PROJECT_ROOT="$(aa_cfg project_root "/work/${USER}")"
VSCODE_BIN="$(aa_cfg vscode_dir "${HOME}/VSCode-linux-x64")/bin/code"
OLLAMA_MODULE="$(aa_cfg ollama_module ollama)"
SCREEN_NAME="$(aa_cfg screen_session ollama)"
TIMEOUT="$(aa_cfg startup_timeout 30)"
OLLAMA_URL="$(aa_ollama_url)"

aa_export_ollama_env

# -----------------------------------------------------------------------------
say "Session"
printf '  config:    %s\n' "${AA_CONFIG_FILE}"
printf '  node:      %s\n' "$(hostname)"
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
    printf '  job:       %s   partition %s\n' \
        "${SLURM_JOB_ID}" "${SLURM_JOB_PARTITION:-?}"
    remaining="$(squeue -h -j "${SLURM_JOB_ID}" -o '%L' 2>/dev/null)"
    [[ -n "${remaining}" ]] && printf '  walltime:  %s remaining\n' "${remaining}"
else
    warn "no SLURM_JOB_ID — are you inside an allocation?"
fi

gpus="$(nvidia-smi --query-gpu=index,name,memory.used,memory.total \
        --format=csv,noheader 2>/dev/null)"
if [[ -n "${gpus}" ]]; then
    while IFS= read -r line; do printf '  gpu:       %s\n' "${line}"; done <<< "${gpus}"
else
    bad "nvidia-smi returned nothing — no GPU in this allocation"
    warn "relaunch the session on a GPU partition"
fi

# -----------------------------------------------------------------------------
say "Ollama"
if aa_ollama_serving; then
    ok "already serving at ${OLLAMA_URL}"
elif [[ "${STATUS_ONLY}" == true ]]; then
    warn "not running"
else
    module load "${OLLAMA_MODULE}" 2>/dev/null || warn "module load ${OLLAMA_MODULE} failed"

    if [[ -z "${OLLAMA_MODELS:-}" ]]; then
        warn "OLLAMA_MODELS is unset — the module normally sets it"
        warn "without it the server falls back to ~/.ollama and will report zero models"
    else
        printf '  models:    %s\n' "${OLLAMA_MODELS}"
    fi

    # A screen session starts a fresh shell and inherits nothing, which is why
    # the module load is repeated and the environment is passed in explicitly.
    # Skipping the module load inside screen is the classic cause of a server
    # that starts fine and reports {"models":[]}.
    env_exports=''
    for entry in "${AA_OLLAMA_EXPORTED[@]}"; do
        entry="${entry%% (from environment)}"
        env_exports+="export ${entry%%=*}='${entry#*=}'"$'\n'
    done

    screen -dmS "${SCREEN_NAME}" bash -lc "
        module load ${OLLAMA_MODULE}
        ${env_exports}
        exec ollama serve
    "

    printf '  waiting for server '
    for _ in $(seq 1 "${TIMEOUT}"); do
        sleep 1
        printf '.'
        aa_ollama_serving && break
    done
    printf '\n'

    if aa_ollama_serving; then
        ok "started (screen session '${SCREEN_NAME}')"
    else
        bad "server did not come up within ${TIMEOUT}s"
        bad "look at the log with: screen -r ${SCREEN_NAME}"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
if aa_ollama_serving; then
    n="$(curl -s --max-time 5 "${OLLAMA_URL}/api/tags" | grep -o '"name"' | wc -l)"
    if [[ "${n}" -gt 0 ]]; then
        ok "${n} models visible"
    else
        bad "server is up but reports ZERO models"
        bad "OLLAMA_MODELS is wrong inside the screen session"
        bad "check with: screen -r ${SCREEN_NAME}"
    fi
    printf '  settings:\n'
    printf '    %s\n' "${AA_OLLAMA_EXPORTED[@]}"
fi

if [[ "${STATUS_ONLY}" == true ]]; then
    say "Loaded models"
    ollama ps 2>/dev/null | sed 's/^/  /' || warn "ollama ps unavailable"
    exit 0
fi

# -----------------------------------------------------------------------------
if aa_is_true "$(aa_cfg preload_model true)"; then
    say "Preloading ${MODEL}"
    # An empty prompt loads the weights without generating anything, getting
    # the cold start out of the way before the first real request.
    if curl -s --max-time 600 "${OLLAMA_URL}/api/generate" \
         -d "{\"model\":\"${MODEL}\",\"prompt\":\"\",\"stream\":false}" &>/dev/null; then
        ok "loaded"
        ollama ps 2>/dev/null | sed 's/^/  /'
    else
        warn "preload failed — wrong model name, or not enough VRAM"
        warn "see what is available with: ollama list"
    fi
fi

# -----------------------------------------------------------------------------
if [[ "${LAUNCH_CODE}" == true ]]; then
    say "VS Code"
    if [[ ! -x "${VSCODE_BIN}" ]]; then
        bad "not found at ${VSCODE_BIN}"
        bad "run ${SCRIPT_DIR}/setup_vscode_arc.sh first"
    elif [[ ! -d "${PROJECT_ROOT}" ]]; then
        bad "project root does not exist: ${PROJECT_ROOT}"
        bad "fix project_root in ${AA_CONFIG_FILE}"
    else
        ok "launching on ${PROJECT_ROOT}"
        nohup "${VSCODE_BIN}" "${PROJECT_ROOT}" &>/dev/null &
        disown
    fi
fi

# -----------------------------------------------------------------------------
say "Ready"
cat << EOF

  Agent extension settings:
      API Provider   Ollama
      Base URL       ${OLLAMA_URL}
      Model          ${MODEL}

  Use the IPv4 literal, not "localhost" — Node resolves localhost to IPv6 ::1
  first while Ollama binds IPv4 only, which surfaces as ECONNREFUSED.

  Before your walltime expires:
      - commit your work
      - have the agent append what changed to memory-bank/progress.md

  Handy:
      screen -r ${SCREEN_NAME}
      ollama ps
      squeue -h -j \$SLURM_JOB_ID -o %L

EOF

