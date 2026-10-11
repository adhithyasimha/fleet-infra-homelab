#!/bin/sh
set -eu

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required" >&2
  exit 1
}
command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required" >&2
  exit 1
}
command -v kubeseal >/dev/null 2>&1 || {
  echo "kubeseal is required" >&2
  exit 1
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sealed_secret="$repo_root/apps/ente/ente-credentials-sealed.yaml"
if [ -e "$sealed_secret" ]; then
  echo "$sealed_secret already exists; move it aside before generating new credentials" >&2
  exit 1
fi

umask 077
museum_config=$(mktemp)
secret_env=$(mktemp)
secret_manifest=$(mktemp)
sealed_manifest=$(mktemp "$repo_root/apps/ente/.ente-credentials-sealed.XXXXXX")
cleanup() {
  rm -f "$museum_config" "$secret_env" "$secret_manifest" "$sealed_manifest"
}
trap cleanup EXIT HUP INT TERM

postgres_password=$(openssl rand -hex 32)
minio_root_user="ente-$(openssl rand -hex 12)"
minio_root_password=$(openssl rand -hex 32)
encryption_key=$(openssl rand -base64 32 | tr -d '\n')
hash_key=$(openssl rand -base64 64 | tr -d '\n')
jwt_secret=$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')

cat >"$secret_env" <<EOF
POSTGRES_PASSWORD=$postgres_password
MINIO_ROOT_USER=$minio_root_user
MINIO_ROOT_PASSWORD=$minio_root_password
EOF

cat >"$museum_config" <<EOF
db:
  host: ente-postgres.apps.svc.cluster.local
  port: 5432
  name: ente_db
  user: pguser
  password: "$postgres_password"

s3:
  are_local_buckets: false
  use_path_style_urls: true
  b2-eu-cen:
    key: "$minio_root_user"
    secret: "$minio_root_password"
    endpoint: ente-storage.example.invalid
    region: eu-central-2
    bucket: b2-eu-cen
  wasabi-eu-central-2-v3:
    key: "$minio_root_user"
    secret: "$minio_root_password"
    endpoint: ente-storage.example.invalid
    region: eu-central-2
    bucket: wasabi-eu-central-2-v3
    compliance: false
  scw-eu-fr-v3:
    key: "$minio_root_user"
    secret: "$minio_root_password"
    endpoint: ente-storage.example.invalid
    region: eu-central-2
    bucket: scw-eu-fr-v3

key:
  encryption: "$encryption_key"
  hash: "$hash_key"

jwt:
  secret: "$jwt_secret"
EOF

kubectl create secret generic ente-credentials \
  --namespace apps \
  --from-env-file="$secret_env" \
  --from-file=museum.yaml="$museum_config" \
  --dry-run=client -o yaml >"$secret_manifest"

kubeseal --format yaml <"$secret_manifest" >"$sealed_manifest"
mv "$sealed_manifest" "$sealed_secret"
echo "Sealed Ente credentials created at apps/ente/ente-credentials-sealed.yaml"
