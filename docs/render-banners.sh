#!/bin/sh
# Renders docs/banner-{en,uk}.png from docs/banner.html and the donate buttons from docs/support.html with headless Chrome.
set -e
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
cd "$(dirname "$0")/.."
python3 -m http.server 8798 -b 127.0.0.1 >/dev/null 2>&1 & SERVER=$!
trap 'kill $SERVER' EXIT
sleep 1
for lang in en uk; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=1600,560 \
    --virtual-time-budget=3000 --screenshot="docs/banner-$lang.png" "http://127.0.0.1:8798/docs/banner.html?lang=$lang" 2>/dev/null
  for id in kofi bmc mono; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --window-size=560,150 \
      --default-background-color=00000000 --virtual-time-budget=3000 --screenshot="docs/support-$id-$lang.png" \
      "http://127.0.0.1:8798/docs/support.html?id=$id&lang=$lang" 2>/dev/null
  done
done
echo "rendered docs/banner-{en,uk}.png and docs/support-*.png"
