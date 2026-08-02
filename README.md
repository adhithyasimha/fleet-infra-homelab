# Fleet Infra 

Complete GitOps setup with Traefik Ingress, n8n automation, PostgreSQL, cert-manager TLS, and Sealed Secrets.

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
  │   ├── authentik/
  │   │   ├── authentik-helm-repository.yaml
  │   │   ├── authentik-db.yaml (CNPG cluster)
  │   │   ├── authentik-helm-release.yaml
  │   │   └── authentik-config-sealed.example.yaml
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

### Authentik (infrastructure/authentik)
- Identity provider (SSO + LDAP directory) for all services
- Postgres via CloudNativePG (authentik-db), Redis reused from databases namespace
- Managed LDAP/Proxy outposts deployed into the cluster automatically (Kubernetes integration)
- Admin UI at auth.example.com (change host in `authentik-helm-release.yaml`)

## Authentik / LDAP setup (first run)

### 1. Before deploying: seal the bootstrap admin secret
The chart requires a sealed secret `authentik-config` in the `authentik` namespace
(secret key + bootstrap admin credentials). Without it, Authentik won't start.

```bash
kubectl create secret generic authentik-config \
  --from-literal=AUTHENTIK_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=AUTHENTIK_BOOTSTRAP_ADMIN_EMAIL="admin@example.com" \
  --from-literal=AUTHENTIK_BOOTSTRAP_ADMIN_PASSWORD="YourSecurePasswordHere" \
  -n authentik --dry-run=client -o yaml > /tmp/authentik-config.yaml

kubeseal -f /tmp/authentik-config.yaml \
  -w infrastructure/authentik/authentik-config-sealed.yaml

# Uncomment in infrastructure/authentik/kustomization.yaml:
# - authentik-config-sealed.yaml
```

Push to git; Flux deploys Authentik. Log in at `https://auth.example.com` with
`akadmin` / your password.

### 2. Enable the LDAP server (one-time, in the Admin UI)
1. **Providers**: Applications → Providers → Create → **LDAP Provider**
   - Base DN: `DC=ldap,DC=wolfslair,DC=cloud`
2. **Application**: Applications → Applications → Create → name it `LDAP`, select the LDAP provider
3. **Outpost**: Applications → Outposts → Create
   - Name: `ldap`, Type: **LDAP**, Integration: **Kubernetes**, select the LDAP application
   - Authentik auto-deploys the LDAP outpost into the cluster (`ghcr.io/goauthentik/ldap`)
4. **Service accounts** for each service: Directory → Users → Create (e.g. `svc-nextcloud`)
   - These are the "bind users" services authenticate against the directory with

### 3. Point services at the LDAP server
All services (in-cluster) connect to the outpost service:

```
ldap://ak-outpost-ldap.authentik.svc.cluster.local:389
ldaps://ak-outpost-ldap.authentik.svc.cluster.local:636   (if enabled)

Base DN:  DC=ldap,DC=wolfslair,DC=cloud
Bind DN:  cn=svc-<service>,ou=users,DC=ldap,DC=wolfslair,DC=cloud
```

> Most apps (Nextcloud, n8n, Immich...) also support **OIDC** — use the
> OIDC provider in Authentik instead of LDAP where possible. LDAP stays
> available for anything that only speaks LDAP.

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
