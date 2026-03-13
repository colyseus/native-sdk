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
PACKAGE_NAME="Colyseus SDK"
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

# Copy Colyseus_SDK.yy — fix parent references, version, and split per-platform file entries
# The source .yy has a single native file entry (macOS dylib) targeting all platforms.
# Split it into per-platform entries so each platform loads the correct binary.
#
# IMPORTANT: jq 1.6 (Ubuntu CI) uses double-precision floats which corrupt 64-bit integers
# like copyToTargets (3026418979657744622 → 3026418979657744384, losing platform bits).
# We use -1 (all platforms) for copyToTargets to avoid this. GameMaker will attempt to load
# all native files on each platform — the wrong-format ones fail silently and the correct
# one succeeds.
fix_trailing_commas "$EXAMPLE/$EXT_DIR/Colyseus_SDK.yy" | jq \
  --arg ver "$VERSION" --arg name "$PACKAGE_NAME" --arg path "$PACKAGE_NAME.yyp" '
  .parent = { "name": $name, "path": $path } |
  .extensionVersion = $ver |
  .copyToTargets = -1 |
  .files as $orig_files |
  .files = [
    ($orig_files[0] | .filename = "libcolyseus.dylib" | .copyToTargets = -1),
    ($orig_files[0] | .filename = "colyseus.dll" | .copyToTargets = -1),
    ($orig_files[0] | .filename = "libcolyseus.so" | .copyToTargets = -1),
    ($orig_files[1] | .copyToTargets = 32)
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

copy_if_exists "$ZIG_OUT/macos/arm64/libcolyseus.dylib" "$STAGE/$EXT_DIR/libcolyseus.dylib"

# macOS
for arch in arm64 x64; do
    copy_if_exists "$ZIG_OUT/macos/$arch/libcolyseus.dylib" "$STAGE/$EXT_DIR/macos/$arch/libcolyseus.dylib"
done

# iOS
copy_if_exists "$ZIG_OUT/ios/arm64/libcolyseus.dylib" "$STAGE/$EXT_DIR/ios/arm64/libcolyseus.dylib"

# Linux (root file for GameMaker to load + arch subdir)
copy_if_exists "$ZIG_OUT/linux/x64/libcolyseus.so" "$STAGE/$EXT_DIR/libcolyseus.so"
copy_if_exists "$ZIG_OUT/linux/x64/libcolyseus.so" "$STAGE/$EXT_DIR/linux/x64/libcolyseus.so"

# Windows (root file for GameMaker to load + arch subdir)
copy_if_exists "$ZIG_OUT/windows/x64/colyseus.dll" "$STAGE/$EXT_DIR/colyseus.dll"
copy_if_exists "$ZIG_OUT/windows/x64/colyseus.dll" "$STAGE/$EXT_DIR/windows/x64/colyseus.dll"
copy_if_exists "$ZIG_OUT/windows/x64/colyseus.pdb" "$STAGE/$EXT_DIR/windows/x64/colyseus.pdb"

# Android
for arch in arm64 arm32 x64; do
    copy_if_exists "$ZIG_OUT/android/$arch/libcolyseus.so" "$STAGE/$EXT_DIR/android/$arch/libcolyseus.so"
done

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
    "PackageName":"$PACKAGE_NAME",
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
