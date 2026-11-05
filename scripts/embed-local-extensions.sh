#!/bin/bash
# Xcode post-resources step. An ordinary build never ships private ZIPs.
set -euo pipefail

destination="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/PreinstalledExtensions"
# Remove files left by an earlier opt-in build in the same DerivedData product.
if [[ -d "$destination" ]]; then
  /usr/bin/find "$destination" -type f -name '*.zip' -delete
fi

if [[ "${XTEND_EMBED_LOCAL_EXTENSIONS:-NO}" != "YES" ]]; then
  exit 0
fi

source_dir="${PROJECT_DIR:?}/Xtend/LocalExtensions"
if [[ ! -d "$source_dir" ]]; then
  echo "XTEND_EMBED_LOCAL_EXTENSIONS=YES requires Xtend/LocalExtensions/*.zip" >&2
  exit 1
fi

shopt -s nullglob
archives=("$source_dir"/*.zip)
if (( ${#archives[@]} == 0 )); then
  echo "XTEND_EMBED_LOCAL_EXTENSIONS=YES but no ZIPs found in $source_dir" >&2
  exit 1
fi

/bin/mkdir -p "$destination"
for archive in "${archives[@]}"; do
  /bin/cp -f "$archive" "$destination/"
  echo "Bundled local extension: $(basename "$archive")"
done
