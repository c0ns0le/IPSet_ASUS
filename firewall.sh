#!/bin/sh
#############################################################################################################
#			         _____ _                     _             __  				    #
#			        / ____| |                   | |           / /  				    #
#			       | (___ | | ___   _ _ __   ___| |_  __   __/ /_  				    #
#			        \___ \| |/ / | | | '_ \ / _ \ __| \ \ / / '_ \ 				    #
#			        ____) |   <| |_| | | | |  __/ |_   \ V /| (_) |				    #
#			       |_____/|_|\_\\__, |_| |_|\___|\__|   \_/  \___/ 				    #
#			                     __/ |                             				    #
#			                    |___/                              				    #
#                                                     							    #
## - 20/10/2018 -		   Asus Firewall Addition By Adamm v6.5.2				    #
##				   https://github.com/Adamm00/IPSet_ASUS		                    #
#############################################################################################################


export PATH=/sbin:/bin:/usr/sbin:/usr/bin$PATH
clear
sed -n '2,16p' "$0"
export LC_ALL=C

retry=1
while [ "$(nvram get ntp_ready)" = "0" ] && [ "$retry" -lt "300" ]; do
	retry=$((retry+1))
	sleep 1
done
if [ "$retry" -ge "300" ]; then logger -st Skynet "[*] NTP Failed To Start After 5 Minutes - Please Fix Immediately!"; echo; exit 1; fi


red="printf \\e[1;31m%s\\e[0m\\n"
grn="printf \\e[1;32m%s\\e[0m\\n"
blue="printf \\e[1;36m%s\\e[0m\\n"
ylow="printf \\e[1;33m%s\\e[0m\\n"
stime="$(date +%s)"


skynetloc="$(grep -ow "skynetloc=.* # Skynet" /jffs/scripts/firewall-start 2>/dev/null | grep -vE "^#" | awk '{print $1}' | cut -c 11-)"
skynetcfg="${skynetloc}/skynet.cfg"
skynetlog="${skynetloc}/skynet.log"
skynetevents="${skynetloc}/events.log"
skynetipset="${skynetloc}/skynet.ipset"

if [ -z "$skynetloc" ] && tty >/dev/null 2>&1; then
	set "install"
fi

###############
#- Functions -#
###############

Kill_Lock () {
		if [ -f "/tmp/skynet.lock" ] && [ -d "/proc/$(sed -n '2p' /tmp/skynet.lock)" ]; then
			logger -st Skynet "[*] Killing Locked Processes ($(sed -n '1p' /tmp/skynet.lock)) (pid=$(sed -n '2p' /tmp/skynet.lock))"
			logger -st Skynet "[*] $(ps | awk -v pid="$(sed -n '2p' /tmp/skynet.lock)" '$1 == pid')"
			kill "$(sed -n '2p' /tmp/skynet.lock)"
			rm -rf /tmp/skynet.lock
			echo
		fi
}

Check_Lock () {
		if [ -f "/tmp/skynet.lock" ] && [ -d "/proc/$(sed -n '2p' /tmp/skynet.lock)" ] && [ "$(sed -n '2p' /tmp/skynet.lock)" != "$$" ]; then
			if [ "$(($(date +%s)-$(sed -n '3p' /tmp/skynet.lock)))" -gt "7200" ]; then
				Kill_Lock
			else
				logger -st Skynet "[*] Lock File Detected ($(sed -n '1p' /tmp/skynet.lock)) (pid=$(sed -n '2p' /tmp/skynet.lock)) - Exiting (cpid=$$)"
				echo; exit 1
			fi
		fi
		echo "$@" > /tmp/skynet.lock
		echo "$$" >> /tmp/skynet.lock
		date +%s >> /tmp/skynet.lock
		lockskynet="true"
}


if [ ! -d "$skynetloc" ] && ! echo "$@" | grep -wqE "(install|uninstall|disable|update|restart|info)"; then
	Check_Lock "$@"
	retry="1"
	if [ -z "$skynetloc" ]; then retry="11"; fi
	while [ ! -d "$skynetloc" ] && [ "$retry" -lt "11" ]; do
		logger -st Skynet "[*] USB Not Found - Sleeping For 10 Seconds ( Attempt $retry Of 10 )"
		retry=$((retry+1))
		sleep 10
	done
	if [ ! -d "$skynetloc" ] || [ ! -w "$skynetloc" ]; then
		logger -st Skynet "[*] Problem With USB Install Location - Please Fix Immediately!"
		logger -st Skynet "[*] When Fixed Run ( sh $0 restart )"
		echo; exit 1
	fi
fi

if [ "$(nvram get wan0_proto)" = "pppoe" ] || [ "$(nvram get wan0_proto)" = "pptp" ] || [ "$(nvram get wan0_proto)" = "l2tp" ]; then
	iface="ppp0"
else
	iface="$(nvram get wan0_ifname)"
fi


Check_Settings () {
		if [ ! -f "$skynetcfg" ]; then
			logger -st Skynet "[*] Configuration File Not Detected - Please Use ( sh $0 install ) To Continue"
			echo; exit 1
		fi

		conflicting_scripts="(IPSet_Block.sh|malware-filter|privacy-filter|ipBLOCKer.sh|ya-malware-block.sh|iblocklist-loader.sh|firewall-reinstate.sh)$"
		if /usr/bin/find /jffs /tmp/mnt | grep -qE "$conflicting_scripts"; then
			logger -st Skynet "[*] $(/usr/bin/find /jffs /tmp/mnt | grep -E "$conflicting_scripts" | xargs) Detected - This Script Will Cause Conflicts! Please Uninstall It ASAP"
		fi

		if ! grep -F "swapon" /jffs/scripts/post-mount | grep -qvE "^#" && ! grep -F "swap" /jffs/configs/fstab 2>/dev/null | grep -qvE "^#"; then
			logger -st Skynet "[*] Skynet Requires A SWAP File - Install One By Running ( $0 debug swap install )"
			echo; exit 1
		fi

		if [ "$(nvram get fw_log_x)" != "drop" ] && [ "$(nvram get fw_log_x)" != "both" ]; then
			nvram set fw_log_x=drop
		fi

		localver="$(Filter_Version "$0")"

		if [ "$banmalwareupdate" = "daily" ]; then
			Load_Cron "banmalwaredaily"
		elif [ "$banmalwareupdate" = "weekly" ]; then
			Load_Cron "banmalwareweekly"
		fi

		if [ "$autoupdate" = "enabled" ]; then
			Load_Cron "autoupdate"
		else
			Load_Cron "checkupdate"
		fi

		if [ -d "/opt/bin" ] && [ ! -L "/opt/bin/firewall" ]; then
			ln -s /jffs/scripts/firewall /opt/bin
		fi

		if [ "$(nvram get jffs2_scripts)" != "1" ]; then
			nvram set jffs2_scripts=1
			logger -st Skynet "[*] Custom JFFS Scripts Enabled - Please Manually Reboot To Apply Changes"
		fi

		if [ "$(nvram get fw_enable_x)" != "1" ]; then
			nvram set fw_enable_x=1
		fi

		if [ -f /opt/share/diversion/.conf/diversion.conf ]; then
			divlocation="/opt/share/diversion"
			if ! grep -qE "bfPlusHosts=on" "${divlocation}/.conf/diversion.conf"; then
				if [ ! -f "${divlocation}/AddPlusHosts" ] && [ ! -f "${divlocation}/AddPlusHostsDismissed" ]; then
					touch "${divlocation}/AddPlusHosts"
				fi
			fi
		fi

		if [ -f "/opt/var/log/dnsmasq.log" ]; then
			extendedstats="enabled"
		else
			extendedstats="disabled"
		fi

		if [ -z "$wifemode" ]; then wifemode="disabled"; fi
}

Check_Files () {
		if [ ! -f "/jffs/scripts/firewall-start" ]; then
			echo "#!/bin/sh" > /jffs/scripts/firewall-start
		elif [ -f "/jffs/scripts/firewall-start" ] && ! head -1 /jffs/scripts/firewall-start | grep -qE "^#!/bin/sh"; then
			sed -i '1s~^~#!/bin/sh\n~' /jffs/scripts/firewall-start
		fi
		if [ ! -f "/jffs/scripts/services-stop" ]; then
			echo "#!/bin/sh" > /jffs/scripts/services-stop
		elif [ -f "/jffs/scripts/services-stop" ] && ! head -1 /jffs/scripts/services-stop | grep -qE "^#!/bin/sh"; then
			sed -i '1s~^~#!/bin/sh\n~' /jffs/scripts/services-stop
		fi
		if [ ! -f "/jffs/scripts/post-mount" ]; then
			echo "#!/bin/sh" > /jffs/scripts/post-mount
		elif [ -f "/jffs/scripts/post-mount" ] && ! head -1 /jffs/scripts/post-mount | grep -qE "^#!/bin/sh"; then
			sed -i '1s~^~#!/bin/sh\n~' /jffs/scripts/post-mount
		fi
		if [ "$1" = "verify" ] && ! grep -qF "# Skynet" /jffs/scripts/services-stop; then
			echo "sh /jffs/scripts/firewall save # Skynet Firewall Addition" >> /jffs/scripts/services-stop
		fi
}

Check_Status () {
		{ [ -f "$skynetipset" ] && ipset -L -n Skynet-Whitelist >/dev/null 2>&1 && iptables -t raw -C PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j DROP >/dev/null 2>&1; } ||
		{ [ -f "$skynetipset" ] && ipset -L -n Skynet-Whitelist >/dev/null 2>&1 && iptables -t raw -C PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP >/dev/null 2>&1 && iptables -t raw -C OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP >/dev/null 2>&1; }
}

Check_Security () {
	if [ "$securemode" = "enabled" ]; then
		if [ "$(nvram get sshd_enable)" = "1" ] && [ "$(uname -o)" = "ASUSWRT-Merlin" ]; then
			logger -st Skynet "[!] Insecure Setting Detected - Disabling WAN SSH Access"
			nvram set sshd_enable="2"
			nvram commit
			restartfirewall="1"
		fi
		if [ "$(nvram get sshd_wan)" = "1" ] && [ "$(uname -o)" = "ASUSWRT-Merlin-LTS" ]; then
			logger -st Skynet "[!] Insecure Setting Detected - Disabling WAN SSH Access"
			nvram set sshd_wan="0"
			nvram commit
			restartfirewall="1"
		fi
		if [ "$(nvram get misc_http_x)" = "1" ]; then
			logger -st Skynet "[!] Insecure Setting Detected - Disabling WAN GUI Access"
			nvram set misc_http_x="0"
			nvram commit
			restartfirewall="1"
		fi
		if [ "$(nvram get pptpd_enable)" = "1" ] && nvram get pptpd_clientlist | grep -qE 'i[0-9]{7}|p[0-9]{7}'; then
			logger -st Skynet "[!] PPTP VPN Server Shows Signs Of Compromise - Investigate Immediately!"
			nvram set pptpd_enable="0"
			nvram set pptpd_broadcast="0"
			nvram commit
			echo "[i] Stopping PPTP Service"
			service stop_pptpd
			echo "[i] Restarting Samba Service"
			service restart_samba
			restartfirewall="1"
		fi
		if [ -e "/var/run/tor" ] || [ -e "/var/run/torrc" ] || [ -e "/var/run/tord" ] || [ -e "/var/run/vpnfilterm" ] || [ -e "/var/run/vpnfilterw" ]; then
			logger -st Skynet "[!] Suspected VPNFilter Malware Found - Investigate Immediately!"
			logger -st Skynet "[!] Caching Potential VPNFilter Malware: ${skynetloc}/vpnfilter.tar.gz"
			tar -czf "${skynetloc}/vpnfilter.tar.gz" "/var/run/tor" "/var/run/torrc" "/var/run/tord" "/var/run/vpnfilterm" "/var/run/vpnfilterw" >/dev/null 2>&1
			rm -rf "/var/run/tor" "/var/run/torrc" "/var/run/tord" "/var/run/vpnfilterm" "/var/run/vpnfilterw"
			restartfirewall="1"
		fi
	fi
}

Unload_IPTables () {
		iptables -t raw -D PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j DROP 2>/dev/null
		iptables -t raw -D PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null
		iptables -t raw -D OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null
		iptables -D SSHBFP -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j SET --add-set Skynet-Blacklist src 2>/dev/null
		iptables -D SSHBFP -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j LOG --log-prefix "[BLOCKED - NEW BAN] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		iptables -D logdrop -m state --state NEW -j LOG --log-prefix "DROP " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		ip6tables -D logdrop -m state --state NEW -j LOG --log-prefix "DROP " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
}

Load_IPTables () {
		if [ "$filtertraffic" = "all" ] || [ "$filtertraffic" = "inbound" ]; then
			iptables -t raw -I PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j DROP 2>/dev/null
		fi
		if [ "$filtertraffic" = "all" ] || [ "$filtertraffic" = "outbound" ]; then
			iptables -t raw -I PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null
			iptables -t raw -I OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null
		fi
		if [ "$(nvram get sshd_enable)" = "1" ] && [ "$(nvram get sshd_bfp)" = "1" ]; then
			pos1="$(iptables --line -nL SSHBFP | grep -F "seconds: 60 hit_count: 4" | grep -E 'DROP|logdrop' | awk '{print $1}')"
			iptables -I SSHBFP "$pos1" -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j SET --add-set Skynet-Master src 2>/dev/null
			iptables -I SSHBFP "$pos1" -m recent --update --seconds 60 --hitcount 4 --name SSH --rsource -j LOG --log-prefix "[BLOCKED - NEW BAN] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		fi
}

Unload_DebugIPTables () {
		iptables -t raw -D PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j LOG --log-prefix "[BLOCKED - INBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		iptables -t raw -D PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		iptables -t raw -D OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
		iptables -D logdrop -m state --state NEW -j LOG --log-prefix "[BLOCKED - INVALID] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
}

Load_DebugIPTables () {
		if [ "$debugmode" = "enabled" ]; then
			if [ "$filtertraffic" = "all" ] || [ "$filtertraffic" = "inbound" ]; then
				pos2="$(iptables --line -nL PREROUTING -t raw | grep -F "Skynet-Master src" | grep -F "DROP" | awk '{print $1}')"
				iptables -t raw -I PREROUTING "$pos2" -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j LOG --log-prefix "[BLOCKED - INBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
			fi
			if [ "$filtertraffic" = "all" ] || [ "$filtertraffic" = "outbound" ]; then
				pos3="$(iptables --line -nL PREROUTING -t raw | grep -F "Skynet-Master dst" | grep -F "DROP" | awk '{print $1}')"
				iptables -t raw -I PREROUTING "$pos3" -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
				pos4="$(iptables --line -nL OUTPUT -t raw | grep -F "Skynet-Master dst" | grep -F "DROP" | awk '{print $1}')"
				iptables -t raw -I OUTPUT "$pos4" -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
			fi
			if [ "$(nvram get fw_log_x)" = "drop" ] || [ "$(nvram get fw_log_x)" = "both" ] && [ "$loginvalid" = "enabled" ]; then
				iptables -I logdrop -m state --state NEW -j LOG --log-prefix "[BLOCKED - INVALID] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null
			fi
		fi
}

Unload_IPSets () {
		ipset -q destroy Skynet-Master
		ipset -q destroy Skynet-Blacklist
		ipset -q destroy Skynet-BlockedRanges
		ipset -q destroy Skynet-Whitelist
}

Unload_Cron () {
		if [ -z "$1" ]; then set "all"; fi
        for cron in "$@"; do
                case "$cron" in
                        save)
                                cru d Skynet_save
                        ;;
                        banmalware)
                                cru d Skynet_banmalware

                        ;;
                        autoupdate)
                                cru d Skynet_autoupdate

                        ;;
                        checkupdate)
                                cru d Skynet_checkupdate

                        ;;
                        all)
                                cru d Skynet_save
                                cru d Skynet_banmalware
                                cru d Skynet_autoupdate
                                cru d Skynet_checkupdate
                        ;;
                        *)
								echo "[*] Error - No Cron Specified To Unload"
						;;
                esac
        done
}

