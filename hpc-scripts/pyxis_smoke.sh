#!/usr/bin/env bash
# ============================================================
# pyxis_smoke.sh — Validate Pyxis + Enroot WITHOUT Slurm.
# Pulls a known image via `enroot import`, unpacks it, runs a
# command inside, reports per-step pass/fail.
#
# Counterpart to burden_without_slurm_smoke.sh (the Apptainer
# equivalent), now exercising the new container runtime.
#
# Usage:
#   ./pyxis_smoke.sh                       # default: ubuntu:24.04
#   ./pyxis_smoke.sh docker://IMAGE:TAG    # any docker image
# ============================================================
set -uo pipefail

IMAGE="${1:-docker://ubuntu:24.04}"
FAILS=0
PASSES=0

# ── Colors (only if stdout is a TTY) ────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    RESET=$'\033[0m'
else
    BOLD="" DIM="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

section() { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
field()   { printf "  ${DIM}%-14s${RESET} %s\n" "$1" "$2"; }
ok()      { printf "  ${GREEN}✓${RESET} %s\n" "$1"; ((PASSES++)); }
fl()      { printf "  ${RED}✗${RESET} %s\n" "$1"; ((FAILS++)); }

# ── Banner ──────────────────────────────────────────────────
echo
printf "${BOLD}${BLUE}╭────────────────────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Pyxis + Enroot stack smoke test (no Slurm)${RESET}           ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"

section "Configuration"
field "Image"      "$IMAGE"
field "User"       "$USER"
field "Host"       "$(hostname -s)"
field "Cache"      "${ENROOT_CACHE_PATH:-/scratch/cluster-software/enroot-cache (default)}"

# ── 1. enroot installed ─────────────────────────────────────
section "1. Enroot binary present"
if command -v enroot >/dev/null 2>&1; then
    ok "enroot at $(command -v enroot) — version $(enroot version)"
else
    fl "enroot not found in PATH"
    echo
    printf "${BOLD}${RED}✗ FAIL — Enroot not installed${RESET}\n"
    exit 1
fi

# ── 2. Userns enabled ───────────────────────────────────────
section "2. Kernel user namespaces"
USERNS=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)
if [[ "$USERNS" == "1" ]]; then
    ok "kernel.unprivileged_userns_clone = $USERNS"
else
    fl "kernel.unprivileged_userns_clone = $USERNS (Enroot needs 1)"
fi

# ── 3. Config sanity ────────────────────────────────────────
section "3. /etc/enroot/enroot.conf"
if [[ -f /etc/enroot/enroot.conf ]]; then
    ok "config present"
    grep -E '^[A-Z_]+' /etc/enroot/enroot.conf | sed "s/^/    ${DIM}│${RESET} /"
else
    fl "/etc/enroot/enroot.conf missing"
fi

# ── 4. Pull image ───────────────────────────────────────────
section "4. enroot import"
WORKDIR="/scratch/$USER/pyxis-smoke-$$"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

IMAGE_NAME=$(echo "${IMAGE#docker://}" | tr '/:' '+')
SQSH_FILE="${IMAGE_NAME}.sqsh"

if enroot import -o "$SQSH_FILE" "$IMAGE" 2>&1 | tail -5; then
    if [[ -f "$SQSH_FILE" ]]; then
        ok "imported $IMAGE → $(ls -lh "$SQSH_FILE" | awk '{print $5}')"
    else
        fl "import claimed success but $SQSH_FILE not present"
    fi
else
    fl "enroot import failed"
    cd /tmp && rm -rf "$WORKDIR"
    echo
    printf "${BOLD}${RED}✗ FAIL — could not import image${RESET}\n"
    exit 1
fi

# ── 5. Create container ─────────────────────────────────────
section "5. enroot create"
CONTAINER_NAME="pyxis-smoke-$$"
if enroot create --name "$CONTAINER_NAME" "$SQSH_FILE" 2>&1 | tail -3; then
    ok "container '$CONTAINER_NAME' created"
else
    fl "enroot create failed"
fi

# ── 6. Run command inside ───────────────────────────────────
section "6. enroot start — run command in container"
START_OUT=$(enroot start "$CONTAINER_NAME" sh -c 'cat /etc/os-release 2>/dev/null | head -3; echo "---"; echo "hostname-inside: $(hostname)"; echo "pid-1: $$"' 2>&1)
START_RC=$?
echo "$START_OUT" | sed "s/^/    ${DIM}│${RESET} /"
if [[ $START_RC -eq 0 ]] && echo "$START_OUT" | grep -q "hostname-inside:"; then
    ok "container ran successfully (rc=$START_RC)"
else
    fl "container failed to run (rc=$START_RC)"
fi

# ── 7. Cleanup ──────────────────────────────────────────────
section "7. Cleanup"
enroot remove -f "$CONTAINER_NAME" >/dev/null 2>&1 && ok "removed container '$CONTAINER_NAME'" || fl "could not remove container"
rm -rf "$WORKDIR" && ok "removed workdir $WORKDIR"

# ── Verdict ─────────────────────────────────────────────────
echo
printf "${BOLD} Result: ${GREEN}$PASSES passed${RESET}, "
if (( FAILS > 0 )); then
    printf "${RED}$FAILS failed${RESET}\n\n"
    printf "${BOLD}${RED}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}see details above${RESET}               ${BOLD}${RED}│${RESET}\n"
    printf "${BOLD}${RED}╰──────────────────────────────────────────╯${RESET}\n\n"
    exit 1
else
    printf "${RED}0 failed${RESET}\n\n"
    printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}Pyxis+Enroot stack healthy${RESET}      ${BOLD}${GREEN}│${RESET}\n"
    printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n\n"
    exit 0
fi
