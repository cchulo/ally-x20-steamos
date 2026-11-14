# SPDX-License-Identifier: GPL-2.0-only
# summary: the Xbox button light: on | off | brightness <0-3> | breathe on|off | restore | node
#
# The light is driven by the controller MCU over the N-KEY configuration
# HID interface (0b05:1b4c, interface 2, the hidraw node whose report
# descriptor declares report ID 0x5a). The reports were captured from
# Armoury Crate 3.1.5 on Windows (docs/xbox-led-capture.md) and verified on
# an X20 on 2026-11-04:
#
#   on / off          bit 0x10 of the LED power mask (5a d1 09 01 <mask>)
#   brightness 0-3    5d d1 20 01 <level>     output report (interrupt OUT)
#   breathe on / off  5a d1 21 02 01 08 / 00 08  feature report
#
# The power mask belongs to hid-asus-ally: it writes it at every probe (so a
# bare mask write is undone at the next boot) and its low bits carry the
# rings' sleep_animation setting. With patch 0016 the driver exposes the
# Xbox bit as the LED attribute xbox_button_light, and on/off write that
# plus a modprobe.d option so the driver sets it from boot on. Without the
# attribute (stock or older module) the mask is written directly, composed
# from the driver's default and its sleep_animation value, for this boot
# only. Brightness and breathing are not part of the mask and the controller
# resets them when its MCU is reinitialised (power-on, resume), so they are
# recorded in /etc/ally-x20-steamos/xbox-led.conf and re-sent by component
# `xboxled` (/etc/ally-x20-steamos/xbox-led-restore, started by a udev rule
# whenever the ring LED device appears and by a systemd unit after every
# resume); `restore` does the same by hand. Nothing here touches the
# joystick ring colours, and nothing is written to MCU flash.

# shellcheck source=lib/component.sh
. "$AX20_SRC/lib/component.sh"

_xbox_led_usage() {
    cat <<USAGE
usage: $AX20_NAME xbox-led [--hidraw <dev>] <command>

  on | off              switch the Xbox button light on or off
  brightness <0-3>      0 (dark) to 3 (brightest); the hardware has 4 steps
  breathe on|off        breathing effect, or steady light
  restore               re-send the recorded brightness and breathe setting
  node                  print the hidraw node the commands are sent to

  --hidraw <dev>        use this hidraw node instead of auto-detecting it

Needs root. on/off is kept by the patched hid-asus-ally (patch 0016);
brightness and breathe are recorded and re-sent at boot and after resume by
component xboxled. See docs/rgb.md, "Xbox button light".
USAGE
}

# Where hidraw nodes are enumerated; tests point this at a fixture tree.
AX20_HIDRAW_SYS=${AX20_HIDRAW_SYS:-/sys/class/hidraw}
# The ring LED device (its xbox_button_light and sleep_animation attributes).
AX20_LEDS_SYS=${AX20_LEDS_SYS:-/sys/class/leds}
# modprobe.d drop-in that makes the driver light the button from boot on.
XBOX_LED_MODPROBE_REL="/etc/modprobe.d/${AX20_NAME}-xbox-led.conf"
# brightness/breathe settings, re-sent at boot and after resume by `xboxled`.
XBOX_LED_CONF_REL="${AX20_EARLY_REL}/xbox-led.conf"

# xbox_led_conf_get <key> : value from the settings file, or nothing.
xbox_led_conf_get() {
    local f
    f=$(ax20_path "$XBOX_LED_CONF_REL")
    [ -r "$f" ] || return 0
    sed -n "s/^$1=//p" "$f" | head -n1
}

# xbox_led_conf_set <key> <value> : rewrite the settings file with this
# value and the other key's current one (manifest entry of component
# xboxled, so uninstall removes it).
xbox_led_conf_set() {
    local key=$1 val=$2 brightness breathe tmp
    brightness=$(xbox_led_conf_get brightness)
    breathe=$(xbox_led_conf_get breathe)
    case "$key" in
        brightness) brightness=$val ;;
        breathe) breathe=$val ;;
    esac
    if [ "$AX20_DRY_RUN" = 1 ]; then
        printf '[dry-run] %s <- brightness=%s breathe=%s\n' "$XBOX_LED_CONF_REL" "${brightness:-}" "${breathe:-}" >&2
        return 0
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-xbox-led.XXXXXX") || die "cannot create a temporary file"
    {
        printf '# Written by %s xbox-led; re-sent at boot and after resume by %s/xbox-led-restore.\n' "$AX20_NAME" "$AX20_EARLY_REL"
        [ -z "$brightness" ] || printf 'brightness=%s\n' "$brightness"
        [ -z "$breathe" ] || printf 'breathe=%s\n' "$breathe"
    } >"$tmp"
    manifest_install_file "$tmp" "$XBOX_LED_CONF_REL" xboxled 0644
    rm -f "$tmp"
}

