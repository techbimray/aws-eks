terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.90.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket = "tcslabsfjbs"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}
# Variables
variable "cluster_name" {
  default     = "eks-vijay"
  description = "give a cluster name"
  type        = string
}
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "aws_region" {
  description = "region for resource creation"
  default     = "us-east-1"
  type        = string
}

variable "eks_node_size" {
  type        = string
  description = " size of the eks node pool instances"
  default     = "t3.medium"
}
variable "eks_node_disk_size" {
  type        = number
  description = "eks node disk size in gb"
  default     = 40
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnet_cidrs" {
  description = "Map of AZ to CIDR for private subnets"
  type        = map(string)
  default = {
    "us-east-1a" = "192.168.0.0/20"
    "us-east-1b" = "192.168.16.0/20"
    "us-east-1c" = "192.168.32.0/20"
  }
}

variable "public_subnet_cidrs" {
  description = "Map of AZ to CIDR for public subnets"
  type        = map(string)
  default = {
    "us-east-1a" = "192.168.48.0/20"
    "us-east-1b" = "192.168.64.0/20"
    "us-east-1c" = "192.168.80.0/20"
  }
}

variable "fargate_namespaces" {
  description = "Kubernetes namespaces to use with Fargate"
  type        = list(string)
  default     = ["fargate-system", "default"]
}

provider "aws" {
  region = var.aws_region
}
# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Get AWS Account ID
data "aws_caller_identity" "current" {}

# Add random string generator for uniqueness
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "main-vpc-${random_string.suffix.result}"
  }
}

# Create private subnets using the map
resource "aws_subnet" "private" {
  for_each          = var.private_subnet_cidrs
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name                                        = "private-subnet-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# Create public subnets using the map
resource "aws_subnet" "public" {
  for_each                = var.public_subnet_cidrs
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "public-subnet-${each.key}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

# Create internet gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw-${random_string.suffix.result}"
  }
}

# Create route table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt-${random_string.suffix.result}"
  }
}

# Create public route table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "public-rt-${random_string.suffix.result}"
  }
}

# Add route to internet via IGW
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate private subnets with route table
resource "aws_route_table_association" "private" {
  for_each       = var.private_subnet_cidrs
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
  for_each       = var.public_subnet_cidrs
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# Create NAT Gateway in first public subnet
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  # Use the first public subnet from the list of keys
  subnet_id = aws_subnet.public[keys(var.public_subnet_cidrs)[0]].id

  tags = {
    Name = "main-nat-gw-${random_string.suffix.result}"
  }
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "nat-eip-${random_string.suffix.result}"
  }
}

# Add route to internet via NAT Gateway for private subnets
resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# EKS Cluster IAM Role
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

# Attach required policies to the EKS cluster role
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# Create the EKS cluster
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = [for subnet in aws_subnet.private : subnet.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }
  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }
  # Ensure IAM role permissions are created before the cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name = "eks-cluster-${random_string.suffix.result}"
  }
}

# Security Group for EKS Cluster
resource "aws_security_group" "eks_cluster" {
  name        = "eks-cluster-sg-${random_string.suffix.result}"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "eks-cluster-sg-${random_string.suffix.result}"
  }
}

# Node Group IAM Role
resource "aws_iam_role" "eks_node_group" {
  name = "eks-node-group-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# Attach policies to Node Group role
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_read" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}

# IAM role for EBS CSI driver
resource "aws_iam_role" "ebs_csi_driver" {
  name = "eks-ebs-csi-driver-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"
      }
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" : "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }]
  })
}

# Attach required policies to the EBS CSI driver role
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

# IAM role for EFS CSI driver
resource "aws_iam_role" "efs_csi_driver" {
  name = "eks-efs-csi-driver-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}"
      }
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" : "system:serviceaccount:kube-system:efs-csi-controller-sa"
        }
      }
    }]
  })
}

# EFS CSI Driver Policy
resource "aws_iam_policy" "efs_csi_policy" {
  name        = "EFSCSIDriverPolicy-${random_string.suffix.result}"
  description = "Policy for EFS CSI driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DescribeAccessPoints",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "ec2:DescribeAvailabilityZones"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/kubernetes.io/cluster/*" = "owned"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:DeleteAccessPoint"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:ResourceTag/kubernetes.io/cluster/*" = "owned"
          }
        }
      }
    ]
  })
}

# Attach EFS CSI policy to role
resource "aws_iam_role_policy_attachment" "efs_csi_policy_attachment" {
  policy_arn = aws_iam_policy.efs_csi_policy.arn
  role       = aws_iam_role.efs_csi_driver.name
}

# IAM role for Fargate
resource "aws_iam_role" "eks_fargate" {
  name = "eks-fargate-profile-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
  })
}

# Attach Fargate execution policy
resource "aws_iam_role_policy_attachment" "eks_fargate_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.eks_fargate.name
}

# Create EKS Managed Node Group
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "eks-node-group-${random_string.suffix.result}"
  node_role_arn   = aws_iam_role.eks_node_group.arn
  subnet_ids      = [for subnet in aws_subnet.private : subnet.id]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = [var.eks_node_size]
  capacity_type  = "ON_DEMAND"
  disk_size      = var.eks_node_disk_size

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_read
  ]

  tags = {
    Name = "eks-node-group-${random_string.suffix.result}"
  }
}

# Install EKS Add-ons
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.40.0-eksbuild.1" # Check latest version
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn

  depends_on = [
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-efs-csi-driver"
  addon_version            = "v2.1.6-eksbuild.1" # Check latest version
  service_account_role_arn = aws_iam_role.efs_csi_driver.arn

  depends_on = [
    aws_eks_node_group.main
  ]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = "v1.3.4-eksbuild.1"  # Check latest version

  depends_on = [
    aws_eks_node_group.main
  ]
}

# Create EKS Fargate Profile
resource "aws_eks_fargate_profile" "main" {
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = "fargate-profile-${random_string.suffix.result}"
  pod_execution_role_arn = aws_iam_role.eks_fargate.arn
  subnet_ids             = [for subnet in aws_subnet.private : subnet.id]

  dynamic "selector" {
    for_each = var.fargate_namespaces
    content {
      namespace = selector.value
    }
  }

  # Optional: Add labels for Fargate pods
  selector {
    namespace = "kube-system"
    labels = {
      "fargate" = "true"
    }
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# Output the EKS cluster endpoint and certificate authority data
output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_security_group_id" {
  description = "Security group IDs attached to the EKS cluster control plane"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = aws_eks_cluster.main.name
}

# Additional outputs
output "fargate_profile_arn" {
  description = "ARN of the EKS Fargate profile"
  value       = aws_eks_fargate_profile.main.arn
}

output "enabled_addons" {
  description = "List of enabled EKS add-ons"
  value = [
    aws_eks_addon.ebs_csi.addon_name,
    aws_eks_addon.efs_csi.addon_name,
    aws_eks_addon.pod_identity_agent.addon_name
  ]
}
