#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 /path/to/Tshunhue.app /path/to/output.dmg [notary-keychain-profile]" >&2
  exit 64
fi

app_path=$1
output_path=$2
notary_profile=${3-}
staging_path=$(mktemp -d /tmp/tshunhue-dmg.XXXXXX)
trap 'rm -rf "$staging_path"' EXIT

cp -R "$app_path" "$staging_path/Tshunhue.app"
ln -s /Applications "$staging_path/Applications"
hdiutil create -quiet -volname Tshunhue -srcfolder "$staging_path" -ov -format UDZO "$output_path"

if [ -n "$notary_profile" ]; then
  xcrun notarytool submit "$output_path" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$output_path"
  xcrun stapler validate "$output_path"
fi

shasum -a 256 "$output_path" > "$output_path.sha256"
