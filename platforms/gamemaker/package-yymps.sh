#!/bin/bash
# Package Colyseus GameMaker Extension as .yymps (importable local package)
#
# This script generates the metadata files (metadata.json, yymanifest.xml,
# .yyp, .resource_order) with correct versions and MD5 hashes, then zips
# everything into a .yymps file.
#
# Usage:
#   ./package-yymps.sh [build_dir]
#
# Arguments:
#   build_dir  Directory containing built binaries (default: uses zig-out + wasm-out)
#
# Prerequisites:
#   - Built binaries in zig-out/lib/ (from `zig build -Dall`)
#   - Built WASM in wasm-out/ (from ./build-wasm.sh)
#   - jq, md5sum/md5

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(jq -r '.version' "$SCRIPT_DIR/version.json")
PACKAGE_DISPLAY_NAME="Colyseus SDK"
PACKAGE_NAME="Colyseus_SDK"
PACKAGE_ID="Colyseus_SDK"
EXT_DIR="extensions/Colyseus_SDK"
SCRIPT_RESOURCE_DIR="scripts/Colyseus"

# Output
OUT_DIR="$SCRIPT_DIR/package-out"
STAGE="$OUT_DIR/stage"

echo "=== Packaging Colyseus GameMaker SDK v${VERSION} ==="

# Clean staging area
rm -rf "$STAGE"
mkdir -p "$STAGE/$EXT_DIR" "$STAGE/$SCRIPT_RESOURCE_DIR"

# =========================================================================
# 1. Copy extension .yy and scripts from source of truth (example project)
# =========================================================================
EXAMPLE="$SCRIPT_DIR/example/BlankProject"

# GameMaker .yy files use trailing commas (not valid JSON).
# Apply the regex repeatedly until stable (handles nested cases on same line).
fix_trailing_commas() {
    perl -0777 -pe '1 while s/,(\s*[\]\}])/$1/g' "$1"
}

# Copy Colyseus_SDK.yy — fix parent references, version, and create per-platform file entries.
# The source .yy has a single native file entry (macOS dylib) used during development.
# We duplicate it into separate file entries for each platform (each with copyToTargets
# targeting only that platform) so GameMaker loads the correct binary per platform.
# ProxyFiles are NOT used — they cause GameMaker to load the wrong binary on macOS.
#
# Platform copyToTargets flags: Windows=1, macOS=2, Linux=4, HTML5=8, iOS=16, Android=32
# Save the macOS functions for reuse across platform entries
MACOS_FUNCTIONS=$(fix_trailing_commas "$EXAMPLE/$EXT_DIR/Colyseus_SDK.yy" | jq '.files[0].functions')

fix_trailing_commas "$EXAMPLE/$EXT_DIR/Colyseus_SDK.yy" | jq \
  --arg ver "$VERSION" --arg name "$PACKAGE_NAME" --arg path "$PACKAGE_NAME.yyp" \
  --argjson funcs "$MACOS_FUNCTIONS" '
  .parent = { "name": $name, "path": $path } |
  .extensionVersion = $ver |
  .copyToTargets = -1 |

  # macOS entry (original): restrict to macOS only, no ProxyFiles
  .files[0].copyToTargets = 2 |
  .files[0].ProxyFiles = [] |

  # Clone file entries for Windows and Linux (same functions, different binary)
  .files += [
    (.files[0] | .filename = "colyseus.dll" | .copyToTargets = 1 | .functions = $funcs),
    (.files[0] | .filename = "libcolyseus.so" | .copyToTargets = 4 | .functions = $funcs)
  ]
' > "$STAGE/$EXT_DIR/Colyseus_SDK.yy"

# Copy Colyseus.gml + Colyseus.yy — fix parent references
cp "$EXAMPLE/$SCRIPT_RESOURCE_DIR/Colyseus.gml" "$STAGE/$SCRIPT_RESOURCE_DIR/Colyseus.gml"
fix_trailing_commas "$EXAMPLE/$SCRIPT_RESOURCE_DIR/Colyseus.yy" | jq \
  --arg name "$PACKAGE_NAME" --arg path "$PACKAGE_NAME.yyp" '
  .parent = { "name": $name, "path": $path }
' > "$STAGE/$SCRIPT_RESOURCE_DIR/Colyseus.yy"

# =========================================================================
# 2. Copy built binaries
# =========================================================================
ZIG_OUT="$SCRIPT_DIR/zig-out/lib"
WASM_OUT="$SCRIPT_DIR/wasm-out"

# Main dylib (macOS arm64 — referenced in .yy filename field)
copy_if_exists() {
    local src="$1" dst="$2"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    fi
}

# macOS — create universal binary via lipo if available, otherwise use single arch
DYLIB_ARM64="$ZIG_OUT/macos/arm64/libcolyseus.dylib"
DYLIB_X64="$ZIG_OUT/macos/x64/libcolyseus.dylib"
if [ -f "$DYLIB_ARM64" ] && [ -f "$DYLIB_X64" ] && command -v lipo &>/dev/null; then
    lipo -create "$DYLIB_ARM64" "$DYLIB_X64" -output "$STAGE/$EXT_DIR/libcolyseus.dylib"
