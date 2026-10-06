output "cluster_name" {
  value = aws_eks_cluster.lab.name
}

output "aws_region" {
  value = var.aws_region
}

output "step" {
  value = var.step
}

output "vpc_cni_version" {
  value = aws_eks_addon.vpc_cni.addon_version
}

output "node_subnet_ids" {
  value = join(" ", aws_subnet.private[*].id)
}

output "pod_subnet_ids" {
  value = join(" ", aws_subnet.pods[*].id)
}

output "vpc_id" {
  value = aws_vpc.lab.id
}
