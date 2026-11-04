#!/bin/zsh
# Renders App Store screenshots from raw/ into out/, using shots.js
set -euo pipefail
cd "${0:A:h}"

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
typeset -A size=(iphone 1320,2868 ipad 2048,2732 mac 2880,1800)
typeset -A names=(
  iphone "note recents sync history snippets widgets"
  ipad "note recents sync history snippets widgets"
  mac "note recents sync history snippets"
)

# Chrome renders a missing image as a blank spot, so check every capture first
missing=()
for img in $(grep -o 'img: "[^"]*"' shots.js | cut -d'"' -f2 | sort -u); do
  [[ -f "raw/$img.png" ]] || missing+=("raw/$img.png")
done
if (( ${#missing} )); then
  print -u2 "Missing raw screenshots, run capture.sh first:"
  print -u2 -l "  "${^missing}
  exit 1
fi

for device in iphone ipad mac; do
  mkdir -p "out/$device"
  rm -f out/$device/*.png(N)
  shots=(${=names[$device]})
  for i in {1..${#shots}}; do
    out="$PWD/out/$device/$i-${shots[$i]}.png"
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --window-size="${size[$device]}" --virtual-time-budget=2000 \
      --allow-file-access-from-files --screenshot="$out" \
      "file://$PWD/template.html?device=$device&name=${shots[$i]}" 2>/dev/null
    echo "$out"
  done
done
