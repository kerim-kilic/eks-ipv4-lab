#!/usr/bin/env bash
# Step 4: shows pods with addresses from the non-routable range reaching the internet.
# Their traffic leaves with the node's address (SNAT), then goes through the NAT gateway.
# Usage: scripts/egress-check.sh [checks] [pause-replicas]
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"

checks=${1:-4}
# Enough pause pods to use up the addresses on the nodes' primary ENIs (5 each on a t3.medium), so the check pods
# get addresses from ENIs in the 100.64 subnets.
pause=${2:-30}

step=$(tf_out step)
out="$RAW_DIR/$step/egress"
mkdir -p "$out"

kubectl apply -f "$REPO_ROOT/k8s/pause.yaml" >/dev/null
kubectl scale deploy pause --replicas="$pause" >/dev/null
kubectl rollout status deploy pause --timeout=5m >/dev/null

for i in $(seq 1 "$checks"); do
  kubectl run "egress-check-$i" --restart=Never --image=curlimages/curl:8.10.1 --command -- \
    sh -c 'echo "pod address: $(hostname -i)"; echo "seen from the internet as: $(curl -s https://checkip.amazonaws.com)"' >/dev/null
done
for i in $(seq 1 "$checks"); do
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/egress-check-$i" --timeout=3m >/dev/null
done

{
  kubectl get pods -l run -o wide
  for i in $(seq 1 "$checks"); do
    echo
    echo "egress-check-$i on $(kubectl get pod "egress-check-$i" -o jsonpath='{.spec.nodeName}'):"
    kubectl logs "egress-check-$i"
  done
} | tee "$out/egress.txt"

# How the node does it: the CNI's SNAT rules and the policy routing that sends traffic for outside the VPC out of the
# primary interface. Read through a debug pod on the node that ran the first check.
node=$(kubectl get pod egress-check-1 -o jsonpath='{.spec.nodeName}')
kubectl debug "node/$node" --image=busybox:1.36 --profile=sysadmin -q --attach=false -- sleep 120 >/dev/null 2>&1 || true
dbg=$(kubectl get pods -o json | jq -r --arg n "$node" \
  '[.items[] | select(.metadata.name | startswith("node-debugger-")) | select(.spec.nodeName == $n and .metadata.deletionTimestamp == null)] | last | .metadata.name // empty')
if [[ -n $dbg ]] && kubectl wait --for=condition=Ready "pod/$dbg" --timeout=60s >/dev/null 2>&1; then
  kubectl exec "$dbg" -- chroot /host sh -c 'iptables-save -t nat | grep AWS-SNAT; echo; iptables-save -t mangle | grep -i connmark; echo; ip rule list; echo; ip route show table main' \
    >"$out/node-routing-$node.txt" 2>&1 || true
  kubectl delete pod "$dbg" --wait=false >/dev/null 2>&1 || true
fi

kubectl delete pods -l run --wait=false >/dev/null
