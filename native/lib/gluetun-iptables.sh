#!/usr/bin/env bash
# gluetun-iptables.sh save|restore: run by torrent-gluetun.service (as root)
# just before Gluetun starts (save) and after it exits (restore).
#
# Part of qbittorrent-vpn-docker's native installer. MIT License (see LICENSE).
#
# Why: Gluetun builds its own iptables firewall (default policy DROP, allow
# only the VPN) and leaves it behind when it exits. In Docker that does not
# matter, because the container's network goes away with it. Here the
# container keeps running, so without this root (apt, the env-editor,
# `native/install.sh update`) would have no internet whenever Gluetun is
# stopped.
#
# "save" keeps a copy of the iptables rules as they are before Gluetun
# starts; "restore" puts exactly that copy back, so rules that something
# else added before Gluetun started survive. Tables that did not exist
# before (Gluetun created them) are emptied and set to ACCEPT. Without a
# saved copy (for example the first stop after an upgrade) every iptables
# table is reset, as earlier versions of this installer did.
# Note: Gluetun itself flushes the whole iptables filter table whenever its
# firewall is switched off, and rules added while it runs are lost on
# restore, so do not rely on other iptables rules in this container.
#
# This is safe for the apps because the torrent user's traffic is held by
# the separate nftables kill switch (table inet torrent_killswitch), which
# this script never touches.
#
# Errors are reported but never make the unit fail: a missing table must
# not stop Gluetun from starting or the unit from stopping.
set -u

dir=/run/torrent-stack
action="${1:-}"

# reset TOOL TABLE: empty one table and accept everything in it.
reset() {
    local tool="$1" table="$2" chain chains
    case "$table" in
        filter) chains="INPUT FORWARD OUTPUT" ;;
        nat) chains="PREROUTING INPUT OUTPUT POSTROUTING" ;;
        mangle) chains="PREROUTING INPUT FORWARD OUTPUT POSTROUTING" ;;
    esac
    "$tool" -w 5 -t "$table" -F 2>/dev/null
    "$tool" -w 5 -t "$table" -X 2>/dev/null
    for chain in $chains; do
        "$tool" -w 5 -t "$table" -P "$chain" ACCEPT 2>/dev/null
    done
}

case "$action" in
    save)
        install -d -m 0700 "$dir"
        for tool in iptables ip6tables; do
            command -v "$tool" >/dev/null 2>&1 || continue
            snap="$dir/$tool-before-gluetun.rules"
            rm -f "$snap"
            # An OUTPUT policy of DROP is Gluetun's own firewall left over
            # from a run whose cleanup did not happen. Never save that as
            # "the rules from before Gluetun".
            if "$tool" -w 5 -S OUTPUT 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
                echo "gluetun-iptables: $tool still holds an earlier Gluetun firewall; it will be reset when Gluetun stops"
                continue
            fi
            "$tool-save" > "$snap.tmp" 2>/dev/null && mv -f "$snap.tmp" "$snap"
        done
        ;;
    restore)
        for tool in iptables ip6tables; do
            command -v "$tool" >/dev/null 2>&1 || continue
            snap="$dir/$tool-before-gluetun.rules"
            if [[ -f "$snap" ]]; then
                for table in filter nat mangle; do
                    grep -qx "\*$table" "$snap" || reset "$tool" "$table"
                done
                if grep -q '^\*' "$snap"; then
                    "$tool-restore" -w 5 < "$snap" 2>/dev/null \
                        || { echo "gluetun-iptables: could not restore $snap; resetting $tool"; for t in filter nat mangle; do reset "$tool" "$t"; done; }
                fi
                rm -f "$snap"
                echo "gluetun-iptables: $tool rules put back as they were before Gluetun started; the kill switch stays in force"
            else
                for table in filter nat mangle; do reset "$tool" "$table"; done
                echo "gluetun-iptables: no saved $tool rules; reset $tool (filter, nat, mangle); the kill switch stays in force"
            fi
        done
        ;;
    *)
        echo "usage: gluetun-iptables.sh save|restore" >&2
        ;;
esac
exit 0
