# Cisco ASAv Firewall Infrastructure on AWS

Deploys a Cisco ASAv virtual firewall appliance on AWS that inspects all HTTP
traffic flowing to an ECS cluster.  The infrastructure is split across two
toolchains — **Terraform** for the VPC/ECS baseline and **AWS CLI + Ansible**
for the firewall appliance — because the ASAv can take up to 30 minutes to
boot, which would stall `terraform apply`.

## Architecture

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────────────────┐
│  AWS VPC  10.0.0.0/16                                            │
│                                                                  │
│  ┌─────────────────────────┐                                     │
│  │  Firewall Subnet        │  10.0.2.0/24  (us-east-1a)          │
│  │  ┌───────────────────┐  │                                     │
│  │  │Cisco ASAv         │  │  Management EIP: 44.217.66.223      │
│  │  │(c5.large)         │  │  VIP EIP:        52.0.225.32        │
│  │  │outside: 10.0.2.153│  │  VIP private:    10.0.2.112         │
│  │  └──────┬────────────┘  │                                     │
│  └─────────┼───────────────┘                                     │
│            │ inside ENI: 10.0.1.38                               │
│            ▼                                                     │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ Workload Subnet A       │  │ Workload Subnet B       │        │
│  │ 10.0.1.0/24 (us-east-1a)│  │ 10.0.3.0/24 (us-east-1b)│        │
│  │ ECS instances           │  │ ECS instances           │        │
│  │ Route: 0.0.0.0/0 → FW   │  │ Route: 0.0.0.0/0 → FW   │        │
│  └─────────────────────────┘  └─────────────────────────┘        │
│            ▲                            ▲                        │
│            │  VPC local routing         │                        │
│  ┌─────────────────────────┐  ┌─────────────────────────┐        │
│  │ ALB Subnet A            │  │ ALB Subnet B            │        │
│  │ 10.0.4.0/24 (us-east-1a)│  │ 10.0.5.0/24 (us-east-1b)│        │
│  │ ALB ENI                 │  │ ALB ENI                 │        │
│  │ Route: 0.0.0.0/0 → IGW  │  │ Route: 0.0.0.0/0 → IGW  │        │
│  └─────────────────────────┘  └─────────────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
```

### Traffic flow (inbound HTTP)

```
Client  ──►  IGW  ──►  Firewall VIP (52.0.225.32:80)
                            │
                       ASAv inspects, twice NAT:
                         src: client IP  → firewall inside IP (10.0.1.38)
                         dst: VIP (10.0.2.112) → ALB (10.0.4.13)
                            │
                            ▼
                       ALB (10.0.4.13:80)
                            │
                            ▼
                       ECS instance (nginx "Hello, World!")
                            │
                       Response returns symmetrically through firewall
