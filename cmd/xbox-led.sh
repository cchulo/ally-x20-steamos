# SPDX-License-Identifier: GPL-2.0-only
# summary: the Xbox button light: on | off | brightness <0-3> | breathe on|off | node
#
# The light is driven by the controller MCU over the N-KEY configuration
# HID interface (0b05:1b4c, interface 2, the hidraw node whose report
# descriptor declares report ID 0x5a). The reports were captured from
# Armoury Crate 3.1.5 on Windows (docs/xbox-led-capture.md) and verified on
# an X20 on 2026-11-04:
#
#   on / off          5a d1 09 01 1f / 0f     feature report (SET_REPORT)
#   brightness 0-3    5d d1 20 01 <level>     output report (interrupt OUT)
#   breathe on / off  5a d1 21 02 01 08 / 00 08  feature report
#
# 0x09 is the "power LED mask" g-helper uses for the rings (low four bits);
# bit 0x10 is the Xbox button. The MCU keeps the settings while powered but
# not across a reboot. Nothing here touches the joystick rings.

_xbox_led_usage() {
    cat <<USAGE
usage: $AX20_NAME xbox-led [--hidraw <dev>] <command>

  on | off              switch the Xbox button light on or off
  brightness <0-3>      0 (dark) to 3 (brightest); the hardware has 4 steps
  breathe on|off        breathing effect, or steady light
  node                  print the hidraw node the commands are sent to

  --hidraw <dev>        use this hidraw node instead of auto-detecting it

Needs root (the hidraw node is root-only). The setting lasts until the next
reboot. See docs/rgb.md, "Xbox button light".
USAGE
}

# Where hidraw nodes are enumerated; tests point this at a fixture tree.
AX20_HIDRAW_SYS=${AX20_HIDRAW_SYS:-/sys/class/hidraw}

# xbox_led_find_node : print /dev/hidrawN of the N-KEY interface, or fail.
# 0b05:1b4c with report ID 0x5a (85 5a) in its report descriptor.
xbox_led_find_node() {
    local d id
    for d in "$AX20_HIDRAW_SYS"/hidraw*; do
        [ -r "$d/device/uevent" ] || continue
        id=$(tr '[:lower:]' '[:upper:]' <"$d/device/uevent")
        case "$id" in *HID_ID=0003:00000B05:00001B4C*) ;; *) continue ;; esac
        [ -r "$d/device/report_descriptor" ] || continue
        if od -An -v -tx1 "$d/device/report_descriptor" | tr -d ' \n' | grep -q '855a'; then
            printf '/dev/%s\n' "$(basename "$d")"
            return 0
        fi
    done
    return 1
}

# xbox_led_send <node> <feature|output> <hex bytes...> : one 64-byte report.
xbox_led_send() {
    local node=$1 kind=$2
    shift 2
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s %s <- %s\n' "$node" "$kind" "$*" >&2
        return 0
    fi
    ax20_have python3 || die "python3 is needed to send HID reports"
    log_debug "xbox-led: $kind $* -> $node"
    python3 -I - "$node" "$kind" "$@" <<'PY'
import fcntl, os, sys
node, kind, *hexbytes = sys.argv[1:]
buf = bytearray(64)
data = bytes(int(h, 16) for h in hexbytes)
buf[: len(data)] = data
fd = os.open(node, os.O_RDWR)
try:
    if kind == "feature":
        # HIDIOCSFEATURE(64) = _IOC(_IOC_WRITE | _IOC_READ, 'H', 0x06, 64)
        fcntl.ioctl(fd, (3 << 30) | (64 << 16) | (ord("H") << 8) | 0x06, bytes(buf))
    else:
        os.write(fd, bytes(buf))
finally:
    os.close(fd)
PY
}

cmd_xbox_led() {
    local node="" sub level
    while [ $# -gt 0 ]; do
        case "$1" in
            --hidraw)
                [ $# -ge 2 ] || die 2 "--hidraw needs a device"
                node=$2
                shift 2
                ;;
            --hidraw=*)
                node=${1#--hidraw=}
                shift
                ;;
            -h | --help | help)
                _xbox_led_usage
                return 0
                ;;
            -*) die 2 "unknown xbox-led option: $1" ;;
            *) break ;;
        esac
    done
    sub=${1:-}
    [ -n "$sub" ] || {
        _xbox_led_usage >&2
        return 2
    }
    shift

    case "$sub" in
        on | off)
            [ $# -eq 0 ] || die 2 "usage: $AX20_NAME xbox-led $sub"
            ;;
        brightness)
            level=${1:-}
            case "$level" in
                [0-3]) ;;
                *) die 2 "usage: $AX20_NAME xbox-led brightness <0-3>" ;;
            esac
            [ $# -eq 1 ] || die 2 "usage: $AX20_NAME xbox-led brightness <0-3>"
            ;;
        breathe)
            case "${1:-}" in
                on | off) ;;
                *) die 2 "usage: $AX20_NAME xbox-led breathe on|off" ;;
            esac
            [ $# -eq 1 ] || die 2 "usage: $AX20_NAME xbox-led breathe on|off"
            ;;
        node)
            [ $# -eq 0 ] || die 2 "usage: $AX20_NAME xbox-led node"
            ;;
        *)
            log_error "unknown xbox-led command: $sub"
            _xbox_led_usage >&2
            return 2
            ;;
    esac

    if [ -z "$node" ]; then
        node=$(xbox_led_find_node) || die "no 0b05:1b4c hidraw node with report ID 0x5a found (is this an X20? pass --hidraw)"
    fi
    if [ "$sub" = node ]; then
        printf '%s\n' "$node"
        return 0
    fi

    [ "$AX20_DRY_RUN" = 1 ] || require_root xbox-led "$sub" "$@"
    case "$sub" in
        on)
            xbox_led_send "$node" feature 5a d1 09 01 1f
            log_info "xbox-led: on"
            ;;
        off)
            xbox_led_send "$node" feature 5a d1 09 01 0f
            log_info "xbox-led: off"
            ;;
        brightness)
            xbox_led_send "$node" output 5d d1 20 01 "0$level"
            log_info "xbox-led: brightness $level"
            ;;
        breathe)
            if [ "$1" = on ]; then
                xbox_led_send "$node" feature 5a d1 21 02 01 08
            else
                xbox_led_send "$node" feature 5a d1 21 02 00 08
            fi
            log_info "xbox-led: breathe $1"
            ;;
    esac
}
