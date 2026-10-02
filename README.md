# HA-infra — Cluster K3s HA sur AWS (Terraform + Ansible)

Déploiement automatisé d'un cluster Kubernetes (K3s) haute disponibilité
sur AWS : 3 masters (etcd embarqué) + 3 workers, avec ArgoCD (GitOps) et
un stack de monitoring (Prometheus + Grafana).

## Architecture

- **VPC** unique, **3 AZ** (multi-AZ réel), 6 subnets :
  - 3 subnets **publics** (un par AZ, masters) : chaque master a une
    Elastic IP (accès SSH/API depuis l'extérieur).
  - 3 subnets **privés** (un par AZ, workers) : sortie Internet via un
    **NAT Gateway dédié par AZ** (pas d'IP publique, pas de NAT
    Gateway partagé entre AZ).
  - Masters et workers sont répartis en round-robin sur les 3 AZ : un
    master + un worker par AZ (voir `terraform output masters` /
    `terraform output workers` pour le détail IP/AZ de chaque noeud).
- **master1** sert de bastion SSH (ProxyJump) pour atteindre les
  workers, quelle que soit leur AZ (routage interne au VPC, natif
  entre subnets d'un même VPC).
- **K3s HA** : etcd embarqué, quorum sur les 3 masters (répartis sur 3
  AZ) — la perte d'une AZ laisse 2 masters actifs, majoritaires pour
  le quorum etcd, et 2 workers.
- **cert-manager** + **Let's Encrypt** (challenge HTTP-01 via Traefik) :
  génère et renouvelle automatiquement les certificats TLS.
- **ArgoCD** exposé via Ingress Traefik HTTPS sur `argocd.domain.com`.
- **Grafana** exposé via Ingress Traefik HTTPS sur `monitoring.domain.com`.

> Le nombre d'AZ utilisées est piloté par `az_count` (défaut : 3,
> aligné sur `master_count`/`worker_count`). Résilience actuelle :
> perte d'une AZ = cluster toujours opérationnel (quorum etcd
> préservé). Limite restante : une panne région AWS entière (rare)
> reste hors de portée d'une infra mono-région — au-delà, il
> faudrait de la réplication inter-région, hors scope de ce projet.

## Structure du projet

```
ha-infra/
├── terraform/
│   ├── main.tf              # Infra AWS (VPC, subnets, EC2, SG, EIP)
│   ├── .terraform.lock.hcl  # Versions exactes des providers (versionné)
│   └── keys/                # Clé SSH (gitignored, à créer soi-même)
│       ├── ma-cle-ssh
│       └── ma-cle-ssh.pub
├── ansible/
│   ├── ansible.cfg
│   ├── hosts                # Inventaire (IPs injectées par scripts/update-hosts.sh)
│   ├── site.yml             # Orchestrateur (à lancer en 4e étape)
│   ├── group_vars/
│   │   └── master/
│   │       └── vault.yml.example  # Template du secret Grafana (à copier + chiffrer)
│   └── playbooks/
│       ├── install-terraform.yml   # Optionnel : installe Terraform (localhost)
│       ├── install-k3s.yml
│       ├── install-cert-manager.yml # cert-manager + ClusterIssuer Let's Encrypt
│       ├── install-argocd.yml
│       ├── install-monitoring.yml
│       └── guestbook.yml           # App de démo ArgoCD
├── scripts/
│   ├── update-ip.sh
│   ├── update-hosts.sh
│   └── set-domain.sh        # Remplace domain.com par ton propre domaine
├── .gitignore
├── .gitattributes
└── README.md
```

## Prérequis

