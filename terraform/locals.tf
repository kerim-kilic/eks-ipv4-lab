locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # 10.20.0.0/24:
  #   .0/27,  .32/27   private (control plane ENIs, nodes, pods)
  #   .64/28, .80/28   public (NAT gateways)
  #   .96/27, .128/25  unused
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 3, i)]
  public_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 4)]

  # 100.64.0.0/16: a /19 per AZ.
  pod_cidrs = [for i, _ in local.azs : cidrsubnet(var.pod_cidr, 3, i)]

  # Only set for steps that change max pods (prefix delegation).
  node_user_data = var.max_pods == null ? null : base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      kubelet:
        config:
          maxPods: ${var.max_pods}

    --BOUNDARY--
  EOT
  )

  # Every step sets all of these, so nothing lingers from the step before. "0" means unset for the IP targets.
  cni_env = merge({
    WARM_ENI_TARGET          = "1"
    WARM_IP_TARGET           = "0"
    MINIMUM_IP_TARGET        = "0"
    ENABLE_PREFIX_DELEGATION = "false"
  }, var.cni_env)
}
