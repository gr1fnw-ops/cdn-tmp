#!/usr/bin/env bash
# XRay VLESS+WS+TLS behind Cloudflare CDN for cdn.moksori.ru
# Adds xray alongside the existing Amnezia containers. Touches nothing else:
# no docker, no sshd, no amnezia configs. Idempotent-ish: skips install if xray present.
set -euo pipefail

UUID="37de4c21-b374-4476-81de-a469370a4614"
WS_PATH="/vq8ejp0rvhfkjcl2"
CDN_HOST="cdn.moksori.ru"
ORIGIN_IP="78.17.17.53"

# --- pick a free CF-supported TCP port --------------------------------------
PORT=""
for p in 443 2053 2087 2083 2096 8443; do
  if ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "ERROR: all CF ports busy"; exit 1; }
# plain-WS inbound on 80 keeps it working if the zone is on SSL mode "Flexible"
HTTP80=""
if ! ss -tlnH "sport = :80" 2>/dev/null | grep -q .; then HTTP80="80"; fi
echo ">> origin TLS port: $PORT, plain port: ${HTTP80:-none}"

# --- install xray binary + systemd unit ------------------------------------
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# --- TLS cert: prefer pasted CF Origin cert, else self-signed ---------------
mkdir -p /usr/local/etc/xray/certs
if [ -f /root/origin.pem ] && [ -f /root/origin.key ]; then
  cp /root/origin.pem /usr/local/etc/xray/certs/origin.pem
  cp /root/origin.key /usr/local/etc/xray/certs/origin.key
  echo ">> using CF origin cert from /root"
else
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout /usr/local/etc/xray/certs/origin.key \
    -out /usr/local/etc/xray/certs/origin.pem \
    -subj "/CN=${CDN_HOST}" >/dev/null 2>&1
  echo ">> generated self-signed cert (CF SSL mode must be Full, not Full-strict)"
fi
chmod 600 /usr/local/etc/xray/certs/origin.key

# --- config ------------------------------------------------------------------
{
cat > /usr/local/etc/xray/config.json <<CFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            { "certificateFile": "/usr/local/etc/xray/certs/origin.pem",
              "keyFile": "/usr/local/etc/xray/certs/origin.key" }
          ]
        },
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
CFG
if [ -n "$HTTP80" ]; then
cat >> /usr/local/etc/xray/config.json <<CFG
    ,
    {
      "listen": "0.0.0.0",
      "port": 80,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}", "level": 0 } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "${WS_PATH}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
CFG
fi
cat >> /usr/local/etc/xray/config.json <<'CFG'
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
CFG
}

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 1
systemctl is-active xray >/dev/null || { journalctl -u xray -n 20 --no-pager; exit 1; }

# --- firewall + bbr ----------------------------------------------------------
if systemctl is-active ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" >/dev/null
  [ -n "$HTTP80" ] && ufw allow 80/tcp >/dev/null
fi
modprobe tcp_bbr 2>/dev/null || true
printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null 2>&1

echo "================================================================"
echo "OK. origin TLS port: ${PORT}, plain port: ${HTTP80:-none}"
echo "vless://${UUID}@${CDN_HOST}:${PORT}?type=ws&encryption=none&security=tls&sni=${CDN_HOST}&fp=chrome&host=${CDN_HOST}&path=%2F${WS_PATH#/}#moksori-xray"
echo "================================================================"
