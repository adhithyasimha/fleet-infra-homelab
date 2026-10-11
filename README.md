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
- Admin UI at `https://lldap.ember-willow-maple-lumen.invalid`
- LDAP is not exposed outside the cluster; only the HTTPS admin UI is routed through Traefik

### FreshRSS (apps/freshrss)
- Private RSS reader at `https://rss.ember-willow-maple-lumen.invalid`
- Persistent SQLite data and extensions volumes
- Feeds refresh twice per hour
- NetworkPolicy permits requests only from the in-cluster Cloudflare Tunnel
- Cloudflare Access must protect the hostname before the first use; see the
  setup section below

### Bitwarden Lite (apps/bitwarden)
- Official Bitwarden single-container deployment at `https://vault.ember-willow-maple-lumen.invalid`
- Persistent SQLite vault data
- Cloudflare Access is required before the public hostname is enabled
- Uses SQLite for vault storage; Bitwarden still requires its official installation
  ID and key to start its backend services

### Ente Photos (apps/ente)
- Self-hosted Ente Photos UI and Museum API served together at
  `https://photos.ember-willow-maple-lumen.invalid`
- PostgreSQL and MinIO-backed storage with persistent volumes
- The object-storage endpoint is `https://ente-storage.ember-willow-maple-lumen.invalid`
- Ente is enabled in Flux with cluster-sealed credentials in
  `apps/ente/ente-credentials-sealed.yaml`

### Pi-hole (apps/pihole)
- One Pi-hole instance serves DNS to LAN devices configured to use its
  `LoadBalancer` IP on TCP/UDP port 53
- This does not change Kubernetes CoreDNS or the node's operating-system DNS
- Admin UI is routed through Cloudflare Tunnel at `https://pihole.ember-willow-maple-lumen.invalid`
- Configure Cloudflare Access for the admin hostname and restrict the DNS
  load-balancer address to trusted LAN clients at the network firewall; the
  service also limits source addresses to `192.168.1.0/24` (update this if the
  LAN subnet changes)

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
Flux will deploy LLDAP. Log in at `https://lldap.ember-willow-maple-lumen.invalid` with `admin` and
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

## FreshRSS setup (first run)

1. In Cloudflare Zero Trust, create a **Self-hosted** Access application for
   `rss.ember-willow-maple-lumen.invalid`. Add an **Allow** policy limited to your identity and
   enable MFA where available. Do this before visiting the hostname.
2. Visit `https://rss.ember-willow-maple-lumen.invalid` and complete the FreshRSS setup wizard
   using the built-in SQLite database.
3. In the authentication step, select **Form Authentication**. After setup, in
   **Administration → Authentication**, leave anonymous reading disabled. In
   **Administration → System configuration**, set the maximum number of user
   accounts to `1` to disable new-user registration.
4. Add feeds directly in FreshRSS, or import an OPML file. YouTube channels use
   `https://www.youtube.com/feeds/videos.xml?channel_id=<CHANNEL_ID>`; news,
   blogs, podcasts, newsletters, Reddit, GitHub releases, and most publications
   can be added from their normal RSS or Atom feed URLs.

The Cloudflare Access policy is intentionally not stored in this repository:
it is account-level configuration managed by Cloudflare Zero Trust. The tunnel
route in `apps/cloudflared/configmap.yaml` only connects the protected hostname
to the private in-cluster service.

## Bitwarden setup (first run)

1. Create a Cloudflare Zero Trust **Self-hosted** Access application for
   `vault.ember-willow-maple-lumen.invalid`, limited to your identity. Do this before enabling the
   public tunnel route.
2. Get the installation ID and key from <https://bitwarden.com/host/>. From the
   repository root, seal them for the target cluster without putting the key in
   shell history or committing plaintext:

   ```bash
   KUBE_CONTEXT=<target-cluster-context> bash apps/bitwarden/generate-installation-secret.sh
   ```

   The helper prompts for the installation ID and key, hides key input, and
   creates `apps/bitwarden/bitwarden-installation-sealed.yaml`. The Bitwarden
   Kustomization includes that manifest. Commit and push the generated sealed
   manifest; Bitwarden Lite requires these values even when using SQLite.
3. Visit `https://vault.ember-willow-maple-lumen.invalid` and register the initial owner
   account. Set `globalSettings__disableUserRegistration` to `"true"` in
   `apps/bitwarden/configmap.yaml` after registration.
4. Configure an encrypted, off-cluster backup for the `bitwarden-data` PVC
   before storing any irreplaceable credentials. Test a restore.

## Ente Photos setup (first run)

1. Ensure DNS routes `photos.ember-willow-maple-lumen.invalid` and
   `ente-storage.ember-willow-maple-lumen.invalid` to the existing Cloudflare Tunnel. Both
   hostnames must be present in Cloudflare DNS and in
   `apps/cloudflared/configmap.yaml`.
2. Wait for Flux to deploy Ente and its storage:

   ```bash
   kubectl get pods,pvc -n apps
   ```

   Ente credentials are already sealed for the cluster and included in Flux.
   To generate a replacement for a different cluster, use
   `KUBE_CONTEXT=<target-cluster-context> sh apps/ente/generate-credentials.sh`;
   the script keeps plaintext in private temporary files and seals against that
   cluster's Sealed Secrets certificate.
3. Visit `https://photos.ember-willow-maple-lumen.invalid` to register the first account. Set up
   backups for both Ente PVCs and test restores before uploading originals.

## Pi-hole setup (first run)

1. Use one Pi-hole DNS endpoint for the LAN. Wait for the `pihole-dns`
   LoadBalancer service to receive a LAN-reachable IP
   (`kubectl get svc -n apps pihole-dns`), then configure that IP as the DNS
   server in the router's DHCP settings. Devices can then use Pi-hole when
   connected to the LAN. This does not redirect Kubernetes pod DNS or change
   the server's own resolver.
2. The service accepts DNS only from `192.168.1.0/24`; update
   `loadBalancerSourceRanges` in `apps/pihole/service.yaml` if your LAN subnet
   changes. Ensure the network firewall also blocks TCP/UDP port 53 from the
   public internet. Do not publish DNS through the Cloudflare Tunnel. A
   LoadBalancer controller must be installed and configured to allocate an
   address reachable by LAN clients.
3. Create a Cloudflare Zero Trust **Self-hosted** Access application for
   `pihole.ember-willow-maple-lumen.invalid` before using the admin UI. Pi-hole generates an
   initial random admin password; retrieve it from the first startup logs with
   `kubectl logs -n apps deploy/pihole`.

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
