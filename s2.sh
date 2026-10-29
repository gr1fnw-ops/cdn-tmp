curl -sL https://cdn.jsdelivr.net/gh/gr1fnw-ops/cdn-tmp@main/server-xhttp.json -o /usr/local/etc/xray/config.json
systemctl restart xray
sleep 1
systemctl is-active xray
echo S2-DONE
