#!/bin/bash
set -euo pipefail

# Golden AMI already has Podman, nginx:alpine image, Quadlet unit,
# and a placeholder index.html. Update content and ensure service is running.

# Write web content (overwrites the placeholder baked into the AMI)
mkdir -p /srv/www
cat > /srv/www/index.html <<'HTML'
<html><body><h1>Hello, World!</h1></body></html>
HTML

# Ensure the nginx container image is available (re-pull if AMI storage was lost)
if ! podman image exists docker.io/library/nginx:alpine; then
  podman pull docker.io/library/nginx:alpine
fi

# Reload and ensure the nginx Quadlet service is running
systemctl daemon-reload
systemctl enable --now nginx

# If the service was already started at boot, restart to ensure fresh state
systemctl restart nginx || true