```

### Why the ALB has its own subnets

The ALB and ECS instances were originally in the same subnets.  When the
workload route table was pointed to the firewall, the ALB's return traffic to
internet clients also went through the firewall.  The firewall dropped these
responses because it never saw the original inbound connection (asymmetric
routing).  Moving the ALB to dedicated subnets with their own IGW route table
solved this — the ALB always has a direct internet path, while the workload
subnets route through the firewall.

### Why the firewall uses a VIP (secondary IP)

The ASAv treats traffic destined to its own interface IP as "self-addressed"
(management-plane traffic like SSH), bypassing NAT processing entirely.  A
secondary private IP (10.0.2.112) was added to the outside ENI as a Virtual IP.
Traffic to this VIP is not self-addressed, so the twice NAT rule processes it
and forwards to the ALB.

## Subnet layout

| Subnet | CIDR | AZ | Purpose |
|---|---|---|---|
| Workload A | 10.0.1.0/24 | us-east-1a | ECS instances + firewall inside ENI |
| Firewall | 10.0.2.0/24 | us-east-1a | ASAv outside interface |
| Workload B | 10.0.3.0/24 | us-east-1b | ECS instances |
| ALB A | 10.0.4.0/24 | us-east-1a | Application Load Balancer |
| ALB B | 10.0.5.0/24 | us-east-1b | Application Load Balancer |

## Project structure

```
CiscoFirewall/
├── main.tf                    # Root module — calls modules/aws
├── variables.tf               # Root variables
├── outputs.tf                 # Root outputs
├── terraform.tfvars           # Variable values
├── provider.tf                # AWS provider config
├── modules/aws/
│   ├── main.tf                # VPC, subnets (workload, firewall, ALB)
│   ├── ecs.tf                 # ECS cluster, ASG, ALB, task def, auto-scaling
│   ├── firewall.tf            # Firewall SG, route tables and associations
│   ├── variables.tf           # Module variables
│   └── outputs.tf             # Module outputs
├── scripts/
│   ├── deploy_asav.sh         # Deploy ASAv via AWS CLI (launch template + ASG)
│   ├── update_routes.sh       # Point workload routes to firewall (or rollback)
│   ├── stress_test.py         # Python stress test (5min on / 5min off cycles)
│   └── asav_deploy_output.env # Deployment details (ENI IDs, EIPs, etc.)
├── ansible/
│   ├── inventory.ini          # ASAv SSH inventory (paramiko, key-based auth)
│   ├── configure_asav.yml     # Full ASAv config playbook
│   └── ansible.cfg            # Ansible settings
└── cisco-asav-key.pem         # EC2 key pair for ASAv SSH (not committed)
```

## Prerequisites

- AWS CLI v2 with credentials configured
- Terraform >= 1.0
- Python 3.10+ (for the stress test script)
- Ansible + `cisco.asa` collection: `ansible-galaxy collection install cisco.asa`
- `paramiko` Python package: `pip install paramiko`
- Cisco ASAv PAYG marketplace subscription active (product ID `87868dac`)
- EC2 key pair named `cisco-asav-key` in us-east-1

## Deployment

### Step 1 — Terraform (VPC, ECS, subnets)

```bash
terraform init
terraform apply
```

Creates the VPC, all five subnets, IGW, route tables, ECS cluster with ASG
(2 × t3.xlarge), ALB, nginx task definition, and the firewall security group.

### Step 2 — AWS CLI (Cisco ASAv firewall)

```bash
./scripts/deploy_asav.sh
```

Deploys the ASAv as a single-instance ASG (c5.large, 2 vCPU / 4 GB, 12 GB
gp3 disk).  The script:
1. Creates a launch template using the latest ASAv PAYG AMI
2. Launches the ASG in the firewall subnet
3. Waits for the instance to reach running state
4. Disables source/dest check on the ENI
5. Allocates an EIP and attaches it
6. Saves all IDs to `scripts/asav_deploy_output.env`
7. Generates `ansible/inventory.ini`

The ASAv takes 15–20 minutes to fully boot.  Wait until SSH is reachable
before proceeding.

### Step 3 — Attach inside ENI

The ASAv needs a second ENI in the workload subnet for its inside interface.
After the instance is running, create and attach it manually:

```bash
# Create inside ENI in workload subnet A
INSIDE_ENI=$(aws ec2 create-network-interface \
  --subnet-id <workload_subnet_a_id> \
  --groups <firewall_sg_id> \
  --description "Cisco ASAv inside interface" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

# Disable source/dest check
aws ec2 modify-network-interface-attribute \
  --network-interface-id $INSIDE_ENI --no-source-dest-check

# Attach to ASAv instance
aws ec2 attach-network-interface \
  --network-interface-id $INSIDE_ENI \
  --instance-id <asav_instance_id> \
  --device-index 1
```

The ASAv must be **rebooted** to detect the hot-plugged ENI.  After reboot the
inside interface appears as `TenGigabitEthernet0/0` (c5 instances use 10G ENA
drivers, not `GigabitEthernet`).

### Step 4 — Ansible (firewall configuration)

```bash
ansible-playbook -i ansible/inventory.ini ansible/configure_asav.yml
```

Configures:
- **Interfaces**: outside (Management0/0, DHCP) and inside (TenGigabitEthernet0/0, DHCP)
- **ACLs**: OUTSIDE_IN (HTTP/HTTPS/ICMP), INSIDE_OUT (workload subnets)
- **NAT**: Outbound PAT for workload traffic; twice NAT for inbound HTTP (VIP → ALB)
- **Routes**: Workload subnet B, ALB subnets via inside gateway
- **ICMP**: Permit on both interfaces, inspection enabled
- **Logging**: Buffered + trap at informational level

**SSH note**: The ASAv only supports `ssh-rsa`.  The Ansible inventory uses
`paramiko` as the SSH transport since modern OpenSSH disables `ssh-rsa` by
default.  For manual SSH:

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -i cisco-asav-key.pem admin@44.217.66.223
```

### Step 5 — Route workload traffic through the firewall

```bash
./scripts/update_routes.sh            # workload → firewall
./scripts/update_routes.sh --rollback # workload → IGW (revert)
```

Points the workload route table's `0.0.0.0/0` route to the firewall's inside
ENI so all ECS outbound traffic is inspected.

**Important**: Every `terraform apply` reverts this route back to the IGW
(because the firewall route is managed outside Terraform state).  Re-run
`update_routes.sh` after each apply.

### Step 6 — Configure the VIP for inbound HTTP

A secondary private IP (NAT VIP) on the outside ENI is needed for the twice
NAT rule.  This was done manually after the initial deployment:

```bash
# Add secondary IP to outside ENI
aws ec2 assign-private-ip-addresses \
  --network-interface-id <outside_eni_id> \
  --secondary-private-ip-address-count 1

# Allocate EIP and associate with the secondary IP
VIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
aws ec2 associate-address \
  --allocation-id $VIP_ALLOC \
  --network-interface-id <outside_eni_id> \
  --private-ip-address <secondary_private_ip>
```

The Ansible playbook configures the corresponding twice NAT rule on the ASAv.

## Stress testing

```bash
# Default: 100 workers, 5min stress / 5min rest, infinite cycles
python3 scripts/stress_test.py

# Custom
python3 scripts/stress_test.py --workers 200 --cycles 3
python3 scripts/stress_test.py --stress 60 --rest 60   # 1min cycles for quick test
```

The script sends HTTP traffic to the firewall VIP (`52.0.225.32`).  Traffic
flows through the full path: Internet → IGW → ASAv → ALB → ECS.

### Auto-scaling behavior

ECS service auto-scaling is configured with two policies:
- **ALBRequestCountPerTarget** (target: 100) — scales on request volume
- **ECSServiceAverageCPUUtilization** (target: 60%) — CPU safety net

Task limits: min 2, max 32.  Scale-out cooldown: 60s, scale-in cooldown: 120s.

Each task uses 1024 CPU units, so a t3.xlarge (4096 CPU) fits ~4 tasks.  The
capacity provider scales the ASG (min 2, max 8 instances) automatically as
tasks outgrow available capacity.

### Observed scaling results

During stress testing with 100 concurrent workers:
- ECS tasks scaled from **2 → 32** (max)
- ASG instances scaled from **2 → 8** (max, all InService)
- Firewall connections peaked at **223** concurrent
- All traffic confirmed flowing through the ASAv (`show conn` on firewall)

### Scale-in behavior after stopping the stress test

After stopping the stress test, the cluster remained at max capacity for
~15 minutes before beginning to scale down.  This is expected — target
tracking scale-in is intentionally conservative:

- AWS requires **both** low alarms (CPU *and* request count) to be in
  ALARM state simultaneously before scaling in.
- Each alarm needs **15 consecutive 1-minute evaluations** below threshold
  — a 15-minute observation window before it fires.
- The CPU alarm triggered quickly (low utilization with no traffic), but
  the request count alarm took the full 15 minutes of near-zero traffic
  before crossing at 23:28 UTC.
- Scale-in then proceeded gradually: tasks 32 → 2, followed by the
  capacity provider scaling the ASG 8 → 2.  The full scale-down takes
  several minutes due to the 120-second scale-in cooldown between each
  step and the 30-second target group deregistration delay.

## ASAv details

| Property | Value |
|---|---|
| Software | ASA 9.20(4)14 |
| Instance type | c5.large (2 vCPU, 4 GB RAM) |
| Disk | 12 GB gp3 |
| License | AWS Licensed (PAYG — not degraded) |
| Outside interface | Management0/0 (10.0.2.153, firewall subnet) |
| Inside interface | TenGigabitEthernet0/0 (10.0.1.38, workload subnet A) |
| Management EIP | 44.217.66.223 |
| VIP EIP | 52.0.225.32 (inbound HTTP entry point) |

## Key design decisions

1. **Terraform + AWS CLI split** — The ASAv takes up to 30 minutes to boot.
   Keeping it outside Terraform avoids blocking `terraform apply` for the rest
   of the infrastructure.

2. **Separate ALB subnets** — The ALB needs a direct IGW route for return
   traffic.  Sharing subnets with the ECS workload (which routes through the
   firewall) causes asymmetric routing drops.

3. **VIP on outside ENI** — The ASAv treats traffic to its own interface IP as
   management traffic, bypassing NAT.  A secondary IP avoids this.

4. **Twice NAT** — Both source and destination are translated for inbound HTTP
   so return traffic flows back symmetrically through the firewall instead of
   taking the ALB's direct IGW route.

5. **c5.large instance type** — 2 vCPU / 4 GB is sufficient for a lab with
   management + inside + outside interfaces.  Cisco recommends C5/M5 (Nitro)
   for ENA driver support.

6. **PAYG licensing** — Avoids degraded mode (100 connections, 100 Kbps)
   that applies to unlicensed/BYOL instances.

## Lessons learned

This project demonstrated that a Cisco ASAv virtual firewall appliance can
be deployed as an EC2 instance to inspect traffic inline on AWS — something
not covered in typical bootcamps or certifications.  Key challenges solved
along the way:

- **ASAv boot time** — up to 30 minutes, requiring separation from Terraform
  into AWS CLI scripts to avoid blocking infrastructure deployments.
- **Asymmetric routing** — the ALB and ECS instances cannot share subnets when
  the workload route table points to the firewall; dedicated ALB subnets with
  their own IGW route table were required.
- **Self-addressed NAT limitation** — the ASAv treats traffic to its own
  interface IP as management-plane, bypassing NAT.  A secondary VIP on the
  outside ENI was the workaround.
- **Twice NAT for symmetric return traffic** — both source and destination
  must be translated so responses flow back through the firewall instead of
  taking the ALB's direct IGW path.
- **Interface detection** — the ASAv on c5 instances uses `TenGigabitEthernet`
  (10G ENA), not `GigabitEthernet`, and requires a reboot to detect
  hot-plugged ENIs.
- **SSH compatibility** — the ASAv only supports `ssh-rsa`, requiring
  `paramiko` for Ansible and explicit algorithm flags for manual SSH.
- **Scale-in latency** — target tracking auto-scaling with multiple policies
  requires all low alarms to agree before scaling in, resulting in a
  ~15-minute observation window after load drops.

## Cleanup

```bash
# 1. Delete ASAv ASG and launch template
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name cisco-asav-asg --force-delete
aws ec2 delete-launch-template --launch-template-id <lt_id>

# 2. Release EIPs
aws ec2 release-address --allocation-id <management_eip_alloc>
aws ec2 release-address --allocation-id <vip_eip_alloc>

# 3. Detach and delete inside ENI
aws ec2 detach-network-interface --attachment-id <attachment_id>
aws ec2 delete-network-interface --network-interface-id <inside_eni_id>

# 4. Destroy Terraform infrastructure
terraform destroy
```
