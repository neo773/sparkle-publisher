#!/usr/bin/env bash

set -e  # Exit on any error

# Configuration
NAME="mactranscribe"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$PROJECT_ROOT/Changelog.md"
WEBSITE="https://github.com/neo773/mactranscribe"
GENERATE_APPCAST_TOOL="$PROJECT_ROOT/Utilities/Sparkle/generate_appcast"

# GitHub configuration
GITHUB_RELEASES_REPO="neo773/mactranscribe-releases"
GITHUB_PAGES_URL="https://neo773.github.io/mactranscribe-releases"

# Check if DMG is provided
if [[ -z "$1" ]]; then
    echo "No DMG file provided!"
    echo "Usage: ./publish-update.sh /path/to/dmg"
    exit 1
fi

DMG_FILE="$(realpath "$1")"  # Ensure absolute path
UPDATE_DIR="$(dirname "$DMG_FILE")"  # Use DMG's directory for appcast
PARTIAL_APPCAST_FILE="$UPDATE_DIR/partial_update.xml"
APPCAST_FILE="$UPDATE_DIR/update.xml"
EXISTING_APPCAST_FILE="$UPDATE_DIR/existing_update.xml"

# Generate `update.xml` using local DMG
echo "Generating Sparkle appcast..."
"$GENERATE_APPCAST_TOOL" --link "$WEBSITE" -o "$PARTIAL_APPCAST_FILE" "$UPDATE_DIR"

# Extract version & build using awk (compatible with macOS)
VERSION=$(awk -F '[<>]' '/<sparkle:shortVersionString>/ {print $3}' "$PARTIAL_APPCAST_FILE")
BUILD=$(awk -F '[<>]' '/<sparkle:version>/ {print $3}' "$PARTIAL_APPCAST_FILE")

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "Failed to extract version or build from appcast!"
    exit 1
fi

echo "Extracted version: $VERSION, build: $BUILD"

# GitHub Release tag and download URL
RELEASE_TAG="v${VERSION}-${BUILD}"
DMG_DOWNLOAD_URL="https://github.com/${GITHUB_RELEASES_REPO}/releases/download/${RELEASE_TAG}/${NAME}.dmg"

