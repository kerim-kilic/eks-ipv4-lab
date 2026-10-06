resource "aws_eks_cluster" "lab" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # The CNI, CoreDNS and kube-proxy are managed as add-ons below instead.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.admin_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # No extended support charges if the cluster outlives its version.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.latest["vpc-cni"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = local.cni_env
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "kube-proxy"
  addon_version               = data.aws_eks_addon_version.latest["kube-proxy"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.lab.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.latest["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Needs nodes to run on.
  depends_on = [aws_eks_node_group.lab]
}

resource "aws_launch_template" "node" {
  name_prefix = "${var.name}-node-"
  user_data   = local.node_user_data

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2, hop limit 1: pods can't reach the node's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-node" }
  }
}

resource "aws_eks_node_group" "lab" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "${var.name}-${var.step}" # new step, new nodes
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.instance_type]

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_route_table_association.private,
    aws_route_table_association.pods,
  ]
}
