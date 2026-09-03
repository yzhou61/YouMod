#!/usr/bin/env bash
# Dispatch the "Build IPA with tweaks" workflow on the fork and wait for the draft release.
#
#   tools/build-ipa.sh <ipa_url> [branch]
#
# The tweak set below mirrors the checkboxes of the last hand-run build; edit it here.
set -euo pipefail

IPA_URL=${1:?usage: $0 <ipa_url> [branch]}
BRANCH=${2:-main}
REPO=yzhou61/YouMod

DISPLAY_NAME=YouTube
BUNDLE_ID=com.google.ios.youtube

# Integrate ... checkboxes. Every one is on by default in the workflow except youquality,
# so each has to be passed explicitly or the defaults silently win.
YOUPIP=false
YTUHD=true
RYD=true
ABCONFIG=false
YOUQUALITY=false
DEMC=false
YTWEAKS=false
YOUSLIDER=false
GONERINO=false
YTSHARE=true
VOLBOOST=false

before=$(gh run list -R "$REPO" --workflow ipa.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')

gh workflow run ipa.yml -R "$REPO" --ref "$BRANCH" \
  -f repo="$REPO" \
  -f branch="$BRANCH" \
  -f ipa_url="$IPA_URL" \
  -f display_name="$DISPLAY_NAME" \
  -f bundle_id="$BUNDLE_ID" \
  -f youpip="$YOUPIP" -f ytuhd="$YTUHD" -f ryd="$RYD" -f abconfig="$ABCONFIG" \
  -f youquality="$YOUQUALITY" -f demc="$DEMC" -f ytweaks="$YTWEAKS" -f youslider="$YOUSLIDER" \
  -f gonerino="$GONERINO" -f ytshare="$YTSHARE" -f volboost="$VOLBOOST"

# The dispatch returns before the run exists; poll until a newer one shows up.
run=$before
for _ in $(seq 1 30); do
  sleep 5
  run=$(gh run list -R "$REPO" --workflow ipa.yml --limit 1 --json databaseId --jq '.[0].databaseId // 0')
  [ "$run" != "$before" ] && break
done
[ "$run" != "$before" ] || { echo "run did not appear" >&2; exit 1; }

echo "run $run: https://github.com/$REPO/actions/runs/$run"
gh run watch "$run" -R "$REPO" --exit-status --interval 30 > /dev/null

tag=$(gh release list -R "$REPO" --limit 1 --json tagName --jq '.[0].tagName')
echo "release: https://github.com/$REPO/releases/tag/$tag"
gh release view "$tag" -R "$REPO" --json assets --jq '.assets[].name'
