#!/usr/bin/env bash
# App Store screenshots: capture, frame, and fit to the sizes Apple accepts.
#
# Usage:
#   Tools/screenshots.sh devices              what this knows how to shoot
#   Tools/screenshots.sh prepare iphone       boot it, tidy the status bar, launch the app
#   Tools/screenshots.sh shot iphone boards   capture what is on screen right now
#   Tools/screenshots.sh frame                frame every capture and fit it to each slot
#   Tools/screenshots.sh clean                throw the lot away
#
# Capturing is deliberately a separate step from framing, and deliberately
# manual: the screens worth showing are a few taps in, and nothing here knows
# which ones you want. Navigate, run `shot`, repeat; `frame` at the end.
#
# The App Store build is what gets installed, not the ordinary one. Its board
# list is the narrowed one, so the screenshots show what a buyer will actually
# see rather than a catalogue the shipped app does not have.
set -euo pipefail

cd "$(dirname "$0")/.."

# Kept out of git -- see .gitignore. These are large, regenerable, and a store
# listing's artwork is not source.
ROOT="Screenshots"
RAW="$ROOT/raw"
OUT="$ROOT/appstore"

# What sits behind the device.
#
# `gradient` (the default) reads the screenshot's own palette and builds a
# two-stop gradient from it, so the backdrop belongs to the picture rather than
# being a colour someone picked once. Pass a hex colour instead for a flat one:
#   BACKGROUND=#000000 Tools/screenshots.sh frame
BACKGROUND="${BACKGROUND:-gradient}"

# Captions drawn above the device, as `name|text` lines. One line covers that
# screenshot on every device and every size, which is the point: the same screen
# should not be captioned two different ways on iPhone and iPad.
TITLES="${TITLES:-Tools/screenshot-titles.txt}"

# San Francisco, which is the typeface the screenshots themselves are set in.
# A web tool would reach for a lookalike; this is the real one, and it is on
# every Mac.
TITLE_FONT="${TITLE_FONT:-/System/Library/Fonts/SFNS.ttf}"

# Weight comes from a stroke in the text's own colour, not from `-weight`:
# San Francisco ships as one variable file with no separate bold cut, and
# ImageMagick here has no fontconfig to resolve a face name against. Drawing
# the glyphs and thickening their outline is what is left, and at this size it
# is indistinguishable from a real bold.
TITLE_STROKE="${TITLE_STROKE:-2}"

# A soft drop shadow: opacity x blur + offset. Not decoration -- white text on a
# mid-tone gradient is legible in the middle and vanishes where the gradient
# runs light, and the shadow is what holds it together across the whole range.
TITLE_SHADOW="${TITLE_SHADOW:-70x10+0+8}"

# How much of the canvas height the device occupies. The rest is headroom above
# it, which is where a title goes if you add one; the device is anchored to the
# bottom edge and clipped there, the way App Store artwork usually is.
DEVICE_HEIGHT="${DEVICE_HEIGHT:-0.86}"

# device key -> simulator name
simulator_for() {
    case "$1" in
        iphone) echo "iPhone 17 Pro" ;;
        ipad)   echo "iPad Air 13-inch (M4)" ;;
        *) return 1 ;;
    esac
}

# device key -> the slots Apple offers, as `name:WIDTHxHEIGHT`.
#
# A slot is a canvas size, not the device's own resolution: the framed device is
# fitted into it. iPhone 17 Pro shoots at 1206x2622, which is neither slot, and
# both are produced from the one capture.
#
# iPad is not optional here. The app declares `UIDeviceFamily = [1, 2]`, and App
# Store Connect will not take a submission from an iPad-capable app without it.
slots_for() {
    case "$1" in
        iphone) echo "iphone-6.9:1320x2868 iphone-6.5:1242x2688" ;;
        ipad)   echo "ipad-13:2048x2732" ;;
        *) return 1 ;;
    esac
}

DEVICES="iphone ipad"

udid_for() {
    local name
    name="$(simulator_for "$1")"
    xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
found = [d['udid'] for runtime in devices.values() for d in runtime if d['name'] == '''$name''']
print(found[0] if found else '')
"
}

