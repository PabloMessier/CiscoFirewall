#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# deploy_asav.sh — Deploy Cisco ASAv into the Terraform-managed
#                  firewall subnet via AWS CLI (Launch Template + ASG)
#
# Prerequisites:
#   - aws cli v2 configured with appropriate credentials
#   - terraform output available (run from repo root)
#   - An EC2 key pair named "cisco-asav-key" (or change KEY_NAME below)
#   - Cisco ASAv marketplace subscription active
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGION="us-east-1"
KEY_NAME="cisco-asav-key"            # Change to your key pair name

# ── Cisco ASAv Instance Profile ───────────────────────────────────
# c5.large  = 2 vCPU / 4 GB  / 3 interfaces (mgmt + inside + outside)
# c5.xlarge = 4 vCPU / 8 GB  / 4 interfaces (mgmt + inside + outside + DMZ)
# For a lab without DMZ, c5.large is sufficient and cheaper.
INSTANCE_TYPE="c5.large"
DISK_SIZE_GB=12                      # ASAv AMI snapshot requires >= 12 GB

# ── Pull values from Terraform state ──────────────────────────────
echo ">>> Reading Terraform outputs..."
SUBNET_ID=$(terraform -chdir="${REPO_ROOT}" output -raw aws_firewall_subnet_id)
SG_ID=$(terraform -chdir="${REPO_ROOT}" output -raw aws_firewall_security_group_id)
VPC_ID=$(terraform -chdir="${REPO_ROOT}" output -raw aws_vpc_id)

echo "    Firewall Subnet : ${SUBNET_ID}"
echo "    Firewall SG     : ${SG_ID}"
echo "    VPC             : ${VPC_ID}"

# ── Find the latest ASAv AMI (standard/PAYG, not BYOL) ─────────
# Cisco owner: 679593333241
# AMIs with suffix 87868dac-* = Standard (PAYG)
# AMIs with suffix 6836725a-* = BYOL (requires separate license)
echo ">>> Looking up latest Cisco ASAv AMI (Standard)..."
AMI_ID=$(aws ec2 describe-images \
  --region "${REGION}" \
  --owners 679593333241 \
  --filters "Name=name,Values=asav9-*-ENA-87868dac-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)

if [[ "${AMI_ID}" == "None" || -z "${AMI_ID}" ]]; then
  echo "ERROR: Could not find a Cisco ASAv AMI. Verify marketplace subscription." >&2
  exit 1
fi
echo "    AMI             : ${AMI_ID}"

# ── Create Launch Template ────────────────────────────────────────
# NOTE: We do NOT hardcode an ENI in the launch template. Doing so
# would break ASG self-healing because an ENI can only attach to one
# instance at a time. Instead, the ASG creates the instance with its
# own ENI, and we configure it (disable source/dest check, attach EIP)
# after the instance is running.
echo ">>> Creating Launch Template..."
LT_ID=$(aws ec2 create-launch-template \
  --region "${REGION}" \
  --launch-template-name "cisco-asav-lt" \
  --launch-template-data "{
    \"ImageId\": \"${AMI_ID}\",
    \"InstanceType\": \"${INSTANCE_TYPE}\",
    \"KeyName\": \"${KEY_NAME}\",
    \"NetworkInterfaces\": [{
      \"DeviceIndex\": 0,
      \"SubnetId\": \"${SUBNET_ID}\",
      \"Groups\": [\"${SG_ID}\"],
      \"AssociatePublicIpAddress\": false
    }],
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {
        \"VolumeSize\": ${DISK_SIZE_GB},
        \"VolumeType\": \"gp3\"
      }
    }],
    \"MetadataOptions\": {
      \"HttpTokens\": \"required\",
      \"HttpEndpoint\": \"enabled\"
    },
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\",        \"Value\": \"Cisco-ASAv-Firewall\"},
        {\"Key\": \"ManagedBy\",   \"Value\": \"AWS-CLI\"},
        {\"Key\": \"Project\",     \"Value\": \"CiscoFirewall-Infrastructure\"}
      ]
    }]
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --output text)

echo "    Launch Template : ${LT_ID}"

