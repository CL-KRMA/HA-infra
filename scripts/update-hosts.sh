#!/bin/bash
# ============================================================
# update-hosts.sh
#
# Recupere les IP publiques des masters depuis `terraform output`
# et les injecte dans hosts a la place des placeholders
# <MASTER1_PUBLIC_IP>, <MASTER2_PUBLIC_IP>, <MASTER3_PUBLIC_IP>.
#
# Prerequis :
#   - avoir fait `terraform apply` au prealable
#   - jq installe (apt install jq / brew install jq)
#
# Usage (depuis n'importe quel dossier, le script se repere lui-meme) :
#   ./scripts/update-hosts.sh                          -> terraform_dir=../terraform hosts_file=../ansible/hosts (par defaut)
#   ./scripts/update-hosts.sh chemin/hosts              -> hosts_file explicite, terraform_dir par defaut
#   ./scripts/update-hosts.sh chemin/terraform chemin/hosts -> les deux explicites
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
DEFAULT_HOSTS_FILE="$SCRIPT_DIR/../ansible/hosts"

if [ $# -eq 1 ]; then
  # Un seul argument fourni : on suppose que c'est le fichier hosts
  TERRAFORM_DIR="$DEFAULT_TERRAFORM_DIR"
  HOSTS_FILE="$1"
else
  TERRAFORM_DIR="${1:-$DEFAULT_TERRAFORM_DIR}"
  HOSTS_FILE="${2:-$DEFAULT_HOSTS_FILE}"
fi

if ! command -v jq &> /dev/null; then
  echo "Erreur : jq n'est pas installe. Installe-le avec 'apt install jq' ou 'brew install jq'." >&2
  exit 1
fi

if [ ! -f "$HOSTS_FILE" ]; then
  echo "Erreur : fichier inventaire introuvable : $HOSTS_FILE" >&2
  exit 1
fi

echo "Lecture des outputs Terraform dans : $TERRAFORM_DIR"
MASTERS_JSON=$(terraform -chdir="$TERRAFORM_DIR" output -json masters)

# Recupere les IP publiques triees par cle (master-1, master-2, master-3)
MASTER1_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-1"].public_ip')
MASTER2_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-2"].public_ip')
MASTER3_IP=$(echo "$MASTERS_JSON" | jq -r '.["master-3"].public_ip')

for name in MASTER1_IP MASTER2_IP MASTER3_IP; do
  val="${!name}"
  if [ -z "$val" ] || [ "$val" == "null" ]; then
    echo "Erreur : impossible de recuperer $name depuis 'terraform output masters'." >&2
    echo "Verifie que 'terraform apply' a bien ete execute et que l'output 'masters' existe." >&2
    exit 1
  fi
done

echo "master1 -> $MASTER1_IP"
echo "master2 -> $MASTER2_IP"
echo "master3 -> $MASTER3_IP"

# Sauvegarde avant modification
cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
echo "Sauvegarde creee : ${HOSTS_FILE}.bak"

# Remplacement des placeholders (toutes les occurrences, y compris
# celle du ProxyJump dans [worker:vars])
sed -i.tmp \
  -e "s/<MASTER1_PUBLIC_IP>/${MASTER1_IP}/g" \
  -e "s/<MASTER2_PUBLIC_IP>/${MASTER2_IP}/g" \
  -e "s/<MASTER3_PUBLIC_IP>/${MASTER3_IP}/g" \
  "$HOSTS_FILE"
rm -f "${HOSTS_FILE}.tmp"

echo "Inventaire mis a jour : $HOSTS_FILE"
