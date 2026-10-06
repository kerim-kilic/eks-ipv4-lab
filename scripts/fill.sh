#!/usr/bin/env bash
# Scales the pause deployment up in steps until the nodes are full, measuring after each step.
# Writes captures/raw/<step>/fill.csv and full snapshots before, at the first IP failure, and at the end.
# Usage: scripts/fill.sh [increment] [settle-seconds]
# shellcheck source=env.sh
source "$(dirname "$0")/env.sh"

increment=${1:-5}
settle=${2:-45}
step=$(tf_out step)
out="$RAW_DIR/$step"
mkdir -p "$out"

kubectl apply -f "$REPO_ROOT/k8s/pause.yaml" >/dev/null
kubectl scale deploy pause --replicas=0 >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=10m >/dev/null

# Room for pause pods: what the kubelets allow, less what's already running.
max_pods=$(kubectl get nodes -o json | jq '[.items[].status.allocatable.pods | tonumber] | add')
others=$(kubectl get pods -A --field-selector=status.phase!=Succeeded -o json | jq '[.items[] | select(.metadata.labels.app != "pause")] | length')
target=$((max_pods - others))
log "Nodes allow $max_pods pods, $others already running: filling to $target pause pods"

sleep "$settle"
"$REPO_ROOT/scripts/capture.sh" 0-before
"$REPO_ROOT/scripts/measure.sh" --header >"$out/fill.csv"
"$REPO_ROOT/scripts/measure.sh" | tee -a "$out/fill.csv"

first_failure=""
replicas=0
last_running=-1
stalled=0
while ((replicas < target)); do
  replicas=$((replicas + increment))
  ((replicas > target)) && replicas=$target
  kubectl scale deploy pause --replicas="$replicas" >/dev/null
  sleep "$settle"
  row=$("$REPO_ROOT/scripts/measure.sh")
  echo "$row" | tee -a "$out/fill.csv"

  failures=$(cut -d, -f4 <<<"$row")
  if [[ -z $first_failure && $failures -gt 0 ]]; then
    first_failure=$replicas
    "$REPO_ROOT/scripts/capture.sh" "1-first-failure-at-$replicas"
    "$REPO_ROOT/scripts/logs.sh" "1-first-failure-at-$replicas"
  fi

  # Once pods fail for lack of addresses, three rounds without one more running pod means the nodes are full.
  running=$(cut -d, -f3 <<<"$row")
  if [[ -n $first_failure ]] && ((running == last_running)); then
    stalled=$((stalled + 1))
    if ((stalled >= 3)); then
      log "No new running pods for $stalled rounds: stopping at $replicas of $target"
      break
    fi
  else
    stalled=0
  fi
  last_running=$running
done

"$REPO_ROOT/scripts/capture.sh" 2-full
"$REPO_ROOT/scripts/logs.sh" 2-full --free-nodes
log "Done. First IP failure at: ${first_failure:-none} pause pods (target $target)"
