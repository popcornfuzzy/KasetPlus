#!/usr/bin/env bash
#
# appcast-release.sh - Resolves what the appcast job would publish, and optionally
# downloads it.
#
# The selection rules used to live in inline workflow steps, where the only way to
# try a change was to publish a release. They live here now: the job runs this
# script with --download-dir, and --dry-run prints the same plan against the real
# releases without downloading or writing anything.
#
# Usage:
#   # What would the next 'Update Appcast' run publish, and from which bases?
#   Scripts/appcast-release.sh --dry-run
#   Scripts/appcast-release.sh --dry-run --tag v0.9.3 --bases 3
#
#   # What the workflow runs:
#   Scripts/appcast-release.sh --download-dir "$RUNNER_TEMP" --github-output
#
# Options:
#   --tag <tag>           Release to publish (default: the latest published one)
#   --repo <owner/name>   Repository to read (default: $GITHUB_REPOSITORY, then the
#                         checkout's origin remote)
#   --bases <n>           Delta bases to keep (default: 5, Sparkle's --maximum-deltas)
#   --allow-prerelease    Let a prerelease into the stable feed
#   --dry-run             Print the plan; download and write nothing
#   --download-dir <dir>  Download into <dir>/release and <dir>/previous
#   --github-output       Write skip/tag/asset to $GITHUB_OUTPUT
#
# Exit status is 0 for a plan the pipeline would accept — including "skip, this
# release is a prerelease" — and non-zero for anything that would fail the job, so
# --dry-run works as a check before tagging a release.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_error() { echo -e "${RED}Error:${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}Warning:${NC} $1" >&2; }

TAG=""
REPO="${GITHUB_REPOSITORY:-}"
BASES=5
ALLOW_PRERELEASE=0
DRY_RUN=0
DOWNLOAD_DIR=""
WRITE_OUTPUTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --bases) BASES="${2:-}"; shift 2 ;;
    --allow-prerelease) ALLOW_PRERELEASE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --download-dir) DOWNLOAD_DIR="${2:-}"; shift 2 ;;
    --github-output) WRITE_OUTPUTS=1; shift ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) print_error "Unknown option: $1"; exit 64 ;;
  esac
done

if [[ -n "$DOWNLOAD_DIR" && "$DRY_RUN" -eq 1 ]]; then
  print_error "--dry-run and --download-dir are exclusive."
  exit 64
fi
if [[ -z "$DOWNLOAD_DIR" && "$DRY_RUN" -eq 0 ]]; then
  print_error "Nothing to do: pass --dry-run or --download-dir <dir>."
  exit 64
fi
if ! [[ "$BASES" =~ ^[0-9]+$ ]]; then
  print_error "--bases must be a non-negative number (got '$BASES')."
  exit 64
fi

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { print_error "$tool is required."; exit 1; }
done

# The checkout's origin is the right default locally: a dry run then asks the
# repository it would publish to, without the caller repeating its name.
if [[ -z "$REPO" ]]; then
  REPO=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null \
    | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#' || true)
fi
if [[ -z "$REPO" || "$REPO" == *:* ]]; then
  print_error "No repository: pass --repo <owner/name> or set GITHUB_REPOSITORY."
  exit 64
fi

if ! gh auth status >/dev/null 2>&1; then
  print_error "gh is not authenticated for $REPO."
  echo "  Run 'gh auth login', or set GH_TOKEN to a token that can read releases." >&2
  exit 1
fi

write_github_output() {
  [[ "$WRITE_OUTPUTS" -eq 1 && -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
}

# --- Resolve the release ----------------------------------------------------

if [[ -z "$TAG" ]]; then
  TAG=$(gh release view --repo "$REPO" --json tagName --jq .tagName 2>/dev/null) \
    || { print_error "Could not read the latest release of $REPO."; exit 1; }
  echo "  No --tag given; using the latest published release: $TAG"
fi

# The same grammar release.yml accepts, prerelease suffix included: a prerelease
# is skipped rather than rejected, so its tag has to parse.
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]]; then
  print_error "'$TAG' is not a release tag (expected vMAJOR.MINOR[.PATCH][-prerelease])."
  exit 1
fi

RELEASE_JSON=$(gh release view "$TAG" --repo "$REPO" \
  --json tagName,isDraft,isPrerelease,publishedAt,assets 2>/dev/null) \
  || { print_error "No release named $TAG in $REPO."; exit 1; }

