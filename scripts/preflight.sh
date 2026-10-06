#!/usr/bin/env bash
# Checks before the first apply of a session. Prints no account details, only whether they match.
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"

fail=0
check() { printf '%-48s %s\n' "$1" "$2"; }

for tool in terraform aws kubectl jq python3; do
  if command -v "$tool" >/dev/null; then check "$tool" "ok"; else check "$tool" "MISSING"; fail=1; fi
done

if ! account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  check "AWS profile $AWS_PROFILE" "NO CREDENTIALS (run aws configure --profile $AWS_PROFILE)"
  exit 1
fi
check "AWS profile $AWS_PROFILE" "ok"

tfvars="$TF_DIR/terraform.tfvars"
if [[ ! -f $tfvars ]]; then
  check "terraform.tfvars" "MISSING (copy terraform.tfvars.example)"
  fail=1
else
  wanted=$(sed -n 's/^allowed_account_id *= *"\([0-9]*\)".*/\1/p' "$tfvars")
  if [[ $account == "$wanted" ]]; then
    check "Credentials are for the lab account" "yes"
  else
    check "Credentials are for the lab account" "NO: stop here"
    fail=1
  fi
fi

region=$(lab_region)
check "Region" "$region"

if ! budgets=$(aws budgets describe-budgets --account-id "$account" --query 'length(Budgets)' --output text 2>/dev/null); then
  # Some accounts block the Budgets API, for example ones lent out for training; their owner's limits apply instead.
  check "AWS Budgets alert" "CAN'T CHECK (Budgets API denied)"
elif [[ $budgets =~ ^[1-9] ]]; then
  check "AWS Budgets alert" "ok ($budgets budget(s))"
else
  check "AWS Budgets alert" "NONE: create one first"
  fail=1
fi

default_version=$(aws eks describe-cluster-versions --region "$region" --default-only \
  --query 'clusterVersions[0].clusterVersion' --output text 2>/dev/null || echo "unknown")
check "Current EKS default Kubernetes version" "$default_version"

# The pinned version must be in standard support: extended support costs extra per cluster hour.
pinned=$(sed -n 's/^kubernetes_version *= *"\(.*\)".*/\1/p' "$tfvars" 2>/dev/null || true)
support=$(aws eks describe-cluster-versions --region "$region" --cluster-versions "$pinned" \
  --query 'clusterVersions[0].versionStatus' --output text 2>/dev/null || echo "unknown")
if [[ $support == STANDARD_SUPPORT ]]; then
  check "Pinned version $pinned" "standard support"
else
  check "Pinned version ${pinned:-(none)}" "NOT IN STANDARD SUPPORT ($support)"
  fail=1
fi

existing=$(aws eks list-clusters --region "$region" --query 'length(clusters)' --output text)
check "EKS clusters already in $region" "$existing"

exit $fail
