# Network configuration
vpc_cidr   = "192.168.0.0/16" # Different from default to show customization
aws_region = "us-east-1"      # AWS region for resource creation

availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

private_subnet_cidrs = {
  "us-east-1a" = "192.168.0.0/20"
  "us-east-1b" = "192.168.16.0/20"
  "us-east-1c" = "192.168.32.0/20"
}

public_subnet_cidrs = {
  "us-east-1a" = "192.168.48.0/20"
  "us-east-1b" = "192.168.64.0/20"
  "us-east-1c" = "192.168.80.0/20"
}

# EKS cluster configuration
eks_node_size      = "t3.medium" # Size of the EKS node pool instances
eks_node_disk_size = 40          # EKS node disk size in GB
cluster_name       = "eks-prod"

# Add IAM users/roles as cluster admins
eks_admin_arns = [
  "arn:aws:iam::430118834478:user/eks16"
]

# Fargate configuration
fargate_namespaces = ["fargate-system", "default", "arc-runners"]