IS_DRAFT=$(jq -r '.isDraft' <<< "$RELEASE_JSON")
IS_PRERELEASE=$(jq -r '.isPrerelease' <<< "$RELEASE_JSON")
PUBLISHED_AT=$(jq -r '.publishedAt' <<< "$RELEASE_JSON")

if [[ "$IS_DRAFT" == "true" ]]; then
  # Draft assets need authentication, so a feed entry pointing at one is a 404
  # for every user.
  print_error "Release $TAG is still a draft; its asset URLs are not public yet."
  exit 1
fi

if [[ "$IS_PRERELEASE" == "true" && "$ALLOW_PRERELEASE" -eq 0 ]]; then
  echo "Release $TAG is a prerelease; the stable feed would be left alone."
  write_github_output "skip=true"
  exit 0
fi

# Prefer the asset named after the tag: earlier releases carry a stray
# kaset-main.dmg from runs that used the branch name as the version.
ASSET=$(jq -r '.assets[].name' <<< "$RELEASE_JSON" | grep -Fx "kaset-$TAG.dmg" | head -1 || true)
if [[ -z "$ASSET" ]]; then
  ASSET=$(jq -r '.assets[].name' <<< "$RELEASE_JSON" | grep -E '\.dmg$' | head -1 || true)
fi
if [[ -z "$ASSET" ]]; then
  print_error "Release $TAG has no .dmg asset to sign."
  exit 1
fi

# --- Resolve the delta bases ------------------------------------------------

# Only releases older than this one qualify: a newer archive belongs to an item
# the feed already carries, and staging it would advertise that archive under
# this release's URL.
BASE_TAGS=()
BASE_ASSETS=()

if [[ "$BASES" -gt 0 ]]; then
  CANDIDATES=$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 \
    --json tagName,publishedAt \
    | jq -r --arg target "$PUBLISHED_AT" --arg tag "$TAG" \
      '.[] | select(.publishedAt < $target) | select(.tagName != $tag) | .tagName' \
    | grep -E '^v[0-9]+\.[0-9]+' || true)

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ ${#BASE_TAGS[@]} -lt "$BASES" ]] || break

    candidate_asset=$(gh release view "$candidate" --repo "$REPO" --json assets \
      --jq '.assets[].name' | grep -Fx "kaset-$candidate.dmg" | head -1 || true)
    if [[ -z "$candidate_asset" ]]; then
      echo "  Skipping $candidate as a delta base: no kaset-$candidate.dmg."
      continue
    fi

    BASE_TAGS+=("$candidate")
    BASE_ASSETS+=("$candidate_asset")
  done <<< "$CANDIDATES"
fi

# --- Report or download -----------------------------------------------------

echo ""
echo "Repository: $REPO"
echo "Publishing: $TAG ($ASSET)"
if [[ ${#BASE_TAGS[@]} -gt 0 ]]; then
  echo "Delta bases (up to $BASES):"
  for index in "${!BASE_TAGS[@]}"; do
    printf '  %-12s %s\n' "${BASE_TAGS[$index]}" "${BASE_ASSETS[$index]}"
  done
else
  echo "Delta bases: none, so the feed would carry the full archive only."
  if [[ "$BASES" -gt 0 ]]; then
    print_warning "No prior release qualifies as a delta base; the feed gets no deltas."
  fi
fi

if [[ -n "$DOWNLOAD_DIR" ]]; then
  mkdir -p "$DOWNLOAD_DIR/release" "$DOWNLOAD_DIR/previous"
  gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" \
    --dir "$DOWNLOAD_DIR/release" --clobber
  if [[ ${#BASE_TAGS[@]} -gt 0 ]]; then
    for index in "${!BASE_TAGS[@]}"; do
      gh release download "${BASE_TAGS[$index]}" --repo "$REPO" \
        --pattern "${BASE_ASSETS[$index]}" --dir "$DOWNLOAD_DIR/previous" --clobber
    done
  fi
  echo ""
  echo "Downloaded into $DOWNLOAD_DIR/release and $DOWNLOAD_DIR/previous:"
  ls -l "$DOWNLOAD_DIR/release" "$DOWNLOAD_DIR/previous"
fi

write_github_output "skip=false"
write_github_output "tag=$TAG"
write_github_output "asset=$ASSET"