Load_Cron () {
		if [ -z "$1" ]; then set "all"; fi
        for cron in "$@"; do
                case "$cron" in
                        save)
                                cru a Skynet_save "0 * * * * sh /jffs/scripts/firewall save"
                        ;;
                        banmalwaredaily)
                                cru a Skynet_banmalware "25 2 * * * sh /jffs/scripts/firewall banmalware"
                        ;;
                        banmalwareweekly)
                                cru a Skynet_banmalware "25 2 * * Mon sh /jffs/scripts/firewall banmalware"
                        ;;
                        autoupdate)
                                cru a Skynet_autoupdate "25 1 * * Mon sh /jffs/scripts/firewall update"
                        ;;
                        checkupdate)
                                cru a Skynet_checkupdate "25 1 * * Mon sh /jffs/scripts/firewall update check"

                        ;;
                        *)
								echo "[*] Error - No Cron Specified To Load"
						;;
                esac
        done
}

Is_IP () {
		grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

Is_Range () {
		grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
}

Is_Port () {
		grep -qE '^[0-9]{1,5}$'
}

Strip_Domain () {
		sed 's~http[s]*://~~;s~/.*~~;s~www\.~~g'
}

Domain_Lookup () {
		nslookup "$(echo "$1" | Strip_Domain)" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk 'NR>2'
}

Extended_Stats () {
	domainlist="$(grep -E "$(echo "$ip" | cut -d '/' -f6-)" /tmp/skynetstats.txt | awk '{print $1}' | Strip_Domain | awk '!x[$0]++' | xargs)"
	echo "${ip}$([ -n "$domainlist" ] && echo " - [$domainlist]")"
}

Filter_Version () {
		if [ -n "$1" ]; then
			grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})' "$1"
		else
			grep -m1 -oE 'v[0-9]{1,2}([.][0-9]{1,2})([.][0-9]{1,2})'
		fi
}

Filter_Date () {
		grep -m1 -oE '[0-9]{1,2}([/][0-9]{1,2})([/][0-9]{1,4})' "$1"
}

Filter_PrivateIP () {
		grep -vE '(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)|(^0.)|(^169\.254\.)|(^22[4-9]\.)|(^23[0-9]\.)|(^255\.255\.255\.255)|(^8\.8\.8\.8)|(^8\.8\.4\.4)'
}

Filter_PrivateSRC () {
		grep -E '(SRC=127\.)|(SRC=10\.)|(SRC=172\.1[6-9]\.)|(SRC=172\.2[0-9]\.)|(SRC=172\.3[0-1]\.)|(SRC=192\.168\.)|(SRC=0.)|(SRC=169\.254\.)|(SRC=22[4-9]\.)|(SRC=23[0-9]\.)|(SRC=255\.255\.255\.255)'
}

Filter_PrivateDST () {
		grep -E '(DST=127\.)|(DST=10\.)|(DST=172\.1[6-9]\.)|(DST=172\.2[0-9]\.)|(DST=172\.3[0-1]\.)|(DST=192\.168\.)|(DST=0.)|(DST=169\.254\.)|(DST=22[4-9]\.)|(DST=23[0-9]\.)|(DST=255\.255\.255\.255)'
}

Save_IPSets () {
		if Check_Status; then
			echo "[i] Saving Changes"
			{ ipset save Skynet-Whitelist; ipset save Skynet-Blacklist; ipset save Skynet-BlockedRanges; ipset save Skynet-Master; } > "$skynetipset" 2>/dev/null
		fi
}

Unban_PrivateIP () {
		if [ "$unbanprivateip" = "enabled" ] && [ "$debugmode" = "enabled" ]; then
			grep -F "INBOUND" /tmp/syslog.log | Filter_PrivateSRC | grep -oE 'SRC=[0-9,\.]*' | cut -c 5- | awk '!x[$0]++' | while IFS= read -r "ip"; do
				ipset -q -A Skynet-Whitelist "$ip" comment "PrivateIP"
				ipset -q -D Skynet-Blacklist "$ip"
				sed -i "\\~SRC=${ip} ~d" "/tmp/syslog.log" "$skynetevents"
			done
			grep -F "OUTBOUND" /tmp/syslog.log | Filter_PrivateDST | grep -oE 'DST=[0-9,\.]*' | cut -c 5- | awk '!x[$0]++' | while IFS= read -r "ip"; do
				ipset -q -A Skynet-Whitelist "$ip" comment "PrivateIP"
				ipset -q -D Skynet-Blacklist "$ip"
				sed -i "\\~DST=${ip} ~d" /tmp/syslog.log
				sed -i "\\~SRC=${ip} ~d" "$skynetevents"
			done
		fi
}

Refresh_AiProtect () {
	if [ "$banaiprotect" = "enabled" ] && [ -f /jffs/.sys/AiProtectionMonitor/AiProtectionMonitor.db ]; then
		if [ -f /opt/bin/opkg ] && [ ! -f /opt/bin/sqlite3 ]; then
			opkg update && opkg install sqlite3-cli
		fi
		if [ -f /opt/bin/opkg ] && [ -f /opt/bin/sqlite3 ] && sqlite3 /jffs/.sys/AiProtectionMonitor/AiProtectionMonitor.db "SELECT src FROM monitor;" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
			sed "\\~add Skynet-Blacklist ~!d;\\~BanAiProtect~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
			sqlite3 /jffs/.sys/AiProtectionMonitor/AiProtectionMonitor.db "SELECT src FROM monitor;" | grep -oE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | awk '!x[$0]++' | Filter_PrivateIP | awk '{print "add Skynet-Blacklist " $1 " comment \"BanAiProtect\""}'  | ipset restore -!
		fi
	fi
}

Refresh_MBans () {
		if grep -qF "[Manual Ban] TYPE=Domain" "$skynetevents"; then
			grep -F "[Manual Ban] TYPE=Domain" "$skynetevents" | awk '{print $9}' | awk '!x[$0]++' | sed 's~Host=~~g' > /tmp/mbans.list
			sed -i '\~\[Manual Ban\] TYPE=Domain~d;' "$skynetevents"
			sed "\\~add Skynet-Blacklist ~!d;\\~ManualBanD~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
			while IFS= read -r "domain"; do
				for ip in $(Domain_Lookup "$domain"); do
					ipset -q -A Skynet-Blacklist "$ip" comment "ManualBanD: $domain" && echo "$(date +"%b %d %T") Skynet: [Manual Ban] TYPE=Domain SRC=$ip Host=$domain " >> "$skynetevents"
				done
			done < /tmp/mbans.list
			wait
			rm -rf /tmp/mbans.list
		fi
}

Refresh_MWhitelist () {
		if grep -qE "Manual Whitelist.* TYPE=Domain" "$skynetevents"; then
			grep -E "Manual Whitelist.* TYPE=Domain" "$skynetevents" | awk '{print $9}' | awk '!x[$0]++' | sed 's~Host=~~g' > /tmp/mwhitelist.list
			sed -i '\~\[Manual Whitelist\] TYPE=Domain~d;' "$skynetevents"
			sed "\\~add Skynet-Whitelist ~!d;\\~ManualWlistD~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
			while IFS= read -r "domain"; do
				for ip in $(Domain_Lookup "$domain"); do
					ipset -q -A Skynet-Whitelist "$ip" comment "ManualWlistD: $domain" && echo "$(date +"%b %d %T") Skynet: [Manual Whitelist] TYPE=Domain SRC=$ip Host=$domain " >> "$skynetevents"
				done &
			done < /tmp/mwhitelist.list
			wait
			cat /tmp/mwhitelist.list >> /jffs/shared-Skynet2-whitelist
			rm -rf /tmp/mwhitelist.list
		fi
}

Whitelist_Extra () {
		{ echo "ipdeny.com"
		echo "speedguide.net"
		echo "otx.alienvault.com"
		echo "raw.githubusercontent.com"
		echo "iplists.firehol.org"
		echo "astrill.com"
		echo "strongpath.net"
		echo "snbforums.com"
		echo "ipapi.co"
		nvram get ntp_server0
		nvram get ntp_server1
		nvram get firmware_server; } > /jffs/shared-Skynet2-whitelist
}

Whitelist_CDN () {
		sed '\~add Skynet-Whitelist ~!d;\~CDN-Whitelist~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
		/usr/sbin/curl -fsL --retry 3 "https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/cdn.list" | dos2unix | grep -oE '^[0-9,./]*$' | awk '!x[$0]++' > /tmp/cdn.list
		awk '{print "add Skynet-Whitelist " $1 " comment \"CDN-Whitelist\""}' /tmp/cdn.list | ipset restore -!
		rm -rf /tmp/cdn.list
}

Whitelist_VPN () {
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_server1_sn)"/24 comment "nvram: vpn_server1_sn"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_server2_sn)"/24 comment "nvram: vpn_server2_sn"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_server_sn)"/24 comment "nvram: vpn_server_sn"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_client1_addr)"/24 comment "nvram: vpn_client1_addr"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_client2_addr)"/24 comment "nvram: vpn_client2_addr"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_client3_addr)"/24 comment "nvram: vpn_client3_addr"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_client4_addr)"/24 comment "nvram: vpn_client4_addr"
		ipset -q -A Skynet-Whitelist "$(nvram get vpn_client5_addr)"/24 comment "nvram: vpn_client5_addr"
		if [ -f "/dev/astrill/openvpn.conf" ]; then ipset -q -A Skynet-Whitelist "$(sed '\~remote ~!d;s~remote ~~' "/dev/astrill/openvpn.conf")"/24 comment "nvram: Astrill_VPN"; fi
}

Whitelist_Shared () {
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_ipaddr)"/32 comment "nvram: wan0_ipaddr"
		ipset -q -A Skynet-Whitelist "$(nvram get lan_ipaddr)"/24 comment "nvram: lan_ipaddr"
		ipset -q -A Skynet-Whitelist "$(nvram get lan_netmask)"/24 comment "nvram: lan_netmask"
		ipset -q -A Skynet-Whitelist "$(nvram get wan_dns1_x)"/32 comment "nvram: wan_dns1_x"
		ipset -q -A Skynet-Whitelist "$(nvram get wan_dns2_x)"/32 comment "nvram: wan_dns2_x"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_dns1_x)"/32 comment "nvram: wan0_dns1_x"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_dns2_x)"/32 comment "nvram: wan0_dns2_x"
		ipset -q -A Skynet-Whitelist "$(nvram get wan_dns | awk '{print $1}')"/32 comment "nvram: wan_dns"
		ipset -q -A Skynet-Whitelist "$(nvram get wan_dns | awk '{print $2}')"/32 comment "nvram: wan_dns"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_dns | awk '{print $1}')"/32 comment "nvram: wan0_dns"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_dns | awk '{print $2}')"/32 comment "nvram: wan0_dns"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_xdns | awk '{print $1}')"/32 comment "nvram: wan0_xdns"
		ipset -q -A Skynet-Whitelist "$(nvram get wan0_xdns | awk '{print $2}')"/32 comment "nvram: wan0_xdns"
		ipset -q -A Skynet-Whitelist 192.30.252.0/22 comment "nvram: Github Content Server"
		ipset -q -A Skynet-Whitelist 192.168.1.0/24 comment "nvram: LAN Subnet"
		if [ -n "$(/usr/bin/find /jffs -name 'shared-*-whitelist')" ]; then
			echo "Whitelisting Shared Domains"
			sed '\~add Skynet-Whitelist ~!d;\~Shared-Whitelist~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
			grep -hvF "#" /jffs/shared-*-whitelist | Strip_Domain | awk '!x[$0]++' | while IFS= read -r "domain"; do
				for ip in $(Domain_Lookup "$domain" 2> /dev/null); do
					ipset -q -A Skynet-Whitelist "$ip" comment "Shared-Whitelist: $domain"
				done &
			done
			wait
		fi
}

Manage_Device () {
		echo "Looking For Available Partitions"
		i=1
		IFS="
		"
		for mounted in $(/bin/mount | grep -E "ext2|ext3|ext4|tfat|exfat" | awk '{print $3" - ("$1")"}') ; do
			echo "[$i]  --> $mounted"
			eval mounts$i="$(echo "$mounted" | awk '{print $1}')"
			i=$((i + 1))
		done
		unset IFS
		if [ "$i" = "1" ]; then
			echo "[*] No Compatible ext* USB Partitions Found - Exiting!"
			echo; exit 1
		fi
		Select_Device (){
				echo
				echo "Please Enter Partition Number Or e To Exit"
				printf "[0-%s]: " "$((i - 1))"
				read -r "partitionNumber"
				echo
				if [ "$partitionNumber" = "e" ] || [ "$partitionNumber" = "exit" ]; then
					echo "[*] Exiting!"
					echo; exit 0
				elif [ -z "$partitionNumber" ] || [ "$partitionNumber" -gt $((i - 1)) ] 2>/dev/null || [ "$partitionNumber" = "0" ]; then
					echo "[*] Invalid Partition Number!"
					Select_Device
				elif [ "$partitionNumber" -eq "$partitionNumber" ] 2>/dev/null;then
					true
				else
					echo "[*] $partitionNumber Isn't An Option!"
					Select_Device
				fi
		}
		Select_Device
		device=""
		eval device=\$mounts"$partitionNumber"
		touch "${device}/rwtest"
		if [ ! -w "${device}/rwtest" ]; then
			echo "[*] Writing To $device Failed - Exiting!"
			Manage_Device
		else
			rm -rf "${device}/rwtest"
		fi
}

Create_Swap () {
	while true; do
		echo "Select SWAP File Size:"
		echo "[1]  --> 256MB"
		echo "[2]  --> 512MB"
		echo "[3]  --> 1GB"
		echo "[4]  --> 2GB"
		echo
		echo "[e]  --> Exit Menu"
		echo
		printf "[1-4]: "
		read -r "menu"
		echo
		case "$menu" in
			1)
				swapsize=262144
				break
			;;
			2)
				swapsize=524288
				break
			;;
			3)
				swapsize=1048576
				break
			;;
			4)
				swapsize=2097152
				break
			;;
			e|exit)
				echo "[*] Exiting!"
				echo; exit 0
			;;
			*)
				echo "[*] $menu Isn't An Option!"
				echo
			;;
		esac
	done
	if [ -f "${device}/myswap.swp" ]; then swapoff "${device}/myswap.swp" 2>/dev/null; rm -rf "${device}/myswap.swp"; fi
	if [ "$(df $device | xargs | awk '{print $11}')" -le "$swapsize" ]; then echo "[*] Not Enough Free Space Available On $device"; Create_Swap; fi
	echo "[i] Creating SWAP File"
	dd if=/dev/zero of="${device}/myswap.swp" bs=1k count="$swapsize"
	mkswap "${device}/myswap.swp"
	swapon "${device}/myswap.swp"
	echo "swapon ${device}/myswap.swp # Skynet Firewall Addition" >> /jffs/scripts/post-mount
	echo "[i] SWAP File Located At ${device}/myswap.swp"
	echo
}

