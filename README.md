# Cisco ASAv Firewall Infrastructure on AWS

Deploys a Cisco ASAv virtual firewall appliance on AWS that inspects all HTTP
traffic flowing to RHEL workload instances running nginx via Podman containers.
The infrastructure is split across two toolchains — **Terraform** for the
VPC/workload baseline and **AWS CLI + Ansible** for the firewall appliance —
because the ASAv can take up to 30 minutes to boot, which would stall
`terraform apply`.

A **Packer**-built golden AMI pre-installs Podman, the nginx container image,
and a Quadlet systemd unit so that workload instances are ready to serve
traffic on boot.

## Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────────────┐
│  AWS VPC  10.0.0.0/16                                            │
│                                                                  │
│  ┌─────────────────────────┐                                     │
│  │  Firewall Subnet        │  10.0.2.0/24                        │
│  │  ┌───────────────────┐  │                                     │
│  │  │ Cisco ASAv        │  │  Management EIP: <mgmt_eip>         │
│  │  │ (c5.large)        │  │  VIP EIP:        <vip_eip>          │
│  │  │ outside: DHCP     │  │                                     │
│  │  └──────┬────────────┘  │                                     │
│  └─────────┼───────────────┘                                     │
│            │ inside ENI (workload subnet)                        │
│            ▼                                                     │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ Workload Subnet A       │  │ Workload Subnet B       │        │
│  │ 10.0.1.0/24             │  │ 10.0.3.0/24             │        │
│  │ RHEL instances (Podman) │  │ RHEL instances (Podman) │        │
│  │ Route: 0.0.0.0/0 → FW  │  │ Route: 0.0.0.0/0 → FW  │        │
│  └─────────────────────────┘  └─────────────────────────┘        │
│            ▲                            ▲                        │
│            │  VPC local routing         │                        │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ ALB Subnet A            │  │ ALB Subnet B            │        │
│  │ 10.0.4.0/24             │  │ 10.0.5.0/24             │        │
│  │ ALB ENI                 │  │ ALB ENI                 │        │
│  │ Route: 0.0.0.0/0 → IGW │  │ Route: 0.0.0.0/0 → IGW │        │
│  └─────────────────────────┘  └─────────────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

### Traffic flow (inbound HTTP)

```
Client  ──►  IGW  ──►  Firewall VIP (<vip_eip>:80)
                            │
                       ASAv inspects, twice NAT:
                         src: client IP  → firewall inside IP
                         dst: VIP        → ALB private IP
                            │
                            ▼
                       ALB  ──►  RHEL instance (nginx container, port 80)
                            │
                       Response returns symmetrically through firewall
```

### Why the ALB has its own subnets

The ALB and workload instances were originally in the same subnets.  When the
workload route table was pointed to the firewall, the ALB's return traffic to
internet clients also went through the firewall.  The firewall dropped these
responses because it never saw the original inbound connection (asymmetric
routing).  Moving the ALB to dedicated subnets with their own IGW route table
solved this — the ALB always has a direct internet path, while the workload
subnets route through the firewall.

### Why the firewall uses a VIP (secondary IP)

The ASAv treats traffic destined to its own interface IP as "self-addressed"
(management-plane traffic like SSH), bypassing NAT processing entirely.  A
secondary private IP on the outside ENI serves as a Virtual IP.  Traffic to
this VIP is not self-addressed, so the twice NAT rule processes it and forwards
to the ALB.

## Subnet layout

- **Workload A** — 10.0.1.0/24 — RHEL instances + firewall inside ENI
- **Firewall** — 10.0.2.0/24 — ASAv outside interface
- **Workload B** — 10.0.3.0/24 — RHEL instances
- **ALB A** — 10.0.4.0/24 — Application Load Balancer
- **ALB B** — 10.0.5.0/24 — Application Load Balancer

## Project structure

