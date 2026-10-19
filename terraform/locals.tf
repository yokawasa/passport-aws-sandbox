locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = local.name

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 を /20 に分割して public / private に割り当てる
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "passport-aws-sandbox"
    },
    var.tags
  )
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}
