#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: tools/release.sh [patch|minor|major|VERSION] [--dry-run]"
  echo "Defaults to a patch bump. Increments the build number, commits, and pushes the default branch and release tag."
}

fail() {
  echo "Release: $*" >&2
  exit 1
}

BUMP="patch"
DRY_RUN=false
BUMP_SET=false
for ARG in "$@"; do
  case "$ARG" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=true ;;
    *)
      if [[ "$BUMP_SET" == true ]]; then usage >&2; exit 1; fi
      BUMP="$ARG"
      BUMP_SET=true
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash all changes before releasing."

VERSION_INFO=$(python3 - Info.plist "$BUMP" <<'PY'
import plistlib
import re
import sys

with open(sys.argv[1], 'rb') as source:
    metadata = plistlib.load(source)
current = metadata['CFBundleShortVersionString']
build = metadata['CFBundleVersion']
pattern = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if not re.fullmatch(pattern, current) or not re.fullmatch(r'[0-9]+', build):
    sys.exit('Release: Info.plist must contain major.minor.patch and an integer build number.')
parts = tuple(map(int, current.split('.')))
bump = sys.argv[2]
if bump in ('patch', 'minor', 'major'):
    index = {'major': 0, 'minor': 1, 'patch': 2}[bump]
    updated = list(parts)
    updated[index] += 1
    updated[index + 1:] = [0] * (2 - index)
    version = '.'.join(map(str, updated))
elif re.fullmatch(pattern, bump):
    version = bump
else:
    sys.exit('Release: choose patch, minor, major, or a version such as 0.3.0.')
if tuple(map(int, version.split('.'))) <= parts:
    sys.exit('Release: the new version must be greater than the current version.')
print(current, build, version, int(build) + 1)
PY
)
read -r CURRENT_VERSION CURRENT_BUILD VERSION BUILD <<< "$VERSION_INFO"
TAG="v$VERSION"

DEFAULT_REF=$(git ls-remote --symref origin HEAD | awk '$1 == "ref:" && $3 == "HEAD" { print $2 }')
[[ "$DEFAULT_REF" == refs/heads/* ]] || fail "Cannot resolve origin's default branch."
DEFAULT_BRANCH="${DEFAULT_REF#refs/heads/}"
[[ "$(git symbolic-ref --quiet --short HEAD)" == "$DEFAULT_BRANCH" ]] || fail "Switch to $DEFAULT_BRANCH before releasing."
git fetch origin --prune --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "refs/remotes/origin/$DEFAULT_BRANCH")" ]] || fail "Local $DEFAULT_BRANCH must match origin/$DEFAULT_BRANCH. Push or reconcile existing commits first."
if git show-ref --verify --quiet "refs/tags/$TAG"; then fail "$TAG already exists."; fi

echo "Uso $CURRENT_VERSION (build $CURRENT_BUILD) -> $VERSION (build $BUILD)"
echo "Release commit and tag $TAG will be pushed to origin/$DEFAULT_BRANCH."
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run: no version changes, commits, tags, or pushes."
  exit 0
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
plutil -lint Info.plist
git add -- Info.plist
git commit -m "Release Uso $VERSION (build $BUILD)"
git tag -a "$TAG" -m "Uso $VERSION"
# Push both refs together so a failed branch update cannot leave a release tag behind.
if ! git push --atomic origin "HEAD:$DEFAULT_REF" "refs/tags/$TAG"; then
  echo "Release push failed. The version commit and $TAG remain local; nothing was rolled back." >&2
  echo "After resolving the remote error, retry: git push --atomic origin HEAD:$DEFAULT_REF refs/tags/$TAG" >&2
  exit 1
fi
echo "Pushed $TAG. GitHub Actions will build, verify, and publish the notarized release."
echo "https://github.com/0xIvan/uso/actions/workflows/release.yml"
