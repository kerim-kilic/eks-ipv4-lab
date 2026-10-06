variable "name" {
  description = "Name for the cluster and a prefix for everything else."
  type        = string
  default     = "eks-ipv4-lab"
}

variable "aws_region" {
  description = "Region for the lab."
  type        = string
  default     = "us-east-1"
}

variable "allowed_account_id" {
  description = "Account to run in. The provider refuses any other."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.allowed_account_id))
    error_message = "Must be a 12-digit AWS account ID."
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public cluster endpoint, usually your own address as a /32."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "Pinned Kubernetes version. scripts/preflight.sh prints the current EKS default."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "Use the minor version only, for example 1.33."
  }
}

# Deliberately small, so addresses run out with a handful of nodes.
variable "vpc_cidr" {
  description = "Primary (routable) VPC range."
  type        = string
  default     = "10.20.0.0/24"
}

variable "pod_cidr" {
  description = "Secondary range from the shared address space (RFC 6598), used for pods in step 4."
  type        = string
  default     = "100.64.0.0/16"
}

variable "instance_type" {
  description = "Node instance type. t3.medium: 3 ENIs with 6 IPv4 addresses each, as in the article."
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Nodes in the managed node group, spread over the two private subnets."
  type        = number
  default     = 4
}

# Set per step, see steps/.

variable "step" {
  description = "Lab step. Part of the node group name, so each step gets new nodes."
  type        = string
  default     = "1-default"
}

variable "cni_env" {
  description = "VPC CNI environment variables for this step, merged over the defaults in locals.tf."
  type        = map(string)
  default     = {}
}

variable "max_pods" {
  description = "kubelet max pods. null keeps the value EKS sets for the instance type."
  type        = number
  default     = null
}

variable "enable_pod_subnets" {
  description = "Add the secondary range and the subnets tagged for the CNI (step 4)."
  type        = bool
  default     = false
}
