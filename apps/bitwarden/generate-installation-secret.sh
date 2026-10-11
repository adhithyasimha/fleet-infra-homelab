#!/usr/bin/env bash
set -euo pipefail

for command_name in kubectl kubeseal; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
done

if [[ -z "${KUBE_CONTEXT:-}" ]]; then
  echo "Set KUBE_CONTEXT to the target cluster before sealing Bitwarden credentials" >&2
  exit 1
fi

repo_root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
sealed_secret="$repo_root/apps/bitwarden/bitwarden-installation-sealed.yaml"
kustomization="$repo_root/apps/bitwarden/kustomization.yaml"

if [[ -e "$sealed_secret" ]]; then
  echo "$sealed_secret already exists; move it aside before generating new credentials" >&2
  exit 1
fi

printf 'Bitwarden installation ID: '
IFS= read -r installation_id
printf 'Bitwarden installation key (input hidden): '
IFS= read -r -s installation_key
printf '\n'

if [[ ! "$installation_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "Installation ID must be a UUID from https://bitwarden.com/host/" >&2
  exit 1
fi
if [[ -z "$installation_key" ]]; then
  echo "Installation key must not be empty" >&2
  exit 1
fi

umask 077
secret_data_dir=$(mktemp -d)
sealing_cert=$(mktemp)
secret_manifest=$(mktemp)
sealed_manifest=$(mktemp "$repo_root/apps/bitwarden/.bitwarden-installation-sealed.XXXXXX")
cleanup() {
  rm -f \
    "$secret_data_dir/installation-id" \
    "$secret_data_dir/installation-key" \
    "$sealing_cert" "$secret_manifest" "$sealed_manifest"
  rmdir "$secret_data_dir"
}
trap cleanup EXIT HUP INT TERM

printf '%s' "$installation_id" >"$secret_data_dir/installation-id"
printf '%s' "$installation_key" >"$secret_data_dir/installation-key"
unset installation_id installation_key

kubectl --context "$KUBE_CONTEXT" cluster-info >/dev/null
kubeseal \
  --context "$KUBE_CONTEXT" \
  --controller-namespace kube-system \
  --controller-name sealed-secrets \
  --fetch-cert >"$sealing_cert"

kubectl --context "$KUBE_CONTEXT" create secret generic bitwarden-installation \
  --namespace apps \
  --from-file="$secret_data_dir" \
  --dry-run=client -o yaml >"$secret_manifest"

kubeseal --cert "$sealing_cert" --format yaml <"$secret_manifest" >"$sealed_manifest"
mv "$sealed_manifest" "$sealed_secret"
echo "Sealed Bitwarden installation credentials created at apps/bitwarden/bitwarden-installation-sealed.yaml"

if ! grep -q '^[[:space:]]*-[[:space:]]*bitwarden-installation-sealed.yaml[[:space:]]*$' "$kustomization"; then
  echo "Add bitwarden-installation-sealed.yaml to apps/bitwarden/kustomization.yaml before reconciling."
fi
