#!/usr/bin/env bash
# XRay VLESS+WS+TLS behind Cloudflare CDN for cdn.moksori.ru (v2, zip via jsdelivr)
set -euo pipefail
UUID="37de4c21-b374-4476-81de-a469370a4614"
WS_PATH="/vq8ejp0rvhfkjcl2"
CDN_HOST="cdn.moksori.ru"

PORT=""
for p in 443 2053 2087 2083 2096 8443; do
  if ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q .; then PORT="$p"; break; fi
done
[ -n "$PORT" ] || { echo "ERROR: all CF ports busy"; exit 1; }
HTTP80=""
if ! ss -tlnH "sport = :80" 2>/dev/null | grep -q .; then HTTP80="80"; fi
echo ">> origin TLS port: $PORT, plain port: ${HTTP80:-none}"

if [ ! -x /usr/local/bin/xray ]; then
  (apt-get install -y -qq unzip >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq unzip >/dev/null 2>&1) || true
  curl -sL https://cdn.jsdelivr.net/gh/gr1fnw-ops/cdn-tmp@main/xray.zip -o /tmp/xr.zip
  unzip -o /tmp/xr.zip xray -d /usr/local/bin/ >/dev/null
  chmod +x /usr/local/bin/xray
fi
/usr/local/bin/xray version

mkdir -p /usr/local/etc/xray/certs
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout /usr/local/etc/xray/certs/origin.key \
  -out /usr/local/etc/xray/certs/origin.pem \
  -subj "/CN=${CDN_HOST}" >/dev/null 2>&1
chmod 600 /usr/local/etc/xray/certs/origin.key

cat > /usr/local/etc/xray/config.json <<CFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": { "clients": [ { "id": "${UUID}", "level": 0 } ], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": { "certificates": [ { "certificateFile": "/usr/local/etc/xray/certs/origin.pem", "keyFile": "/usr/local/etc/xray/certs/origin.key" } ] },
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
      "settings": { "clients": [ { "id": "${UUID}", "level": 0 } ], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "${WS_PATH}" } },
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

cat > /etc/systemd/system/xray.service <<UNIT
[Unit]
Description=XRay VLESS service
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1
systemctl is-active xray >/dev/null || { journalctl -u xray -n 20 --no-pager; exit 1; }

if systemctl is-active ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" >/dev/null
  [ -n "$HTTP80" ] && ufw allow 80/tcp >/dev/null
fi
modprobe tcp_bbr 2>/dev/null || true
printf "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n" > /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null 2>&1

echo "================================================================"
echo "OK. origin TLS port: ${PORT}, plain: ${HTTP80:-none}"
echo "vless://${UUID}@${CDN_HOST}:${PORT}?type=ws&encryption=none&security=tls&sni=${CDN_HOST}&fp=chrome&host=${CDN_HOST}&path=%2F${WS_PATH#/}#moksori-xray"
echo "================================================================"
