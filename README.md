# Fleet Infra 

Complete GitOps setup with Traefik Ingress, n8n automation, PostgreSQL, cert-manager TLS, Sealed Secrets, and lightweight LDAP.

## Architecture

```
clusters/wolfslair/
  ├── kustomization.yaml (root orchestrator)
  ├── flux-system/
  ├── base/namespaces/
  ├── infrastructure/
  │   ├── traefik/
  │   ├── cert-manager/
  │   │   ├── jetstack-helm-repository.yaml
  │   │   ├── cert-manager-helm-release.yaml
  │   │   └── letsencrypt-issuers.yaml (prod + staging)
  │   ├── sealedsecrets/
  │   │   ├── sealedsecrets-helm-repository.yaml
  │   │   └── sealed-secrets-helm-release.yaml
   │   ├── lldap/
   │   │   ├── deployment.yaml
   │   │   ├── service.yaml
   │   │   ├── pvc.yaml
   │   │   └── ingress.yaml
  │   ├── postgres-helm-release.yaml
  │   └── helm-repositories.yaml
  └── apps/
      └── n8n/
          ├── helm-release.yaml (cert-manager annotations enabled)
          ├── postgres-credentials-sealed.yaml (sealed secret)
          └── kustomization.yaml
```

## Deploy

### Prerequisites
- Kubernetes cluster (1.23+)
- Flux CLI installed
- kubeseal CLI (for managing sealed secrets)

### 1. Bootstrap Flux
```bash
flux bootstrap github \
  --owner=<your-username> \
  --repo=fleet-infra \
  --path=clusters/wolfslair \
  --personal
```

### 2. Verify infrastructure deployment
```bash
kubectl get pods -n traefik
kubectl get pods -n cert-manager
kubectl get pods -n kube-system | grep sealed
```

### 3. Create sealed PostgreSQL credentials
```bash
# Generate sealing key from your cluster
kubectl get secret -n kube-system sealed-secrets-key -o yaml > sealing-key.yaml

# Create a regular secret locally
kubectl create secret generic postgres-credentials \
  --from-literal=password=your-secure-password \
  -n apps \
  --dry-run=client \
  -o yaml > postgres-credentials.yaml

# Seal it (offline, safe to commit)
kubeseal -f postgres-credentials.yaml -w apps/n8n/postgres-credentials-sealed.yaml

# Uncomment in apps/n8n/kustomization.yaml:
# - postgres-credentials-sealed.yaml

# Push to git; Flux will deploy it
git add apps/n8n/postgres-credentials-sealed.yaml
git commit -m "Add sealed postgres credentials"
git push
```

### 4. Watch reconciliation
```bash
flux get helmrelease --all-namespaces --watch
```

## Components

### Traefik (infrastructure/traefik)
- Ingress controller with Traefik annotations
- LoadBalancer service on ports 80/443
- Integration with cert-manager for automatic TLS

### cert-manager (infrastructure/cert-manager)
- Automated TLS certificate generation via Let's Encrypt
- ClusterIssuers for production and staging
- HTTP-01 validation through Traefik ingress

### Sealed Secrets (infrastructure/sealedsecrets)
- Encrypts secrets before committing to git
- Only unseals secrets in-cluster
- Safe to store credentials in version control

### n8n (apps/n8n)
- Helm-based deployment with queue webhooks
- PostgreSQL backend via sealed secret
- Automatic TLS via cert-manager
- Traefik ingress routing

### PostgreSQL (infrastructure/postgres)
- Bitnami chart in databases namespace
- 10Gi storage (edit for production)
- Credentials passed as sealed secret

### LLDAP (infrastructure/lldap)
- Lightweight LDAP server with SQLite-backed persistent storage
- Internal LDAP service at `lldap.lldap.svc.cluster.local:3890`
- Admin UI at `https://lldap.example.com`
- LDAP is not exposed outside the cluster; only the HTTPS admin UI is routed through Traefik

## LLDAP setup (first run)

### 1. Seal the bootstrap secret
LLDAP requires an admin password plus stable signing/key-seed secrets. Create them locally:

```bash
kubectl create secret generic lldap-config \
   --from-literal=ldap-user-pass='YourSecurePasswordHere' \
   --from-literal=jwt-secret="$(openssl rand -hex 32)" \
   --from-literal=key-seed="$(openssl rand -hex 32)" \
   -n lldap --dry-run=client -o yaml > /tmp/lldap-config.yaml

kubeseal -f /tmp/lldap-config.yaml \
   -w infrastructure/lldap/lldap-config-sealed.yaml
```

Add the generated file to `infrastructure/lldap/kustomization.yaml`, then push it.
Flux will deploy LLDAP. Log in at `https://lldap.example.com` with `admin` and
the password you chose.

### 2. Point services at LLDAP
Services in the cluster connect directly to:

```
ldap://lldap.lldap.svc.cluster.local:3890

Base DN:  dc=wolfslair,dc=cloud
Users:    ou=people,dc=wolfslair,dc=cloud
Groups:   ou=groups,dc=wolfslair,dc=cloud
```

Create a separate read-only bind user for each service instead of sharing the
LLDAP administrator account. Nextcloud and Rancher can then be configured to
use this LDAP endpoint in their respective administration interfaces.

## Configuration

### Update email for Let's Encrypt
Edit `infrastructure/cert-manager/letsencrypt-issuers.yaml`:
```yaml
email: your-email@example.com
```

### Update domain
Change `n8n.example.com` in:
- `apps/n8n/helm-release.yaml`
- DNS records (CNAME/A record to Traefik LoadBalancer IP)

### Add more apps
Use the Makefile helper:
```bash
make new-app
```

## Sealed Secrets Workflow

1. **Generate credentials locally** (without pushing):
   ```bash
   kubectl create secret generic my-secret --from-literal=password=xxx --dry-run=client -o yaml
   ```

2. **Seal them**:
   ```bash
   kubeseal -f my-secret.yaml -w my-secret-sealed.yaml
   ```

3. **Commit sealed secret** (safe):
   ```bash
   git add my-secret-sealed.yaml
   git commit -m "Add sealed secret"
   ```

4. **Flux automatically deploys** and unseals in-cluster

## Verify TLS

```bash
# Check cert-manager issued certificates
kubectl get certificate -n apps

# Check ingress TLS status
kubectl get ingress -n apps -o wide

# Test HTTPS
curl -v https://n8n.example.com
```

## Next steps

1. Set up backup strategy (Velero or similar)
2. Add monitoring (Prometheus + Grafana)
3. Configure external PostgreSQL for production
4. Rotate sealed-secrets encryption key regularly
5. Set up backup of sealed-secrets key