- Un compte AWS avec les credentials configurés (`~/.aws/credentials` ou
  variables d'environnement).
- Terraform installé sur la machine de contrôle (ou lancer l'étape 0
  ci-dessous pour l'installer).
- `jq` installé (utilisé par `scripts/update-hosts.sh`).
- Une paire de clés SSH nommée `ma-cle-ssh` / `ma-cle-ssh.pub` placée
  dans `terraform/keys/` (non versionnée, voir `.gitignore`).
- Ansible installé sur la machine de contrôle.
- **Domaine** : ce projet utilise `argocd.domain.com` et
  `monitoring.domain.com` comme exemples. Remplace `domain.com` par
  ton propre domaine partout où il apparaît avec :
  `./scripts/set-domain.sh mondomaine.fr` (voir étape 1bis ci-dessous).
- **Pour le TLS Let's Encrypt** : les DNS de `argocd.domain.com` et
  `monitoring.domain.com` (une fois remplacés par ton domaine) doivent
  déjà pointer vers l'IP publique de `master1` (EIP donnée par
  `terraform output master1_public_ip`) **avant** de lancer l'étape
  cert-manager — le challenge HTTP-01 est validé par Let's Encrypt
  depuis l'extérieur, sur le port 80.
- **Mot de passe Grafana (ansible-vault)** : `ansible-vault` installé
  (fourni avec Ansible). Voir étape 3ter ci-dessous — le playbook
  monitoring refuse de s'exécuter tant que le mot de passe n'est pas
  configuré.

## Déploiement — étapes

```bash
# 0. (optionnel) Installer Terraform sur cette machine
cd ansible
ansible-playbook playbooks/install-terraform.yml
cd ..

# 1. Sécuriser la clé SSH
chmod 600 terraform/keys/ma-cle-ssh

# 1bis. Rendre les scripts exécutables (une seule fois), puis remplacer
#       le domaine d'exemple (domain.com) par le tien
chmod +x scripts/update-ip.sh scripts/update-hosts.sh scripts/set-domain.sh
./scripts/set-domain.sh mondomaine.fr

# 2. Détecter son IP publique et appliquer le Terraform
#    (lance `terraform init`, génère terraform/terraform.tfvars
#    puis lance `terraform apply` : le plan est affiché et il faut
#    taper "yes" pour confirmer ; ajouter -y pour ignorer la confirmation)
./scripts/update-ip.sh

# 3. Injecter les IP publiques des masters dans l'inventaire ansible/hosts
./scripts/update-hosts.sh

# 3bis. Pointer les DNS argocd.domain.com et monitoring.domain.com vers
#       l'IP publique de master1 (terraform output master1_public_ip),
#       et attendre la propagation avant l'étape 4.

# 3ter. Configurer le mot de passe Grafana (ansible-vault, une fois)
cp ansible/group_vars/master/vault.yml.example ansible/group_vars/master/vault.yml
nano ansible/group_vars/master/vault.yml
# -> remplacer la ligne grafana_admin_password par un vrai mot de
#    passe AVANT de chiffrer (sinon le playbook refusera de
#    continuer avec la valeur placeholder). Sauvegarder (Ctrl+O,
#    Entree) puis quitter (Ctrl+X).
ansible-vault encrypt ansible/group_vars/master/vault.yml
# -> Ansible demande de creer un mot de passe de VAULT (a retenir,
#    different du mot de passe Grafana) : c'est celui qui sera
#    redemande a chaque --ask-vault-pass.

# 4. Déployer K3s + cert-manager/Let's Encrypt + ArgoCD + Monitoring + demo
cd ansible
ansible-playbook site.yml -e letsencrypt_email=TON_VRAI_EMAIL@TON_DOMAINE.com --ask-vault-pass
```

> ⚠️ `letsencrypt_email` doit être une **vraie adresse email que tu
> possèdes** (Gmail, etc.). Let's Encrypt rejette explicitement les
> domaines `example.com` / `example.org` / `example.net` — utiliser
> le placeholder tel quel fait échouer l'étape cert-manager avec
> l'erreur `forbidden domain "example.com"`.

Pour modifier le mot de passe Grafana **après** l'avoir déjà chiffré
(sans repartir de zéro) :

```bash
export EDITOR=nano
ansible-vault edit ansible/group_vars/master/vault.yml
```

`ansible-vault edit` déchiffre temporairement le fichier dans
l'éditeur choisi, puis le rechiffre automatiquement à la sauvegarde —
pas besoin de refaire `encrypt` à la main. Sans `export EDITOR=nano`,
Ansible ouvre **vim** par défaut : pour sauvegarder et quitter,
`Échap` puis `:wq` puis `Entrée` (ou `:q!` pour annuler sans
sauvegarder).

Pour ne rejouer qu'une étape (depuis le dossier `ansible/`) :

```bash
ansible-playbook site.yml --tags k3s
ansible-playbook site.yml --tags cert-manager -e letsencrypt_email=TON_VRAI_EMAIL@TON_DOMAINE.com
ansible-playbook site.yml --tags argocd
ansible-playbook site.yml --tags monitoring --ask-vault-pass
ansible-playbook site.yml --skip-tags guestbook --ask-vault-pass   # tout sauf la demo
```

> `--ask-vault-pass` n'est necessaire que pour les etapes qui touchent
> Grafana (le mot de passe est chiffre dans
> `ansible/group_vars/master/vault.yml`). Alternative sans saisie
> interactive : `--vault-password-file=<chemin>` avec un fichier
> contenant le mot de passe du vault (a ne JAMAIS committer, deja
> couvert par `.gitignore`).

> `letsencrypt_email` sert uniquement aux alertes d'expiration de
> Let's Encrypt. Si omis, la valeur par défaut du playbook
> (`changeme@domain.com`) est utilisée — à éviter en usage réel.
> Le playbook `install-cert-manager.yml` crée aussi un ClusterIssuer
> `letsencrypt-staging` (rate-limit large, certificats non fiables par
> les navigateurs) utile pour tester sans consommer le quota strict de
> `letsencrypt-prod` (le seul utilisé par défaut par les Ingress
> ArgoCD/Grafana).

> Les scripts `update-ip.sh` et `update-hosts.sh` se repèrent tout
> seuls grâce à leur propre emplacement (`scripts/`) : ils peuvent être
> lancés depuis n'importe quel dossier, tant que la structure
> `terraform/` / `ansible/` / `scripts/` reste inchangée.

### Piloter le cluster depuis ta machine (kubectl local)

Sur master1, `/home/ubuntu/.kube/config` pointe vers `127.0.0.1` —
c'est volontaire : ce fichier est utilisé par tous les playbooks qui
exécutent `kubectl`/`helm` **depuis master1 lui-même** (cert-manager,
ArgoCD, monitoring...). Le remplacer par l'IP publique casserait ces
appels : **AWS ne permet pas à une instance de se joindre elle-même
via sa propre IP publique/EIP** (pas de hairpin NAT).

Pour piloter le cluster depuis ta propre machine, un kubeconfig
**externe** séparé est généré automatiquement à l'étape K3s :

```bash
scp -i terraform/keys/ma-cle-ssh \
  ubuntu@<MASTER1_PUBLIC_IP>:/home/ubuntu/.kube/config-external \
  ./kubeconfig-master1

export KUBECONFIG=./kubeconfig-master1
kubectl get nodes
```

### Accéder à ArgoCD et Grafana

Une fois `ansible-playbook site.yml` terminé sans erreur, les deux
interfaces sont accessibles en HTTPS (certificat Let's Encrypt) :

- **ArgoCD** : `https://argocd.<tondomaine>/`
  - Utilisateur : `admin`
  - Mot de passe : généré automatiquement par ArgoCD à l'installation,
    à récupérer avec (depuis master1, ou via le kubeconfig externe) :
    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d && echo
    ```
    Ce mot de passe n'est affiché qu'une fois dans les logs Ansible
    pendant le déploiement (message `Afficher les informations
    d'acces ArgoCD`) — la commande ci-dessus permet de le
    re-récupérer à tout moment tant que le secret n'a pas été changé
    ou supprimé.

- **Grafana** : `https://monitoring.<tondomaine>/`
  - Utilisateur : `admin`
  - Mot de passe : celui que tu as défini dans
    `ansible/group_vars/master/vault.yml` (étape 3ter).

## Sécurité — à savoir avant un usage réel

- ✅ **Port 6443 (API K3s) restreint à `allowed_ssh_cidr`** (même CIDR
  que SSH) dans le security group — plus d'exposition à `0.0.0.0/0`.
  `scripts/update-ip.sh` positionne automatiquement ce CIDR sur l'IP
  publique de la machine de contrôle à chaque run.
- ✅ **Mot de passe Grafana chiffré via `ansible-vault`** (voir étape
  3ter) — plus de mot de passe en clair dans le repo. Le playbook
  `install-monitoring.yml` refuse de s'exécuter si le vault n'est pas
  configuré.
- **ArgoCD en HTTP simple côté service** (`server.insecure=true`) :
  le TLS est désormais terminé par l'Ingress Traefik (Let's Encrypt),
  donc le trafic **externe** est chiffré ; seul le trajet interne
  Ingress → pod `argocd-server` (dans le cluster) reste en clair, ce
  qui est acceptable au sein d'un même VPC.
- **cert-manager / Let's Encrypt** : le `ClusterIssuer` par défaut
  utilisé est `letsencrypt-prod`, soumis aux
  [rate limits officiels](https://letsencrypt.org/docs/rate-limits/)
  (ex. 5 échecs de validation par host/heure) — utiliser
  `letsencrypt-staging` pour les tests répétés.
- **State Terraform en local** : pas de backend distant (S3 + lock
  DynamoDB) — à ajouter si le projet est utilisé en équipe.
- **Pas de RBAC Kubernetes ni de NetworkPolicy** : le kubeconfig admin
  donne un accès complet au cluster, et tous les pods peuvent
  communiquer entre eux (y compris entre les namespaces `argocd`,
  `monitoring`, `demo`) — à durcir avant un usage multi-utilisateurs
  ou avec des charges sensibles.
- **AMI figée en dur** (`ami_id` dans `main.tf`) : pas de mécanisme de
  mise à jour automatique des patches de sécurité de l'OS — à
  surveiller manuellement ou via un pipeline de rebuild régulier.

## Dépannage rapide

- `terraform output masters` vide/erreur → vérifier qu'un `terraform
  apply` a bien abouti dans `terraform/`.
- SSH vers un worker échoue → vérifier que master1 est bien joignable
  (bastion via ProxyJump) et que `terraform/keys/ma-cle-ssh` est en `600`.
- `kubectl get nodes` incomplet → relancer `ansible-playbook site.yml
  --tags k3s` depuis `ansible/`, les tâches sont idempotentes
  (`creates:` sur les installations k3s).
- La tâche `Verifier que le cluster est pret` (ou n'importe quel appel
  `kubectl`/`helm` exécuté sur master1) reste bloquée en
  `FAILED - RETRYING` sans jamais aboutir → symptôme classique d'un
  kubeconfig qui pointe par erreur vers l'IP publique de master1 au
  lieu de `127.0.0.1` (AWS ne supporte pas qu'une instance se joigne
  elle-même via sa propre EIP). Vérifier que
  `/home/ubuntu/.kube/config` sur master1 utilise bien `127.0.0.1` —
  seul `/home/ubuntu/.kube/config-external` doit contenir l'IP
  publique (voir section « Piloter le cluster depuis ta machine »).
- Certificat TLS jamais `Ready` (`kubectl describe certificate -n
  argocd argocd-server-tls` ou `-n monitoring grafana-tls`) → vérifier
  que le DNS pointe bien vers l'IP publique de master1 et que le port
  80 est bien accessible depuis Internet (challenge HTTP-01) ; inspecter
  aussi `kubectl describe challenge -A` et
  `kubectl logs -n cert-manager deploy/cert-manager`.