Purge_Logs () {
		sed '\~BLOCKED -~!d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null >> "$skynetlog"
		sed -i '\~BLOCKED -~d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null
		if [ "$(du "$skynetlog" | awk '{print $1}')" -ge "10240" ]; then
			sed -i '\~BLOCKED -~d' "$skynetlog"
			sed -i '\~Skynet: \[#\] ~d' "$skynetevents"
			sed -i '\~Skynet: \[Complete\]~d' "$skynetevents" # Legacy Code
			if [ "$(du "$skynetlog" | awk '{print $1}')" -ge "3000" ]; then
				true > "$skynetlog"
			fi
		fi
		if [ "$1" = "all" ] || [ "$(grep -cE "Skynet: [#] " "/tmp/syslog.log" 2>/dev/null)" -gt "24" ] 2>/dev/null; then
			sed '\~Skynet: \[#\] ~!d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null >> "$skynetevents"
			sed -i '\~Skynet: \[#\] ~d;\~Skynet: \[i\] ~d;\~Skynet: \[\*\] Lock ~d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null
		fi
}

Print_Log () {
		oldips="$blacklist1count"
		oldranges="$blacklist2count"
		blacklist1count="$(grep -Foc "add Skynet-Black" "$skynetipset" 2> /dev/null)"
		blacklist2count="$(grep -Foc "add Skynet-Block" "$skynetipset" 2> /dev/null)"
		if Check_Status; then
			if [ "$filtertraffic" != "outbound" ]; then
				hits1="$(iptables -xnvL PREROUTING -t raw | grep -Fv "LOG" | grep -F "Skynet-Master src" | awk '{print $1}')"
			else
				hits1="0"
			fi
			if [ "$filtertraffic" != "inbound" ]; then
				hits2="$(($(iptables -xnvL PREROUTING -t raw | grep -Fv "LOG" | grep -F "Skynet-Master dst" | awk '{print $1}')+$(iptables -xnvL OUTPUT -t raw | grep -Fv "LOG" | grep -F "Skynet-Master dst" | awk '{print $1}')))"
			else
				hits2="0"
			fi
		fi
		ftime="$(($(date +%s) - stime))"
		if ! echo "$((blacklist1count - oldips))" | grep -qF "-"; then newips="+$((blacklist1count - oldips))"; else newips="$((blacklist1count - oldips))"; fi
		if ! echo "$((blacklist2count - oldranges))" | grep -qF "-"; then newranges="+$((blacklist2count - oldranges))"; else newranges="$((blacklist2count - oldranges))"; fi
		if [ "$1" = "minimal" ]; then
			$grn "$blacklist1count IPs (${newips}) -- $blacklist2count Ranges Banned (${newranges}) || $hits1 Inbound -- $hits2 Outbound Connections Blocked!"
		else
			logz="[#] $blacklist1count IPs (${newips}) -- $blacklist2count Ranges Banned (${newranges}) || $hits1 Inbound -- $hits2 Outbound Connections Blocked! [$1] [${ftime}s]"
			logger -t Skynet "$logz"; echo "$logz"
		fi
}

Write_Config () {
	{ echo "## Generated By Skynet - Do Not Manually Edit ##"
	echo "## $(date +"%b %d %T") ##"
	echo
	echo "## Installer ##"
	echo "model=\"$model\""
	echo "localver=\"$localver\""
	echo "autoupdate=\"$autoupdate\""
	echo "banmalwareupdate=\"$banmalwareupdate\""
	echo "forcebanmalwareupdate=\"$forcebanmalwareupdate\""
	echo "debugmode=\"$debugmode\""
	echo "filtertraffic=\"$filtertraffic\""
	echo
	echo "## Other ##"
	echo "blacklist1count=\"$blacklist1count\""
	echo "blacklist2count=\"$blacklist2count\""
	echo "customlisturl=\"$customlisturl\""
	echo "customlist2url=\"$customlist2url\""
	echo "countrylist=\"$countrylist\""
	echo "excludelists=\"$excludelists\""
	echo "unbanprivateip=\"$unbanprivateip\""
	echo "loginvalid=\"$loginvalid\""
	echo "banaiprotect=\"$banaiprotect\""
	echo "securemode=\"$securemode\""
	echo "extendedstats=\"$extendedstats\""
	echo "wifemode=\"$wifemode\""; } > "$skynetcfg"
}


##########
#- Menu -#
##########


Load_Menu () {
	. "$skynetcfg"
	echo "Router Model; $model"
	echo "Skynet Version; $localver ($(Filter_Date "$0"))"
	echo "$(iptables --version) - ($iface @ $(nvram get lan_ipaddr))"
	ipset -v
	echo "FW Version; $(nvram get buildno)_$(nvram get extendno) ($(uname -v | awk '{print $5" "$6" "$9}')) ($(uname -r))"
	echo "Install Dir; $skynetloc ($(df -h "$skynetloc" | xargs | awk '{print $11 " / " $9}') Space Available)"
	if grep -F "swapon" /jffs/scripts/post-mount 2>/dev/null | grep -qvE "^#"; then swaplocation="$(grep -o "swapon .*" /jffs/scripts/post-mount | grep -vE "^#" | awk '{print $2}')"; echo "SWAP File; $swaplocation ($(du -h "$swaplocation" | awk '{print $1}'))"; fi
	echo "Boot Args; $(grep -E "start.* # Skynet" /jffs/scripts/firewall-start 2>/dev/null | grep -vE "^#" | cut -c 4- | cut -d '#' -f1)"
	if [ -n "$countrylist" ]; then echo "Banned Countries; $countrylist"; fi
	if [ -f "/tmp/skynet.lock" ] && [ -d "/proc/$(sed -n '2p' /tmp/skynet.lock)" ]; then $red "[*] Lock File Detected ($(sed -n '1p' /tmp/skynet.lock)) (pid=$(sed -n '2p' /tmp/skynet.lock))"; lockedwarning=1; fi
	if [ -n "$lockedwarning" ]; then $ylow "[*] Locked Processes Generally Take 1-2 Minutes To Complete And May Result In Temporarily \"Failed\" Tests"; fi
	unset "lockedwarning"
	echo
	if ! grep -E "start.* # Skynet" /jffs/scripts/firewall-start 2>/dev/null | grep -qvE "^#"; then printf "Checking Firewall-Start Entry...			"; $red "[Failed]"; fi
	if ! iptables -t raw -C PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j DROP 2>/dev/null && [ "$filtertraffic" != "outbound" ]; then printf "Checking Inbound Filter Rules...			"; $red "[Failed]"; nolog="1"; fi
	if ! iptables -t raw -C PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null || \
	! iptables -t raw -C OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null && [ "$filtertraffic" != "inbound" ]; then printf "Checking Outbound Filter Rules...			"; $red "[Failed]"; nolog="1"; fi
	if ! ipset -L -n Skynet-Whitelist >/dev/null 2>&1; then printf "Checking Whitelist IPSet...				"; $red "[Failed]"; nolog="1"; fi
	if ! ipset -L -n Skynet-BlockedRanges >/dev/null 2>&1; then printf "Checking BlockedRanges IPSet...				"; $red "[Failed]"; nolog="1"; fi
	if ! ipset -L -n Skynet-Blacklist >/dev/null 2>&1; then printf "Checking Blacklist IPSet...				"; $red "[Failed]"; nolog="1"; fi
	if ! ipset -L -n Skynet-Master >/dev/null 2>&1; then printf "Checking Skynet IPSet...				"; $red "[Failed]"; nolog="1"; fi
	if [ "$wifemode" = "enabled" ]; then $ylow "Wife Mode Is Enabled!"; fi
	if [ "$nolog" != "1" ]; then Print_Log "minimal"; fi
	unset "nolog"
	unset "option1" "option2" "option3" "option4" "option5"
	reloadmenu="1"
	Purge_Logs
	echo
	while true; do
		echo "Select Menu Option:"
		echo "[1]  --> Unban"
		echo "[2]  --> Ban"
		echo "[3]  --> Banmalware"
		echo "[4]  --> Whitelist"
		echo "[5]  --> Import IP List"
		echo "[6]  --> Deport IP List"
		echo "[7]  --> Save"
		echo "[8]  --> Restart Skynet"
		echo "[9]  --> Temporarily Disable Skynet"
		echo "[10] --> Update Skynet"
		echo "[11] --> Settings"
		echo "[12] --> Debug Options"
		echo "[13] --> Stats"
		echo "[14] --> Install Skynet"
		echo "[15] --> Uninstall"
		echo
		echo "[r]  --> Reload Menu"
		echo "[e]  --> Exit Menu"
		echo
		printf "[1-15]: "
		read -r "menu"
		echo
		case "$menu" in
			1)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="unban"
				while true; do
					echo "What Type Of Input Would You Like To Unban:"
					echo "[1]  --> IP"
					echo "[2]  --> Range"
					echo "[3]  --> Domain"
					echo "[4]  --> Comment"
					echo "[5]  --> Country"
					echo "[6]  --> Malware"
					echo "[7]  --> Non Manual Bans"
					echo "[8]  --> All"
					echo
					printf "[1-8]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							option2="ip"
							echo "Input IP To Unban:"
							echo
							printf "[IP]: "
							read -r "option3"
							echo
							if ! echo "$option3" | Is_IP; then echo "[*] $option3 Is Not A Valid IP"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						2)
							option2="range"
							echo "Input Range To Unban:"
							echo
							printf "[Range]: "
							read -r "option3"
							echo
							if ! echo "$option3" | Is_Range; then echo "[*] $option3 Is Not A Valid Range"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						3)
							option2="domain"
							echo "Input Domain To Unban:"
							echo
							printf "[URL]: "
							read -r "option3"
							echo
							if [ -z "$option3" ]; then echo "[*] URL Field Can't Be Empty - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						4)
							option2="comment"
							echo "Remove Bans Matching Comment:"
							echo
							printf "[Comment]: "
							read -r "option3"
							echo
							if [ "${#option3}" -gt "255" ]; then echo "[*] $option3 Is Not A Valid Comment. 255 Chars Max"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						5)
							option2="country"
							break
						;;
						6)
							option2="malware"
							break
						;;
						7)
							option2="nomanual"
							break
						;;
						8)
							option2="all"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			2)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="ban"
				while true; do
					echo "What Type Of Input Would You Like To Ban:"
					echo "[1]  --> IP"
					echo "[2]  --> Range"
					echo "[3]  --> Domain"
					echo "[4]  --> Country"
					echo
					printf "[1-4]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							option2="ip"
							echo "Input IP To Ban:"
							echo
							printf "[IP]: "
							read -r "option3"
							echo
							if ! echo "$option3" | Is_IP; then echo "[*] $option3 Is Not A Valid IP"; echo; unset "option2" "option3"; continue; fi
							echo "Input Comment For Ban:"
							echo
							printf "[Comment]: "
							read -r "option4"
							echo
							if [ "${#option4}" -gt "244" ]; then echo "[*] $option4 Is Not A Valid Comment. 244 Chars Max"; echo; unset "option2" "option3" "option4"; continue; fi
							break
						;;
						2)
							option2="range"
							echo "Input Range To Ban:"
							echo
							printf "[Range]: "
							read -r "option3"
							echo
							if ! echo "$option3" | Is_Range; then echo "[*] $option3 Is Not A Valid Range"; echo; unset "option2" "option3"; continue; fi
							echo "Input Comment For Ban:"
							echo
							printf "[Comment]: "
							read -r "option4"
							echo
							if [ "${#option4}" -gt "243" ]; then echo "[*] $option3 Is Not A Valid Comment. 243 Chars Max"; echo; unset "option2" "option3" "option4"; continue; fi
							break
						;;
						3)
							option2="domain"
							echo "Input Domain To Ban:"
							echo
							printf "[URL]: "
							read -r "option3"
							echo
							if [ -z "$option3" ]; then echo "[*] URL Field Can't Be Empty - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						4)
							option2="country"
							if [ -n "$countrylist" ]; then echo "Countries Currently Banned: (${countrylist})"; fi
							echo "Input Country Abbreviations To Ban:"
							echo
							printf "[Countries]: "
							read -r "option3"
							echo
							if [ -z "$option3" ]; then echo "[*] Country Field Can't Be Empty - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							if echo "$option3" | grep -qF "\""; then echo "[*] Country Field Can't Include Quotes - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			3)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="banmalware"
				while true; do
					echo "Select Option:"
					echo "[1]  --> Update"
					echo "[2]  --> Change Filter List"
					echo "[3]  --> Reset Filter List"
					echo "[4]  --> Exclude Individual Lists"
					echo "[5]  --> Reset Exclusion List"
					echo
					printf "[1-5]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							break
						;;
						2)
							echo "Input Custom Filter List URL:"
							printf "[URL]: "
							read -r "option2"
							echo
							if [ -z "$option2" ]; then echo "[*] URL Field Can't Be Empty - Please Try Again"; echo; unset "option2"; continue; fi
							break
						;;
						3)
							option2="reset"
							break
						;;
						4)
							option2="exclude"
							echo "Input Names Of Lists To Exclude Seperated By Pipes"
							echo "Example - list1.ipset|list2.ipset|list3.ipset"
							echo
							printf "[Lists]: "
							read -r "option3"
							echo
							if [ -z "$option3" ]; then echo "[*] Exclusion List Can't Be Empty - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						5)
							option2="exclude"
							option3="reset"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			4)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="whitelist"
				while true; do
					echo "Select Whitelist Option:"
					echo "[1]  --> IP/Range"
					echo "[2]  --> Domain"
					echo "[3]  --> Refresh VPN Whitelist"
					echo "[4]  --> Remove Entries"
					echo "[5]  --> Refresh Entries"
					echo "[6]  --> List Entries"
					echo
					printf "[1-7]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							option2="ip"
							echo "Input IP Or Range To Whitelist:"
							echo
							printf "[IP/Range]: "
							read -r "option3"
							echo
							if ! echo "$option3" | Is_IP && ! echo "$option3" | Is_Range ; then echo "[*] $option3 Is Not A Valid IP/Range"; echo; unset "option2" "option3"; continue; fi
							echo "Input Comment For Whitelist:"
							echo
							printf "[Comment]: "
							read -r "option4"
							echo
							if [ "${#option4}" -gt "242" ]; then echo "[*] $option4 Is Not A Valid Comment. 242 Chars Max"; echo; unset "option2" "option3" "option4"; continue; fi
							break
						;;
						2)
							option2="domain"
							echo "Input Domain To Whitelist:"
							echo
							printf "[URL]: "
							read -r "option3"
							echo
							if [ -z "$option3" ]; then echo "[*] URL Field Can't Be Empty - Please Try Again"; echo; unset "option2" "option3"; continue; fi
							break
						;;
						3)
							option2="vpn"
							break
						;;
						4)
							option2="remove"
							while true; do
								echo "Remove From Whitelist:"
								echo "[1]  --> All Non-Default Entries"
								echo "[2]  --> IP/Range"
								echo "[3]  --> Entries Matching Comment"
								echo
								printf "[1-3]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="all"
										break
									;;
									2)
										option3="entry"
										echo "Input IP Or Range To Remove:"
										echo
										printf "[IP/Range]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP && ! echo "$option4" | Is_Range ; then echo "[*] $option4 Is Not A Valid IP/Range"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									3)
										option3="comment"
										echo "Remove Entries Based On Comment:"
										echo
										printf "[Comment]: "
										read -r "option4"
										echo
										if [ "${#option4}" -gt "255" ]; then echo "[*] $option4 Is Not A Valid Comment. 255 Chars Max"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						5)
							option2="refresh"
							break
						;;
						6)
							option2="list"
							while true; do
								echo "Select Entries To List:"
								echo "[1]  --> All"
								echo "[2]  --> Manually Added IPs"
								echo "[3]  --> Manually Added Domains"
								echo "[4]  --> Imported Entries"
								echo
								printf "[1-4]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										break
									;;
									2)
										option3="ips"
										break
									;;
									3)
										option3="domains"
										break
									;;
									4)
										option3="imported"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			5)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="import"
				while true; do
					echo "Select Where To Import List:"
					echo "[1]  --> Blacklist"
					echo "[2]  --> Whitelist"
					echo
					printf "[1-2]: "
					read -r "menu3"
					echo
					case "$menu3" in
						1)
							option2="blacklist"
							break
						;;
						2)
							option2="whitelist"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu3 Isn't An Option!"
							echo
						;;
					esac
				done
				echo "Input URL/Local File To Import:"
				echo
				printf "[File]: "
				read -r "option3"
				echo
				if [ -z "$option3" ]; then echo "[*] File Field Can't Be Empty - Please Try Again"; echo; unset "option1" "option2" "option3"; continue; fi
				break
			;;
			6)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="deport"
				while true; do
					echo "Select Where To Deport List From:"
					echo "[1]  --> Blacklist"
					echo "[2]  --> Whitelist"
					echo
					printf "[1-2]: "
					read -r "menu3"
					echo
					case "$menu3" in
						1)
							option2="blacklist"
							break
						;;
						2)
							option2="whitelist"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu3 Isn't An Option!"
							echo
						;;
					esac
				done
				echo "Input URL/Local File To Deport"
				echo
				printf "[File]: "
				read -r "option3"
				echo
				if [ -z "$option3" ]; then echo "[*] File Field Can't Be Empty - Please Try Again"; echo; unset "option1" "option2" "option3"; continue; fi
				break
			;;
			7)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; Load_Menu; break; fi
				option1="save"
				break
			;;
			8)
				option1="restart"
				break
			;;
			9)
				option1="disable"
				break
			;;
			10)
				option1="update"
				while true; do
					echo "Select Update Option:"
					echo "[1]  --> Check For And Install Any New Updates"
					echo "[2]  --> Check For Updates Only"
					echo "[3]  --> Force Update Even If No Updates Detected"
					echo
					printf "[1-3]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							break
						;;
						2)
							option2="check"
							break
						;;
						3)
							option2="-f"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			11)
				option1="settings"
				while true; do
					echo "Select Setting To Toggle:"
					echo "[1]  --> Autoupdate - 		$(if [ "$autoupdate" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi)"
					echo "[2]  --> Banmalware - 		$(if [ "$banmalwareupdate" = "daily" ] || [ "$banmalwareupdate" = "weekly" ]; then $grn "[$banmalwareupdate]"; else $red "[Disabled]"; fi)"
					echo "[3]  --> Debug Mode -		$(if [ "$debugmode" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi)"
					echo "[4]  --> Filter Traffic - 	$($grn "[$filtertraffic]")"
					echo "[5]  --> Unban PrivateIP - 	$(if [ "$unbanprivateip" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi)"
					echo "[6]  --> Log Invalid Packets -	$(if [ "$loginvalid" = "enabled" ]; then $grn "[Enabled]";else $ylow "[Disabled]"; fi)"
					echo "[7]  --> Ban AiProtect - 	$(if [ "$banaiprotect" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi)"
					echo "[8]  --> Secure Mode -		$(if [ "$securemode" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi)"
					echo "[9]  --> Wife Mode -		$(if [ "$wifemode" = "enabled" ]; then $grn "[Enabled]"; else $ylow "[Disabled]"; fi)"
					echo
					printf "[1-9]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="autoupdate"
							while true; do
								echo "Select Autoupdate Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						2)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="banmalware"
							while true; do
								echo "Select Banmalware Option:"
								echo "[1]  --> Daily"
								echo "[2]  --> Weekly"
								echo "[3]  --> Disable"
								echo
								printf "[1-3]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="daily"
										break
									;;
									2)
										option3="weekly"
										break
									;;
									3)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						3)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="debugmode"
							while true; do
								echo "Select Debug Mode Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						4)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="filter"
							while true; do
								echo "Select Filter Option:"
								echo "[1]  --> All Traffic"
								echo "[2]  --> Inbound"
								echo "[3]  --> Outbound"
								echo
								printf "[1-3]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="all"
										break
									;;
									2)
										option3="inbound"
										break
									;;
									3)
										option3="outbound"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						5)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="unbanprivate"
							while true; do
								echo "Select Filter PrivateIP Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						6)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="loginvalid"
							while true; do
								echo "Select Invalid Packet Logging Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						7)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="banaiprotect"
							while true; do
								echo "Select Ban AiProtect Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						8)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="securemode"
							while true; do
								echo "Select Secure Mode Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="enable"
										break
									;;
									2)
										option3="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						9)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option1="wm"
							while true; do
								echo "Select Wife Mode Option:"
								echo "[1]  --> Enable"
								echo "[2]  --> Disable"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										echo "Input Custom Filter List URL:"
										printf "[URL]: "
										read -r "option2"
										echo
										if [ -z "$option2" ]; then echo "[*] URL Field Can't Be Empty - Please Try Again"; echo; unset "option2"; continue; fi
										break
										break
									;;
									2)
										option2="disable"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			wm)
				option1="wm"
				break
			;;
			12)
				option1="debug"
				while true; do
					echo "Select Debug Option:"
					echo "[1]  --> Show Debug Entries As They Appear"
					echo "[2]  --> Print Debug Info"
					echo "[3]  --> Cleanup Syslog Entries"
					echo "[4]  --> SWAP File Management"
					echo "[5]  --> Backup Skynet Files"
					echo "[6]  --> Restore Skynet Files"
					echo
					printf "[1-6]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="watch"
							while true; do
								echo "Select Watch Option:"
								echo "[1]  --> All"
								echo "[2]  --> IP"
								echo "[3]  --> Port"
								echo
								printf "[1-3]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										break
									;;
									2)
										option3="ip"
										printf "[IP]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP; then echo "[*] $option4 Is Not A Valid IP"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									3)
										option3="port"
										printf "[Port]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_Port || [ "$option4" -gt "65535" ]; then echo "[*] $option4 Is Not A Valid Port"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						2)
							option2="info"
							break
						;;
						3)
							option2="clean"
							break
						;;
						4)
							option2="swap"
							while true; do
								echo "Select SWAP Option:"
								echo "[1]  --> Install"
								echo "[2]  --> Uninstall"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="install"
										break
									;;
									2)
										option3="uninstall"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						5)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="backup"
							break
						;;
						6)
							if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
							option2="restore"
							break
						;;
						e|exit|back|menu)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			13)
				option1="stats"
				while true; do
					echo "Select Stat Option:"
					echo "[1]  --> Display"
					echo "[2]  --> Search"
					echo "[3]  --> Remove"
					echo "[4]  --> Reset"
					echo
					printf "[1-4]: "
					read -r "menu2"
					echo
					case "$menu2" in
						1)
							while true; do
								echo "Show Top x Results:"
								echo "[1]  --> 10"
								echo "[2]  --> 20"
								echo "[3]  --> 50"
								echo "[4]  --> Custom"
								echo
								printf "[1-4]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="10"
										break
									;;
									2)
										option3="20"
										break
									;;
									3)
										option3="50"
										break
									;;
									4)
										echo "Enter Custom Amount:"
										echo
										printf "[Number]: "
										read -r "option3"
										echo
										if ! [ "$option3" -eq "$option3" ] 2>/dev/null; then echo "[*] $option3 Isn't A Valid Number!"; echo; unset "option3" continue; fi
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break 2
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							while true; do
								echo "Show Packet Type:"
								echo "[1]  --> All"
								echo "[2]  --> TCP"
								echo "[3]  --> UDP"
								echo "[4]  --> ICMP"
								echo
								printf "[1-4]: "
								read -r "menu4"
								echo
								case "$menu4" in
									1)
										break
									;;
									2)
										option2="tcp"
										break
									;;
									3)
										option2="udp"
										break
									;;
									4)
										option2="icmp"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu4 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						2)
							option2="search"
							while true; do
								echo "Search Options:"
								echo "[1]  --> Based On Port x"
								echo "[2]  --> Entries From Specific IP"
								echo "[3]  --> Search Malwarelists For IP"
								echo "[4]  --> Search Manualbans"
								echo "[5]  --> Search For Outbound Entries From Local Device"
								echo "[6]  --> Hourly Reports"
								echo
								printf "[1-6]: "
								read -r "menu4"
								echo
								case "$menu4" in
									1)
										option3="port"
										printf "[Port]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_Port || [ "$option4" -gt "65535" ]; then echo "[*] $option4 Is Not A Valid Port"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									2)
										option3="ip"
										printf "[IP]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP && ! echo "$option4" | Is_Range ; then echo "[*] $option4 Is Not A Valid IP/Range"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									3)
										option3="malware"
										printf "[IP]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP && ! echo "$option4" | Is_Range ; then echo "[*] $option4 Is Not A Valid IP/Range"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									4)
										option3="manualbans"
										break
									;;
									5)
										option3="device"
										printf "[Local IP]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP; then echo "[*] $option4 Is Not A Valid IP"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									6)
										option3="reports"
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break 2
									;;
									*)
										echo "[*] $menu4 Isn't An Option!"
										echo
									;;
								esac
							done
							while true; do
								echo "Show Top x Results:"
								echo "[1]  --> 10"
								echo "[2]  --> 20"
								echo "[3]  --> 50"
								echo "[4]  --> Custom"
								echo
								printf "[1-4]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										if [ -n "$option4" ]; then
											option5="10"
										else
											option4="10"
										fi
										break
									;;
									2)
										if [ -n "$option4" ]; then
											option5="20"
										else
											option4="20"
										fi
										break
									;;
									3)
										if [ -n "$option4" ]; then
											option5="50"
										else
											option4="50"
										fi
										break
									;;
									4)
										echo "Enter Custom Amount:"
										echo
										printf "[Number]: "
										read -r "optionx"
										echo
										if ! [ "$optionx" -eq "$optionx" ] 2>/dev/null; then echo "[*] $optionx Isn't A Valid Number!"; echo; unset "optionx"; continue; fi
										if [ -n "$option4" ]; then
											option5="$optionx"
										else
											option4="$optionx"
										fi
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						3)
							option2="remove"
							while true; do
								echo "Search Options:"
								echo "[1]  --> Logs Containing Specific IP"
								echo "[2]  --> Logs Containing Specific Port"
								echo
								printf "[1-2]: "
								read -r "menu3"
								echo
								case "$menu3" in
									1)
										option3="ip"
										printf "[IP]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_IP; then echo "[*] $option4 Is Not A Valid IP"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									2)
										option3="port"
										printf "[Port]: "
										read -r "option4"
										echo
										if ! echo "$option4" | Is_Port || [ "$option4" -gt "65535" ]; then echo "[*] $option4 Is Not A Valid Port"; echo; unset "option3" "option4"; continue; fi
										break
									;;
									e|exit|back|menu)
										unset "option1" "option2" "option3" "option4" "option5"
										clear
										Load_Menu
										break 2
									;;
									*)
										echo "[*] $menu3 Isn't An Option!"
										echo
									;;
								esac
							done
							break
						;;
						4)
							option2="reset"
							break
						;;
						e|exit)
							unset "option1" "option2" "option3" "option4" "option5"
							clear
							Load_Menu
							break
						;;
						*)
							echo "[*] $menu2 Isn't An Option!"
							echo
						;;
					esac
				done
				break
			;;
			14)
				option1="install"
				break
			;;
			15)
				option1="uninstall"
				break
			;;
			r|reload)
				clear
				Load_Menu
				break
			;;
			e|exit)
				echo "[*] Exiting!"
				echo; exit 0
			;;
			*)
				echo "[*] $menu Isn't An Option!"
				echo
			;;
		esac
	done
}

