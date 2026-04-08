#!/bin/bash
set -euo pipefail

echo "==> Installing Podman"
sudo dnf install -y podman

echo "==> Pre-pulling nginx:alpine"
sudo podman pull docker.io/library/nginx:alpine

echo "==> Creating Podman Quadlet systemd unit"
sudo mkdir -p /etc/containers/systemd
sudo tee /etc/containers/systemd/nginx.container > /dev/null <<'UNIT'
[Unit]
Description=nginx Hello World
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/library/nginx:alpine
PublishPort=80:80
Volume=/srv/www/index.html:/usr/share/nginx/html/index.html:ro,Z

[Install]
WantedBy=multi-user.target
UNIT

echo "==> Pre-pulling stress-ng image"
sudo podman pull docker.io/alexeiled/stress-ng

echo "==> Creating stress-ng Quadlet units (CPU sidecar pods)"
for i in 1 2 3; do
sudo tee /etc/containers/systemd/stress-worker-${i}.container > /dev/null <<UNIT
[Unit]
Description=CPU stress worker ${i}
After=network-online.target

[Container]
Image=docker.io/alexeiled/stress-ng
Exec=--cpu 1 --cpu-load 50 --timeout 0

[Install]
WantedBy=multi-user.target
UNIT
done

echo "==> Creating default content (placeholder so Quadlet volume mount succeeds on boot)"
sudo mkdir -p /srv/www
sudo tee /srv/www/index.html > /dev/null <<'HTML'
<html><body><h1>Hello, World!</h1></body></html>
HTML

echo "==> Reloading systemd (Quadlet generates nginx.service)"
sudo systemctl daemon-reload

echo "==> Starting nginx service (Quadlet handles auto-enable via WantedBy)"
sudo systemctl start nginx

echo "==> Verifying nginx is serving on port 80"
for i in $(seq 1 30); do
  if curl -sf http://localhost/ > /dev/null 2>&1; then
    echo "    nginx is responding on port 80"
    break
  fi
  echo "    Waiting for nginx... ($i/30)"
  sleep 2
done
curl -sf http://localhost/ > /dev/null || { echo "ERROR: nginx not responding on port 80"; exit 1; }

echo "==> Cleaning dnf cache to reduce AMI size"
sudo dnf clean all
sudo rm -rf /var/cache/dnf

echo "==> Done. AMI is fully self-contained — nginx starts on boot."
