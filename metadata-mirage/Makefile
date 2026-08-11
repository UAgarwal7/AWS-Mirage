# Metadata Mirage - intentionally vulnerable AWS SSRF -> IAM privesc lab.
# Deploy ONLY in an isolated, throwaway AWS account. See NOTICE.md.

TF := terraform -chdir=terraform

.PHONY: deploy plan attack harden destroy clean help

help:              ## Show this help
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*## /\t/'

deploy:            ## Stand up the vulnerable lab (IMDSv1 allowed)
	$(TF) init -input=false
	$(TF) apply -auto-approve

plan:              ## Preview changes without applying
	$(TF) plan

attack:            ## Run the full SSRF -> privesc-to-admin chain against the running lab
	@bash attack/attack.sh \
		"$$($(TF) output -raw instance_public_ip)" \
		"$$($(TF) output -raw app_port)" \
		"$$($(TF) output -raw role_name)" \
		"$$($(TF) output -raw app_policy_arn)"

harden:            ## Flip to IMDSv2-required (in place); re-run attack to watch it get blocked
	$(TF) apply -auto-approve -var enforce_imdsv2=true

destroy:           ## Tear down everything Terraform created
	$(TF) destroy -auto-approve

clean:             ## Remove local terraform state/cache (run AFTER destroy)
	rm -rf terraform/.terraform terraform/terraform.tfstate*
