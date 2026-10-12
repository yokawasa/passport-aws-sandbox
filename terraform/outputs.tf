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

output "ecr_repository_url" {
  description = "API イメージの push 先"
  value       = aws_ecr_repository.api.repository_url
}

output "app_namespace" {
  description = "API の namespace"
  value       = kubernetes_namespace.app.metadata[0].name
}

output "kubeconfig_command" {
  description = "kubeconfig を更新するコマンド"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
