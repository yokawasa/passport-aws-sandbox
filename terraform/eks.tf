module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # 運用端末から kubectl したいので public エンドポイントを有効化。
  # 本番では endpoint_public_access_cidrs を絞るか false にする。
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true

  # terraform apply を実行した IAM プリンシパルに cluster-admin を付与
  enable_cluster_creator_admin_permissions = true

  vpc_id = module.vpc.vpc_id
  # ノードも control plane ENI も private subnet に配置する
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}
    vpc-cni = {
      # ノード起動前に入れておく
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type

      min_size     = var.node_group_size.min
      max_size     = var.node_group_size.max
      desired_size = var.node_group_size.desired

      labels = {
        role = "api"
      }
    }
  }

  tags = local.tags
}
