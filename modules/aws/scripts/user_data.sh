#!/bin/bash
dnf install -y httpd php

# Static health-check page (for NLB TCP health checks)
cat > /var/www/html/index.html <<'HTML'
<html><body><h1>Hello, World!</h1></body></html>
HTML

# CPU-intensive endpoint — burns ~20-50ms of CPU per request
# Tuned for t3.micro (10% baseline CPU). Uses SHA-256 chaining
# to generate steady, measurable CPU load without timing out.
cat > /var/www/html/cpu.php <<'PHP'
<?php
$start = hrtime(true);

// SHA-256 hash chain — ~20-50ms on throttled t3.micro
$data = random_bytes(1024);
for ($i = 0; $i < 5000; $i++) {
    $data = hash('sha256', $data, true);
}

$elapsed = (hrtime(true) - $start) / 1e6;

header('Content-Type: text/plain');
echo "OK " . bin2hex(substr($data, 0, 8)) . " " . round($elapsed) . "ms\n";
PHP

systemctl enable --now httpd
systemctl start --now httpd

# Open HTTP in firewalld (RHEL enables firewalld by default)
firewall-cmd --permanent --add-service=http
firewall-cmd --reload
