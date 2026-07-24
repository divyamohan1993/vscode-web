#!/usr/bin/env bash
# create-vm.sh — Provision a GCloud VM for code-server (VS Code in the browser)
# Idempotent: safe to rerun. Uses cheapest viable VM for 10+ parallel agents.
#
# Usage:
#   ./deploy/create-vm.sh                       # uses defaults below
#   VM_NAME=code-server ZONE=us-central1-a ./deploy/create-vm.sh
#
# Defaults (override via env):
#   VM_NAME      = code-server
#   ZONE         = us-central1-a   (cheapest e2 pricing; CF proxy handles India latency)
#   MACHINE_TYPE = e2-standard-2   (2 vCPU, 8GB RAM — minimum viable for 10 agents)
#   DISK_SIZE    = 50              (GB, pd-balanced)
#   IMAGE_FAMILY = ubuntu-2204-lts
#   IMAGE_PROJECT= ubuntu-os-cloud
#
# Cost (us-central1, sustained): e2-standard-2 ~ $24.27/mo running 24/7,
# ~ $6.70/mo if STOPPED when idle (you only pay for the disk while stopped).
# Stop when not coding:  gcloud compute instances stop code-server --zone=us-central1-a
# Start again:           gcloud compute instances start code-server --zone=us-central1-a

set -euo pipefail

VM_NAME="${VM_NAME:-code-server}"
ZONE="${ZONE:-us-central1-a}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-2}"
DISK_SIZE="${DISK_SIZE:-50}"
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
SERVICE_ACCOUNT_FLAG=""

# Fail fast if no project configured
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -z "${PROJECT}" || "${PROJECT}" == "(unset)" ]]; then
  echo "ERROR: No GCP project configured. Run: gcloud config set project <PROJECT_ID>" >&2
  exit 1
fi
echo "Using GCP project: ${PROJECT}"

# Use default compute service account if it exists; otherwise skip (instance uses the
# Compute Engine default service account automatically when --service-account is omitted).
DEFAULT_SA="$(gcloud iam service-accounts list --filter='email:compute@developer.gserviceaccount.com OR email:-compute@developer.gserviceaccount.com' --format='value(email)' 2>/dev/null | head -n1 || true)"
# Prefer the project-number compute default SA
PROJECT_NUM="$(gcloud projects describe "${PROJECT}" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -n "${PROJECT_NUM}" ]]; then
  DEFAULT_SA="${PROJECT_NUM}-compute@developer.gserviceaccount.com"
  SERVICE_ACCOUNT_FLAG="--service-account=${DEFAULT_SA} --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write"
fi

echo "Provisioning VM '${VM_NAME}' in ${ZONE} (${MACHINE_TYPE}, ${DISK_SIZE}GB disk)..."

# 1. Firewall rule for HTTP/HTTPS (code-server behind Nginx on 80/443). Idempotent.
FW_HTTP="allow-http-https"
if ! gcloud compute firewall-rules describe "${FW_HTTP}" >/dev/null 2>&1; then
  echo "Creating firewall rule '${FW_HTTP}' (tcp:80,443 from 0.0.0.0/0)..."
  gcloud compute firewall-rules create "${FW_HTTP}" \
    --allow=tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --description="Allow HTTP/HTTPS for code-server" \
    --target-tags=code-server
else
  echo "Firewall rule '${FW_HTTP}' already exists."
fi

# 2. Create the VM if it does not exist. Idempotent.
if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "VM '${VM_NAME}' already exists in ${ZONE}."
else
  echo "Creating VM '${VM_NAME}'..."
  gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --boot-disk-size="${DISK_SIZE}GB" \
    --boot-disk-type=pd-balanced \
    --tags=code-server,http-server,https-server \
    ${SERVICE_ACCOUNT_FLAG} \
    --metadata=enable-oslogin=FALSE \
    --no-shielded-secure-boot
fi

# 3. Fetch the external IP
EXTERNAL_IP="$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"
echo ""
echo "============================================================"
echo "VM '${VM_NAME}' is ready."
echo "  External IP : ${EXTERNAL_IP}"
echo "  Zone        : ${ZONE}"
echo "  Machine     : ${MACHINE_TYPE}"
echo "============================================================"
echo ""
echo "NEXT STEPS:"
echo "  1. Copy your .env and bootstrap script to the VM:"
echo "     gcloud compute scp deploy/autoconfig.sh .env ${VM_NAME}:~/ --zone=${ZONE}"
echo "     (create .env locally first — see .env.example)"
echo "  2. SSH in and run the bootstrap:"
echo "     gcloud compute ssh ${VM_NAME} --zone=${ZONE}"
echo "     sudo bash ~/autoconfig.sh"
echo "  3. Add Cloudflare DNS A record (you do this manually):"
echo "     A    code.dmj.one  ->  ${EXTERNAL_IP}   (Proxy: ON)"
echo "  4. Access: https://code.dmj.one  (or http://${EXTERNAL_IP} until DNS propagates)"
echo ""
echo "STOP WHEN NOT CODING (saves ~75% cost):"
echo "  gcloud compute instances stop ${VM_NAME} --zone=${ZONE}"
echo "START AGAIN:"
echo "  gcloud compute instances start ${VM_NAME} --zone=${ZONE}"
echo "  (IP may change on stop/start; use the DNS record, or reserve a static IP)"
echo ""
echo "OPTIONAL: Reserve a static external IP so it survives stop/start:"
echo "  gcloud compute addresses create ${VM_NAME}-ip --region=\$(echo ${ZONE} | sed 's/-[a-z]$//') --addresses=${EXTERNAL_IP}"
