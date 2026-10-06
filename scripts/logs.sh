#!/usr/bin/env bash
# Saves the logs that explain a step to captures/raw/<step>/<label>/logs/: the aws-node container logs, ipamd's own
# log from each node, and kubectl describe for the nodes and for a pod that couldn't get an address.
# Usage: scripts/logs.sh <label> [--free-nodes]
# --free-nodes scales the pause pods to 0 after the describes, so nodes at max pods have room for the debug pods.
# Only for the end of a step: the logs on the nodes are history, the state was captured before.
source "$(dirname "$0")/env.sh"

label=${1:?usage: logs.sh <label>}
step=$(tf_out step)
out="$RAW_DIR/$step/$label/logs"
mkdir -p "$out"

log "Saving logs for $step/$label"

kubectl describe nodes >"$out/describe-nodes.txt"
kubectl describe deploy pause >"$out/describe-deploy-pause.txt" 2>/dev/null || true

# One pod whose sandbox failed for lack of an address, and one the scheduler couldn't place, if there are any.
failed=$(kubectl get events --field-selector reason=FailedCreatePodSandBox -o json |
  jq -r '[.items[] | select(.message | test("assign an IP address")) | .involvedObject.name] | last // empty')
if [[ -n $failed ]] && kubectl get pod "$failed" >/dev/null 2>&1; then
  kubectl describe pod "$failed" >"$out/describe-pod-ip-failure.txt"
fi
pending=$(kubectl get pods -l app=pause -o json |
  jq -r '[.items[] | select(.status.conditions[]? | .type == "PodScheduled" and .status == "False") | .metadata.name] | first // empty')
if [[ -n $pending ]]; then
  kubectl describe pod "$pending" >"$out/describe-pod-unschedulable.txt"
fi

if [[ ${2:-} == --free-nodes ]]; then
  log "Scaling the pause pods to 0 to make room for the debug pods"
  kubectl scale deploy pause --replicas=0 >/dev/null
  kubectl wait --for=delete pod -l app=pause --timeout=3m >/dev/null 2>&1 || true
fi

for pod in $(kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[*].metadata.name}'); do
  node=$(kubectl -n kube-system get pod "$pod" -o jsonpath='{.spec.nodeName}')
  kubectl -n kube-system logs "$pod" -c aws-node >"$out/aws-node-$node.log" 2>&1 || true

  # ipamd writes its detailed log on the node. A debug pod on the host network can read it without a pod address.
  kubectl debug "node/$node" --image=busybox:1.36 --profile=general -q --attach=false \
    -- sleep 300 >/dev/null 2>&1 || true
  dbg=$(kubectl get pods -o json | jq -r --arg n "$node" \
    '[.items[] | select(.metadata.name | startswith("node-debugger-")) | select(.spec.nodeName == $n and .metadata.deletionTimestamp == null)] | last | .metadata.name // empty')
  if [[ -n $dbg ]] && kubectl wait --for=condition=Ready "pod/$dbg" --timeout=45s >/dev/null 2>&1; then
    kubectl exec "$dbg" -- sh -c 'cat /host/var/log/aws-routed-eni/ipamd.log' >"$out/ipamd-$node.log" 2>/dev/null || true
    kubectl exec "$dbg" -- sh -c 'cat /host/var/log/aws-routed-eni/plugin.log' >"$out/cni-plugin-$node.log" 2>/dev/null || true
  fi
  [[ -n $dbg ]] && kubectl delete pod "$dbg" --wait=false >/dev/null 2>&1 || true
done

log "Saved to ${out#"$REPO_ROOT"/}"
