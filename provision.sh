#!/usr/bin/env bash
set -euo pipefail

# --- Configurable variables ---
AWS_REGION="${AWS_REGION:-us-east-1}"        # change if needed
KEY_NAME="${KEY_NAME:-devops-test-key}"
SG_NAME="${SG_NAME:-devops-test-sg}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.medium}"  # t3.medium for Prometheus comfort
INSTANCE_NAME="${INSTANCE_NAME:-devops-test-k3s}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"            # CHANGE to your IP for better security
HTTP_CIDR="${HTTP_CIDR:-0.0.0.0/0}"
TAG_PROJECT="${TAG_PROJECT:-devops-test-task}"
# --------------------------------

echo "Using AWS region: $AWS_REGION"
aws configure set region "$AWS_REGION"

# 1) Find latest Ubuntu 22.04 Jammy AMI for the region
echo "Finding latest Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=architecture,Values=x86_64" "Name=root-device-type,Values=ebs" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
  echo "Could not find an AMI automatically. Exiting."
  exit 1
fi
echo "Selected AMI: $AMI_ID"

# 2) Create keypair (if it doesn't exist)
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "Key pair $KEY_NAME already exists in AWS."
else
  echo "Creating key pair $KEY_NAME..."
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text > "${KEY_NAME}.pem"
  chmod 600 "${KEY_NAME}.pem"
  echo "Saved private key to ${KEY_NAME}.pem"
fi

# 3) Create security group (if not exists)
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "${SG_ID:-}" ] || [ "${SG_ID}" == "None" ]; then
  echo "Creating security group ${SG_NAME}..."
  SG_ID=$(aws ec2 create-security-group --group-name "$SG_NAME" --description "Devops test SG (SSH,HTTP)" --query 'GroupId' --output text)
  echo "Created SG ${SG_ID}"
  # Authorize SSH and HTTP
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$SSH_CIDR" || true
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 80 --cidr "$HTTP_CIDR" || true
  echo "Authorized ingress: SSH(22) from $SSH_CIDR, HTTP(80) from $HTTP_CIDR"
else
  echo "Security group ${SG_NAME} exists: ${SG_ID}"
fi

# 4) User-data script to run on instance
read -r -d '' USERDATA <<'EOF'
#!/bin/bash
set -e

# Update and essential packages
apt-get update -y
apt-get install -y curl ca-certificates gnupg lsb-release

# Install k3s (default: single-node server with Traefik)
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# Wait for k3s and traefik
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for i in $(seq 1 60); do
  if kubectl get nodes >/dev/null 2>&1; then break; fi
  sleep 2
done

# Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Add Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Deploy sample nginx via bitnami/nginx
kubectl create namespace web || true
helm upgrade --install my-nginx bitnami/nginx --namespace web --wait

# Wait for Traefik to be ready (k3s default ingress)
kubectl -n kube-system wait --for=condition=ready pod -l app.kubernetes.io/name=traefik --timeout=180s || true

# Create an Ingress to expose nginx on port 80 (via Traefik)
cat <<'ING' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: web
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-nginx
            port:
              number: 80
ING

# Deploy Prometheus stack
kubectl create namespace monitoring || true
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --wait
EOF

# 5) Launch EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${TAG_PROJECT}}]" \
  --user-data "$USERDATA" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Launched instance: $INSTANCE_ID"
echo "$INSTANCE_ID" > instance_id.txt
echo "$SG_ID" > sg_id.txt

# 6) Wait for instance to be running and get public IP
echo "Waiting for instance to be 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance public IP: $PUBLIC_IP"
echo "$PUBLIC_IP" > public_ip.txt

cat <<INFO

✅ Provisioning complete.

Public IP: $PUBLIC_IP

SSH from your computer (Git Bash or Linux/macOS terminal):
  ssh -i ${KEY_NAME}.pem ubuntu@${PUBLIC_IP}

Then on the instance:
  sudo su -
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  kubectl get nodes
  kubectl get pods -A

Open your browser to:
  http://${PUBLIC_IP}/
(Nginx via Traefik Ingress on port 80)

Prometheus (from the instance, port-forward):
  kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090

Then open http://localhost:9090 and try queries like:
  up
  node_memory_MemAvailable_bytes

INFO

echo "Done."
