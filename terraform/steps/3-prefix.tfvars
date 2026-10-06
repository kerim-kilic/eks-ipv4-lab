# Step 3: a /28 prefix per ENI slot instead of single addresses, and a kubelet told it may run more pods.
step = "3-prefix"

cni_env = {
  ENABLE_PREFIX_DELEGATION = "true"
  WARM_PREFIX_TARGET       = "1"
}

max_pods = 110
