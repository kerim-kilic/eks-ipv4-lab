#!/usr/bin/env bash
# Prints one CSV row describing the cluster's address use right now. With --header, prints the column names.
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"

if [[ ${1:-} == --header ]]; then
  echo "time,replicas,running,ip_failures,unschedulable,pods_in_pod_cidr,node_subnet_free,pod_subnet_free,cni_total_ips,cni_assigned_ips,enis_in_node_subnets"
  exit 0
fi

region=$(lab_region)
pod_cidr_prefix=100.64.

pods=$(kubectl get pods -l app=pause -o json)
replicas=$(kubectl get deploy pause -o jsonpath='{.spec.replicas}')
running=$(jq '[.items[] | select(.status.phase == "Running")] | length' <<<"$pods")
unschedulable=$(jq '[.items[] | select(.status.conditions[]? | .type == "PodScheduled" and .status == "False")] | length' <<<"$pods")
in_pod_cidr=$(jq --arg p "$pod_cidr_prefix" '[.items[] | select((.status.podIP // "") | startswith($p))] | length' <<<"$pods")

# Pods that exist now and whose sandbox failed because the CNI had no address to give.
ip_failures=$(kubectl get events --field-selector reason=FailedCreatePodSandBox -o json |
  jq --argjson pods "$(jq '[.items[].metadata.name]' <<<"$pods")" \
    '[.items[] | select(.message | test("assign an IP address")) | .involvedObject.name | select(. as $n | $pods | index($n))] | unique | length')

subnet_free() {
  [[ -z $1 ]] && { echo "-"; return; }
  # shellcheck disable=SC2086 # word splitting is the point: a space-separated list of IDs
  aws ec2 describe-subnets --region "$region" --subnet-ids $1 \
    --query 'sum(Subnets[].AvailableIpAddressCount)' --output text
}
node_free=$(subnet_free "$(tf_out node_subnet_ids)")
pod_free=$(subnet_free "$(tf_out pod_subnet_ids)")

# The CNI's own view: addresses held on each node against addresses given to pods.
cni_total=0
cni_assigned=0
for pod in $(kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[*].metadata.name}'); do
  metrics=$(kubectl get --raw "/api/v1/namespaces/kube-system/pods/$pod:61678/proxy/metrics" 2>/dev/null || true)
  total=$(awk '/^awscni_total_ip_addresses /{print $2}' <<<"$metrics")
  assigned=$(awk '/^awscni_assigned_ip_addresses /{print $2}' <<<"$metrics")
  total=${total:-0} assigned=${assigned:-0}
  cni_total=$((cni_total + ${total%.*}))
  cni_assigned=$((cni_assigned + ${assigned%.*}))
done

enis=$(aws ec2 describe-network-interfaces --region "$region" \
  --filters "Name=subnet-id,Values=$(tf_out node_subnet_ids | tr ' ' ',')" \
  --query 'length(NetworkInterfaces)' --output text)

echo "$(date +%H:%M:%S),$replicas,$running,$ip_failures,$unschedulable,$in_pod_cidr,$node_free,$pod_free,$cni_total,$cni_assigned,$enis"
