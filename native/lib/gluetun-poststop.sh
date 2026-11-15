#!/usr/bin/env bash
# gluetun-poststop.sh: kept so that a torrent-gluetun.service unit written
# by an earlier version of native/install.sh can still clean up after
# Gluetun while `update` replaces it. New units call gluetun-iptables.sh.
#
# Part of qbittorrent-vpn-docker's native installer. MIT License (see LICENSE).
exec /bin/bash "$(dirname "$0")/gluetun-iptables.sh" restore
