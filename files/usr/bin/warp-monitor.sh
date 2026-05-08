#!/bin/sh

INTERFACE="warp"
TEST_IP="1.1.1.1"
STATE_FILE="/tmp/warp_state"

# Check if interface exists
if ! ip link show dev $INTERFACE >/dev/null 2>&1; then
    STATUS=1
else
    # Ping 3 times, wait 2s max per ping
    if ping -c 3 -W 2 -I $INTERFACE $TEST_IP >/dev/null 2>&1; then
        STATUS=0
    else
        STATUS=1
    fi
fi

PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null)
[ -z "$PREV_STATE" ] && PREV_STATE=0

if [ "$STATUS" -eq 0 ] && [ "$PREV_STATE" -ne 0 ]; then
    logger -t warp-monitor "WARP is UP. Enabling PBR rules."
    for section in $(uci show pbr | grep "=policy" | cut -d. -f2 | cut -d= -f1); do
        if [ "$(uci -q get pbr.$section.interface)" = "$INTERFACE" ]; then
            uci set pbr.$section.enabled=1
        fi
    done
    uci commit pbr
    /etc/init.d/pbr reload
    echo 0 > "$STATE_FILE"

elif [ "$STATUS" -ne 0 ] && [ "$PREV_STATE" -eq 0 ]; then
    logger -t warp-monitor "WARP is DOWN. Disabling PBR rules."
    for section in $(uci show pbr | grep "=policy" | cut -d. -f2 | cut -d= -f1); do
        if [ "$(uci -q get pbr.$section.interface)" = "$INTERFACE" ]; then
            uci set pbr.$section.enabled=0
        fi
    done
    uci commit pbr
    /etc/init.d/pbr reload
    echo 1 > "$STATE_FILE"
fi