if [ -z "$1" ]; then
	Load_Menu
fi

if [ -n "$option1" ]; then
	set "$option1" "$option2" "$option3" "$option4" "$option5"
	stime="$(date +%s)"
	echo "[$] $0 $*" | tr -s " "
	echo
fi

if [ -f "$skynetcfg" ]; then
	. "$skynetcfg"
fi


##############
#- Commands -#
##############


case "$1" in
	unban)
		if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
		Check_Lock "$@"
		Purge_Logs
		case "$2" in
			ip)
				if ! echo "$3" | Is_IP; then echo "[*] $3 Is Not A Valid IP"; echo; exit 2; fi
				echo "[i] Unbanning $3"
				ipset -D Skynet-Blacklist "$3"
				sed -i "\\~\\(BLOCKED.*=$3 \\|Manual Ban.*=$3 \\)~d" "$skynetlog" "$skynetevents"
			;;
			range)
				if ! echo "$3" | Is_Range; then echo "[*] $3 Is Not A Valid Range"; echo; exit 2; fi
				echo "[i] Unbanning $3"
				ipset -D Skynet-BlockedRanges "$3"
				sed -i "\\~\\(BLOCKED.*=$3 \\|Manual Ban.*=$3 \\)~d" "$skynetlog" "$skynetevents"
			;;
			domain)
				if [ -z "$3" ]; then echo "[*] Domain Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
				echo "[i] Removing $3 From Blacklist"
				for ip in $(Domain_Lookup "$3"); do
					echo "[i] Unbanning $ip"
					ipset -D Skynet-Blacklist "$ip"
					sed -i "\\~\\(BLOCKED.*=$ip \\|Manual Ban.*=$ip \\)~d" "$skynetlog" "$skynetevents"
				done
			;;
			comment)
				if [ -z "$3" ]; then echo "[*] Comment Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
				echo "[i] Removing Bans With Comment Containing ($3)"
				sed "\\~add Skynet-Whitelist ~d;\\~$3~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
				echo "[i] Removing Old Logs - This May Take Awhile (To Skip Type ctrl+c)"
				trap 'break; echo' 2
				sed "\\~add Skynet-Whitelist ~d;\\~$3~!d;s~ comment.*~~" "$skynetipset" | cut -d' ' -f3 | while IFS= read -r "ip"; do
					sed -i "\\~\\(BLOCKED.*=$ip \\|Manual Ban.*=$ip \\)~d" "$skynetlog" "$skynetevents"
				done
			;;
			country)
				echo "[i] Removing Previous Country Bans (${countrylist})"
				sed '\~add Skynet-Whitelist ~d;\~Country: ~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
				unset "countrylist"
			;;
			malware)
				echo "[i] Removing Previous Malware Bans"
				sed '\~add Skynet-Whitelist ~d;\~BanMalware~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
			;;
			nomanual)
				sed -i '\~Manual ~!d' "$skynetlog"
				ipset flush Skynet-Blacklist
				ipset flush Skynet-BlockedRanges
				sed '\~add Skynet-Whitelist ~d;\~Manual[R]*Ban: ~!d' "$skynetipset" | ipset restore -!
				iptables -Z PREROUTING -t raw
			;;
			all)
				echo "[i] Removing All $((blacklist1count + blacklist2count)) Entries From Blacklist"
				ipset flush Skynet-Blacklist
				ipset flush Skynet-BlockedRanges
				iptables -Z PREROUTING -t raw
				true > "$skynetlog"
				sed -i '\~Manual Ban~d' "$skynetevents"

			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
		Save_IPSets
		echo
	;;

	ban)
		if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
		Check_Lock "$@"
		Purge_Logs
		case "$2" in
			ip)
				if ! echo "$3" | Is_IP; then echo "[*] $3 Is Not A Valid IP"; echo; exit 2; fi
				if [ "${#4}" -gt "244" ]; then echo "[*] $4 Is Not A Valid Comment. 244 Chars Max"; echo; exit 2; fi
				echo "[i] Banning $3"
				desc="$4"
				if [ -z "$4" ]; then
					desc="$(date +"%b %d %T")"
				fi
				ipset -A Skynet-Blacklist "$3" comment "ManualBan: $desc" && echo "$(date +"%b %d %T") Skynet: [Manual Ban] TYPE=Single SRC=$3 COMMENT=$desc " >> "$skynetevents"
			;;
			range)
				if ! echo "$3" | Is_Range; then echo "[*] $3 Is Not A Valid Range"; echo; exit 2; fi
				if [ "${#4}" -gt "243" ]; then echo "[*] $4 Is Not A Valid Comment. 243 Chars Max"; echo; exit 2; fi
				echo "[i] Banning $3"
				desc="$4"
				if [ -z "$4" ]; then
					desc="$(date +"%b %d %T")"
				fi
				ipset -A Skynet-BlockedRanges "$3" comment "ManualRBan: $desc" && echo "$(date +"%b %d %T") Skynet: [Manual Ban] TYPE=Range SRC=$3 COMMENT=$desc " >> "$skynetevents"
			;;
			domain)
				if [ -z "$3" ]; then echo "[*] Domain Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
				echo "[i] Adding $3 To Blacklist"
				for ip in $(Domain_Lookup "$3"); do
					echo "[i] Banning $ip"
					ipset -A Skynet-Blacklist "$ip" comment "ManualBanD: $3" && echo "$(date +"%b %d %T") Skynet: [Manual Ban] TYPE=Domain SRC=$ip Host=$3 " >> "$skynetevents"
				done
			;;
			country)
				if [ -z "$3" ]; then echo "[*] Country Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
				if echo "$3" | grep -qF "\""; then echo "[*] Country Field Can't Include Quotes - Please Try Again"; echo; exit 2; fi
				countrylinklist="$(echo $3 | awk '{print tolower($0)}')"
				if [ -n "$countrylist" ]; then
					echo "[i] Removing Previous Country Bans (${countrylist})"
					sed '\~add Skynet-Whitelist ~d;\~Country: ~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
				fi
				if [ "${#3}" -gt "246" ]; then countrylist="Multiple Countries"; else countrylist="$countrylinklist"; fi
				echo "[i] Banning Known IP Ranges For (${3})"
				echo "[i] Downloading Lists"
				for country in $countrylinklist; do
					/usr/sbin/curl -fsL --retry 3 http://ipdeny.com/ipblocks/data/aggregated/"$country"-aggregated.zone >> /tmp/countrylist.txt
				done
				echo "[i] Filtering IPv4 Ranges & Applying Blacklists"
				grep -F "/" /tmp/countrylist.txt | sed -n "/^[0-9,\\.,\\/]*$/s/^/add Skynet-BlockedRanges /;s/$/& comment \"Country: $countrylist\"/p" | ipset restore -!
				rm -rf "/tmp/countrylist.txt"
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
		Save_IPSets
		echo
	;;

	banmalware|wm)
		if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
		trap '' 2
		Check_Lock "$@"
		Purge_Logs
		if [ "$2" = "disable" ] && [ "$wifemode" = "disabled" ] && [ "$1" = "wm" ]; then
			echo "[*] Wife Mode Already Disabled - Stopping Banmalware"
			echo; exit 1
		fi
		if [ "$wifemode" = "enabled" ] && [ "$1" = "wm" ] && [ -z "$2" ]; then
			echo "[i] Wife Mode Disabled"
			wifemode="disabled"
			set "banmalware"
		fi
		if [ "$wifemode" = "enabled" ] && [ "$1" = "banmalware" ]; then
			set "wm"
		fi
		if [ "$2" = "exclude" ]; then
			if [ "$3" = "reset" ] || [ -z "$3" ]; then
				echo "[i] Exclusion List Reset"
				unset "excludelists"
			else
				excludelists="$3"
			fi
			set "banmalware"
		fi
		if [ -n "$excludelists" ]; then echo "[i] Excluding Lists Matching The Words; $excludelists"; fi
		if [ "$2" = "reset" ]; then
			echo "[i] Filter URL Reset"
			unset "customlisturl"
		fi
		if [ -n "$2" ] && [ "$2" != "reset" ] && [ "$1" != "wm" ]; then
			customlisturl="$2"
			listurl="$customlisturl"
			echo "[i] Custom Filter Detected: $customlisturl"
		elif [ "$1" = "wm" ]; then
			if [ -z "$2" ] && [ -z "$customlist2url" ]; then
				logger -st Skynet "[*] Wife-Mode URL Not Detected - Stopping Banmalware"
				echo; exit 1
			else
				wifemode="enabled"
				echo "[i] Wife Mode Enabled"
				if [ -z "$customlist2url" ] || [ -n "$2" ]; then
					customlist2url="$2"
					listurl="$customlist2url"
				else
					listurl="$customlist2url"
				fi
				echo "[i] Custom Filter Detected: $customlist2url"
			fi
		else
			if [ -n "$customlisturl" ]; then
				listurl="$customlisturl"
				echo "[i] Custom Filter Detected: $customlisturl"
			else
				listurl="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/filter.list"
			fi
		fi
		/usr/sbin/curl -fsL --retry 3 "$listurl" >/dev/null 2>&1 || { logger -st Skynet "[*] 404 Error Detected - Stopping Banmalware" ; echo; exit 1; }
		btime="$(date +%s)" && printf "[i] Downloading filter.list 	"
		if [ -n "$excludelists" ]; then
			/usr/sbin/curl -fsL --retry 3 "$listurl" | dos2unix | grep -vE "($excludelists)" > /jffs/shared-Skynet-whitelist && $grn "[$(($(date +%s) - btime))s]"
		else
			/usr/sbin/curl -fsL --retry 3 "$listurl" | dos2unix > /jffs/shared-Skynet-whitelist && $grn "[$(($(date +%s) - btime))s]"
		fi
		echo >> /jffs/shared-Skynet-whitelist
		btime="$(date +%s)" && printf "[i] Refreshing Whitelists	"
		Whitelist_Extra
		Whitelist_CDN
		Whitelist_VPN
		Whitelist_Shared >/dev/null 2>&1
		Refresh_MWhitelist && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Consolidating Blacklist 	"
		mkdir -p /tmp/skynet
		cwd="$(pwd)"
		cd /tmp/skynet || exit 1
		while IFS= read -r "domain" && [ -n "$domain" ]; do
			/usr/sbin/curl -fsL --retry 3 "$domain" -O &
		done < /jffs/shared-Skynet-whitelist
		wait
		cd "$cwd" || exit 1
		dos2unix /tmp/skynet/*
		cat /tmp/skynet/* | grep -oE '^[0-9,./]*$' | awk '!x[$0]++' | Filter_PrivateIP > /tmp/skynet/malwarelist.txt && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Filtering IPv4 Addresses 	"
		sed -i '\~comment \"BanMalware\"~d' "$skynetipset"
		grep -vF "/" /tmp/skynet/malwarelist.txt | awk '{print "add Skynet-Blacklist " $1 " comment \"BanMalware\""}' >> "$skynetipset" && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Filtering IPv4 Ranges 	"
		grep -F "/" /tmp/skynet/malwarelist.txt | awk '{print "add Skynet-BlockedRanges " $1 " comment \"BanMalware\""}' >> "$skynetipset" && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Applying New Blacklist	"
		ipset flush Skynet-Blacklist; ipset flush Skynet-BlockedRanges
		ipset restore -! -f "$skynetipset" >/dev/null 2>&1 && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Refreshing AiProtect Bans 	"
		Refresh_AiProtect && $grn "[$(($(date +%s) - btime))s]"
		btime="$(date +%s)" && printf "[i] Saving Changes 		"
		Save_IPSets >/dev/null 2>&1 && $grn "[$(($(date +%s) - btime))s]"
		unset "forcebanmalwareupdate"
		echo
		echo "[i] For False Positive Website Bans Use; ( sh $0 whitelist domain URL )"
		rm -rf /tmp/skynet
		trap - 2
		echo
	;;

	whitelist)
		if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
		Check_Lock "$@"
		Purge_Logs
		case "$2" in
			ip|range)
				if ! echo "$3" | Is_IP && ! echo "$3" | Is_Range ; then echo "[*] $3 Is Not A Valid IP/Range"; echo; exit 2; fi
				if [ "${#4}" -gt "242" ]; then echo "[*] $4 Is Not A Valid Comment. 242 Chars Max"; echo; exit 2; fi
				echo "[i] Whitelisting $3"
				desc="$4"
				if [ -z "$4" ]; then
					desc="$(date +"%b %d %T")"
				fi
				ipset -A Skynet-Whitelist "$3" comment "ManualWlist: $desc" && sed -i "\\~=$3 ~d" "$skynetlog" "$skynetevents" && echo "$(date +"%b %d %T") Skynet: [Manual Whitelist] TYPE=Single SRC=$3 COMMENT=$desc " >> "$skynetevents"
				ipset -q -D Skynet-Blacklist "$3"
				ipset -q -D Skynet-BlockedRanges "$3"
			;;
			domain)
				if [ -z "$3" ]; then echo "[*] Domain Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
				echo "[i] Adding $3 To Whitelist"
				for ip in $(Domain_Lookup "$3"); do
					echo "[i] Whitelisting $ip"
					ipset -A Skynet-Whitelist "$ip" comment "ManualWlistD: $3" && sed -i "\\~=$ip ~d" "$skynetlog" "$skynetevents" && echo "$(date +"%b %d %T") Skynet: [Manual Whitelist] TYPE=Domain SRC=$ip Host=$3 " >> "$skynetevents"
					ipset -q -D Skynet-Blacklist "$ip"
				done
				if [ "$?" = "1" ]; then echo "$3" >> /jffs/shared-Skynet2-whitelist; fi
			;;
			vpn)
				echo "[i] Updating VPN Whitelist"
				Whitelist_VPN
			;;
			remove)
				case "$3" in
					entry)
						if ! echo "$4" | Is_IP && ! echo "$4" | Is_Range ; then echo "[*] $4 Is Not A Valid IP/Range"; echo; exit 2; fi
						echo "[i] Removing $4 From Whitelist"
						ipset -D Skynet-Whitelist "$4" && sed -i "\\~=$4 ~d" "$skynetlog" "$skynetevents"
					;;
					comment)
						if [ -z "$4" ]; then echo "[*] Comment Field Can't Be Empty - Please Try Again"; echo; exit 2; fi
						echo "[i] Removing All Entries With Comment Matching \"$4\" From Whitelist"
						sed "\\~add Skynet-Whitelist ~!d;\\~$4~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
						sed "\\~add Skynet-Whitelist ~!d;\\~$4~!d" "$skynetipset" | awk '{print $3}' > /tmp/ip.list
						while read -r ip; do
							sed -i "\\~=$ip ~d" "$skynetlog" "$skynetevents"
						done < /tmp/ip.list
						rm -rf /tmp/ip.list
					;;
					all)
						echo "[i] Flushing Whitelist"
						ipset flush Skynet-Whitelist
						echo "[i] Adding Default Entries"
						true > "$skynetipset"
						sed -i '\~Manual Whitelist~d' "$skynetevents"
						Whitelist_Extra
						Whitelist_CDN
						Whitelist_VPN
						Whitelist_Shared
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			refresh)
				echo "[i] Refreshing Shared Whitelist Files"
				Whitelist_Extra
				Whitelist_CDN
				Whitelist_VPN
				Whitelist_Shared
				Refresh_MWhitelist
			;;
			list)
				case "$3" in
					ips)
						sed '\~add Skynet-Whitelist ~!d;\~ManualWlist:~!d;s~add Skynet-Whitelist ~~' "$skynetipset"
					;;
					domains)
						sed '\~add Skynet-Whitelist ~!d;\~ManualWlistD:~!d;s~add Skynet-Whitelist ~~' "$skynetipset"
					;;
					imported)
						sed '\~add Skynet-Whitelist ~!d;\~Imported:~!d;s~add Skynet-Whitelist ~~' "$skynetipset"
					;;
					*)
						sed '\~add Skynet-Whitelist ~!d;s~add Skynet-Whitelist ~~' "$skynetipset"
					;;
				esac
				echo
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
		Save_IPSets
		echo
	;;

	import)
		case "$2" in
			blacklist)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				Purge_Logs
				echo "[i] This Function Extracts All IPs And Adds Them ALL To Blacklist"
				if [ -f "$3" ]; then
					echo "[i] Local Custom List Detected: $3"
					grep -oE '^[0-9,./]*$' "$3" > /tmp/iplist-unfiltered.txt
				elif [ -n "$3" ]; then
					echo "[i] Remote Custom List Detected: $3"
					/usr/sbin/curl -fsL --retry 3 "$3" | grep -oE '^[0-9,./]*$' > /tmp/iplist-unfiltered.txt || { echo "[*] 404 Error Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }
				else
					echo "[*] URL/File Field Can't Be Empty - Please Try Again"
					echo; exit 2
				fi
				dos2unix /tmp/iplist-unfiltered.txt
				if ! grep -qE '^[0-9,./]*$' /tmp/iplist-unfiltered.txt; then { echo "[*] No Content Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }; fi
				echo "[i] Processing List"
				if [ -n "$4" ] && [ "${#4}" -le "245" ]; then
					grep -vF "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk -v desc="Imported: $4" '{print "add Skynet-Blacklist " $1 " comment \"" desc "\""}' > /tmp/iplist-filtered.txt
					grep -F "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk -v desc="Imported: $4" '{print "add Skynet-BlockedRanges " $1 " comment \"" desc "\""}' >> /tmp/iplist-filtered.txt
				else
					imptime="$(date +"%b %d %T")"
					grep -vF "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk -v imptime="$imptime" '{print "add Skynet-Blacklist " $1 " comment \"Imported: " imptime "\""}' > /tmp/iplist-filtered.txt
					grep -F "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk -v imptime="$imptime" '{print "add Skynet-BlockedRanges " $1 " comment \"Imported: " imptime "\""}' >> /tmp/iplist-filtered.txt
				fi
				echo "[i] Adding IPs To Blacklist"
				ipset restore -! -f "/tmp/iplist-filtered.txt"
				rm -rf /tmp/iplist-unfiltered.txt /tmp/iplist-filtered.txt
				Save_IPSets
				echo
			;;
			whitelist)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				Purge_Logs
				echo "[i] This Function Extracts All IPs And Adds Them ALL To Whitelist"
				if [ -f "$3" ]; then
					echo "[i] Local Custom List Detected: $3"
					grep -oE '^[0-9,./]*$' "$3" > /tmp/iplist-unfiltered.txt
				elif [ -n "$3" ]; then
					echo "[i] Remote Custom List Detected: $3"
					/usr/sbin/curl -fsL --retry 3 "$3" | grep -oE '^[0-9,./]*$' > /tmp/iplist-unfiltered.txt || { echo "[*] 404 Error Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }
				else
					echo "[*] URL/File Field Can't Be Empty - Please Try Again"
					echo; exit 2
				fi
				dos2unix /tmp/iplist-unfiltered.txt
				if ! grep -qE '^[0-9,./]*$' /tmp/iplist-unfiltered.txt; then { echo "[*] No Content Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }; fi
				echo "[i] Processing List"
				if [ -n "$4" ] && [ "${#4}" -le "245" ]; then
					Filter_PrivateIP < /tmp/iplist-unfiltered.txt | awk -v desc="Imported: $4" '{print "add Skynet-Whitelist " $1 " comment \"" desc "\""}' > /tmp/iplist-filtered.txt
				else
					imptime="$(date +"%b %d %T")"
					Filter_PrivateIP < /tmp/iplist-unfiltered.txt | awk -v imptime="$imptime" '{print "add Skynet-Whitelist " $1 " comment \"Imported: " imptime "\""}' > /tmp/iplist-filtered.txt
				fi
				echo "[i] Adding IPs To Whitelist"
				ipset restore -! -f "/tmp/iplist-filtered.txt"
				rm -rf /tmp/iplist-unfiltered.txt /tmp/iplist-filtered.txt
				Save_IPSets
				echo
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
	;;

	deport)
		case "$2" in
			blacklist)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				Purge_Logs
				echo "[i] This Function Extracts All IPs And Removes Them ALL From Blacklist"
				if [ -f "$3" ]; then
					echo "[i] Local Custom List Detected: $3"
					grep -oE '^[0-9,./]*$' "$3" > /tmp/iplist-unfiltered.txt
				elif [ -n "$3" ]; then
					echo "[i] Remote Custom List Detected: $3"
					/usr/sbin/curl -fsL --retry 3 "$3" | grep -oE '^[0-9,./]*$' > /tmp/iplist-unfiltered.txt || { echo "[*] 404 Error Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }
				else
					echo "[*] URL/File Field Can't Be Empty - Please Try Again"
					echo; exit 2
				fi
				dos2unix /tmp/iplist-unfiltered.txt
				if [ "$(grep -coE '^[0-9,./]*$' /tmp/iplist-unfiltered.txt)" = "0" ]; then { echo "[*] No Content Detected - Stopping Deport"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }; fi
				echo "[i] Processing IPv4 Addresses"
				grep -vF "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk '{print "del Skynet-Blacklist " $1}' > /tmp/iplist-filtered.txt
				echo "[i] Processing IPv4 Ranges"
				grep -F "/" /tmp/iplist-unfiltered.txt | Filter_PrivateIP | awk '{print "del Skynet-BlockedRanges " $1}' >> /tmp/iplist-filtered.txt
				echo "[i] Removing IPs From Blacklist"
				ipset restore -! -f "/tmp/iplist-filtered.txt"
				rm -rf /tmp/iplist-unfiltered.txt /tmp/iplist-filtered.txt
				Save_IPSets
				echo
			;;
			whitelist)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				Purge_Logs
				echo "[i] This Function Extracts All IPs And Removes Them ALL From Whitelist"
				if [ -f "$3" ]; then
					echo "[i] Local Custom List Detected: $3"
					grep -oE '^[0-9,./]*$' "$3" > /tmp/iplist-unfiltered.txt
				elif [ -n "$3" ]; then
					echo "[i] Remote Custom List Detected: $3"
					/usr/sbin/curl -fsL --retry 3 "$3" | grep -oE '^[0-9,./]*$' > /tmp/iplist-unfiltered.txt || { echo "[*] 404 Error Detected - Stopping Import"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }
				else
					echo "[*] URL/File Field Can't Be Empty - Please Try Again"
					echo; exit 2
				fi
				dos2unix /tmp/iplist-unfiltered.txt
				if [ "$(grep -coE '^[0-9,./]*$' /tmp/iplist-unfiltered.txt)" = "0" ]; then { echo "[*] No Content Detected - Stopping Deport"; rm -rf /tmp/iplist-unfiltered.txt; echo; exit 1; }; fi
				echo "[i] Processing IPv4 Addresses"
				Filter_PrivateIP < /tmp/iplist-unfiltered.txt | awk '{print "del Skynet-Whitelist " $1}' > /tmp/iplist-filtered.txt
				echo "[i] Removing IPs From Whitelist"
				ipset restore -! -f "/tmp/iplist-filtered.txt"
				rm -rf /tmp/iplist-unfiltered.txt /tmp/iplist-filtered.txt
				Save_IPSets
				echo
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
	;;

	save)
		if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
		Check_Lock "$@"
		Unban_PrivateIP
		Purge_Logs
		Save_IPSets
		Check_Security
		sed -i "\\~USER $(nvram get http_username) pid .*/jffs/scripts/firewall ~d" /tmp/syslog.log
		echo
	;;

	start)
		trap '' 2
		Check_Lock "$@"
		logger -st Skynet "[%] Startup Initiated... ( $(echo "$@" | sed 's~start ~~g') )"
		Unload_Cron "all"
		Check_Settings
		Check_Files "verify"
		Load_Cron "save"
		modprobe xt_set
		if [ -f "$skynetipset" ]; then ipset restore -! -f "$skynetipset"; else logger -st Skynet "[i] Setting Up Skynet"; touch "$skynetipset"; fi
		if ! ipset -L -n Skynet-Whitelist >/dev/null 2>&1; then ipset -q create Skynet-Whitelist hash:net comment; fi
		if ! ipset -L -n Skynet-Blacklist >/dev/null 2>&1; then ipset -q create Skynet-Blacklist hash:ip --maxelem 500000 comment; fi
		if ! ipset -L -n Skynet-BlockedRanges >/dev/null 2>&1; then ipset -q create Skynet-BlockedRanges hash:net --maxelem 200000 comment; fi
		if ! ipset -L -n Skynet-Master >/dev/null 2>&1; then ipset -q create Skynet-Master list:set; ipset -q -A Skynet-Master Skynet-Blacklist; ipset -q -A Skynet-Master Skynet-BlockedRanges; fi
		Unban_PrivateIP
		Purge_Logs "all"
		sed '\~add Skynet-Whitelist ~!d;\~nvram: ~!d;s~ comment.*~~;s~add~del~g' "$skynetipset" | ipset restore -!
		Whitelist_Extra
		Whitelist_CDN
		Whitelist_VPN
		Whitelist_Shared
		Refresh_MWhitelist
		Refresh_MBans
		Refresh_AiProtect
		Check_Security
		Save_IPSets
		while [ "$(($(date +%s) - stime))" -lt "20" ]; do
			sleep 1
		done
		Unload_IPTables
		Unload_DebugIPTables
		Load_IPTables
		Load_DebugIPTables
		sed -i '\~DROP IN=~d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null
		trap - 2
		if [ "$forcebanmalwareupdate" = "true" ]; then Write_Config; rm -rf "/tmp/skynet.lock"; exec "$0" banmalware; fi
	;;

	restart)
		Check_Lock "$@"
		Purge_Logs
		Save_IPSets
		echo "[i] Unloading Skynet Components"
		Unload_Cron "all"
		Unload_IPTables
		Unload_DebugIPTables
		Unload_IPSets
		iptables -t raw -F
		logger -t Skynet "[%] Restarting Firewall Service"; echo "[%] Restarting Firewall Service"
		restartfirewall="1"
		nolog="2"
		echo
	;;

	disable)
		Check_Lock "$@"
		Save_IPSets
		echo "[i] Unloading Skynet Components"
		Unload_Cron "all"
		Unload_IPTables
		Unload_DebugIPTables
		Unload_IPSets
		logger -t Skynet "[%] Skynet Disabled"; echo "[%] Skynet Disabled"
		Purge_Logs "all"
		nolog="2"
		echo
	;;

	update)
		Check_Lock "$@"
		trap '' 2
		remoteurl="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/firewall.sh"
		/usr/sbin/curl -fsL --retry 3 "$remoteurl" | grep -qF "Adamm" || { logger -st Skynet "[*] 404 Error Detected - Stopping Update"; echo; exit 1; }
		remotever="$(/usr/sbin/curl -fsL --retry 3 "$remoteurl" | Filter_Version)"
		if [ "$localver" = "$remotever" ] && [ "$2" != "-f" ]; then
			logger -t Skynet "[%] Skynet Up To Date - $localver"; echo "[%] Skynet Up To Date - $localver"
			nolog="2"
		elif [ "$localver" != "$remotever" ] && [ "$2" = "check" ]; then
			logger -t Skynet "[%] Skynet Update Detected - $remotever"; echo "[%] Skynet Update Detected - $remotever"
			nolog="2"
		elif [ "$2" = "-f" ]; then
			echo "[i] Forcing Update"
		fi
		if [ "$localver" != "$remotever" ] || [ "$2" = "-f" ] && [ "$nolog" != "2" ]; then
			logger -t Skynet "[%] New Version Detected - Updating To $remotever"; echo "[%] New Version Detected - Updating To $remotever"
			Save_IPSets >/dev/null 2>&1
			echo "[i] Unloading Skynet Components"
			Unload_Cron "all"
			Unload_IPTables
			Unload_DebugIPTables
			Unload_IPSets
			iptables -t raw -F
			/usr/sbin/curl -fsL --retry 3 "$remoteurl" -o "$0" || { logger -st Skynet "[*] Update Failed - Exiting"; echo; exit 1; }
			logger -t Skynet "[%] Restarting Firewall Service"; echo "[%] Restarting Firewall Service"
			service restart_firewall
			echo; exit 0
		fi
		trap - 2
		echo
	;;

	settings)
		case "$2" in
			autoupdate)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						autoupdate="enabled"
						Unload_Cron "checkupdate"
						Load_Cron "autoupdate"
						echo "[i] Skynet Automatic Updates Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						autoupdate="disabled"
						Unload_Cron "autoupdate"
						Load_Cron "checkupdate"
						echo "[i] Skynet Automatic Updates Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			banmalware)
				case "$3" in
					daily)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						banmalwareupdate="daily"
						Unload_Cron "banmalware"
						Load_Cron "banmalwaredaily"
						echo "[i] Daily Banmalware Updates Enabled"
					;;
					weekly)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						banmalwareupdate="weekly"
						Unload_Cron "banmalware"
						Load_Cron "banmalwareweekly"
						echo "[i] Weekly Banmalware Updates Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						banmalwareupdate="disabled"
						Unload_Cron "banmalware"
						echo "[i] Banmalware Updates Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			debugmode)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						debugmode="enabled"
						Unload_DebugIPTables
						Load_DebugIPTables
						echo "[i] Debug Mode Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						debugmode="disabled"
						Unload_DebugIPTables
						echo "[i] Debug Mode Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			filter)
				case "$3" in
					all)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						filtertraffic="all"
						Unload_IPTables
						Unload_DebugIPTables
						Load_IPTables
						Load_DebugIPTables
						echo "[i] Inbound & Outbound Filtering Enabled"

					;;
					inbound)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						filtertraffic="inbound"
						Unload_IPTables
						Unload_DebugIPTables
						Load_IPTables
						Load_DebugIPTables
						echo "[i] Inbound Filtering Enabled"
					;;
					outbound)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						filtertraffic="outbound"
						Unload_IPTables
						Unload_DebugIPTables
						Load_IPTables
						Load_DebugIPTables
						echo "[i] Outbound Filtering Enabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			unbanprivate)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						unbanprivateip="enabled"
						echo "[i] Unban Private IP Enabled"

					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						unbanprivateip="disabled"
						echo "[i] Unban Private IP Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			loginvalid)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						loginvalid="enabled"
						Unload_DebugIPTables
						Load_DebugIPTables
						echo "[i] Invalid IP Logging Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						loginvalid="disabled"
						Unload_DebugIPTables
						Load_DebugIPTables
						echo "[i] Invalid IP Logging Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			banaiprotect)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						if [ ! -f /opt/bin/opkg ]; then echo "[i] This Feature Requires Entware - Exiting"; echo; exit 0; fi
						banaiprotect="enabled"
						Refresh_AiProtect
						echo "[i] Ban AiProtect Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						banaiprotect="disabled"
						sed "\\~add Skynet-Blacklist ~!d;\\~BanAiProtect~!d;s~ comment.*~~;s~add~del~g" "$skynetipset" | ipset restore -!
						echo "[i] Ban AiProtect Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
				Save_IPSets
			;;
			securemode)
				case "$3" in
					enable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						securemode="enabled"
						Check_Security
						echo "[i] Secure Mode Enabled"
					;;
					disable)
						if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
						Check_Lock "$@"
						Purge_Logs
						securemode="disabled"
						echo "[i] Secure Mode Disabled"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
		echo
	;;

	debug)
		case "$2" in
			watch)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				if [ "$debugmode" = "disabled" ]; then echo "[*] Debug Mode Is Disabled - Exiting!"; echo; exit 2; fi
				trap 'echo;echo; echo "[*] Stopping Log Monitoring"; Purge_Logs' 2
				echo "[i] Watching Logs For Debug Entries (ctrl +c) To Stop"
				echo
				Purge_Logs
				case "$3" in
					ip)
						if ! echo "$4" | Is_IP; then echo "[*] $4 Is Not A Valid IP"; echo; exit 2; fi
						echo "[i] Filtering Entries Involving IP $4"
						echo
						tail -F /tmp/syslog.log | while read -r logoutput; do
							if echo "$logoutput" | grep -qE "INVALID.*=$4 "; then
								$blue "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $blue "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -qE "INBOUND.*=$4 "; then
								$ylow "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -qE "OUTBOUND.*=$4 "; then
								$red "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							fi
						done
					;;
					port)
						if ! echo "$4" | Is_Port || [ "$4" -gt "65535" ]; then echo "[*] $4 Is Not A Valid Port"; echo; exit 2; fi
						echo "[i] Filtering Entries Involving Port $4"
						echo
						tail -F /tmp/syslog.log | while read -r logoutput; do
							if echo "$logoutput" | grep -qE "INAVLID.*PT=$4 "; then
								$blue "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $blue "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -qE "INBOUND.*PT=$4 "; then
								$ylow "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -qE "OUTBOUND.*PT=$4 "; then
								$red "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							fi
						done
					;;
					*)
						tail -F /tmp/syslog.log | while read -r logoutput; do
							if echo "$logoutput" | grep -q "INVALID"; then
								$blue "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $blue "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -q "INBOUND"; then
								$ylow "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							elif echo "$logoutput" | grep -q "OUTBOUND"; then
								$red "$logoutput"
								if [ "$extendedstats" = "enabled" ]; then
									domainlist="$(grep -E "reply.* is $(echo "$logoutput" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sed 's/.$//')" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | xargs)"
									[ -n "$domainlist" ] && $red "Associated Domain(s) - [$domainlist]"
								fi
							fi
						done
					;;
				esac
				nocfg="1"
			;;
			info)
				echo "Router Model; $model"
				echo "Skynet Version; $localver ($(Filter_Date "$0"))"
				echo "$(iptables --version) - ($iface @ $(nvram get lan_ipaddr))"
				ipset -v
				echo "FW Version; $(nvram get buildno)_$(nvram get extendno) ($(uname -v | awk '{print $5" "$6" "$9}')) ($(uname -r))"
				echo "Install Dir; $skynetloc ($(df -h "$skynetloc" | xargs | awk '{print $11 " / " $9}') Space Available)"
				if grep -F "swapon" /jffs/scripts/post-mount 2>/dev/null | grep -qvE "^#"; then swaplocation="$(grep -o "swapon .*" /jffs/scripts/post-mount | grep -vE "^#" | awk '{print $2}')"; echo "SWAP File; $swaplocation ($(du -h "$swaplocation" | awk '{print $1}'))"; fi
				echo "Boot Args; $(grep -E "start.* # Skynet" /jffs/scripts/firewall-start | grep -vE "^#" | cut -c 4- | cut -d '#' -f1)"
				if [ -n "$countrylist" ]; then echo "Banned Countries; $countrylist"; fi
				if [ -f "/tmp/skynet.lock" ] && [ -d "/proc/$(sed -n '2p' /tmp/skynet.lock)" ]; then $red "[*] Lock File Detected ($(sed -n '1p' /tmp/skynet.lock)) (pid=$(sed -n '2p' /tmp/skynet.lock))"; lockedwarning=1; else $grn "No Lock File Found"; fi
				if [ -n "$lockedwarning" ]; then $ylow "[*] Locked Processes Generally Take 1-2 Minutes To Complete And May Result In Temporarily \"Failed\" Tests"; fi
				unset "lockedwarning"
				passedtests="0"
				totaltests="16"
				echo
				printf "[i] Checking Install Directory Write Permissions...	"
				if [ -w "$skynetloc" ]; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Firewall-Start Entry...			"
				if grep -E "start.* # Skynet" /jffs/scripts/firewall-start | grep -qvE "^#"; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Services-Stop Entry...			"
				if grep -F "# Skynet" /jffs/scripts/services-stop | grep -qvE "^#"; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking CronJobs...				"
				if [ "$(cru l | grep -c "Skynet")" -ge "2" ]; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking IPSet Comment Support...			"
				if [ -f /lib/modules/"$(uname -r)"/kernel/net/netfilter/ipset/ip_set_hash_ipmac.ko ]; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Log Level %s Settings...			" "$(nvram get message_loglevel)"
				if [ "$(nvram get message_loglevel)" -le "$(nvram get log_level)" ]; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking For Duplicate Rules In RAW...		"
				if [ "$(iptables-save -t raw | sort | uniq -d | grep -c " ")" = "0" ]; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Inbound Filter Rules...			"
				if iptables -t raw -C PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j DROP 2>/dev/null; then $grn "[Passed]"; passedtests=$((passedtests+1));	elif [ "$filtertraffic" = "outbound" ]; then $ylow "[Disabled]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Inbound Debug Rules			"
				if iptables -t raw -C PREROUTING -i "$iface" -m set ! --match-set Skynet-Whitelist src -m set --match-set Skynet-Master src -j LOG --log-prefix "[BLOCKED - INBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null; then $grn "[Passed]"; passedtests=$((passedtests+1)); elif [ "$debugmode" = "disabled" ] || [ "$filtertraffic" = "outbound" ]; then $ylow "[Disabled]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Outbound Filter Rules...			"
				if iptables -t raw -C PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null && \
				iptables -t raw -C OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j DROP 2>/dev/null; then $grn "[Passed]"; passedtests=$((passedtests+1)); elif [ "$filtertraffic" = "inbound" ]; then $ylow "[Disabled]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Outbound Debug Rules			"
				if iptables -t raw -C PREROUTING -i br0 -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null && \
				iptables -t raw -C OUTPUT -m set ! --match-set Skynet-Whitelist dst -m set --match-set Skynet-Master dst -j LOG --log-prefix "[BLOCKED - OUTBOUND] " --log-tcp-sequence --log-tcp-options --log-ip-options 2>/dev/null; then $grn "[Passed]"; passedtests=$((passedtests+1)); elif [ "$debugmode" = "disabled" ] || [ "$filtertraffic" = "inbound" ]; then $ylow "[Disabled]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Whitelist IPSet...				"
				if ipset -L -n Skynet-Whitelist >/dev/null 2>&1; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking BlockedRanges IPSet...			"
				if ipset -L -n Skynet-BlockedRanges >/dev/null 2>&1; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Blacklist IPSet...				"
				if ipset -L -n Skynet-Blacklist >/dev/null 2>&1; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				printf "[i] Checking Skynet IPSet...				"
				if ipset -L -n Skynet-Master >/dev/null 2>&1; then $grn "[Passed]"; passedtests=$((passedtests+1)); else $red "[Failed]"; fi
				if [ -f /opt/share/diversion/.conf/diversion.conf ]; then
					printf "[i] Checking For Diversion Plus Content...   	        "
					divlocation="/opt/share/diversion"
					if grep -qE "bfPlusHosts=on" "${divlocation}/.conf/diversion.conf"; then
						$grn "[Passed]"
						passedtests=$((passedtests+1));
					elif [ -f "${divlocation}/AddPlusHostsDismissed" ]; then
						$ylow "[Dismissed]"
						passedtests=$((passedtests+1));
					else
						$red "[Failed]"
					fi
				else
					totaltests=$((totaltests-1));
				fi
				echo
				printf "[i] Checking Autoupdate Setting...			"
				if [ "$autoupdate" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi
				printf "[i] Checking Auto-Banmalware Update Setting...		"
				if [ "$banmalwareupdate" = "daily" ] || [ "$banmalwareupdate" = "weekly" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi
				printf "[i] Checking Debug Mode Setting...			"
				if [ "$debugmode" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi
				printf "[i] Checking Filter Traffic Setting...			"
				if [ "$filtertraffic" = "all" ] ; then $grn "[Enabled]"; else $ylow "[Selective]"; fi
				printf "[i] Checking Unban PrivateIP Setting...			"
				if [ "$unbanprivateip" = "enabled" ]; then $grn "[Enabled]"; else $ylow "[Disabled]"; fi
				printf "[i] Checking Log Invalid Setting...			"
				if [ "$loginvalid" = "enabled" ]; then $grn "[Enabled]"; else $ylow "[Disabled]"; fi
				printf "[i] Checking Ban AiProtect Setting...			"
				if [ "$banaiprotect" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi
				printf "[i] Checking Secure Mode Setting...			"
				if [ "$securemode" = "enabled" ]; then $grn "[Enabled]"; else $red "[Disabled]"; fi
				printf "[i] Checking Wife Mode Setting...			"
				if [ "$wifemode" = "enabled" ]; then $grn "[Enabled]"; else $ylow "[Disabled]"; fi
				echo
				echo "${passedtests}/${totaltests} Tests Sucessful."
				nocfg="1"
			;;
			clean)
				echo "[i] Cleaning Syslog Entries"
				Purge_Logs "all"
				sed -i '\~Skynet: \[%\] ~d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null
				echo "[i] Complete!"
				echo
				nolog="2"
				nocfg="1"
			;;
			swap)
				case "$3" in
					install)
						Check_Lock "$@"
						Check_Files
						if ! grep -qF "swapon" /jffs/scripts/post-mount; then
							Manage_Device
							Create_Swap
							Save_IPSets >/dev/null 2>&1
							echo "[i] Unloading Skynet Components"
							Unload_Cron "all"
							Unload_IPTables
							Unload_DebugIPTables
							Unload_IPSets
							logger -t Skynet "[%] Restarting Firewall Service"; echo "[%] Restarting Firewall Service"
							restartfirewall="1"
							nolog="2"
						else
							echo "[*] Pre-existing SWAP File Detected - Exiting!"
						fi
					;;
					uninstall)
						if ! grep -qF "swapon" /jffs/scripts/post-mount 2>/dev/null; then echo "[*] No SWAP File Detected - Exiting!"; echo; exit 1; fi
						Check_Lock "$@"
						swaplocation="$(grep -o "swapon .*" /jffs/scripts/post-mount | awk '{print $2}')"
						echo "[i] Removing SWAP File ($swaplocation)"
						if [ -f "$swaplocation" ]; then
							Save_IPSets >/dev/null 2>&1
							sed -i '\~swapon ~d' /jffs/scripts/post-mount
							swapoff "$swaplocation"
							if rm -rf "$swaplocation"; then echo "[i] SWAP File Removed"; else "[*] SWAP File Partially Removed - Please Inspect Manually"; fi
							echo "[i] Unloading Skynet Components"
							Unload_Cron "all"
							Unload_IPTables
							Unload_DebugIPTables
							Unload_IPSets
							logger -t Skynet "[%] Restarting Firewall Service"; echo "[%] Restarting Firewall Service"
							restartfirewall="1"
							nolog="2"
						else
							sed -i '\~swapon ~d' /jffs/scripts/post-mount
							echo "[*] SWAP File Partially Removed - Please Inspect Manually"
							echo; exit 1
						fi
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			backup)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				Purge_Logs
				echo "[i] Backing Up Skynet Related Files"
				echo
				Save_IPSets >/dev/null 2>&1
				tar -czvf "${skynetloc}/Skynet-Backup.tar.gz" -C "$skynetloc" skynet.ipset skynet.log events.log skynet.cfg
				echo
				echo "[i] Backup Saved To ${skynetloc}/Skynet-Backup.tar.gz"
			;;
			restore)
				if ! Check_Status; then echo "[*] Skynet Not Running - Exiting"; echo; exit 0; fi
				Check_Lock "$@"
				backuplocation="${skynetloc}/Skynet-Backup.tar.gz"
				if [ ! -f "$backuplocation" ]; then
					echo "[*] Skynet Backup Doesn't Exist In Expected Path, Please Provide Location"
					echo
					printf "[Location]: "
					read -r "backuplocation"
					echo
					if [ ! -f "$backuplocation" ]; then
						echo "[*] Skynet Backup Doesn't Exist In Specified Path - Exiting"
						echo; exit 2
					fi
				fi
				echo "[i] Restoring Skynet Backup"
				echo
				Purge_Logs
				Unload_IPTables
				Unload_DebugIPTables
				Unload_IPSets
				tar -xzvf "$backuplocation" -C "$skynetloc"
				echo
				echo "[i] Backup Restored"
				logger -t Skynet "[%] Restarting Firewall Service"; echo "[%] Restarting Firewall Service"
				restartfirewall="1"
				nolog="2"
			;;
			*)
				echo "Command Not Recognized, Please Try Again"
				echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
				echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
				echo; exit 2
			;;
		esac
		echo
	;;

	stats)
		Purge_Logs
		nocfg="1"
		if [ "$debugmode" = "disabled" ]; then
			echo
			$red "[*] !!! Debug Mode Is Disabled !!!"
			$red "[*] To Enable Use ( sh $0 settings debugmode enable )"
			echo
		fi
		if [ ! -s "$skynetlog" ] && [ ! -s "$skynetevents" ]; then
			echo "[*] No Debug Data Detected - Give This Time To Generate"
			echo; exit 0
		else
			echo "[i] Debug Data Detected in $skynetlog - $(du -h "$skynetlog" | awk '{print $1}')"
		fi
		echo "[i] Monitoring From $(grep -m1 -F "BLOCKED -" "$skynetlog" | awk '{print $1" "$2" "$3}') To $(grep -F "BLOCKED -" "$skynetlog" | tail -1 | awk '{print $1" "$2" "$3}')"
		echo "[i] $(wc -l < "$skynetlog") Block Events Detected"
		echo "[i] $({ grep -E 'INBOUND|INVALID' "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- ; grep -F "OUTBOUND" "$skynetlog" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- ; } | awk '!x[$0]++' | wc -l) Unique IPs"
		echo "[i] $(grep -Fc "Manual Ban" "$skynetevents") Manual Bans Issued"
		echo
		counter=10
		case "$2" in
			reset)
				sed -i '\~BLOCKED -~d' "$skynetlog"
				sed -i '\~Skynet: \[#\] ~d' "$skynetevents" "/tmp/syslog.log-1" "/tmp/syslog.log" 2>/dev/null
				iptables -Z PREROUTING -t raw
				echo "[i] Stat Data Reset"
			;;
			remove)
				case "$3" in
					ip)
						if ! echo "$4" | Is_IP; then echo "[*] $4 Is Not A Valid IP"; echo; exit 2; fi
						logcount="$(grep -c "=$4 " "$skynetlog")"
						sed -i "\\~=$4 ~d" "$skynetlog"
						echo "[i] $logcount Log Entries Removed Containing IP $4"
					;;
					port)
						if ! echo "$4" | Is_Port || [ "$4" -gt "65535" ]; then echo "[*] $4 Is Not A Valid Port"; echo; exit 2; fi
						logcount="$(grep -c "PT=$4 " "$skynetlog")"
						sed -i "\\~=$4 ~d" "$skynetlog"
						echo "[i] $logcount Log Entries Removed Containing Port $4"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			search)
				case "$3" in
					port)
						if ! echo "$4" | Is_Port || [ "$4" -gt "65535" ]; then echo "[*] $4 Is Not A Valid Port"; echo; exit 2; fi
						if [ "$5" -eq "$5" ] 2>/dev/null; then counter="$5"; fi
						echo "[i] Port $4 First Tracked On $(grep -m1 -F "PT=$4 " "$skynetlog" | awk '{print $1" "$2" "$3}')"
						echo "[i] Port $4 Last Tracked On $(grep -F "PT=$4 " "$skynetlog" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo "[i] $(grep -Foc "PT=$4 " "$skynetlog") Attempts Total"
						echo "[i] $(grep -F "PT=$4 " "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | awk '!x[$0]++' | wc -l) Unique IPs"
						echo
						$red "First Block Tracked On Port $4;"
						grep -m1 -F "PT=$4 " "$skynetlog"
						echo
						$red "$counter Most Recent Blocks On Port $4;";
						grep -F "PT=$4 " "$skynetlog" | tail -"$counter"
						echo
					;;
					ip)
						if ! echo "$4" | Is_IP; then echo "[*] $4 Is Not A Valid IP"; echo; exit 2; fi
						if [ "$5" -eq "$5" ] 2>/dev/null; then counter="$5"; fi
						ipset test Skynet-Whitelist "$4" && found1=true
						ipset test Skynet-Blacklist "$4" && found2=true
						ipset test Skynet-BlockedRanges "$4" && found3=true
						echo
						if [ -n "$found1" ]; then $red "Whitelist Reason;"; grep -F "add Skynet-Whitelist $(echo "$4" | cut -d '.' -f1-3)." "$skynetipset" | awk '{$1=$2=$4=""; print $0}' | tr -s " "; echo; fi
						if [ -n "$found2" ]; then $red "Blacklist Reason;"; grep -F "add Skynet-Blacklist $4 " "$skynetipset" | awk '{$1=$2=$3=$4=""; print $0}' | tr -s " "; echo; fi
						if [ -n "$found3" ]; then $red "BlockedRanges Reason;"; grep -F "add Skynet-BlockedRanges $(echo "$4" | cut -d '.' -f1-3)." "$skynetipset" | awk '{$1=$2=$4=""; print $0}' | tr -s " "; fi
						echo
						if [ "$extendedstats" = "enabled" ] && grep -q "reply.* is $4" /opt/var/log/dnsmasq*; then
							$red "Associated Domain(s);"
							grep -E "reply.* is $4" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
							echo; echo
						fi
						echo "[i] IP Location - $(curl -fsL https://ipapi.co/${4}/country_name/) ($(curl -fsL https://ipapi.co/${4}/asn/))"
						echo
						echo "[i] $4 First Tracked On $(grep -m1 -F "=$4 " "$skynetlog" | awk '{print $1" "$2" "$3}')"
						echo "[i] $4 Last Tracked On $(grep -F "=$4 " "$skynetlog" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo "[i] $(grep -Foc "=$4 " "$skynetlog") Blocks Total"
						echo
						$red "Event Log Entries From $4;"
						grep -F "=$4 " "$skynetevents"
						echo
						$red "First Block Tracked From $4;"
						grep -m1 -F "=$4 " "$skynetlog"
						echo
						$red "$counter Most Recent Blocks From $4;"
						grep -F "=$4 " "$skynetlog" | tail -"$counter"
						echo
						$red "Top $counter Targeted Ports From $4 (Inbound);"
						grep -E "INBOUND.*SRC=$4 " "$skynetlog" | grep -oE 'DPT=[0-9]{1,5}' | cut -c 5- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://www.speedguide.net/port.php?port="$2}'
						echo
						$red "Top $counter Sourced Ports From $4 (Inbound);"
						grep -E "INBOUND.*SRC=$4 " "$skynetlog" | grep -oE 'SPT=[0-9]{1,5}' | cut -c 5- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://www.speedguide.net/port.php?port="$2}'
					;;
					malware)
						Check_Lock "$@"
						if ! echo "$4" | Is_IP && ! echo "$4" | Is_Range ; then echo "[*] $4 Is Not A Valid IP/Range"; echo; exit 2; fi
						if [ "$extendedstats" = "enabled" ] && grep -q "reply.* is $4" /opt/var/log/dnsmasq*; then
							$red "Associated Domain(s);"
							grep -E "reply.* is $4" /opt/var/log/dnsmasq* | awk '{print $6}' | Strip_Domain | awk '!x[$0]++' | grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
							echo; echo
						fi
						ip="$(echo "$4" | sed "s~\\.~\\\\.~g")"
						if [ -n "$customlisturl" ]; then listurl="$customlisturl"; else listurl="https://raw.githubusercontent.com/Adamm00/IPSet_ASUS/master/filter.list"; fi
						/usr/sbin/curl -fsL --retry 3 "$listurl" -o /jffs/shared-Skynet-whitelist
						echo >> /jffs/shared-Skynet-whitelist
						mkdir -p /tmp/skynet
						cwd="$(pwd)"
						cd /tmp/skynet || exit 1
						while IFS= read -r "domain" && [ -n "$domain" ]; do
							/usr/sbin/curl -fsL --retry 3 "$domain" -O &
						done < /jffs/shared-Skynet-whitelist
						wait
						dos2unix /tmp/skynet/*
						cd "$cwd" || exit 1
						$red "Exact Matches;"
						grep -HE "^$ip$" /tmp/skynet/* | cut -d '/' -f4- | while IFS= read -r "list"; do
							echo "$(grep -F "$(echo "$list" | cut -d ':' -f1)" /jffs/shared-Skynet-whitelist) - $(echo "$list" | cut -d ':' -f2-)"
						done
						echo;echo
						$red "Possible CIDR Matches;"
						grep -HE "^$(echo "$ip" | cut -d '.' -f1-3)..*/" /tmp/skynet/* | cut -d '/' -f4- | while IFS= read -r "list"; do
							echo "$(grep -F "$(echo "$list" | cut -d ':' -f1)" /jffs/shared-Skynet-whitelist) - $(echo "$list" | cut -d ':' -f2-)"
						done
						echo
						rm -rf /tmp/skynet
					;;
					manualbans)
						if [ "$4" -eq "$4" ] 2>/dev/null; then counter="$4"; fi
						echo "First Manual Ban Issued On $(grep -m1 -F "Manual Ban" "$skynetevents" | awk '{print $1" "$2" "$3}')"
						echo "Last Manual Ban Issued On $(grep -F "Manual Ban" "$skynetevents" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo
						$red "First Manual Ban Issued;"
						grep -m1 -F "Manual Ban" "$skynetevents"
						echo
						$red "$counter Most Recent Manual Bans;"
						grep -F "Manual Ban" "$skynetevents" | tail -"$counter"
					;;
					device)
						if ! echo "$4" | Is_IP; then echo "[*] $4 Is Not A Valid IP"; echo; exit 2; fi
						if [ "$5" -eq "$5" ] 2>/dev/null; then counter="$5"; fi
						ipset test Skynet-Whitelist "$4" && found1=true
						ipset test Skynet-Blacklist "$4" && found2=true
						ipset test Skynet-BlockedRanges "$4" && found3=true
						echo
						if [ -n "$found1" ]; then $red "Whitelist Reason;"; grep -F "add Skynet-Whitelist $4 " "$skynetipset" | awk '{$1=$2=$3=$4=""; print $0}' | tr -s " "; echo; fi
						if [ -n "$found2" ]; then $red "Blacklist Reason;"; grep -F "add Skynet-Blacklist $4 " "$skynetipset" | awk '{$1=$2=$3=$4=""; print $0}' | tr -s " "; echo; fi
						if [ -n "$found3" ]; then $red "BlockedRanges Reason;"; grep -F "add Skynet-BlockedRanges $(echo "$4" | cut -d '.' -f1-3)." "$skynetipset" | awk '{$1=$2=$4=""; print $0}' | tr -s " "; fi
						echo
						echo "[i] $4 First Tracked On $(grep -m1 -E "OUTBOUND.* SRC=$4 " "$skynetlog" | awk '{print $1" "$2" "$3}')"
						echo "[i] $4 Last Tracked On $(grep -E "OUTBOUND.* SRC=$4 " "$skynetlog" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo "[i] $(grep -Eoc -E "OUTBOUND.* SRC=$4 " "$skynetlog") Blocks Total"
						echo
						$red "Device Name;"
						if grep -qF " $4 " "/var/lib/misc/dnsmasq.leases"; then grep -F " $4 " "/var/lib/misc/dnsmasq.leases" | awk '{print $4}'; else echo "No Name Found"; fi
						echo
						$red "First Block Tracked From $4;"
						grep -m1 -E "OUTBOUND.* SRC=$4 " "$skynetlog"
						echo
						$red "$counter Most Recent Blocks From $4;"
						grep -E "OUTBOUND.* SRC=$4 " "$skynetlog" | tail -"$counter"
					;;
					reports)
						if [ "$4" -eq "$4" ] 2>/dev/null; then counter="$4"; fi
						sed '\~Skynet: \[#\] ~!d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null >> "$skynetevents"
						sed -i '\~Skynet: \[#\] ~d' /tmp/syslog.log-1 /tmp/syslog.log 2>/dev/null
						echo "[i] First Report Issued On $(grep -m1 -F "Skynet: [#] " "$skynetevents" | awk '{print $1" "$2" "$3}')"
						echo "[i] Last Report Issued On $(grep -F "Skynet: [#] " "$skynetevents" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo
						$red "First Report Issued;"
						grep -m1 -F "Skynet: [#] " "$skynetevents"
						echo
						$red "$counter Most Recent Reports;"
						grep -F "Skynet: [#] " "$skynetevents" | tail -"$counter"
					;;
					invalid)
						if [ "$4" -eq "$4" ] 2>/dev/null; then counter="$4"; fi
						echo "[i] First Invalid Block Issued On $(grep -m1 -F "BLOCKED - INVALID" "$skynetlog" | awk '{print $1" "$2" "$3}')"
						echo "[i] Last Invalid Block Issued On $(grep -F "BLOCKED - INVALID" "$skynetlog" | tail -1 | awk '{print $1" "$2" "$3}')"
						echo
						$red "First Report Issued;"
						grep -m1 -F "BLOCKED - INVALID" "$skynetlog"
						echo
						$red "$counter Most Recent Reports;"
						grep -F "BLOCKED - INVALID" "$skynetlog" | tail -"$counter"
					;;
					*)
						echo "Command Not Recognized, Please Try Again"
						echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
						echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
						echo; exit 2
					;;
				esac
			;;
			*)
				if [ "$2" -eq "$2" ] 2>/dev/null; then
					counter="$2"
				elif [ "$3" -eq "$3" ] 2>/dev/null; then
					counter="$3"
				fi
				case "$2" in
					tcp)
						proto=TCP
					;;
					udp)
						proto=UDP
					;;
					icmp)
						proto=ICMP
					;;
				esac
				if [ "$extendedstats" = "enabled" ]; then
					grep -hE 'reply.* is ([0-9]{1,3}\.){3}[0-9]{1,3}$' /opt/var/log/dnsmasq* | awk '{print $6 " " $8}' | awk '!x[$0]++' > /tmp/skynetstats.txt
				fi
				$red "Top $counter Targeted Ports (Inbound); (Torrent Clients May Cause Excess Hits In Debug Mode)"
				grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE 'DPT=[0-9]{1,5}' | cut -c 5- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://www.speedguide.net/port.php?port="$2}'
				echo
				$red "Top $counter Source Ports (Inbound);"
				grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE 'SPT=[0-9]{1,5}' | cut -c 5- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://www.speedguide.net/port.php?port="$2}'
				echo
				$red "Last $counter Unique Connections Blocked (Inbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}'
				fi
				echo
				$red "Last $counter Unique Connections Blocked (Outbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E "OUTBOUND.*$proto" "$skynetlog" | grep -vE 'DPT=80 |DPT=443 ' | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E "OUTBOUND.*$proto" "$skynetlog" | grep -vE 'DPT=80 |DPT=443 ' | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}'
				fi
				echo
				if [ "$loginvalid" = "enabled" ]; then
					$red "Last $counter Unique Connections Blocked (Invalid);"
					if [ "$extendedstats" = "enabled" ]; then
						grep -E "INVALID.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}' | while IFS= read -r "ip"; do
							Extended_Stats
						done
					else
						grep -E "INVALID.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}'
					fi
					echo
				fi
				$red "Last $counter Manual Bans;"
				if [ "$extendedstats" = "enabled" ]; then
					grep -F "Manual Ban" "$skynetevents" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | tail -"$counter" | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -F "Manual Ban" "$skynetevents" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | tail -"$counter" | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}'
				fi
				echo
				$red "Last $counter Unique HTTP(s) Blocks (Outbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E 'DPT=80 |DPT=443 ' "$skynetlog" | grep -E "OUTBOUND.*$proto" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E 'DPT=80 |DPT=443 ' "$skynetlog" | grep -E "OUTBOUND.*$proto" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' | awk '!x[$0]++' | head -"$counter" | awk '{print "https://otx.alienvault.com/indicator/ip/"$1}'
				fi
				echo
				$red "Top $counter HTTP(s) Blocks (Outbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E 'DPT=80 |DPT=443 ' "$skynetlog" | grep -E "OUTBOUND.*$proto" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E 'DPT=80 |DPT=443 ' "$skynetlog" | grep -E "OUTBOUND.*$proto" | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}'
				fi
				echo
				$red "Top $counter Blocks (Inbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E "INBOUND.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}'
				fi
				echo
				$red "Top $counter Blocks (Outbound);"
				if [ "$extendedstats" = "enabled" ]; then
					grep -E "OUTBOUND.*$proto" "$skynetlog" | grep -vE 'DPT=80 |DPT=443 ' | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}' | while IFS= read -r "ip"; do
						Extended_Stats
					done
				else
					grep -E "OUTBOUND.*$proto" "$skynetlog" | grep -vE 'DPT=80 |DPT=443 ' | grep -oE ' DST=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}'
				fi
				echo
				if [ "$loginvalid" = "enabled" ]; then
					$red "Top $counter Blocks (Invalid);"
					if [ "$extendedstats" = "enabled" ]; then
						grep -E "INVALID.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}' | while IFS= read -r "ip"; do
							Extended_Stats
						done
					else
						grep -E "INVALID.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1"x https://otx.alienvault.com/indicator/ip/"$2}'
					fi
					echo
				fi
				$red "Top $counter Blocked Devices (Outbound);"
				grep -E "OUTBOUND.*$proto" "$skynetlog" | grep -oE ' SRC=[0-9,\.]* ' | cut -c 6- | sort -n | uniq -c | sort -nr | head -"$counter" | awk '{print $1 "x "$2}' > /tmp/skynetstats.txt
				awk '{print $2}' /tmp/skynetstats.txt | while IFS= read -r "localip"; do
					if grep -qF " $localip " "/var/lib/misc/dnsmasq.leases"; then
						sed -i "s~$localip$~$localip $(grep -F " $localip " "/var/lib/misc/dnsmasq.leases" | awk '{print $4}')~g" /tmp/skynetstats.txt
					elif [ "$localip" = "$(nvram get wan_ipaddr)" ]; then
						sed -i "s~$localip$~$localip $model~g" /tmp/skynetstats.txt
					else
						sed -i "s~$localip$~$localip (No Name Found)~g" /tmp/skynetstats.txt
					fi
				done
				cat /tmp/skynetstats.txt
				rm -rf /tmp/skynetstats.txt
			;;
		esac
		echo
	;;

	install)
		Check_Lock "$@"
		if [ "$(ipset -v | grep -Fo v6)" != "v6" ]; then
			echo "[*] IPSet Version Not Supported - Please Update To Latest Firmware"
			echo; exit 1
		fi
		if [ ! -f /lib/modules/"$(uname -r)"/kernel/net/netfilter/ipset/ip_set_hash_ipmac.ko ]; then
			echo "[*] IPSet Extensions Not Supported - Please Update To Latest Firmware"
			echo; exit 1
		fi
		if [ "$(nvram get jffs2_scripts)" != "1" ]; then
			nvram set jffs2_scripts=1
			forcereboot=1
		fi
		if [ "$(nvram get fw_enable_x)" != "1" ]; then
			nvram set fw_enable_x=1
		fi
		if [ "$(nvram get fw_log_x)" != "drop" ] && [ "$(nvram get fw_log_x)" != "both" ]; then
			nvram set fw_log_x=drop
		fi
		Check_Files
		echo "[i] Installing Skynet $(Filter_Version "$0")"
		echo
		Manage_Device
		mkdir -p "${device}/skynet"
		echo
		while true; do
			echo "What Type Of Traffic Do You Want To Filter?"
			echo "[1]  --> All  - (Recommended)"
			echo "[2]  --> Inbound"
			echo "[3]  --> Outbound"
			echo
			echo "[e]  --> Exit Menu"
			echo
			echo "Please Select Option"
			printf "[1-3]: "
			read -r "mode1"
			echo
			case "$mode1" in
				1)
					echo "[i] All Traffic Selected"
					filtertraffic="all"
					break
				;;
				2)
					echo "[i] Inbound Traffic Selected"
					filtertraffic="inbound"
					break
				;;
				3)
					echo "[i] Outbound Traffic Selected"
					filtertraffic="outbound"
					break
				;;
				e|exit)
					echo "[*] Exiting!"
					echo; exit 0
				;;
				*)
					echo "[*] $mode1 Isn't An Option!"
					echo
				;;
			esac
		done
		echo
		echo
		while true; do
			echo "Would You Like To Enable Debug Mode?"
			echo "Debug Mode Is Used For Generating Stats And Monitoring Blocked IP's"
			echo "[1]  --> Yes  - (Recommended)"
			echo "[2]  --> No"
			echo
			echo "[e]  --> Exit Menu"
			echo
			echo "Please Select Option"
			printf "[1-2]: "
			read -r "mode3"
			echo
			case "$mode3" in
				1)
					echo "[i] Debug Mode Enabled"
					debugmode="enabled"
					break
				;;
				2)
					echo "[i] Debug Mode Disabled"
					debugmode="disabled"
					break
				;;
				e|exit)
					echo "[*] Exiting!"
					echo; exit 0
				;;
				*)
					echo "[*] $mode3 Isn't An Option!"
					echo
				;;
			esac
		done
		echo
		echo
		while true; do
			echo "Would You Like To Enable Automatic Malwarelist Updating?"
			echo "[1]  --> Yes (Daily)  - (Recommended)"
			echo "[2]  --> Yes (Weekly)"
			echo "[3]  --> No"
			echo
			echo "[e]  --> Exit Menu"
			echo
			echo "Please Select Option"
			printf "[1-3]: "
			read -r "mode4"
			echo
			case "$mode4" in
				1)
					echo "[i] Malware List Updating Enabled & Scheduled For 2.25am Every Day"
					banmalwareupdate="daily"
					forcebanmalwareupdate="true"
					break
				;;
				2)
					echo "[i] Malware List Updating Enabled & Scheduled For 2.25am Every Monday"
					banmalwareupdate="weekly"
					forcebanmalwareupdate="true"
					break
				;;
				3)
					echo "[i] Malware List Updating Disabled"
					banmalwareupdate="disabled"
					break
				;;
				e|exit)
					echo "[*] Exiting!"
					echo; exit 0
				;;
				*)
					echo "[*] $mode4 Isn't An Option!"
					echo
				;;
			esac
		done
		echo
		echo
		while true; do
			echo "Would You Like To Enable Weekly Skynet Updating?"
			echo "[1]  --> Yes  - (Recommended)"
			echo "[2]  --> No"
			echo
			echo "[e]  --> Exit Menu"
			echo
			echo "Please Select Option"
			printf "[1-2]: "
			read -r "mode5"
			echo
			case "$mode5" in
				1)
					echo "[i] Skynet Updating Enabled & Scheduled For 1.25am Every Monday"
					autoupdate="enabled"
					break
				;;
				2)
					echo "[i] Auto Updating Disabled"
					autoupdate="disabled"
					break
				;;
				e|exit)
					echo "[*] Exiting!"
					echo; exit 0
				;;
				*)
					echo "[*] $mode5 Isn't An Option!"
					echo
				;;
			esac
		done
		echo
		echo
		if ! grep -F "swapon" /jffs/scripts/post-mount | grep -qvE "^#" && ! grep -F "swap" /jffs/configs/fstab 2>/dev/null | grep -qvE "^#"; then Create_Swap; fi
		if [ -f "$skynetlog" ]; then mv "$skynetlog" "${device}/skynet/skynet.log"; fi
		if [ -f "$skynetevents" ]; then mv "$skynetevents" "${device}/skynet/events.log"; fi
		if [ -f "$skynetipset" ]; then mv "$skynetipset" "${device}/skynet/skynet.ipset"; fi
		if [ -f "${skynetloc}/Skynet-Backup.tar.gz" ]; then mv "${skynetloc}/Skynet-Backup.tar.gz" "${device}/skynet/Skynet-Backup.tar.gz"; fi
		if [ "$skynetloc" != "${device}/skynet" ]; then rm -rf "$skynetloc"; fi
		skynetloc="${device}/skynet"
		skynetcfg="${device}/skynet/skynet.cfg"
		touch "${device}/skynet/events.log"
		touch "${device}/skynet/skynet.log"
		[ -z "$(nvram get odmpid)" ] && model="$(nvram get productid)" || model="$(nvram get odmpid)"
		if [ -z "$loginvalid" ]; then loginvalid="disabled"; fi
		if [ -z "$unbanprivateip" ]; then unbanprivateip="enabled"; fi
		if [ -z "$banaiprotect" ] && [ -f /opt/bin/opkg ]; then banaiprotect="enabled"; fi
		if [ -z "$securemode" ]; then securemode="enabled"; fi
		if [ -z "$wifemode" ]; then wifemode="disabled"; fi
		Write_Config
		cmdline="sh /jffs/scripts/firewall start skynetloc=${device}/skynet # Skynet Firewall Addition"
		if grep -E "sh /jffs/scripts/firewall .* # Skynet" /jffs/scripts/firewall-start 2>/dev/null | grep -qvE "^#"; then
			sed -i "s~sh /jffs/scripts/firewall .* # Skynet .*~$cmdline~" /jffs/scripts/firewall-start
		else
			echo "$cmdline" >> /jffs/scripts/firewall-start
		fi
		cmdline="sh /jffs/scripts/firewall save # Skynet Firewall Addition"
		if grep -E "sh /jffs/scripts/firewall .* # Skynet" /jffs/scripts/services-stop 2>/dev/null | grep -qvE "^#"; then
			sed -i "s~sh /jffs/scripts/firewall .* # Skynet .*~$cmdline~" /jffs/scripts/services-stop
		else
			echo "$cmdline" >> /jffs/scripts/services-stop
		fi
		chmod 0755 /jffs/scripts/*
		echo
		nvram commit
		if [ "$forcereboot" = "1" ]; then
			echo "[i] Reboot Required To Complete Installation"
			printf "[i] Press Enter To Confirm..."
			read -r "continue"
			reboot
			exit 0
		fi
		Unload_Cron "all"
		Unload_IPTables
		Unload_DebugIPTables
		Unload_IPSets
		iptables -t raw -F
		echo "[%] Restarting Firewall Service To Complete Installation"
		restartfirewall="1"
		nolog="2"
	;;

	uninstall)
		echo "If You Were Experiencing Issues, Try Update Or Visit SNBForums/Github For Support"
		echo "https://github.com/Adamm00/IPSet_ASUS"
		echo
		while true; do
			echo "Are You Sure You Want To Uninstall?"
			echo
			echo "[1]  --> Yes"
			echo "[2]  --> No"
			echo
			echo "Please Select Option"
			printf "[1-2]: "
			read -r "continue"
			echo
			case "$continue" in
				1)
					if grep -E "swapon .* # Skynet" /jffs/scripts/post-mount 2>/dev/null | grep -qvE "^#"; then
						while true; do
							echo "Would You Like To Remove Skynet Generated Swap File?"
							echo "[1]  --> Yes"
							echo "[2]  --> No"
							echo
							echo "Please Select Option"
							printf "[1-2]: "
							read -r "removeswap"
							echo
							case "$removeswap" in
								1)
									echo "[i] Removing Skynet Generated SWAP File"
									swaplocation="$(grep -o "swapon .*" /jffs/scripts/post-mount | grep -vE "^#" | awk '{print $2}')"
									sed -i '\~ Skynet ~d' /jffs/scripts/post-mount
									swapoff "$swaplocation"
									rm -rf "$swaplocation"
									break
								;;
								2)
									break
								;;
								e|exit)
									echo "[*] Exiting!"
									echo; exit 0
								;;
								*)
									echo "[*] $removeswap Isn't An Option!"
									echo
								;;
							esac
						done
					fi
					echo "[i] Unloading Skynet Components"
					Purge_Logs "all"
					Unload_Cron "all"
					Kill_Lock
					Unload_IPTables
					Unload_DebugIPTables
					Unload_IPSets
					nvram set fw_log_x=none
					echo "[i] Removing Traces Of Skynet"
					sed -i '\~ Skynet ~d' /jffs/scripts/firewall-start /jffs/scripts/services-stop
					rm -rf "/jffs/shared-Skynet-whitelist" "/jffs/shared-Skynet2-whitelist" "/opt/bin/firewall" "$skynetloc" "/jffs/scripts/firewall" "/tmp/skynet.lock"
					iptables -t raw -F
					echo "[%] Restarting Firewall Service"
					service restart_firewall
					exit 0
				;;
				2|e|exit)
					echo "[*] Exiting!"
					echo; exit 0
				;;
				*)
					echo "[*] $continue Isn't An Option!"
					echo
				;;
			esac
		done
	;;

	*)
		echo "Command Not Recognized, Please Try Again"
		echo "For Help Check https://github.com/Adamm00/IPSet_ASUS#help"
		echo "For Common Issues Check https://github.com/Adamm00/IPSet_ASUS/wiki#common-issues"
		echo
	;;

esac

if [ "$nolog" != "2" ]; then Print_Log "$@"; echo; fi
if [ "$nocfg" != "1" ]; then Write_Config; fi
if [ "$lockskynet" = "true" ]; then rm -rf "/tmp/skynet.lock"; fi
if [ "$restartfirewall" = "1" ]; then service restart_firewall; echo; fi
if [ -n "$reloadmenu" ]; then echo; echo; printf "[i] Press Enter To Continue..."; read -r "continue"; exec "$0"; fi