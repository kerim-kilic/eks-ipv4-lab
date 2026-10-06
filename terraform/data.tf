data "aws_availability_zones" "available" {
  state = "available"

  # EKS can't place a cluster in these. Zone IDs, because AZ names differ per account.
  exclude_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]
}

data "aws_eks_addon_version" "latest" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy"])

  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.lab.version
  most_recent        = true
}
