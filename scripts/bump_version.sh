#!/usr/bin/env bash
set -euo pipefail

# scripts/bump_version.sh
# Usage:
#   ./scripts/bump_version.sh <major|minor|patch> [--build <build-number>] [--tag] [--push]
# Examples:
#   ./scripts/bump_version.sh patch
#   ./scripts/bump_version.sh minor --build 10 --tag --push

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_PATH="$REPO_ROOT/WhisperServer/Info.plist"
PBXPROJ_PATH="$REPO_ROOT/WhisperServer.xcodeproj/project.pbxproj"

if [ ! -f "$PLIST_PATH" ]; then
  echo "Info.plist not found at $PLIST_PATH"
  exit 1
fi

BUMP_PART=""
BUILD_NUMBER=""
DO_TAG=false
DO_PUSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --tag)
      DO_TAG=true
      shift
      ;;
    --push)
      DO_PUSH=true
      shift
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      if [ -z "$BUMP_PART" ]; then
        BUMP_PART="$1"
      else
        echo "Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate bump part
if [[ -z "$BUMP_PART" ]]; then
  echo "Usage: $0 <major|minor|patch> [--build <build-number>] [--tag] [--push]"
  exit 1
fi

if [[ ! "$BUMP_PART" =~ ^(major|minor|patch)$ ]]; then
  echo "Invalid bump part: $BUMP_PART. Use major, minor, or patch."
  exit 1
fi

# Read MARKETING_VERSION from project.pbxproj (choose the highest X.Y.Z found, default 0.0.0)
if [ ! -f "$PBXPROJ_PATH" ]; then
  echo "Xcode project not found at $PBXPROJ_PATH"
  exit 1
fi

MV_LIST=$(grep -Eo 'MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+' "$PBXPROJ_PATH" | awk '{print $3}')
if [ -z "$MV_LIST" ]; then
  CURRENT_VERSION="0.0.0"
else
  CURRENT_VERSION="0.0.0"
  while IFS= read -r v; do
    if [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
      IFS='.' read -r a b c <<< "$v"
      IFS='.' read -r ca cb cc <<< "$CURRENT_VERSION"
      if (( a>ca || (a==ca && b>cb) || (a==ca && b==cb && c>cc) )); then
        CURRENT_VERSION="$v"
      fi
    fi
  done <<< "$MV_LIST"
fi

if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Current MARKETING_VERSION ('$CURRENT_VERSION') is not in X.Y.Z format. Resetting to 0.0.0"
  MAJOR=0
  MINOR=0
  PATCH=0
else
  MAJOR=${BASH_REMATCH[1]}
  MINOR=${BASH_REMATCH[2]}
  PATCH=${BASH_REMATCH[3]}
fi

case "$BUMP_PART" in
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  patch)
    PATCH=$((PATCH + 1))
    ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
echo "Bumping version: $CURRENT_VERSION -> $NEW_VERSION"

# Update MARKETING_VERSION in project.pbxproj (all occurrences)
echo "Updating MARKETING_VERSION in project to $NEW_VERSION"
LC_ALL=C sed -i '' -E "s/(MARKETING_VERSION = )[0-9]+\.[0-9]+\.[0-9]+;/\\1$NEW_VERSION;/g" "$PBXPROJ_PATH"

# Ensure Info.plist uses $(MARKETING_VERSION) as CFBundleShortVersionString
PLIST_SHORT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST_PATH" 2>/dev/null || echo "")
if [ "$PLIST_SHORT_VER" != '$(MARKETING_VERSION)' ]; then
  echo "Setting Info.plist CFBundleShortVersionString to $(MARKETING_VERSION)"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString $(MARKETING_VERSION)' "$PLIST_PATH"
fi

if [ -n "$BUILD_NUMBER" ]; then
  echo "Setting build number to $BUILD_NUMBER"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST_PATH"
else
  # If no build number passed, increment current numeric build (if integer), else set to 1
  CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo "")
  if [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    NEXT_BUILD=$((CURRENT_BUILD + 1))
  else
    NEXT_BUILD=1
  fi
  echo "Auto bumping build number: $CURRENT_BUILD -> $NEXT_BUILD"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST_PATH"
fi

git -C "$REPO_ROOT" add "$PLIST_PATH"
echo "Review and commit the updated project files (Info.plist and project.pbxproj) manually."

# Tagging (tags are created on current HEAD; ensure you've committed changes before tagging)
if [ "$DO_TAG" = true ]; then
  TAG_NAME="v$NEW_VERSION"
  echo "Creating tag $TAG_NAME on current HEAD (ensure you've committed)."
  git -C "$REPO_ROOT" tag -a "$TAG_NAME" -m "Release $TAG_NAME"
  if [ "$DO_PUSH" = true ]; then
    echo "Pushing tag $TAG_NAME to origin"
    git -C "$REPO_ROOT" push origin "$TAG_NAME"
  fi
else
  if [ "$DO_PUSH" = true ]; then
    echo "Pushing current branch to origin"
    git -C "$REPO_ROOT" push
  fi
fi

echo "Done. Info.plist updated at $PLIST_PATH"
