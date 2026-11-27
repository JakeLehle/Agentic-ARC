#!/bin/bash
# =============================================================================
# setup_vscode_arc.sh — one-time install of VS Code + extensions
#
# Installs into your home directory, which on Arc is shared storage, so one
# install serves every compute node. No admin privileges needed.
#
# Run it wherever you have outbound internet. On Arc, GPU compute nodes do have
# it; the script tests before downloading and tells you either way.
#
# Idempotent — safe to re-run.
#
#   bash setup_vscode_arc.sh            install
#   bash setup_vscode_arc.sh --check    report state, change nothing
#
# All paths, URLs and extension IDs come from ../config.yaml.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_config.sh
source "${SCRIPT_DIR}/lib_config.sh" || { echo "cannot source lib_config.sh" >&2; exit 1; }

CHECK_ONLY=false
case "${1:-}" in
    --check)   CHECK_ONLY=true ;;
    -h|--help) sed -n '3,17p' "$0"; exit 0 ;;
    '')        ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

aa_init "${SCRIPT_DIR}" || exit 1

VSCODE_DIR="$(aa_cfg vscode_dir "${HOME}/VSCode-linux-x64")"
VSCODE_BIN="${VSCODE_DIR}/bin/code"
VSIX_DIR="$(aa_cfg vsix_dir "${HOME}/vsix")"
VSCODE_URL="$(aa_cfg vscode_url 'https://update.code.visualstudio.com/latest/linux-x64/stable')"
TARBALL="${HOME}/.vscode-download.tar.gz"

# -----------------------------------------------------------------------------
say "Context"
printf '  config:  %s\n' "${AA_CONFIG_FILE}"
printf '  host:    %s\n' "$(hostname)"
printf '  target:  %s\n' "${VSCODE_DIR}"
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
    printf '  slurm:   job %s on %s\n' "${SLURM_JOB_ID}" "${SLURM_JOB_PARTITION:-?}"
else
    printf '  slurm:   no allocation (login node or plain shell)\n'
fi

# -----------------------------------------------------------------------------
say "Network"
NET_OK=false
if curl -sIL --max-time 20 "${VSCODE_URL}" 2>/dev/null | head -1 | grep -q .; then
    NET_OK=true
    ok "VS Code download endpoint reachable"
else
    bad "cannot reach ${VSCODE_URL}"
    warn "if this is a compute node, try again from a login node"
    warn "some clusters route outbound traffic only from login nodes"
fi

MARKET_OK=false
if curl -sIL --max-time 20 'https://marketplace.visualstudio.com' 2>/dev/null | head -1 | grep -q .; then
    MARKET_OK=true
    ok "extension marketplace reachable"
else
    warn "marketplace unreachable — will install from ${VSIX_DIR} instead"
fi

# -----------------------------------------------------------------------------
say "Current state"
if [[ -x "${VSCODE_BIN}" ]]; then
    ok "VS Code installed: $("${VSCODE_BIN}" --version 2>/dev/null | head -1)"
    VSCODE_PRESENT=true
else
    warn "VS Code not found at ${VSCODE_BIN}"
    VSCODE_PRESENT=false
fi

if [[ "${VSCODE_PRESENT}" == true ]]; then
    installed="$("${VSCODE_BIN}" --list-extensions 2>/dev/null)"
    if [[ -n "${installed}" ]]; then
        ok "extensions installed:"
        printf '%s\n' "${installed}" | sed 's/^/           /'
    else
        warn "no extensions installed yet"
    fi
fi

if command -v module &>/dev/null; then
    mod="$(aa_cfg ollama_module ollama)"
    if module avail "${mod}" 2>&1 | grep -qi "${mod}"; then
        ok "'${mod}' module available"
    else
        warn "'${mod}' module not listed by 'module avail' — may still load by name"
    fi
else
    warn "no 'module' command — not on a cluster login/compute node?"
fi

if [[ "${CHECK_ONLY}" == true ]]; then
    say "Check only — nothing changed"
    exit 0
fi

# -----------------------------------------------------------------------------
if [[ "${VSCODE_PRESENT}" == false ]]; then
    if [[ "${NET_OK}" == false ]]; then
        bad "cannot download without network access — re-run from a login node"
        exit 1
    fi

    say "Downloading VS Code"
    if ! curl -L --progress-bar "${VSCODE_URL}" -o "${TARBALL}"; then
        bad "download failed"
        exit 1
    fi

    # A proxy error page will happily save as a .tar.gz, so check the type
    # rather than trusting the extension.
    if ! file "${TARBALL}" 2>/dev/null | grep -qi gzip; then
        bad "downloaded file is not a gzip archive — likely a proxy error page"
        bad "inspect it with: head -c 200 ${TARBALL}"
        exit 1
    fi

    say "Extracting"
    # The tarball contains a VSCode-linux-x64/ directory. Extract to the parent
    # of the configured target so the result lands where config.yaml says.
    parent="$(dirname "${VSCODE_DIR}")"
    mkdir -p "${parent}"
    if ! tar -xzf "${TARBALL}" -C "${parent}"; then
        bad "extraction failed"
        exit 1
    fi

    if [[ -x "${VSCODE_BIN}" ]]; then
        ok "installed to ${VSCODE_DIR}"
        rm -f "${TARBALL}"
    else
        bad "expected ${VSCODE_BIN} after extraction but it is not there"
        bad "check what the archive contained: ls ${parent}"
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
say "Extensions"
ext_count=0
[[ -v CFG_EXTENSIONS_LIST[@] ]] && ext_count="${#CFG_EXTENSIONS_LIST[@]}"

if [[ "${ext_count}" -eq 0 ]]; then
    warn "no extensions listed in config.yaml"
elif [[ "${MARKET_OK}" == true ]]; then
    for ext in "${CFG_EXTENSIONS_LIST[@]}"; do
        if "${VSCODE_BIN}" --list-extensions 2>/dev/null | grep -qix "${ext}"; then
            ok "already installed: ${ext}"
        else
            printf '  installing %s ...\n' "${ext}"
            if "${VSCODE_BIN}" --install-extension "${ext}" --force &>/dev/null; then
                ok "installed: ${ext}"
            else
                bad "failed: ${ext}"
            fi
        fi
    done
else
    mkdir -p "${VSIX_DIR}"
    if compgen -G "${VSIX_DIR}/*.vsix" > /dev/null; then
        for vsix in "${VSIX_DIR}"/*.vsix; do
            printf '  installing %s ...\n' "$(basename "${vsix}")"
            if "${VSCODE_BIN}" --install-extension "${vsix}" --force &>/dev/null; then
                ok "installed $(basename "${vsix}")"
            else
                bad "failed $(basename "${vsix}")"
            fi
        done
    else
        warn "no .vsix files in ${VSIX_DIR}"
        warn "download them from marketplace.visualstudio.com on any machine with"
        warn "a browser, copy them there, and re-run this script"
        printf '\n  needed:\n'
        printf '    %s\n' "${CFG_EXTENSIONS_LIST[@]}"
    fi
fi

# -----------------------------------------------------------------------------
say "Done"
cat << EOF

  Start a session with:

      ${SCRIPT_DIR}/start_ai_session.sh

  That brings up Ollama with the settings from config.yaml and launches
  VS Code on $(aa_cfg project_root "/work/\$USER").

EOF