```
CiscoFirewall/
├── main.tf                        # Root module — calls modules/aws
├── variables.tf                   # Root variables
├── outputs.tf                     # Root outputs
├── terraform.tfvars               # Variable values (region, CIDRs, AMI ID)
├── provider.tf                    # AWS provider config
├── modules/aws/
│   ├── main.tf                    # VPC, subnets (workload, firewall, ALB)
│   ├── workload.tf                # Launch template, ASG, ALB, auto-scaling policies
│   ├── firewall.tf                # Firewall SG, route tables and associations
│   ├── variables.tf               # Module variables
│   ├── outputs.tf                 # Module outputs
│   ├── scripts/
│   │   └── workload_user_data.sh  # EC2 user data (writes HTML, starts nginx)
│   └── json/
│       └── workload_assume_role.json  # IAM assume-role policy for SSM
├── packer/
│   ├── workload.pkr.hcl           # Packer template — builds golden AMI
│   └── scripts/
│       └── provision.sh           # Installs Podman, pulls nginx, creates Quadlet unit
├── scripts/
│   ├── deploy_asav.sh             # Deploy ASAv via AWS CLI
│   ├── update_routes.sh           # Point workload routes to firewall (or rollback)
│   ├── stress_test.py             # Python stress test (5min on / 5min off cycles)
│   ├── defaults.json              # Stress test config (URL, workers, durations)
│   └── asav_deploy_output.env     # Deployment details (ENI IDs, EIPs, etc.)
├── ansible/
│   ├── inventory.ini              # ASAv SSH inventory
│   ├── configure_asav.yml         # Full ASAv config playbook
│   └── ansible.cfg                # Ansible settings
└── cisco-asav-key.pem             # EC2 key pair for ASAv SSH (not committed)
```

## Prerequisites

- AWS CLI v2 with credentials configured
- Terraform >= 1.0
- Packer >= 1.8 with the `amazon` plugin
- Python 3.10+ (for the stress test script)
- Ansible + `cisco.asa` collection: `ansible-galaxy collection install cisco.asa`
- `paramiko` Python package: `pip install paramiko`
- Cisco ASAv PAYG marketplace subscription active (product ID `87868dac`)
- EC2 key pair in your target region

## Deployment

### Step 1 — Packer (Golden AMI)

```bash
packer init packer/workload.pkr.hcl
packer build packer/workload.pkr.hcl
```

Builds a RHEL 10.1 AMI with:
- Podman installed
- `nginx:alpine` container image pre-pulled
- Quadlet systemd unit (`/etc/containers/systemd/nginx.container`) for automatic startup
- Placeholder `index.html` so the container starts successfully on boot
- Firewall port 80 opened (if firewalld is present)

Copy the output AMI ID into `terraform.tfvars` as `workload_ami_id`.

### Step 2 — Terraform (VPC, ASG, ALB)

```bash
terraform init
terraform apply
```

Creates the VPC, all five subnets, IGW, route tables, RHEL workload ASG
(2–6 × t3.xlarge with Packer AMI), ALB, target group, IAM role for SSM, and
the firewall security group.

### Step 3 — AWS CLI (Cisco ASAv firewall)

```bash
# Set REGION and KEY_NAME in the script first
./scripts/deploy_asav.sh
```

Deploys the ASAv as a single instance (c5.large, 2 vCPU / 4 GB, 12 GB gp3).
The script creates a launch template, launches the instance, disables source/dest
check, allocates an EIP, and saves all IDs to `scripts/asav_deploy_output.env`.

The ASAv takes 15–20 minutes to fully boot.  Wait until SSH is reachable.

### Step 4 — Attach inside ENI

The ASAv needs a second ENI in the workload subnet for its inside interface:

```bash
INSIDE_ENI=$(aws ec2 create-network-interface \
  --subnet-id <workload_subnet_a_id> \
  --groups <firewall_sg_id> \
  --description "ASAv Inside ENI (TenGigabitEthernet0/0)" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

aws ec2 modify-network-interface-attribute \
  --network-interface-id $INSIDE_ENI --no-source-dest-check

aws ec2 attach-network-interface \
  --network-interface-id $INSIDE_ENI \
  --instance-id <asav_instance_id> \
  --device-index 1
```

Reboot the ASAv to detect the hot-plugged ENI.

### Step 5 — Ansible (firewall configuration)

```bash
# Set the ASAv EIP and key path in ansible/inventory.ini
# Set alb_server_ip and firewall_vip in ansible/configure_asav.yml
ansible-playbook -i ansible/inventory.ini ansible/configure_asav.yml
```

Configures interfaces, ACLs, PAT, twice NAT for inbound HTTP (VIP → ALB),
static routes, ICMP inspection, and logging.

### Step 6 — Route workload traffic through the firewall

```bash
# Set REGION in the script first
./scripts/update_routes.sh            # workload → firewall
./scripts/update_routes.sh --rollback # workload → IGW (revert)
```

