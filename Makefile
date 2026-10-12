# ---------------------------------------------------------------------------
# 使い方:
#   make tf-init TFSTATE_BUCKET=my-tfstate-bucket
#   make tf-apply
#   make deploy
#   make url
# ---------------------------------------------------------------------------
SHELL := /bin/bash

TF_DIR         ?= terraform
ENVIRONMENT    ?= dev
PROJECT        ?= eks-api
REGION         ?= ap-northeast-1
TFSTATE_BUCKET ?=
TFSTATE_KEY    ?= terraform-aws-eks-api/$(ENVIRONMENT)/terraform.tfstate
IMAGE_TAG      ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo latest)
NAMESPACE      ?= api

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

.PHONY: tf-destroy
tf-destroy: ## terraform destroy (先に make undeploy で ALB を消すこと)
	$(TF) destroy

.PHONY: kubeconfig
kubeconfig: ## kubeconfig を更新
	aws eks update-kubeconfig --region $(REGION) --name $(PROJECT)-$(ENVIRONMENT)

.PHONY: build push
ECR_URL = $(shell $(TF) output -raw ecr_repository_url)

build: ## Docker イメージをビルド
	docker build --platform linux/amd64 -t $(ECR_URL):$(IMAGE_TAG) app

push: build ## ECR にログインして push
	aws ecr get-login-password --region $(REGION) \
		| docker login --username AWS --password-stdin $(shell echo $(ECR_URL) | cut -d/ -f1)
	docker push $(ECR_URL):$(IMAGE_TAG)

.PHONY: deploy
deploy: push ## k8s マニフェストを適用
	sed "s|IMAGE_PLACEHOLDER|$(ECR_URL):$(IMAGE_TAG)|" k8s/deployment.yaml | kubectl apply -f -
	kubectl apply -f k8s/service.yaml
	kubectl apply -f k8s/ingress.yaml
	kubectl -n $(NAMESPACE) rollout status deployment/sample-api

.PHONY: undeploy
undeploy: ## Ingress (= ALB) ごと削除
	kubectl delete -f k8s/ingress.yaml --ignore-not-found
	kubectl delete -f k8s/service.yaml --ignore-not-found
	kubectl -n $(NAMESPACE) delete deployment sample-api --ignore-not-found

.PHONY: url
url: ## ALB の DNS 名を表示
	@kubectl -n $(NAMESPACE) get ingress sample-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo

.PHONY: smoke
smoke: ## ALB 経由で疎通確認
	@host=$$(kubectl -n $(NAMESPACE) get ingress sample-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); \
	echo "GET http://$$host/" && curl -fsS "http://$$host/" && echo
