#!/usr/bin/env bash
# After terraform destroy: confirms nothing billable is left. Prints counts only.
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"

name=eks-ipv4-lab
region=${1:-$(lab_region)}
left=0

count() {
  local label=$1 n=$2
  if [[ $n == 0 ]]; then
    printf '%-40s %s\n' "$label" "none"
  else
    printf '%-40s %s\n' "$label" "$n LEFT"
    left=1
  fi
}

count "EKS clusters" "$(aws eks list-clusters --region "$region" --query 'length(clusters)' --output text)"
count "Running or pending instances" "$(aws ec2 describe-instances --region "$region" \
  --filters "Name=tag:eks:cluster-name,Values=$name" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'length(Reservations[].Instances[])' --output text)"
count "NAT gateways" "$(aws ec2 describe-nat-gateways --region "$region" \
  --filter "Name=state,Values=pending,available,deleting" --query 'length(NatGateways)' --output text)"
count "Elastic IPs" "$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text)"
count "Load balancers" "$(aws elbv2 describe-load-balancers --region "$region" --query 'length(LoadBalancers)' --output text)"
count "ENIs left by the CNI" "$(aws ec2 describe-network-interfaces --region "$region" \
  --filters "Name=tag-key,Values=cluster.k8s.amazonaws.com/name" --query 'length(NetworkInterfaces)' --output text)"
count "Lab VPCs" "$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Project,Values=$name" \
  --query 'length(Vpcs)' --output text)"
count "Lab IAM roles" "$(aws iam list-roles --query "length(Roles[?starts_with(RoleName, '$name')])" --output text)"

exit $left
