# Step 2: keep a couple of spare addresses per node instead of a spare ENI.
step = "2-warm-ip"

cni_env = {
  WARM_IP_TARGET    = "2"
  MINIMUM_IP_TARGET = "5"
}
