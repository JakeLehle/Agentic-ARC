#!/bin/bash
# =============================================================================
# lib_config.sh — shared config loader and output helpers for Agentic ARC
#
# Sourced by the other scripts in this directory. Not meant to be run directly.
#
# Parses a flat subset of YAML:
#   key: value        ->  $CFG_KEY
#   key:              ->  $CFG_KEY_LIST  (bash array)
#     - item
#
# Deliberately not a real YAML parser: no nested maps, no multi-line strings,
# no anchors. The config format is kept flat so this stays ~40 lines with zero
# dependencies and fails in obvious ways.
#
# $USER, $HOME and a leading ~/ are expanded by string substitution. Values are
# never passed through eval.
#
# Requires bash 4.3+ for namerefs (RHEL 8 ships 4.4).
# =============================================================================

# --- output helpers ----------------------------------------------------------
# Colour only when stdout is a terminal, so piped output stays clean.
if [[ -t 1 ]]; then
    _C_HEAD=$'\033[1;36m'; _C_OK=$'\033[0;32m'
    _C_WARN=$'\033[0;33m'; _C_BAD=$'\033[0;31m'; _C_OFF=$'\033[0m'
else
    _C_HEAD=''; _C_OK=''; _C_WARN=''; _C_BAD=''; _C_OFF=''
fi

say()  { printf '\n%s==> %s%s\n' "${_C_HEAD}" "$*" "${_C_OFF}"; }
ok()   { printf '  %s[ok]%s %s\n'  "${_C_OK}"   "${_C_OFF}" "$*"; }
warn() { printf '  %s[!!]%s %s\n'  "${_C_WARN}" "${_C_OFF}" "$*"; }
bad()  { printf '  %s[xx]%s %s\n'  "${_C_BAD}"  "${_C_OFF}" "$*" >&2; }

# --- identity ----------------------------------------------------------------
# $USER is not guaranteed to be set — it is absent in some batch and cron
# contexts. Without a fallback, "/work/$USER" silently becomes "/work/", which
# fails later in a way that points nowhere near the cause.
AA_USER="${USER:-$(id -un 2>/dev/null)}"
AA_HOME="${HOME:-$(getent passwd "${AA_USER}" 2>/dev/null | cut -d: -f6)}"

# --- value cleanup -----------------------------------------------------------
aa__clean() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"          # ltrim
    s="${s%"${s##*[![:space:]]}"}"          # rtrim
    if [[ ${#s} -ge 2 ]]; then              # strip one layer of matching quotes
        [[ "$s" == \"*\" ]] && s="${s:1:${#s}-2}"
        [[ "$s" == \'*\' ]] && s="${s:1:${#s}-2}"
    fi
    s="${s//\$\{USER\}/${AA_USER}}"
    s="${s//\$USER/${AA_USER}}"
    s="${s//\$\{HOME\}/${AA_HOME}}"
    s="${s//\$HOME/${AA_HOME}}"
    [[ "$s" == '~/'* ]] && s="${AA_HOME}/${s:2}"
    printf '%s' "$s"
}

# --- locate the config file --------------------------------------------------
# Order: $AGENTIC_ARC_CONFIG, then repo-relative (works wherever it is cloned),
# then the conventional location in $HOME.
aa_find_config() {
    local script_dir="$1" candidate
    for candidate in \
        "${AGENTIC_ARC_CONFIG:-}" \
        "${script_dir}/../config.yaml" \
        "${script_dir}/../config.yml" \
        "${HOME}/Agentic-ARC/config.yaml"
    do
        [[ -n "${candidate}" && -r "${candidate}" ]] || continue
        # Resolve to an absolute path without requiring realpath
        printf '%s' "$(cd "$(dirname "${candidate}")" && pwd)/$(basename "${candidate}")"
        return 0
    done
    return 1
}

# --- parse -------------------------------------------------------------------
aa_load_config() {
    local file="$1"
    if [[ ! -r "${file}" ]]; then
        bad "config not readable: ${file}"
        return 1
    fi

    local line key val item current=''
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"                                 # tolerate CRLF
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue        # whole-line comment
        [[ "${line}" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]] \
            && line="${BASH_REMATCH[1]}"                     # trailing comment
        [[ -z "${line//[[:space:]]/}" ]] && continue         # blank

        if [[ "${line}" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
            # list item, belongs to the most recent bare key
            [[ -z "${current}" ]] && continue
            item="$(aa__clean "${BASH_REMATCH[1]}")"
            [[ -z "${item}" ]] && continue
            local -n _arr="CFG_${current}_LIST"
            _arr+=("${item}")

        elif [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="$(aa__clean "${BASH_REMATCH[2]}")"
            if [[ -z "${val}" ]]; then
                current="${key^^}"                           # a list follows
                unset "CFG_${current}_LIST" 2>/dev/null || true
                declare -g -a "CFG_${current}_LIST"
            else
                declare -g "CFG_${key^^}=${val}"
                current=''
            fi
        fi
    done < "${file}"
}

# --- scalar getter with default ----------------------------------------------
aa_cfg() {
    local name="CFG_${1^^}"
    printf '%s' "${!name:-${2-}}"
}

# --- booleans ----------------------------------------------------------------
aa_is_true() {
    case "${1,,}" in
        true|yes|y|1|on) return 0 ;;
        *)               return 1 ;;
    esac
}

# --- OLLAMA_* passthrough ----------------------------------------------------
# Every ollama_env_<name> key becomes OLLAMA_<NAME>. Add a line to the config
# and it is exported here with no change to any script.
#
# An OLLAMA_* variable already set in the environment wins, so a one-off
# override on the command line still works:
#   OLLAMA_KEEP_ALIVE=5m ./start_ai_session.sh
aa_export_ollama_env() {
    local var suffix target
    AA_OLLAMA_EXPORTED=()
    while IFS= read -r var; do
        suffix="${var#CFG_OLLAMA_ENV_}"
        target="OLLAMA_${suffix}"
        if [[ -n "${!target:-}" ]]; then
            AA_OLLAMA_EXPORTED+=("${target}=${!target} (from environment)")
        else
            export "${target}=${!var}"
            AA_OLLAMA_EXPORTED+=("${target}=${!var}")
        fi
    done < <(compgen -v | grep '^CFG_OLLAMA_ENV_' | sort)
}

# --- ollama endpoint ---------------------------------------------------------
aa_ollama_url() {
    printf 'http://%s:%s' \
        "$(aa_cfg ollama_host 127.0.0.1)" \
        "$(aa_cfg ollama_port 11434)"
}

aa_ollama_serving() {
    curl -s --max-time 3 "$(aa_ollama_url)/api/tags" &>/dev/null
}

# --- load, with reporting ----------------------------------------------------
# Convenience wrapper: find, parse, export, and say where it came from.
aa_init() {
    local script_dir="$1" cfg
    if [[ -z "${AA_USER}" ]]; then
        bad "cannot determine the current username (\$USER unset and 'id -un' failed)"
        return 1
    fi
    if ! cfg="$(aa_find_config "${script_dir}")"; then
        bad "no config.yaml found"
        bad "looked in: \$AGENTIC_ARC_CONFIG, ${script_dir}/../config.yaml, ${AA_HOME}/Agentic-ARC/config.yaml"
        return 1
    fi
    aa_load_config "${cfg}" || return 1
    AA_CONFIG_FILE="${cfg}"
    return 0
}

