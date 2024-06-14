provider "aws" {
  region = "us-west-2"

}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
    }
  }
}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"
  domain_for_route53 = var.domain_name_in_route53
}


provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.eks_cluster_id]
  }
}


module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.32.1"

  #   tenant      = local.tenant
  #   environment = local.environment
  #   zone        = local.zone

  cluster_name = var.cluster_name

  # EKS Cluster VPC and Subnet mandatory config
  vpc_id             = var.vpc_id
  private_subnet_ids = var.private_subnets

  # EKS CONTROL PLANE VARIABLES
  cluster_version = "1.24"

  # EKS Managed Nodes in AZ
  managed_node_groups = {
    mg_5 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["t3.medium"]
      min_size        = 1
      max_size        = 1
      desired_size    = 1
      subnet_ids      = var.private_subnets
    }
  }

  # EKS LOCAL ZONE NODE GROUP
  self_managed_node_groups = {
    self_mg_4 = {
      node_group_name    = "self-managed-ondemand"
      instance_type      = "t3.medium"
      capacity_type      = ""                # Optional Use this only for SPOT capacity as capacity_type = "spot"
      launch_template_os = "amazonlinux2eks" # amazonlinux2eks  or bottlerocket or windows
      # launch_template_os = "bottlerocket" # amazonlinux2eks  or bottlerocket or windows
      block_device_mappings = [
        {
          device_name = "/dev/xvda"
          volume_type = "gp2"
          volume_size = "20"
        },
      ]
      enable_monitoring = false
      # AUTOSCALING
      max_size = "2"
      # EFS CSI Drvier required two nodes so that installing helm chart will not stuck 
      min_size = "2"

      subnet_ids = [var.private_subnets_local_zone]
    },
  }

  cluster_security_group_additional_rules = {
      ingress_nodes = {
      description                = "Allow all connections from nodes"
      protocol                   = "-1"
      from_port                  = 0
      to_port                    = 0
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  #----------------------------------------------------------------------------------------------------------#
  # Securaity groups used in this module created by the upstream modules terraform-aws-eks (https://github.com/terraform-aws-modules/terraform-aws-eks).
  #   Upstrem module implemented Security groups based on the best practices doc https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html.
  #   So, by default the security groups are restrictive. Users needs to enable rules for specific ports required for App requirement or Add-ons
  #   See the notes below for each rule used in these examples
  #----------------------------------------------------------------------------------------------------------#
  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }


}


module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.32.1//modules/kubernetes-addons"

  eks_cluster_id               = module.eks_blueprints.eks_cluster_id
  eks_worker_security_group_id = module.eks_blueprints.worker_node_security_group_id
  auto_scaling_group_names     = module.eks_blueprints.self_managed_node_group_autoscaling_groups

  eks_cluster_domain = local.domain_for_route53


  # EKS Addons
  # TODO: Took ~15 min to deploy addons, need to debug further 
  # enable_amazon_eks_vpc_cni            = true
  # enable_amazon_eks_coredns            = true
  # enable_amazon_eks_kube_proxy         = true
  #enable_amazon_eks_aws_ebs_csi_driver = true
  #enable_aws_load_balancer_controller = false 

  enable_metrics_server               = true

  enable_external_dns       = true
  # enable_cluster_autoscaler = true


  enable_aws_efs_csi_driver = true
  # EFS CSI Drvier required two nodes so that installing helm chart will not stuck 
  depends_on = [
    module.eks_blueprints.self_managed_node_groups,
    module.eks_blueprints.managed_node_groups
  ]
}


resource "aws_security_group_rule" "allow_node_sg_to_cluster_sg" {
  description = "Self-managed Nodegroup to Cluster API/Managed Nodegroup all traffic"

  source_security_group_id = module.eks_blueprints.worker_node_security_group_id
  security_group_id        = module.eks_blueprints.cluster_primary_security_group_id
  type                     = "ingress"
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0

  depends_on = [
    module.eks_blueprints
  ]
}

resource "aws_security_group_rule" "allow_node_sg_from_cluster_sg" {
  description = "Cluster API/Managed Nodegroup to Self-Managed Nodegroup all traffic"
  source_security_group_id = module.eks_blueprints.cluster_primary_security_group_id
  security_group_id        = module.eks_blueprints.worker_node_security_group_id
  type                     = "ingress"
  protocol                 = "-1"
  from_port                = 0
  to_port                  = 0

  depends_on = [
    module.eks_blueprints
  ]
}


resource "null_resource" "kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks_blueprints.eks_cluster_id}"
  }

  depends_on = [
    module.eks_blueprints
  ]


}
