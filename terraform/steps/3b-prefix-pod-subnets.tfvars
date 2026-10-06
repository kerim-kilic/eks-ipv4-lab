# Step 3b: prefix delegation again, now with the pod subnets from step 4 to take the /28s, and the kubelet told 60 pods.
# 60 is below the cap EKS puts on managed node groups (110 below 30 vCPUs), so it shows whether our own value reaches the nodes.
step = "3b-prefix-pod-subnets"

cni_env = {
  ENABLE_PREFIX_DELEGATION = "true"
  WARM_PREFIX_TARGET       = "1"
}

max_pods = 60

enable_pod_subnets = true
