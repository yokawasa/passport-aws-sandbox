# ---------------------------------------------------------------------------
# 使い方:
#   make tf-init TFSTATE_BUCKET=my-tfstate-bucket
#   make tf-apply
#   make kubeconfig
# ---------------------------------------------------------------------------
SHELL := /bin/bash

TF_DIR         ?= terraform
ENVIRONMENT    ?= dev
PROJECT        ?= passport-sandbox
REGION         ?= ap-northeast-1
TFSTATE_BUCKET ?=
TFSTATE_KEY    ?= passport-sandbox/$(ENVIRONMENT)/terraform.tfstate

TF = terraform -chdir=$(TF_DIR)

.PHONY: help
help: ## コマンド一覧
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## tfstate 用 S3 バケットを作成
	@test -n "$(TFSTATE_BUCKET)" || (echo "TFSTATE_BUCKET を指定してください" && exit 1)
	terraform -chdir=$(TF_DIR)/bootstrap init
	terraform -chdir=$(TF_DIR)/bootstrap apply -var="bucket_name=$(TFSTATE_BUCKET)" -var="region=$(REGION)"

.PHONY: tf-init
tf-init: ## S3 backend で terraform init
	@test -n "$(TFSTATE_BUCKET)" || (echo "TFSTATE_BUCKET を指定してください" && exit 1)
	$(TF) init -reconfigure \
		-backend-config="bucket=$(TFSTATE_BUCKET)" \
		-backend-config="key=$(TFSTATE_KEY)" \
		-backend-config="region=$(REGION)"

.PHONY: tf-fmt
tf-fmt: ## terraform fmt
	terraform fmt -recursive $(TF_DIR)

.PHONY: tf-validate
tf-validate: ## terraform validate
	$(TF) validate

.PHONY: tf-plan
tf-plan: ## terraform plan
	$(TF) plan

.PHONY: tf-apply
tf-apply: ## terraform apply
	$(TF) apply

.PHONY: destroy-check
destroy-check: ## VPC 内に LB / SG の残骸がないか確認 (tf-destroy の前に実行)
	@vpc=$$($(TF) output -raw vpc_id 2>/dev/null); \
	test -n "$$vpc" || (echo "vpc_id を取得できません。既に destroy 済みか init が未実行です" && exit 1); \
	echo "VPC $$vpc に残っている Load Balancer:"; \
	lbs=$$(aws elbv2 describe-load-balancers --region $(REGION) \
		--query "LoadBalancers[?VpcId=='$$vpc'].LoadBalancerName" --output text); \
	if [ -n "$$lbs" ]; then \
		echo "  $$lbs"; \
		echo ""; \
		echo "⚠️  LB が残っています。これらは Terraform の管理外 (AWS Load Balancer Controller が作成) のため、"; \
		echo "    残したまま tf-destroy すると subnet の削除が DependencyViolation で失敗します。"; \
		echo "    'helm uninstall passport -n passport' を実行し、LB が消えるまで待ってください。"; \
		exit 1; \
	else \
		echo "  (なし)"; \
	fi; \
	echo ""; \
	echo "VPC $$vpc に残っている k8s 由来のセキュリティグループ:"; \
	sgs=$$(aws ec2 describe-security-groups --region $(REGION) \
		--filters Name=vpc-id,Values=$$vpc \
		--query "SecurityGroups[?GroupName!='default'].GroupId" --output text); \
	if [ -n "$$sgs" ]; then \
		echo "  $$sgs"; \
		echo ""; \
		echo "⚠️  セキュリティグループが残っています。LB 本体を消しても付随する SG は残るため、"; \
		echo "    残したまま tf-destroy すると VPC の削除が DependencyViolation で失敗します。"; \
		echo "    docs/troubleshooting.md の「VPC の DependencyViolation」を参照して削除してください。"; \
		exit 1; \
	else \
		echo "  (なし)"; \
	fi

.PHONY: tf-destroy
tf-destroy: ## terraform destroy (先に make destroy-check を実行すること)
	$(TF) destroy

.PHONY: kubeconfig
kubeconfig: ## kubeconfig を更新
	aws eks update-kubeconfig --region $(REGION) --name $(PROJECT)-$(ENVIRONMENT)
