#!/usr/bin/env bash
# Writes credentials for the lab cluster to .kubeconfig in the repository (git-ignored).
source "$(dirname "$0")/env.sh"

aws eks update-kubeconfig --region "$(lab_region)" --name "$(tf_out cluster_name)" --kubeconfig "$KUBECONFIG" >/dev/null
kubectl get nodes -o wide