# Extract changelog for this version (INCLUDING title)
CHANGELOG_CONTENT=$(awk -v version="$VERSION" -v build="$BUILD" '
    BEGIN {found=0}
    $0 ~ "^## " version " \\(" build "\\) " {found=1}  # Start capturing from title
    found && /^## / && !($0 ~ "^## " version " \\(" build "\\) ") {exit}  # Stop at next title
    found {print}
' "$CHANGELOG")

if [[ -z "$CHANGELOG_CONTENT" ]]; then
    echo "No changelog entry found for version $VERSION (Build $BUILD)."
    exit 1
fi

# Convert changelog to HTML
CHANGELOG_HTML=$(echo "$CHANGELOG_CONTENT" | pandoc -f markdown-auto_identifiers -t html | sed 's/"/\&quot;/g')

# Wrap the HTML in a <div>
FULL_CHANGELOG_HTML=$(cat <<EOF
<div>
    $CHANGELOG_HTML
</div>
EOF
)

# Show preview in plain text
echo "Changelog Preview:"
echo "---------------------------------------------------------"
echo "$CHANGELOG_CONTENT"
echo "---------------------------------------------------------"

# Ask for confirmation before proceeding
echo -n "Proceed with creating update (y/n)? "
read answer
if [[ "$answer" != "${answer#[Nn]}" ]]; then
    echo "Update canceled."
    exit 1
fi

# Clone gh-pages branch to a temp directory for appcast management
GHPAGES_TMPDIR=$(mktemp -d)
trap 'rm -rf "$GHPAGES_TMPDIR"' EXIT

echo "Fetching existing appcast from gh-pages branch..."
if git clone --branch gh-pages --single-branch --depth 1 \
    "https://github.com/${GITHUB_RELEASES_REPO}.git" "$GHPAGES_TMPDIR" 2>/dev/null; then

    if [[ -f "$GHPAGES_TMPDIR/update.xml" ]]; then
        cp "$GHPAGES_TMPDIR/update.xml" "$EXISTING_APPCAST_FILE"
        APPCAST_EXISTS=true

        # Check for duplicate build
        if grep -q "<sparkle:version>${BUILD}</sparkle:version>" "$EXISTING_APPCAST_FILE"; then
            echo "Build $BUILD already exists in update.xml!"
            echo "Aborting to prevent duplicate versions."
            exit 1
        fi
    else
        echo "gh-pages branch exists but no update.xml found. Creating fresh appcast."
        APPCAST_EXISTS=false
    fi
else
    echo "No gh-pages branch found. Run the one-time setup first."
    exit 1
fi

# Merge old appcast (if exists) or use the new one
if [[ "$APPCAST_EXISTS" == true ]]; then
    echo "Merging new update into existing appcast..."

    # Copy everything up to <channel> (keep header and opening tag)
    awk '/<channel>/ {print; exit} {print}' "$EXISTING_APPCAST_FILE" > "$APPCAST_FILE"

    # Insert the new update entry at the top (newest version first)
    awk '/<item>/,/<\/item>/' "$PARTIAL_APPCAST_FILE" >> "$APPCAST_FILE"

    # Append all existing <item> entries (preserving version history)
    awk '/<item>/,/<\/item>/' "$EXISTING_APPCAST_FILE" >> "$APPCAST_FILE"

    # Close the channel properly
    echo "</channel></rss>" >> "$APPCAST_FILE"
else
    echo "Using new appcast as the initial update.xml."
    cp "$PARTIAL_APPCAST_FILE" "$APPCAST_FILE"
fi

# Inject changelog into `update.xml`
perl -i -pe "s{</item>}{<description><![CDATA[$FULL_CHANGELOG_HTML]]></description>\n</item>}g" "$APPCAST_FILE"

# Replace enclosure URL with GitHub Releases download URL
perl -i -pe "s{<enclosure url=\"[^\"]*\"}{<enclosure url=\"$DMG_DOWNLOAD_URL\"}g" "$APPCAST_FILE"

# Ask for final confirmation before publishing
echo -n "Proceed with creating GitHub release and publishing appcast? (y/n) "
read answer
if [[ "$answer" != "${answer#[Nn]}" ]]; then
    echo "Upload canceled."
    exit 1
fi

# Create GitHub Release and upload DMG
echo "Creating GitHub release ${RELEASE_TAG}..."
if gh release view "$RELEASE_TAG" --repo "$GITHUB_RELEASES_REPO" > /dev/null 2>&1; then
    echo "Release ${RELEASE_TAG} already exists. Uploading DMG to existing release..."
    gh release upload "$RELEASE_TAG" "$DMG_FILE" \
        --repo "$GITHUB_RELEASES_REPO" \
        --clobber
else
    gh release create "$RELEASE_TAG" "$DMG_FILE" \
        --repo "$GITHUB_RELEASES_REPO" \
        --title "${NAME} ${VERSION} (${BUILD})" \
        --notes "$CHANGELOG_CONTENT"
fi

# Update appcast on gh-pages branch
echo "Publishing appcast to GitHub Pages..."
cp "$APPCAST_FILE" "$GHPAGES_TMPDIR/update.xml"

ORIGINAL_DIR="$(pwd)"
cd "$GHPAGES_TMPDIR"
git add update.xml
git commit -m "Update appcast for ${VERSION} (${BUILD})"
git push origin gh-pages
cd "$ORIGINAL_DIR"

echo "Done. Release is live!"
echo "  DMG: $DMG_DOWNLOAD_URL"
echo "  Appcast: ${GITHUB_PAGES_URL}/update.xml"
