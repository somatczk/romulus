#!/usr/bin/with-contenv bash
# skip executables inside torrents: fake releases ship malware as "<episode>.exe"
conf=/config/qBittorrent/qBittorrent.conf
[ -f "$conf" ] || exit 0
list='*.exe, *.scr, *.lnk, *.bat, *.cmd, *.com, *.pif, *.vbs, *.msi, *.zipx, *.arj'
sed -i '/^Session\\ExcludedFileNames/d' "$conf"
sed -i "/^\[BitTorrent\]$/a Session\\\\ExcludedFileNamesEnabled=true\nSession\\\\ExcludedFileNames=$list" "$conf"