require_tools() {
    local missing=()
    command -v fastlane >/dev/null || missing+=("fastlane (brew install fastlane)")
    command -v magick >/dev/null || missing+=("imagemagick (brew install imagemagick)")
    if [ ${#missing[@]} -gt 0 ]; then
        printf 'missing: %s\n' "${missing[@]}" >&2
        exit 1
    fi
    # frameit refuses without these, and the download is a one-time few hundred
    # megabytes, so it is checked rather than run on every invocation.
    if [ ! -d "$HOME/.fastlane/frameit/latest" ]; then
        echo "device frames are not downloaded: fastlane frameit download_frames" >&2
        exit 1
    fi
}

# Two hex colours for a gradient, read off the screenshot.
#
# Saturation decides, not frequency. A light interface is almost entirely
# near-white -- on this app's board list, one grey accounts for more pixels than
# everything else together -- and the colour worth building a backdrop from is
# the accent, which is a few hundred pixels of orange. Frequency still breaks
# ties, dampened by a fourth root so it cannot overrule saturation.
#
# The pair stays inside one hue family, light at the top and deep at the bottom.
# Rotating further looks livelier on a mockup and muddy on a real screenshot: a
# warm accent swung towards green lands on olive.
gradient_for() {
    python3 - "$1" <<'PYTHON'
import colorsys, re, subprocess, sys

raw = subprocess.run(
    ["magick", sys.argv[1], "-resize", "120x120", "-colors", "16",
     "-format", "%c", "histogram:info:-"],
    capture_output=True, text=True).stdout

candidates = []
for line in raw.splitlines():
    match = re.search(r"^\s*(\d+):.*?#([0-9A-Fa-f]{6})", line)
    if not match:
        continue
    count, hexa = int(match.group(1)), match.group(2)
    r, g, b = (int(hexa[i:i + 2], 16) / 255 for i in (0, 2, 4))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    if 0.12 < v < 0.97 and s > 0.12:
        candidates.append((s * (count ** 0.25), h, s, v))

def rgb(h, s, v):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, max(0.0, min(1.0, s)), max(0.0, min(1.0, v)))
    return "#%02X%02X%02X" % (round(r * 255), round(g * 255), round(b * 255))

if not candidates:
    # A screenshot with no colour in it at all -- a plain list on a grey
    # background, say. Charcoal reads as deliberate; a washed-out grey gradient
    # reads as a mistake.
    print("#3A3A3C #1C1C1E")
else:
    _, h, s, v = max(candidates)
    print(rgb(h - 0.015, s * 1.55, 0.92), rgb(h + 0.015, s * 1.75, 0.46))
PYTHON
}

# The caption for a screenshot, or nothing if it has none.
title_for() {
    [ -f "$TITLES" ] || return 0
    awk -F'|' -v want="$1" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 == want { sub(/^[^|]*\|/, ""); print; exit }
    ' "$TITLES"
}

cmd_devices() {
    for device in $DEVICES; do
        printf '%-8s %-24s %s\n' "$device" "$(simulator_for "$device")" "$(slots_for "$device")"
    done
}

cmd_prepare() {
    local device="${1:-}"
    [ -n "$device" ] || { echo "usage: $0 prepare <device>" >&2; exit 1; }
    local udid
    udid="$(udid_for "$device")"
    [ -n "$udid" ] || { echo "no simulator named '$(simulator_for "$device")'" >&2; exit 1; }

    xcrun simctl boot "$udid" 2>/dev/null || true
    open -a Simulator >/dev/null 2>&1 || true

    # The marketing status bar. Apple does not require it, but a real one dates
    # the screenshot and shows whatever the host's wifi was doing.
    xcrun simctl status_bar "$udid" override \
        --time "09:41" \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState charged --batteryLevel 100 2>/dev/null || true

    make appstore SIMULATOR="$(simulator_for "$device")"

    echo
    echo "Navigate to the screen you want, then:"
    echo "  $0 shot $device <name>"
}

cmd_shot() {
    local device="${1:-}" name="${2:-}"
    [ -n "$device" ] && [ -n "$name" ] || { echo "usage: $0 shot <device> <name>" >&2; exit 1; }
    local udid
    udid="$(udid_for "$device")"
    [ -n "$udid" ] || { echo "no simulator for '$device'" >&2; exit 1; }

    mkdir -p "$RAW/$device"
    local path="$RAW/$device/$name.png"
    xcrun simctl io "$udid" screenshot "$path" >/dev/null 2>&1
    printf '%s  %s\n' "$(sips -g pixelWidth -g pixelHeight "$path" | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/ /;s/pixelHeight:/x/')" "$path"
}

cmd_frame() {
    require_tools
    local any=0

    for device in $DEVICES; do
        local dir="$RAW/$device"
        # `find` rather than a glob: a device with nothing shot yet must not
        # stop the ones that do have captures.
        [ -d "$dir" ] && [ -n "$(find "$dir" -name '*.png' ! -name '*_framed.png' -print -quit)" ] || continue

        echo "==> $device"
        # frameit writes `<name>_framed.png` beside each input, matching a
        # device frame by the capture's resolution -- which is why the frame
        # list having no iPhone 17 does not matter: the 16 Pro is the same
        # 1206x2622 and is chosen on that basis.
        ( cd "$dir" && fastlane frameit >/dev/null 2>&1 ) || {
            echo "   frameit failed in $dir" >&2
            continue
        }

        for slot in $(slots_for "$device"); do
            local label="${slot%%:*}" size="${slot##*:}"
            mkdir -p "$OUT/$label"
            for framed in "$dir"/*_framed.png; do
                [ -e "$framed" ] || continue
                local base
                base="$(basename "$framed" _framed.png)"
                local width="${size%%x*}" height="${size##*x}"
                local device_px
                device_px="$(python3 -c "print(round($height * $DEVICE_HEIGHT))")"

                # The backdrop, either derived or flat.
                local canvas="$dir/.canvas-$label.png"
                if [ "$BACKGROUND" = "gradient" ]; then
                    # Read off the raw capture rather than the framed one: same
                    # pixels, without a frame's chrome voting on the palette.
                    local stops
                    stops="$(gradient_for "$dir/$base.png")"
                    magick -size "$size" -define gradient:angle=160 \
                        "gradient:${stops% *}-${stops#* }" "$canvas"
                else
                    magick -size "$size" "xc:$BACKGROUND" "$canvas"
                fi

                # `-trim +repage` first, or the device sits small in the middle
                # of a wide margin: frameit surrounds it with transparent
                # padding, and scaling the padded image scales the padding too.
                #
                # `-alpha remove -alpha off` last is not optional: that padding
                # is an alpha channel, and App Store Connect rejects any
                # screenshot carrying one. It is the failure that shows up at
                # upload, long after the picture looks right.
                magick "$framed" -trim +repage -resize "x$device_px" "$dir/.device.png"
                magick "$canvas" "$dir/.device.png" \
                    -gravity south -geometry +0+0 -composite \
                    "$dir/.composed.png"

                local title
                title="$(title_for "$base")"
                if [ -n "$title" ]; then
                    # `caption:` rather than `annotate`, so a line too long for
                    # the canvas wraps instead of running off the edge.
                    # Measured against the headroom the device left above it.
                    local text_width point_size
                    text_width="$(python3 -c "print(round($width * 0.82))")"
                    point_size="$(python3 -c "print(round($width * 0.062))")"
                    magick -background none -fill white \
                        -stroke white -strokewidth "$TITLE_STROKE" \
                        -font "$TITLE_FONT" -pointsize "$point_size" \
                        -size "${text_width}x" -gravity center \
                        caption:"$title" "$dir/.title.png"
                    magick "$dir/.title.png" \
                        \( +clone -background black -shadow "$TITLE_SHADOW" \) \
                        +swap -background none -layers merge +repage \
                        "$dir/.title.png"
                    # Centred in the band above the device rather than pinned to
                    # the top edge, so one line and two lines both sit right.
                    local band top
                    band="$(python3 -c "print($height - $device_px)")"
                    top="$(python3 -c "
import subprocess
h = int(subprocess.run(['magick','identify','-format','%h','$dir/.title.png'],
                       capture_output=True, text=True).stdout)
print(max(0, round(($band - h) / 2)))")"
                    magick "$dir/.composed.png" "$dir/.title.png" \
                        -gravity north -geometry +0+"$top" -composite \
                        "$dir/.composed.png"
                    rm -f "$dir/.title.png"
                fi

                magick "$dir/.composed.png" -alpha remove -alpha off "$OUT/$label/$base.png"
                rm -f "$dir/.composed.png"
                rm -f "$canvas" "$dir/.device.png"
                any=1
            done
            echo "   $label -> $OUT/$label"
        done

        rm -f "$dir"/*_framed.png
    done

    [ "$any" -eq 1 ] || { echo "nothing captured yet: $0 prepare <device>" >&2; exit 1; }

    echo
    echo "Ready to upload:"
    find "$OUT" -name '*.png' | sort | while read -r file; do
        printf '  %-22s %s\n' "$(sips -g pixelWidth -g pixelHeight "$file" | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/ /;s/pixelHeight:/x/')" "$file"
    done
}

cmd_clean() {
    rm -rf "$ROOT"
    echo "removed $ROOT"
}

case "${1:-}" in
    devices) cmd_devices ;;
    prepare) shift; cmd_prepare "$@" ;;
    shot)    shift; cmd_shot "$@" ;;
    frame)   cmd_frame ;;
    clean)   cmd_clean ;;
    *)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
