#!/usr/bin/env bash
set -euo pipefail

KEY_NAME="${KEY_NAME:-devops-test-key}"

if [ ! -f instance_id.txt ] || [ ! -f sg_id.txt ]; then
  echo "Missing instance_id.txt or sg_id.txt. Run provision.sh first (or set IDs manually)."
  exit 1
fi

INSTANCE_ID=$(cat instance_id.txt)
SG_ID=$(cat sg_id.txt)

echo "Terminating instance $INSTANCE_ID ..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
echo "Instance terminated."

echo "Deleting security group $SG_ID ..."
aws ec2 delete-security-group --group-id "$SG_ID" || true

echo "Deleting key pair $KEY_NAME ..."
aws ec2 delete-key-pair --key-name "$KEY_NAME" || true

if [ -f "${KEY_NAME}.pem" ]; then
  echo "Removing local private key ${KEY_NAME}.pem ..."
  rm -f "${KEY_NAME}.pem"
fi

echo "Cleanup complete."