# xbox_led_send_breathe <node> <on|off>
xbox_led_send_breathe() {
    if [ "$2" = on ]; then
        xbox_led_send "$1" feature 5a d1 21 02 01 08
    else
        xbox_led_send "$1" feature 5a d1 21 02 00 08
    fi
}

# xbox_led_dev : print the ring LED sysfs directory, or nothing.
xbox_led_dev() {
    local d
    for d in "$AX20_LEDS_SYS"/go_s:rgb:joystick_rings "$AX20_LEDS_SYS"/ally:rgb:joystick_rings; do
        [ -d "$d" ] && printf '%s\n' "$d" && return 0
    done
    return 1
}

# xbox_led_power <on|off> <hidraw node> : switch the light.
# 1. driver attribute (patch 0016): write it, and record the choice for the
#    next boot in a modprobe.d option (manifest entry of component modules,
#    so uninstall removes it).
# 2. no attribute: write the mask once, keeping the driver's sleep bit.
xbox_led_power() {
    local want=$1 node=$2 led val sleep mask tmp
    val=0
    [ "$want" = on ] && val=1
    led=$(xbox_led_dev || true)
    if [ -n "$led" ] && [ -e "$led/xbox_button_light" ]; then
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] %s/xbox_button_light <- %s\n' "$led" "$val" >&2
        else
            printf '%s\n' "$val" >"$led/xbox_button_light" || die "writing $led/xbox_button_light failed"
        fi
        tmp=$(mktemp "${TMPDIR:-/tmp}/ax20-xbox-led.XXXXXX") || die "cannot create a temporary file"
        printf '# Written by %s xbox-led %s. Lights the Xbox button from boot on.\n' "$AX20_NAME" "$want" >"$tmp"
        printf 'options hid-asus-ally xbox_button_light=%s\n' "$val" >>"$tmp"
        if [ "$AX20_DRY_RUN" = 1 ]; then
            printf '[dry-run] %s <- xbox_button_light=%s\n' "$XBOX_LED_MODPROBE_REL" "$val" >&2
        else
            manifest_install_file "$tmp" "$XBOX_LED_MODPROBE_REL" modules 0644
        fi
        rm -f "$tmp"
        log_info "xbox-led: $want (kept across reboots)"
        return 0
    fi
    # Fallback: the driver's default mask (boot | awake | shutdown = 0x0b)
    # plus its sleep_animation bit, plus the Xbox bit. Lost at the next boot.
    sleep=0
    if [ -n "$led" ] && [ -r "$led/sleep_animation" ]; then
        sleep=$(cat "$led/sleep_animation")
    fi
    mask=$((0x0b | (sleep ? 0x04 : 0) | (val ? 0x10 : 0)))
    xbox_led_send "$node" feature 5a d1 09 01 "$(printf '%02x' "$mask")"
    log_info "xbox-led: $want (until the next reboot: this hid-asus-ally has no xbox_button_light attribute)"
}

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
    local node="" sub level breathe
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
        node | restore)
            [ $# -eq 0 ] || die 2 "usage: $AX20_NAME xbox-led $sub"
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
        on | off) xbox_led_power "$sub" "$node" ;;
        brightness)
            xbox_led_send "$node" output 5d d1 20 01 "0$level"
            xbox_led_conf_set brightness "$level"
            log_info "xbox-led: brightness $level (re-sent at boot and after resume)"
            ;;
        breathe)
            xbox_led_send_breathe "$node" "$1"
            xbox_led_conf_set breathe "$1"
            log_info "xbox-led: breathe $1 (re-sent at boot and after resume)"
            ;;
        restore)
            level=$(xbox_led_conf_get brightness)
            breathe=$(xbox_led_conf_get breathe)
            [ -z "$breathe" ] || xbox_led_send_breathe "$node" "$breathe"
            [ -z "$level" ] || xbox_led_send "$node" output 5d d1 20 01 "0$level"
            if [ -z "$level$breathe" ]; then
                log_info "xbox-led: nothing recorded in $XBOX_LED_CONF_REL"
            else
                log_info "xbox-led: restored brightness=${level:-unchanged} breathe=${breathe:-unchanged}"
            fi
            ;;
    esac
}
