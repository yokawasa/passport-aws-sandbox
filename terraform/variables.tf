variable "project" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "eks-api"
}

variable "environment" {
  description = "環境名 (dev / stg / prd など)"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC の CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "利用する AZ の数 (ALB は最低 2 AZ 必要)"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "ALB を使うため az_count は 2 以上にしてください。"
  }
}

variable "single_nat_gateway" {
  description = "NAT Gateway を 1 台に集約してコストを抑えるか (本番では false 推奨)"
  type        = bool
  default     = true
}

variable "kubernetes_version" {
  description = "EKS の Kubernetes バージョン"
  type        = string
  default     = "1.33"
}

variable "endpoint_public_access_cidrs" {
  description = "EKS API エンドポイントへのアクセスを許可する CIDR"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Managed Node Group のインスタンスタイプ"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_size" {
  description = "Managed Node Group の台数設定"
  type = object({
    min     = number
    max     = number
    desired = number
  })
  default = {
    min     = 2
    max     = 4
    desired = 2
  }
}

variable "node_capacity_type" {
  description = "ON_DEMAND または SPOT"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type は ON_DEMAND か SPOT を指定してください。"
  }
}

variable "app_namespace" {
  description = "API をデプロイする Kubernetes namespace"
  type        = string
  default     = "api"
}

variable "tags" {
  description = "全リソースに付与する追加タグ"
  type        = map(string)
  default     = {}
}
