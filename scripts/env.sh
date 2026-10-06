# Sourced by the other scripts: shared settings and helpers.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TF_DIR="$REPO_ROOT/terraform"
RAW_DIR="$REPO_ROOT/captures/raw"

export AWS_PROFILE=${AWS_PROFILE:-eks-lab}
# A kubeconfig of its own, so the lab never touches ~/.kube/config.
export KUBECONFIG="$REPO_ROOT/.kubeconfig"

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

# From terraform.tfvars, so it works before the first apply and after the destroy.
lab_region() {
  local region
  region=$(sed -n 's/^aws_region *= *"\(.*\)".*/\1/p' "$TF_DIR/terraform.tfvars" 2>/dev/null || true)
  echo "${region:-us-east-1}"
}

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}
