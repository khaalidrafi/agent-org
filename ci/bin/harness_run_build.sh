#!/usr/bin/env bash
# harness_run_build.sh — MODULAR harness build + REGISTRY REUSE.
#
# Owner order 2026-10-30 #hq: "on each CI run, only agents needed by that
# run can be built/used" and "Why should it build like stupid each time?
# Can't it just reuse a built image?" — so a run that names bodies FIRST
# tries to PULL each stage (base, every body, full) prebuilt from GHCR for
# the CURRENT kit sha; only stages no earlier run has published are built,
# and every fresh build is pushed back for the runs after it. Registry
# trouble NEVER fails a run: it degrades to the local build path
# (cache-from type=gha), the exact pre-registry behavior.
#
# usage:
#   harness_run_build.sh -b <BASE_TAG> -o <OUT_TAG> [-f <DOCKERFILE>]
#                        [-r <GHCR_PREFIX>] -- [BODY...]
#   no BODY names -> FULL harness (every body; the legacy/unknown-seat
#                    fail-safe path — never a silently incomplete image)
# Body names are validated against the Dockerfile's own `FROM base AS
# body-<name>` stages; ANY unknown name fails safe to the full build.
# Image tags (with -r REGISTRY): REGISTRY:base-<kitsha>, REGISTRY:body-<n>-<kitsha>,
# REGISTRY:full-<kitsha> — the kit sha pins law + Dockerfile, so equal sha
# means equal image and equal sha images are safe to reuse verbatim.
set -euo pipefail

DOCKERFILE=ci/docker/harness/Dockerfile
BASE_TAG=
OUT_TAG=
REGISTRY=
while [ $# -gt 0 ]; do
  case "$1" in
    -f) DOCKERFILE=$2; shift 2 ;;
    -b) BASE_TAG=$2; shift 2 ;;
    -o) OUT_TAG=$2; shift 2 ;;
    -r) REGISTRY=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "harness_run_build.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
BODIES=("$@")
[ -n "$BASE_TAG" ] || { echo "harness_run_build.sh: -b BASE_TAG required" >&2; exit 2; }
[ -n "$OUT_TAG" ] || { echo "harness_run_build.sh: -o OUT_TAG required" >&2; exit 2; }
[ -f "$DOCKERFILE" ] || { echo "harness_run_build.sh: no such Dockerfile: $DOCKERFILE" >&2; exit 2; }

build() {
  docker buildx build --load \
    --cache-from type=gha \
    --cache-to type=gha,mode=max \
    "$@"
}

# --- registry reuse (all best-effort; a run never fails on the registry) --
REGISTRY_ON=false
KIT_SHA=""
if [ -n "$REGISTRY" ]; then
  CI_ROOT=$(cd "$(dirname "$0")/.." && pwd)
  if KIT_SHA=$(git -C "$CI_ROOT" rev-parse HEAD 2>/dev/null); then
    REGISTRY_ON=true
  else
    echo "::warning::harness_run_build.sh: kit sha unresolvable at $CI_ROOT — no registry reuse, building locally"
  fi
fi

# try_reuse REMOTE LOCAL -> 0 when REMOTE existed, was pulled and tagged LOCAL.
try_reuse() {
  [ "$REGISTRY_ON" = true ] || return 1
  if docker manifest inspect "$1" >/dev/null 2>&1 \
     && docker pull -q "$1" >/dev/null 2>&1 \
     && docker tag "$1" "$2" >/dev/null 2>&1; then
    echo "harness: REUSED $1 (prebuilt by an earlier run — zero build)"
    return 0
  fi
  return 1
}

# try_publish LOCAL REMOTE — push a fresh build so future runs reuse it.
try_publish() {
  [ "$REGISTRY_ON" = true ] || return 0
  if docker tag "$1" "$2" 2>/dev/null && docker push -q "$2" >/dev/null 2>&1; then
    echo "harness: PUBLISHED $2 (later runs reuse it, no rebuild)"
  else
    echo "::warning::harness_run_build.sh: publish failed for $2 (packages: write missing?) — this run keeps its local build"
  fi
}

# Bodies defined by the kit Dockerfile itself (single source of truth).
KNOWN=$(sed -nE 's/^FROM base AS body-([a-z0-9-]+)$/\1/p' "$DOCKERFILE" | sort | tr '\n' ' ')

if [ "${#BODIES[@]}" -eq 0 ]; then
  echo "harness: no body list given -> FULL harness build (all bodies: ${KNOWN:-?})"
  if try_reuse "$REGISTRY:full-$KIT_SHA" "$OUT_TAG"; then
    exit 0
  fi
  build -f "$DOCKERFILE" -t "$OUT_TAG" .
  try_publish "$OUT_TAG" "$REGISTRY:full-$KIT_SHA"
  exit 0
fi

BAD=""
for b in "${BODIES[@]}"; do
  case " $KNOWN " in
    *" $b "*) ;;
    *) BAD="$BAD $b" ;;
  esac
done
if [ -n "$BAD" ]; then
  echo "::warning::harness_run_build.sh: unknown body(s):$BAD — failing safe to the FULL harness build (known bodies: $KNOWN)"
  if try_reuse "$REGISTRY:full-$KIT_SHA" "$OUT_TAG"; then
    exit 0
  fi
  build -f "$DOCKERFILE" -t "$OUT_TAG" .
  try_publish "$OUT_TAG" "$REGISTRY:full-$KIT_SHA"
  exit 0
fi

echo "harness: MODULAR build — bodies:${BODIES[*]} (kit can also provide: $KNOWN)"

# Shared base — one pull or one build, then reused by the overlay below.
if ! try_reuse "$REGISTRY:base-$KIT_SHA" "$BASE_TAG"; then
  build -f "$DOCKERFILE" --target base -t "$BASE_TAG" .
  try_publish "$BASE_TAG" "$REGISTRY:base-$KIT_SHA"
fi

for b in "${BODIES[@]}"; do
  if ! try_reuse "$REGISTRY:body-$b-$KIT_SHA" "harness-body-$b:local"; then
    echo "harness: building ONLY body-$b (not in the registry yet)"
    build -f "$DOCKERFILE" --target "body-$b" -t "harness-body-$b:local" .
    try_publish "harness-body-$b:local" "$REGISTRY:body-$b-$KIT_SHA"
  fi
done

# Overlay: FROM base + one COPY per body (directory COPY merges, never
# deletes — base-owned files like /usr/local/bin/team-chat and
# /opt/agent-team survive; sibling-body files stay intact). This is the
# ONLY build a fully-reused run still does, and it is two COPY layers.
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
{
  echo "FROM $BASE_TAG"
  for b in "${BODIES[@]}"; do
    echo "COPY --from=harness-body-$b:local /usr/local /usr/local"
    echo "COPY --from=harness-body-$b:local --chown=1001:1001 /home/agent /home/agent"
  done
} > "$TMPD/Dockerfile"
echo "harness: overlaying ${#BODIES[@]} body image(s) onto the shared base -> $OUT_TAG"
build -f "$TMPD/Dockerfile" -t "$OUT_TAG" .
echo "harness: DONE — $OUT_TAG carries exactly:${BODIES[*]}"
