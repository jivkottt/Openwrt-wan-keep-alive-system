#!/bin/sh

echo "==== Instalation WAN Keep-Alive ===="

# 1. Check openwrt pakage manager (apk or opkg)
if command -v apk >/dev/null 2>&1; then
    echo "apk software menager available. Updating and instaling..."
    apk update
    apk add luci-compat
elif command -v opkg >/dev/null 2>&1; then
    echo "opkg software menager available. Updating and instaling..."
    opkg update
    opkg install luci-compat
else
    echo "ERROR: Missing apk or opkg software menager!"
    exit 1
fi

# 2. Creating direcrories
echo "Creating LuCI direcrories..."
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /etc/config
mkdir -p /usr/bin
mkdir -p /etc/init.d

# 3. Creating UCI configuration (/etc/config/wankeepalive)
echo "Creating /etc/config/wankeepalive..."
cat << 'EOF' > /etc/config/wankeepalive
config wankeepalive 'main'
	option enabled '1'
	option check_interval '120'
	option ping_hosts '1.1.1.1 8.8.8.8'
	option interface_fail_threshold '5'
	option router_fail_threshold '15'
	list target_interfaces 'lte'
EOF

# 4. Creating daemon script (/usr/bin/wan-keep-alive.sh)
echo "Creating /usr/bin/wan-keep-alive.sh..."
cat << 'EOF' > /usr/bin/wan-keep-alive.sh
#!/bin/sh

# Proverka na podrazbirahti se stoinosti i uci nastroiki
get_config() {
    ENABLED=$(uci -q get wankeepalive.main.enabled || echo "0")
    CHECK_INTERVAL=$(uci -q get wankeepalive.main.check_interval || echo "120")
    PING_HOSTS=$(uci -q get wankeepalive.main.ping_hosts || echo "1.1.1.1 8.8.8.8")
    IF_THRESHOLD=$(uci -q get wankeepalive.main.interface_fail_threshold || echo "5")
    ROUTER_THRESHOLD=$(uci -q get wankeepalive.main.router_fail_threshold || echo "15")
    TARGET_INTERFACES=$(uci -q get wankeepalive.main.target_interfaces)
}

FAIL_COUNT=0

logger -t wankeepalive "Uslugata e startirana uspeshno."

while true; do
    get_config

    if [ "$ENABLED" -ne 1 ]; then
        sleep 60
        continue
    fi

    ONLINE=0

    # Testvanie na vsichki zadani IP adresi
    for host in $PING_HOSTS; do
        if ping -c 2 -W 3 "$host" >/dev/null 2>&1; then
            ONLINE=1
            break
        fi
    done

    if [ $ONLINE -eq 1 ]; then
        if [ $FAIL_COUNT -gt 0 ]; then
            logger -t wankeepalive "Vruzkata e vuzstanovena. Zabyrsvane na broyacha."
            FAIL_COUNT=0
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        logger -t wankeepalive "Proverkata se provali! Posledovatelni greshki: $FAIL_COUNT"

        # 1. Restartirane na routera PRI TOCHNO SAVPADENIE na praga
        if [ $FAIL_COUNT -eq $ROUTER_THRESHOLD ]; then
            logger -t wankeepalive "Dostignat e pragat za restart na routera ($ROUTER_THRESHOLD greshki). Restartirane..."
            sync
            reboot
            exit 0
        fi

        # 2. Restartirane na interfeysite EDNOKRATNO PRI TOCHNO SAVPADENIE na praga
        if [ $FAIL_COUNT -eq $IF_THRESHOLD ]; then
            logger -t wankeepalive "Dostignat e pragat za restart na interfeysite ($IF_THRESHOLD greshki). Ednokratno restartirane..."
            for iface in $TARGET_INTERFACES; do
                logger -t wankeepalive "Restartirane na interfeys: $iface"
                ifdown "$iface"
                sleep 3
                ifup "$iface"
            done
            sleep 30
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
EOF

chmod +x /usr/bin/wan-keep-alive.sh

# 5. Creating init.d / procd service (/etc/init.d/wankeepalive)
echo "Creating /etc/init.d/wankeepalive..."
cat << 'EOF' > /etc/init.d/wankeepalive
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG=/usr/bin/wan-keep-alive.sh

start_service() {
    config_load wankeepalive
    
    local enabled
    config_get_bool enabled main enabled 0

    if [ "$enabled" -eq 1 ]; then
        procd_open_instance
        procd_set_param command "$PROG"
        procd_set_param respawn
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
    fi
}

reload_service() {
    stop
    start
}
EOF

chmod +x /etc/init.d/wankeepalive

# 6. Creating LuCI Controller
echo "Creating LuCI controller..."
cat << 'EOF' > /usr/lib/lua/luci/controller/wankeepalive.lua
module("luci.controller.wankeepalive", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/wankeepalive") then
        return
    end

    entry({"admin", "services", "wankeepalive"}, cbi("wankeepalive"), _("WAN Keep Alive"), 60).dependent = true
end
EOF

# 7. Creating LuCI Model (CBI)
echo "Creating LuCI CBI model..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/wankeepalive.lua
m = Map("wankeepalive", translate("WAN Keep Alive"), translate("Setting up automatic monitoring and restoration of the Internet connection."))

s = m:section(NamedSection, "main", "wankeepalive", translate("Main settings"))

-- ON / OFF
e = s:option(Flag, "enabled", translate("ON"))
e.rmempty = false

-- Ping Hostove
hosts = s:option(Value, "ping_hosts", translate("IP addresses for verification"), translate("Separated by a space (example: 1.1.1.1 8.8.8.8)"))
hosts.rmempty = false

-- Check interval
interval = s:option(Value, "check_interval", translate("Check interval (seconds)"), translate("Time between pings (example for 2 min: 120)"))
interval.datatype = "uinteger"
interval.rmempty = false

-- Selection of restart interfaces
ifaces = s:option(MultiValue, "target_interfaces", translate("Interfeysi za restart"), translate("Select which interface(s) to restart when the first threshold is reached"))
local uci = luci.model.uci.cursor()
uci:foreach("network", "interface", function(c)
    if c[".name"] ~= "loopback" then
        ifaces:value(c[".name"])
    end
end)

-- Interface restart threshold
if_thresh = s:option(Value, "interface_fail_threshold", translate("Errors for restarting interface(s)"), translate("Number of consecutive errors before restart of selected interfaces"))
if_thresh.datatype = "uinteger"
if_thresh.rmempty = false

-- Router restart threshold
r_thresh = s:option(Value, "router_fail_threshold", translate("Errors for Router restart"), translate("Number of consecutive errors before router restart"))
r_thresh.datatype = "uinteger"
r_thresh.rmempty = false

-- Number protection / validation
function r_thresh.validate(self, value, section)
    local if_val = tonumber(if_thresh:formvalue(section))
    local r_val = tonumber(value)
    
    if r_val and if_val and r_val <= if_val then
        return nil, translate("Error: The router restart threshold must be greater than the interface(s) restart threshold!")
    end
    return value
end

return m
EOF

# 8. Cleaning LuCI cash and restarting servicies
echo "Service activation and cash recharge..."
/etc/init.d/wankeepalive enable

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/wankeepalive restart

echo "==== Successful installation! WAN Keep-Alive is active on LuCI (Services -> WAN Keep Alive) ===="

# Remove instalation script.
rm -f "$0"
