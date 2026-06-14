#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/release.sh <version|patch|minor|major>
#
# Examples:
#   ./scripts/release.sh 0.2.0    # explicit version
#   ./scripts/release.sh patch    # 0.1.0 -> 0.1.1
#   ./scripts/release.sh minor    # 0.1.0 -> 0.2.0
#   ./scripts/release.sh major    # 0.1.0 -> 1.0.0

VERSION="${1:?Usage: $0 <version|patch|minor|major>}"

ROOT="$(git rev-parse --show-toplevel)"
CARGO_TOML="$ROOT/Cargo.toml"

# Read current version from [package] section
CURRENT=$(sed -n '/\[package\]/,/^\[/{s/^version = "\(.*\)"/\1/p}' "$CARGO_TOML")
if [ -z "$CURRENT" ]; then
    echo "Error: could not read current version from $CARGO_TOML"
    exit 1
fi
echo "Current version: $CURRENT"

# Compute new version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$VERSION" in
    major) NEW="$((MAJOR + 1)).0.0" ;;
    minor) NEW="${MAJOR}.$((MINOR + 1)).0" ;;
    patch) NEW="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
    *)     NEW="$VERSION" ;;
esac

if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: invalid version format '$NEW' (expected X.Y.Z)"
    exit 1
fi

if [ "$NEW" = "$CURRENT" ]; then
    echo "Error: new version is the same as current ($CURRENT)"
    exit 1
fi

echo "New version: $NEW"

# Check clean working directory
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working directory not clean. Commit or stash changes first."
    exit 1
fi

# Update version in Cargo.toml (portable: works on both macOS BSD sed and GNU sed)
sed -i.bak "s/^version = \"$CURRENT\"/version = \"$NEW\"/" "$CARGO_TOML" && rm -f "$CARGO_TOML.bak"

# Regenerate Cargo.lock
cargo check --quiet 2>/dev/null || true

# Generate changelog
if command -v git-cliff &>/dev/null; then
    git-cliff --tag "v$NEW" -o "$ROOT/CHANGELOG.md"
    git add "$ROOT/CHANGELOG.md"
    echo "Updated CHANGELOG.md"
fi

# Commit and tag
git add "$CARGO_TOML" "$ROOT/Cargo.lock"
git commit -m "release: v$NEW"
git tag -a "v$NEW" -m "v$NEW"

echo ""
echo "Created commit and tag v$NEW"
echo "Run 'git push && git push --tags' to trigger the release workflow."
