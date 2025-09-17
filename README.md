# devops-test-task

Test task: Provision an EC2 (Ubuntu 22.04), install k3s, deploy a sample app (Nginx) via Helm, deploy Prometheus (kube-prometheus-stack), and demonstrate metric collection.

## Files
- `provision.sh` — Automates AWS EC2 provisioning + k3s + Helm + Nginx + Prometheus.
- `cleanup.sh` — Deletes the created instance, security group, and key pair (careful!).

> **Prerequisites**
> - AWS CLI v2 installed and configured (`aws configure`) with an **IAM** user (not root).
> - Git installed (for cloning/pushing).
> - SSH client available (Git Bash on Windows includes it).

## Quick Start
1) Make the script executable:
```bash
chmod +x provision.sh cleanup.sh
```

2) Run the provisioner:
```bash
./provision.sh
```
It will print the Public IP at the end.

3) SSH to the instance:
```bash
ssh -i devops-test-key.pem ubuntu@<PUBLIC_IP_FROM_SCRIPT>
```

4) On the instance (after `sudo su -`), verify:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
kubectl get pods -A
```

5) Open your browser to:
```
http://<PUBLIC_IP_FROM_SCRIPT>/
```
You should see the Nginx welcome page (served via Traefik Ingress on port 80).

6) Check Prometheus metrics (from the instance or via port-forward):
```bash
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
```
Then open http://localhost:9090 and run a query like:
```
up
```
or
```
node_memory_MemAvailable_bytes
```

## Cleanup
When done, from your local machine (not the instance):
```bash
./cleanup.sh
```
This terminates the instance, deletes the SG and the key pair created by `provision.sh`.
