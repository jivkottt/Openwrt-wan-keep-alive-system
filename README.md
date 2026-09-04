# Openwrt-wan-keep-alive-system
The system is used to monitor the WAN interface and in case of a problem with it, attempts to restart first the specified interfaces and if not success restore connetion then the entire router.
The settings interface will appear in the LuCI menu under Services -> WAN Keep Alive.
All parameters are configured through the LuCI interface:
1. System status: ON/OFF
2. IP addresses used for checking (ping is sent to them)
3. Interval between checks (e.g. 120 sec).
4. Interfaces that will be restarted in case of a problem (All selected interfaces will be restarted at once.)
5. Number of failed checks for restarting the interfaces (default 5).
6. Number of failed checks for restarting the entire router (default 15).
The counters for failed attempts are kept only in the RAM as process variables. When the router is restarted, they are automatically reset. All log entries will be visible (until the router is restarted) directly in Status -> System Log in LuCI, without wearing out the flash memory.
The system works without external dependencies: Only built-in openwrt tools are used.

Installation:
1. Log into the router via SSH.
2. Start the following command from router terminal (trought ssh connction):
wget -O /tmp/install_wankeepalive.sh "https://raw.githubusercontent.com/jivkottt/Openwrt-wan-keep-alive-system/main/install_wankeepalive.sh" && chmod +x /tmp/install_wankeepalive.sh && /tmp/install_wankeepalive.sh
This command will download the script (install_wankeepalive.sh) and install it automatically.
