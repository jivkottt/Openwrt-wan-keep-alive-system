#!/bin/sh

echo "==== Startirane na automatichnata instalaciya na WAN Keep-Alive ===="

# 1. Proverka na paketniya menidzhar (apk ili opkg)
if command -v apk >/dev/null 2>&1; then
    echo "Nameren e apk menidzhar. Obnovyavane i instalirane..."
    apk update
    apk add luci-compat
elif command -v opkg >/dev/null 2>&1; then
    echo "Nameren e opkg menidzhar. Obnovyavane i instalirane..."
    opkg update
    opkg install luci-compat
else
    echo "Greshka: Ne e nameren nito apk, nito opkg!"
    exit 1
fi

# 2. Sazdavane na neobhodimite papki
echo "Sazdavane na direktorii za LuCI..."
mkdir -p /usr/lib/lua/luci/model/cbi
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /etc/config
mkdir -p /usr/bin
mkdir -p /etc/init.d

# 3. Sazdavane na UCI konfiguratsiyata (/etc/config/wankeepalive)
echo "Sazdavane na /etc/config/wankeepalive..."
cat << 'EOF' > /etc/config/wankeepalive
config wankeepalive 'main'
	option enabled '1'
	option check_interval '120'
	option ping_hosts '1.1.1.1 8.8.8.8'
	option interface_fail_threshold '5'
	option router_fail_threshold '15'
	list target_interfaces 'lte'
EOF

# 4. Sazdavane na osnovniya daemon script (/usr/bin/wan-keep-alive.sh)
echo "Sazdavane na /usr/bin/wan-keep-alive.sh..."
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

        # Logika za restartirane na routera (pri dostiganie na po-visokia prag)
        if [ $FAIL_COUNT -ge $ROUTER_THRESHOLD ]; then
            logger -t wankeepalive "Dostignat e pragat za restart na routera ($ROUTER_THRESHOLD greshki). Restartirane..."
            sync
            reboot
            exit 0
        fi

        # Logika za restartirane na izbranite interfeysi
        if [ $FAIL_COUNT -ge $IF_THRESHOLD ]; then
            logger -t wankeepalive "Dostignat e pragat za restart na interfeysite ($IF_THRESHOLD greshki)."
            for iface in $TARGET_INTERFACES; do
                logger -t wankeepalive "Restartirane na interfeys: $iface"
                ifdown "$iface"
                sleep 2
                ifup "$iface"
            done
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
EOF

chmod +x /usr/bin/wan-keep-alive.sh

# 5. Sazdavane na init.d / procd usluga (/etc/init.d/wankeepalive)
echo "Sazdavane na /etc/init.d/wankeepalive..."
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

# 6. Sazdavane na LuCI Controller
echo "Sazdavane na LuCI controller..."
cat << 'EOF' > /usr/lib/lua/luci/controller/wankeepalive.lua
module("luci.controller.wankeepalive", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/wankeepalive") then
        return
    end

    entry({"admin", "services", "wankeepalive"}, cbi("wankeepalive"), _("WAN Keep Alive"), 60).dependent = true
end
EOF

# 7. Sazdavane na LuCI Model (CBI)
echo "Sazdavane na LuCI CBI model..."
cat << 'EOF' > /usr/lib/lua/luci/model/cbi/wankeepalive.lua
m = Map("wankeepalive", translate("WAN Keep Alive"), translate("Nastroika na avtomati4noto sledene i vuzstanovyavane na internet vruzkata."))

s = m:section(NamedSection, "main", "wankeepalive", translate("Osnovni nastroiki"))

-- Vkluchvane / Izkluchvane
e = s:option(Flag, "enabled", translate("Aktivno"))
e.rmempty = false

-- Ping Hostove
hosts = s:option(Value, "ping_hosts", translate("IP adresi za proverka"), translate("Razdeleni sus prostranstvo (naprimer: 1.1.1.1 8.8.8.8)"))
hosts.rmempty = false

-- Interval na proverka
interval = s:option(Value, "check_interval", translate("Interval na proverka (sekundi)"), translate("Vreme mejdu pings (naprimer za 2 min: 120)"))
interval.datatype = "uinteger"
interval.rmempty = false

-- Izbor na interfeysi za restart
ifaces = s:option(MultiValue, "target_interfaces", translate("Interfeysi za restart"), translate("Izberete koi mrejobi interfeysi da se restartirat pri purvia prag"))
local uci = luci.model.uci.cursor()
uci:foreach("network", "interface", function(c)
    if c[".name"] ~= "loopback" then
        ifaces:value(c[".name"])
    end
end)

-- Prag za restart na interfeysi
if_thresh = s:option(Value, "interface_fail_threshold", translate("Greshki za restart na interfeysa"), translate("Broi posledovatelni greshki predi restart na izbranite interfeysi"))
if_thresh.datatype = "uinteger"
if_thresh.rmempty = false

-- Prag za restart na routera
r_thresh = s:option(Value, "router_fail_threshold", translate("Greshki za restart na routera"), translate("Broi posledovatelni greshki predi restart na celia router"))
r_thresh.datatype = "uinteger"
r_thresh.rmempty = false

-- Zastita / Validacia na chislata
function r_thresh.validate(self, value, section)
    local if_val = tonumber(if_thresh:formvalue(section))
    local r_val = tonumber(value)
    
    if r_val and if_val and r_val <= if_val then
        return nil, translate("Greshka: Pragyt za restart na routera trjabva da e po-goljam ot pragyt za interfeysa!")
    end
    return value
end

return m
EOF

# 8. Chistene na LuCI kesh i restartirane na uslugite
echo "Aktivirane na uslugata i perezarezhdane na kesh..."
/etc/init.d/wankeepalive enable

rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/

/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/wankeepalive restart

echo "==== Uspehsno priklyucheno! WAN Keep-Alive e aktiven v LuCI (Services -> WAN Keep Alive) ===="
