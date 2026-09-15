#!/bin/bash
set -e

# Le script vit dans scripts/, le code Terraform dans ../terraform
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"
cd "$TERRAFORM_DIR"

MY_IP=$(curl -s -4 https://ifconfig.me)

if [ -z "$MY_IP" ]; then
  echo "Erreur : impossible de récupérer l'IP publique"
  exit 1
fi

echo "IP détectée : $MY_IP"
echo "allowed_ssh_cidr = \"${MY_IP}/32\"" > terraform.tfvars

terraform apply -auto-approve
