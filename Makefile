# ---------------------------------------------------------------------------
# SecureDocs session control.
#
# The cluster costs roughly $0.25/hour and is destroyed after every session, so
# the build-up and tear-down happen more often than anything else in the repo.
# Every step in here was a command that had to be remembered, and one of them
# was forgotten yesterday and left a $16/month orphan behind.
#
#   make up       build L1, refresh kubeconfig, print the hostname
#   make down     destroy L1, sweep orphans, verify $0
#   make status   what is currently costing money
# ---------------------------------------------------------------------------

REGION  ?= ap-southeast-2
ENV     ?= dev
CLUSTER  = securedocs-$(ENV)
L1       = infra/l1
L0       = infra/l0
TFVARS   = envs/$(ENV).tfvars

.PHONY: help up down status kubeconfig host sweep l0

help: ## Show this help
	@grep -hE '^[a-z0-9-]+:.*##' $(MAKEFILE_LIST) \
	  | sed -e 's/:.*##/|/' \
	  | awk -F'|' '{ printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }'

# ── build ───────────────────────────────────────────────────────────────────

up: ## Build the cluster, refresh kubeconfig, print the hostname
	cd $(L1) && terraform workspace select $(ENV) \
	  && terraform init -input=false \
	  && terraform apply -var-file=$(TFVARS)
	@$(MAKE) --no-print-directory kubeconfig
	@$(MAKE) --no-print-directory host

l0: ## Apply the permanent layer (VPC, ECR, S3, secret container)
	cd $(L0) && terraform workspace select $(ENV) \
	  && terraform apply -var-file=$(TFVARS)

kubeconfig: ## Point kubectl at the current cluster
	@# The EKS endpoint is regenerated on every rebuild. Terraform reads it
	@# live so it never notices; kubectl and helm read this file and fail with
	@# "no such host" until it is refreshed.
	aws eks update-kubeconfig --name $(CLUSTER) --region $(REGION)

host: ## Resolve the NLB and write the sslip.io hostname into values-eks.yaml
	@# AWS publishes the DNS record a minute or two AFTER the load balancer
	@# reports ready, so a single lookup right after `apply` reliably fails.
	@# Retry for three minutes rather than making the human do it.
	@nlb=$$(cd $(L1) && terraform output -raw nlb_hostname); \
	for i in $$(seq 1 18); do \
	  ip=$$(dig +short $$nlb | head -1); \
	  [ -n "$$ip" ] && break; \
	  echo "waiting for $$nlb to resolve ($$i/18)"; \
	  sleep 10; \
	done; \
	if [ -z "$$ip" ]; then echo "NLB still not resolvable after 3 minutes"; exit 1; fi; \
	sed -i "s|^  host: .*|  host: $$ip.sslip.io|" charts/securedocs/values-eks.yaml; \
	echo "host: $$ip.sslip.io"; \
	echo "commit and push - ArgoCD only reads git:"; \
	echo "  git commit -am 'New NLB address' && git push origin argocd"

# ── teardown ────────────────────────────────────────────────────────────────

down: ## Destroy the cluster, sweep orphans, verify nothing is billing
	cd $(L1) && terraform destroy -var-file=$(TFVARS)
	@$(MAKE) --no-print-directory sweep
	@$(MAKE) --no-print-directory status

sweep: ## Delete load balancers and target groups Terraform does not own
	@# The NLB is created by the AWS Load Balancer Controller, not Terraform,
	@# so it is in nobody's state file. If Helm's uninstall times out it
	@# survives the destroy and bills ~$$16/month forever. This happened.
	@for lb in $$(aws elbv2 describe-load-balancers --region $(REGION) \
	    --query 'LoadBalancers[?starts_with(LoadBalancerName, `k8s-`)].LoadBalancerArn' \
	    --output text); do \
	  echo "orphaned load balancer: $$lb"; \
	  aws elbv2 delete-load-balancer --region $(REGION) --load-balancer-arn $$lb; \
	done
	@for tg in $$(aws elbv2 describe-target-groups --region $(REGION) \
	    --query 'TargetGroups[?starts_with(TargetGroupName, `k8s-`)].TargetGroupArn' \
	    --output text); do \
	  echo "orphaned target group: $$tg"; \
	  aws elbv2 delete-target-group --region $(REGION) --target-group-arn $$tg || true; \
	done

status: ## List everything currently costing money
	@echo "clusters:"       && aws eks list-clusters --region $(REGION) --query 'clusters' --output text
	@echo "nat gateways:"   && aws ec2 describe-nat-gateways --region $(REGION) \
	  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
	@echo "load balancers:" && aws elbv2 describe-load-balancers --region $(REGION) \
	  --query 'LoadBalancers[].LoadBalancerName' --output text
	@echo "instances:"      && aws ec2 describe-instances --region $(REGION) \
	  --filters Name=instance-state-name,Values=running \
	  --query 'Reservations[].Instances[].InstanceId' --output text
	@echo "(all blank = \$$0/hour)"
