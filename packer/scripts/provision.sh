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

echo "==> Creating default content (placeholder so Quadlet volume mount succeeds on boot)"
sudo mkdir -p /srv/www
sudo tee /srv/www/index.html > /dev/null <<'HTML'
<html><body><h1>Hello, World!</h1></body></html>
HTML

echo "==> Reloading systemd (Quadlet generates nginx.service)"
sudo systemctl daemon-reload

echo "==> Cleaning dnf cache to reduce AMI size"
sudo dnf clean all
sudo rm -rf /var/cache/dnf

echo "==> Done. AMI is ready."
