#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# update_routes.sh — Re-point the workload route table's default
#                    route to the Cisco ASAv ENI for traffic inspection
#
# Run AFTER the ASAv is booted and configured via Ansible.
# This script:
#   1. Finds the workload route table
#   2. Replaces the IGW default route with the firewall ENI
#   3. Verifies the change
#
# Rollback:
#   ./update_routes.sh --rollback
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Load deployment details ───────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/asav_deploy_output.env" ]]; then
  source "${SCRIPT_DIR}/asav_deploy_output.env"
else
  echo "ERROR: asav_deploy_output.env not found. Run deploy_asav.sh first." >&2
  exit 1
fi

# ── Look up the Internet Gateway for the VPC ─────────────────────
IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "${REGION}" \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

# Find the workload route table by its Name tag
WORKLOAD_RT_ID=$(aws ec2 describe-route-tables \
  --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=tag:Name,Values=AWS Workload Route Table" \
  --query 'RouteTables[0].RouteTableId' \
  --output text)

echo "    Workload RT : ${WORKLOAD_RT_ID}"
echo "    Firewall ENI: ${ASAV_ENI_ID}"
echo "    IGW         : ${IGW_ID}"

# ── Rollback mode ─────────────────────────────────────────────────
if [[ "${1:-}" == "--rollback" ]]; then
  echo ">>> Rolling back: pointing default route back to IGW..."
  aws ec2 replace-route \
    --region "${REGION}" \
    --route-table-id "${WORKLOAD_RT_ID}" \
    --destination-cidr-block "0.0.0.0/0" \
    --gateway-id "${IGW_ID}"
  echo ">>> Rollback complete — workload traffic bypasses firewall."
  exit 0
fi

# ── Verify the ASAv ENI exists and is attached ────────────────────
ENI_STATUS=$(aws ec2 describe-network-interfaces \
  --region "${REGION}" \
  --network-interface-ids "${ASAV_ENI_ID}" \
  --query 'NetworkInterfaces[0].Status' \
  --output text)

if [[ "${ENI_STATUS}" != "in-use" ]]; then
  echo "ERROR: Firewall ENI ${ASAV_ENI_ID} status is '${ENI_STATUS}', expected 'in-use'." >&2
  echo "       Ensure the ASAv instance is running before updating routes." >&2
  exit 1
fi

# ── Replace the default route ─────────────────────────────────────
echo ">>> Updating workload route table default route → firewall ENI..."
aws ec2 replace-route \
  --region "${REGION}" \
  --route-table-id "${WORKLOAD_RT_ID}" \
  --destination-cidr-block "0.0.0.0/0" \
  --network-interface-id "${ASAV_ENI_ID}"

# ── Verify ────────────────────────────────────────────────────────
echo ">>> Verifying route table..."
aws ec2 describe-route-tables \
  --region "${REGION}" \
  --route-table-ids "${WORKLOAD_RT_ID}" \
  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`]' \
  --output table

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Route Update Complete"
echo "════════════════════════════════════════════════════════════"
echo "  Workload subnet traffic now flows through Cisco ASAv"
echo "  Firewall ENI: ${ASAV_ENI_ID}"
echo ""
echo "  To rollback:  ./scripts/update_routes.sh --rollback"
echo "════════════════════════════════════════════════════════════"
