.PHONY: new-app
new-app:
	@read -p "App name: " app; \
	mkdir -p apps/$$app; \
	echo "name: $$app\nnamespace: apps\nhost: $$app.example.com\nservice: $$app\nport: 8080\npath: /\ntls: true\ningressClassName: traefik" > apps/$$app/metadata.yaml; \
	go run apps/scripts/generate_ingress.go -metadata apps/$$app/metadata.yaml -output apps/$$app/ingress.yaml; \
	echo "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - ingress.yaml" > apps/$$app/kustomization.yaml; \
	echo "✓ Created apps/$$app with ingress"

.PHONY: validate
validate:
	kustomize build clusters/wolfslair/ > /tmp/manifests.yaml && echo "✓ Kustomize validation passed"

.PHONY: flux-status
flux-status:
	flux get helmrelease --all-namespaces

.PHONY: watch-pods
watch-pods:
	kubectl get pods -A --watch

.PHONY: get-ingress
get-ingress:
	kubectl get ingress -A

.PHONY: get-certs
get-certs:
	kubectl get certificate -A
	@echo "\n=== Certificate Status ==="
	kubectl describe certificate -A

.PHONY: logs-n8n
logs-n8n:
	kubectl logs -n apps -l app.kubernetes.io/name=n8n -f

.PHONY: port-forward-n8n
port-forward-n8n:
	kubectl port-forward -n apps svc/n8n 5678:5678

.PHONY: seal-secret
seal-secret:
	@read -p "Secret name: " name; \
	read -sp "Secret password: " pass; \
	echo; \
	kubectl create secret generic $$name --from-literal=password=$$pass -n apps --dry-run=client -o yaml | kubeseal -f - -w apps/n8n/$$name-sealed.yaml; \
	echo "✓ Sealed secret created at apps/n8n/$$name-sealed.yaml"; \
	echo "Remember to uncomment in kustomization.yaml"

.PHONY: export-sealing-key
export-sealing-key:
	kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealing-key.yaml
	@echo "✓ Sealing key exported to sealing-key.yaml"
	@echo "WARNING: Keep this file secure and DO NOT commit to git"
