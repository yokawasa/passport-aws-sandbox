output "region" {
  description = "AWS リージョン"
  value       = var.region
}

output "cluster_name" {
  description = "EKS クラスタ名"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API エンドポイント"
  value       = module.eks.cluster_endpoint
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "ALB が配置される public subnet"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "ノードが配置される private subnet"
  value       = module.vpc.private_subnets
}

output "kubeconfig_command" {
  description = "kubeconfig を更新するコマンド"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "passport_proxy_irsa_role_arn" {
  description = "Passport Proxy の ServiceAccount に付与する IAM ロール ARN"
  value       = module.passport_proxy_irsa.iam_role_arn
}

output "passport_demo_secret_name" {
  description = "検証用シークレットの名前 ({{vault:...}} に指定する値)"
  value       = try(aws_secretsmanager_secret.demo[0].name, null)
}