elif [ -f "$DYLIB_ARM64" ]; then
    cp "$DYLIB_ARM64" "$STAGE/$EXT_DIR/libcolyseus.dylib"
elif [ -f "$DYLIB_X64" ]; then
    cp "$DYLIB_X64" "$STAGE/$EXT_DIR/libcolyseus.dylib"
fi

# Windows
copy_if_exists "$ZIG_OUT/windows/x64/colyseus.dll" "$STAGE/$EXT_DIR/colyseus.dll"

# Linux
copy_if_exists "$ZIG_OUT/linux/x64/libcolyseus.so" "$STAGE/$EXT_DIR/libcolyseus.so"

# WASM
copy_if_exists "$WASM_OUT/colyseus_wasm.js" "$STAGE/$EXT_DIR/colyseus_wasm.js"

# =========================================================================
# 3. Generate .yyp (project file)
# =========================================================================
cat > "$STAGE/$PACKAGE_NAME.yyp" << EOFYYP
{
  "\$GMProject":"v1",
  "%Name":"$PACKAGE_NAME",
  "AudioGroups":[
    {"\$GMAudioGroup":"v1","%Name":"audiogroup_default","exportDir":"","name":"audiogroup_default","resourceType":"GMAudioGroup","resourceVersion":"2.0","targets":-1}
  ],
  "configs":{"children":[],"name":"Default"},
  "defaultScriptType":0,
  "Folders":[],
  "ForcedPrefabProjectReferences":[],
  "IncludedFiles":[],
  "isEcma":false,
  "LibraryEmitters":[],
  "MetaData":{
    "IDEVersion":"2024.1400.4.1003",
    "PackageType":"Asset",
    "PackageName":"$PACKAGE_DISPLAY_NAME",
    "PackageID":"$PACKAGE_ID",
    "PackagePublisher":"Colyseus",
    "PackageVersion":"$VERSION"
  },
  "name":"$PACKAGE_NAME",
  "resources":[
    {"id":{"name":"${PACKAGE_ID}","path":"$EXT_DIR/Colyseus_SDK.yy"}},
    {"id":{"name":"Colyseus","path":"$SCRIPT_RESOURCE_DIR/Colyseus.yy"}}
  ],
  "resourceType":"GMProject",
  "resourceVersion":"2.0",
  "RoomOrderNodes":[],
  "templateType":null,
  "TextureGroups":[
    {"\$GMTextureGroup":"","%Name":"Default","autocrop":true,"border":2,"compressFormat":"bz2","customOptions":"","directory":"","groupParent":null,"isScaled":true,"loadType":"default","mipsToGenerate":0,"name":"Default","resourceType":"GMTextureGroup","resourceVersion":"2.0","targets":-1}
  ]
}
EOFYYP

# =========================================================================
# 4. Generate .resource_order
# =========================================================================
cat > "$STAGE/$PACKAGE_NAME.resource_order" << 'EOFRO'
{
  "FolderOrderSettings":[],
  "ResourceOrderSettings":[]
}
EOFRO

# =========================================================================
# 5. Generate metadata.json
# =========================================================================
cat > "$STAGE/metadata.json" << EOFMETA
{
  "package_id": "$PACKAGE_ID",
  "display_name": "$PACKAGE_NAME",
  "version": "$VERSION",
  "package_type": "asset",
  "ide_version": "2023.4.0.0"
}
EOFMETA

# =========================================================================
# 6. Generate yymanifest.xml with MD5 hashes
# =========================================================================

# Cross-platform MD5
calc_md5() {
    if command -v md5sum &>/dev/null; then
        md5sum "$1" | awk '{print toupper($1)}'
    else
        md5 -q "$1" | tr 'a-f' 'A-F'
    fi
}

{
    echo '<?xml version="1.0" encoding="utf-8"?>'
    echo '<files>'

    # Find all files relative to stage dir, skip .DS_Store
    cd "$STAGE"
    find . -type f ! -name '.DS_Store' ! -name 'yymanifest.xml' | sort | while read -r filepath; do
        # Strip leading ./
        relpath="${filepath#./}"
        hash=$(calc_md5 "$relpath")
        echo "	<file md5=\"$hash\">$relpath</file>"
    done

    echo '</files>'
} > "$STAGE/yymanifest.xml"

# =========================================================================
# 7. Create .yymps (zip)
# =========================================================================
YYMPS_FILE="$OUT_DIR/colyseus-gamemaker-${VERSION}.yymps"
rm -f "$YYMPS_FILE"
cd "$STAGE"
zip -r "$YYMPS_FILE" . -x '*.DS_Store'

echo ""
echo "=== Package complete ==="
echo "Output: $YYMPS_FILE"
echo ""
ls -lh "$YYMPS_FILE"