**Important**: `terraform apply` reverts this route back to the IGW (the
firewall route is managed outside Terraform state).  Re-run `update_routes.sh`
after each apply.

### Step 7 — Configure the VIP for inbound HTTP

Add a secondary private IP to the outside ENI and associate an EIP:

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

## Stress testing

```bash
# Set DEFAULT_URL in scripts/defaults.json to your ALB DNS first
python3 scripts/stress_test.py
python3 scripts/stress_test.py --workers 300 --cycles 2
python3 scripts/stress_test.py --stress 60 --rest 60   # quick 1min cycles
```

Traffic flows through the full path: Internet → IGW → ASAv → ALB → RHEL
(nginx container).

### Auto-scaling behavior

The workload ASG has two target tracking policies:
- **ALBRequestCountPerTarget** (target: 100) — scales on request volume
- **ASGAverageCPUUtilization** (target: 80%) — CPU safety net

ASG limits: min 2, desired 4, max 6 instances.

### Observed scaling results (v2)

With 300 concurrent workers (2 cycles × 5 min stress / 2 min rest):
- ASG scaled from **2 → 6** instances (max)
- **~166K requests per cycle**, **100% success rate**
- Average latency: **541ms** (includes ASAv hop)
- Throughput: ~26.5K req/s effective

### Scale-in behavior

After stopping the stress test, the ASG remained at max capacity for ~10 minutes.
Target tracking scale-in requires **both** low alarms (CPU and request count) to
be in ALARM state before scaling down.  The CPU alarm fires quickly, but the
`ALBRequestCountPerTarget` alarm can take longer when there is zero traffic
(CloudWatch may report insufficient data).  A small trickle of requests can
help the metric publish data points below threshold and trigger scale-in.

## Key design decisions

1. **RHEL + Podman instead of ECS** — Uses RHEL 10.1 instances with Podman
   containers managed by Quadlet systemd units.  A Packer-built golden AMI
   pre-installs everything so instances are ready to serve on boot.

2. **Terraform + AWS CLI split** — The ASAv takes up to 30 minutes to boot.
   Keeping it outside Terraform avoids blocking `terraform apply`.

3. **Separate ALB subnets** — The ALB needs a direct IGW route for return
   traffic.  Sharing subnets with the workload (which routes through the
   firewall) causes asymmetric routing drops.

4. **VIP on outside ENI** — The ASAv treats traffic to its own interface IP as
   management traffic, bypassing NAT.  A secondary IP avoids this.

5. **Twice NAT** — Both source and destination are translated for inbound HTTP
   so return traffic flows symmetrically through the firewall.

6. **Packer golden AMI** — Pre-bakes Podman, the nginx image, Quadlet unit, and
   a placeholder `index.html` so the container starts on boot before user data
   runs.  User data overwrites the HTML and ensures the service is running.

## Lessons learned

- **Quadlet auto-start timing** — Quadlet units with `WantedBy=multi-user.target`
  auto-start on boot before cloud-init user data runs.  The AMI must include a
  placeholder for any volume-mounted files or the container will fail to start.
- **firewalld on RHEL** — If firewalld is installed, port 80 must be explicitly
  opened.  If it's not installed, user data scripts must not call `firewall-cmd`
  under `set -euo pipefail` or the entire script fails.
- **ASAv boot time** — Up to 30 minutes, requiring separation from Terraform.
- **Asymmetric routing** — The ALB and workload instances cannot share subnets
  when the workload route table points to the firewall.
- **Self-addressed NAT limitation** — The ASAv treats traffic to its own
  interface IP as management-plane, bypassing NAT.  A secondary VIP is needed.
- **Interface detection** — The ASAv on c5 instances uses `TenGigabitEthernet`
  (10G ENA), not `GigabitEthernet`, and requires a reboot to detect hot-plugged ENIs.
- **SSH compatibility** — The ASAv only supports `ssh-rsa`, requiring `paramiko`
  for Ansible.
- **Scale-in latency** — Target tracking with multiple policies requires all low
  alarms to agree before scaling in, resulting in an observation window after
  load drops.

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

# 4. Deregister Packer AMIs and delete snapshots
aws ec2 deregister-image --image-id <ami_id>
aws ec2 delete-snapshot --snapshot-id <snap_id>
```
