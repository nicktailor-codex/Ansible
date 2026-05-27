#!/usr/bin/env bash
# ============================================================
# test_containers_fleet.sh — verify the catalog container runs
# on EVERY node via Slurm + Pyxis + Enroot.
#
# Submits one srun job per partition, each landing on a specific
# node, running the curated catalog image and exercising regenie.
# Confirms: the job ran on the expected node, the container
# started, and REGENIE responded from inside it.
#
# Usage:
#   ./test_containers_fleet.sh [path-to-sqsh]
#
# Default image: /software/containers/burdentesting/latest.sqsh
# ============================================================
set -uo pipefail

IMAGE="${1:-/software/containers/burdentesting/latest.sqsh}"
ACCOUNT="${ACCOUNT:-research}"

# partition:expected-node — one per box so we test all four
TARGETS="cpu:insiiukcpu01 gpu01:insiiukgpu01 gpu02:insiiukgpu02 cgpu01:insiiukcgpu01"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; BLUE=$'\033[34m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; GREEN=""; BLUE=""; DIM=""; RESET=""
fi

echo
printf "${BOLD}${BLUE}╭────────────────────────────────────────────────────────╮${RESET}\n"
printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Fleet container test — catalog image on every node${RESET}    ${BOLD}${BLUE}│${RESET}\n"
printf "${BOLD}${BLUE}╰────────────────────────────────────────────────────────╯${RESET}\n"
echo
echo "  Image:   $IMAGE"
echo "  Account: $ACCOUNT"

if [[ ! -f "$IMAGE" ]]; then
  printf "\n${RED}✗ catalog image not found: %s${RESET}\n" "$IMAGE"
  echo "  (is /software mounted on this node?)"
  exit 1
fi
echo "  Size:    $(ls -lh "$IMAGE" | awk '{print $5}')"
echo

PASS=0
FAIL=0
FAILED_NODES=""

for entry in $TARGETS; do
  part="${entry%%:*}"
  node="${entry##*:}"
  printf "${BOLD}── %-8s (expect %s) ──${RESET}\n" "$part" "$node"

  # Run the container: report which host it landed on + first REGENIE line.
  # regenie --help can exit non-zero on some builds, so success is judged by
  # output content (REGENIE banner) + correct node, not solely exit code.
  OUT=$(srun --partition="$part" --account="$ACCOUNT" --time=00:05:00 \
        --job-name="ctest-$part" \
        --container-image="$IMAGE" \
        bash -c 'echo "HOST:$(hostname -s)"; regenie --help 2>&1 | grep -m1 -i "REGENIE v"' 2>&1)

  RANON=$(echo "$OUT" | grep -oE 'HOST:[^ ]+' | head -1 | cut -d: -f2)
  if echo "$OUT" | grep -qi "REGENIE v" && [[ "$RANON" == "$node" ]]; then
    VER=$(echo "$OUT" | grep -oiE "REGENIE v[0-9.]+[a-z.]*" | head -1)
    printf "  ${GREEN}✓ PASS${RESET}  ran on ${BOLD}%s${RESET}, %s responded\n" "$RANON" "$VER"
    ((PASS++))
  else
    printf "  ${RED}✗ FAIL${RESET}  (ran-on='%s' expected='%s')\n" "${RANON:-?}" "$node"
    echo "$OUT" | grep -vE '^pyxis: (importing|imported)' | sed "s/^/      ${DIM}│${RESET} /" | head -8
    ((FAIL++))
    FAILED_NODES="$FAILED_NODES $node"
  fi
  echo
done

# ── Verdict ─────────────────────────────────────────────────
printf "${BOLD} Result: ${GREEN}%d passed${RESET}, " "$PASS"
if (( FAIL > 0 )); then
  printf "${RED}%d failed${RESET}  (%s)\n\n" "$FAIL" "${FAILED_NODES# }"
  printf "${BOLD}${RED}╭──────────────────────────────────────────╮${RESET}\n"
  printf "${BOLD}${RED}│${RESET}  ${BOLD}${RED}✗ FAIL${RESET}  ${RED}see details above${RESET}               ${BOLD}${RED}│${RESET}\n"
  printf "${BOLD}${RED}╰──────────────────────────────────────────╯${RESET}\n\n"
  exit 1
else
  printf "${RED}0 failed${RESET}\n\n"
  printf "${BOLD}${GREEN}╭──────────────────────────────────────────╮${RESET}\n"
  printf "${BOLD}${GREEN}│${RESET}  ${BOLD}${GREEN}✓ PASS${RESET}  ${GREEN}catalog runs on all 4 nodes${RESET}     ${BOLD}${GREEN}│${RESET}\n"
  printf "${BOLD}${GREEN}╰──────────────────────────────────────────╯${RESET}\n\n"
  exit 0
fi
