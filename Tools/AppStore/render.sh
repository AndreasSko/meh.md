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

# The raw captures one slide uses, from its layout in shots.js
captures() {
  python3 -c '
import re, sys
layouts = open("shots.js").read().split("const layouts", 1)[1]
device = re.search(r"\n  %s: \{(.*?)\n  \}," % sys.argv[1], layouts, re.S).group(1)
slide = re.search(r"\n    %s: \[(.*?)\],\n" % sys.argv[2], device + "\n", re.S).group(1)
print("\n".join(sorted(set(re.findall(r"img: \"([^\"]*)\"", slide)))))
' "$1" "$2"
}

for device in iphone ipad mac; do
  mkdir -p "out/$device"
  rm -f out/$device/*.png(N)
  shots=(${=names[$device]})
  for i in {1..${#shots}}; do
    out="$PWD/out/$device/$i-${shots[$i]}.png"
    # Chrome renders a missing image as a blank spot, so skip the slide
    missing=()
    for img in $(captures $device ${shots[$i]}); do
      [[ -f "raw/$img.png" ]] || missing+=("raw/$img.png")
    done
    if (( ${#missing} )); then
      print -u2 "Skipped $device ${shots[$i]}, missing ${missing[*]}; run capture.sh"
      continue
    fi
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
      --window-size="${size[$device]}" --virtual-time-budget=2000 \
      --allow-file-access-from-files --screenshot="$out" \
      "file://$PWD/template.html?device=$device&name=${shots[$i]}" 2>/dev/null
    echo "$out"
  done
done
