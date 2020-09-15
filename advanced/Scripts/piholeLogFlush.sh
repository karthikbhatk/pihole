#!/usr/bin/env bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Flushes Pi-hole's log file
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

colfile="/opt/pihole/COL_TABLE"
source ${colfile}

# Determine database location
# Obtain DBFILE=... setting from pihole-FTL.db
# Constructed to return nothing when
# a) the setting is not present in the config file, or
# b) the setting is commented out (e.g. "#DBFILE=...")
FTLconf="/etc/pihole/pihole-FTL.conf"
if [ -e "$FTLconf" ]; then
    DBFILE="$(sed -n -e 's/^\s*DBFILE\s*=\s*//p' ${FTLconf})"
fi
# Test for empty string. Use standard path in this case.
if [ -z "$DBFILE" ]; then
    DBFILE="/etc/pihole/pihole-FTL.db"
fi

# Find out dnsmasq log file.
dnsmasq_log=$(awk 'match($0, /log-facility=(.*)/, a) {print a[1]}' /etc/dnsmasq.d/01-pihole.conf)
if [ -z "$dnsmasq_log" ]; then
  # If no config set, use default log location.
  dnsmasq_log=/var/log/pihole.log
fi

if [[ "$@" != *"quiet"* ]]; then
    echo -ne "  ${INFO} Flushing ${dnsmasq_log} ..."
fi
if [[ "$@" == *"once"* ]]; then
    # Nightly logrotation
    if command -v /usr/sbin/logrotate >/dev/null; then
        # Logrotate once
        /usr/sbin/logrotate --force /etc/pihole/logrotate
    else
        # Copy pihole.log over to pihole.log.1
        # and empty out pihole.log
        # Note that moving the file is not an option, as
        # dnsmasq would happily continue writing into the
        # moved file (it will have the same file handler)
        cp ${dnsmasq_log} ${dnsmasq_log}.1
        echo " " > ${dnsmasq_log}
        chmod 644 ${dnsmasq_log}
    fi
else
    # Manual flushing
    if command -v /usr/sbin/logrotate >/dev/null; then
        # Logrotate twice to move all data out of sight of FTL
        /usr/sbin/logrotate --force /etc/pihole/logrotate; sleep 3
        /usr/sbin/logrotate --force /etc/pihole/logrotate
    else
        # Flush both pihole.log and pihole.log.1 (if existing)
        echo " " > ${dnsmasq_log}
        if [ -f ${dnsmasq_log}.1 ]; then
            echo " " > ${dnsmasq_log}.1
            chmod 644 ${dnsmasq_log}.1
        fi
    fi
    # Delete most recent 24 hours from FTL's database, leave even older data intact (don't wipe out all history)
    deleted=$(sqlite3 "${DBFILE}" "DELETE FROM queries WHERE timestamp >= strftime('%s','now')-86400; select changes() from queries limit 1")

    # Restart pihole-FTL to force reloading history
    sudo pihole restartdns
fi

if [[ "$@" != *"quiet"* ]]; then
    echo -e "${OVER}  ${TICK} Flushed ${dnsmasq_log}"
    echo -e "  ${TICK} Deleted ${deleted} queries from database"
fi