# ── Create Auto Scaling Group (min=max=desired=1) ────────────────
# Grace period set to 1800s (30 min) because the ASAv can take up to
# 30 minutes to fully boot. A shorter grace period risks the ASG
# terminating and replacing the instance in a loop.
echo ">>> Creating ASG..."
aws autoscaling create-auto-scaling-group \
  --region "${REGION}" \
  --auto-scaling-group-name "cisco-asav-asg" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
  --min-size 1 \
  --max-size 1 \
  --desired-capacity 1 \
  --vpc-zone-identifier "${SUBNET_ID}" \
  --health-check-type EC2 \
  --health-check-grace-period 1800 \
  --tags "Key=Name,Value=Cisco-ASAv-ASG,PropagateAtLaunch=false"

echo ">>> ASG created. Waiting for instance to launch..."

# ── Wait for the instance to reach running state ──────────────────
INSTANCE_ID=""
for i in $(seq 1 60); do
  INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
    --region "${REGION}" \
    --auto-scaling-group-names "cisco-asav-asg" \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || true)

  if [[ -n "${INSTANCE_ID}" && "${INSTANCE_ID}" != "None" ]]; then
    STATE=$(aws ec2 describe-instances \
      --region "${REGION}" \
      --instance-ids "${INSTANCE_ID}" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text)
    echo "    Instance ${INSTANCE_ID} — ${STATE}"
    [[ "${STATE}" == "running" ]] && break
  fi
  sleep 20
done

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: Instance did not launch within the expected time." >&2
  exit 1
fi

# ── Post-launch: Disable source/dest check on the instance ENI ────
# Firewalls must forward traffic not addressed to them, so AWS
# source/destination check must be disabled.
echo ">>> Configuring instance ENI..."
ENI_ID=$(aws ec2 describe-instances \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' \
  --output text)

aws ec2 modify-network-interface-attribute \
  --region "${REGION}" \
  --network-interface-id "${ENI_ID}" \
  --no-source-dest-check

echo "    ENI             : ${ENI_ID} (source/dest check disabled)"

# ── Post-launch: Allocate and associate an Elastic IP ─────────────
echo ">>> Allocating Elastic IP..."
ALLOC_OUTPUT=$(aws ec2 allocate-address \
  --region "${REGION}" \
  --domain vpc \
  --output json)

ALLOC_ID=$(echo "${ALLOC_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AllocationId'])")
EIP=$(echo "${ALLOC_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['PublicIp'])")

aws ec2 associate-address \
  --region "${REGION}" \
  --allocation-id "${ALLOC_ID}" \
  --network-interface-id "${ENI_ID}"

echo "    EIP             : ${EIP}"

# ── Save deployment details for Ansible and route update ──────────
cat > "${SCRIPT_DIR}/asav_deploy_output.env" <<EOF
# Cisco ASAv deployment details — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
ASAV_ENI_ID=${ENI_ID}
ASAV_EIP=${EIP}
ASAV_EIP_ALLOC_ID=${ALLOC_ID}
ASAV_INSTANCE_ID=${INSTANCE_ID}
ASAV_LT_ID=${LT_ID}
ASAV_AMI_ID=${AMI_ID}
FIREWALL_SUBNET_ID=${SUBNET_ID}
FIREWALL_SG_ID=${SG_ID}
VPC_ID=${VPC_ID}
EOF

echo "    Saved to        : ${SCRIPT_DIR}/asav_deploy_output.env"

# ── Generate Ansible inventory ────────────────────────────────────
cat > "${REPO_ROOT}/ansible/inventory.ini" <<EOF
[asav]
${EIP} ansible_user=admin ansible_connection=network_cli ansible_network_os=cisco.asa.asa ansible_ssh_private_key_file=${REPO_ROOT}/${KEY_NAME}.pem
EOF

echo "    Inventory       : ${REPO_ROOT}/ansible/inventory.ini"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Cisco ASAv Deployment Complete"
echo "════════════════════════════════════════════════════════════"
echo "  Instance Type : ${INSTANCE_TYPE} (2 vCPU / 4 GB RAM)"
echo "  Disk          : ${DISK_SIZE_GB} GB gp3"
echo "  Management IP : ${EIP}"
echo "  ENI ID        : ${ENI_ID}"
echo "  Instance      : ${INSTANCE_ID}"
echo ""
echo "  SSH access    : ssh -i ${REPO_ROOT}/${KEY_NAME}.pem admin@${EIP}"
echo ""
echo "  Next steps:"
echo "    1. Wait ~20-30 min for ASAv to fully boot"
echo "    2. Run: ansible-playbook -i ansible/inventory.ini ansible/configure_asav.yml"
echo "    3. Run: ./scripts/update_routes.sh"
echo "════════════════════════════════════════════════════════════"
