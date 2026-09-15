# ============================================================
# Variables
# ============================================================
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "allowed_ssh_cidr" {
  description = "CIDR autorise pour SSH ET pour l'API K3s (port 6443) - remplace par ton IP : 'x.x.x.x/32'"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Type d'instance (masters et workers)"
  type        = string
  default     = "m5.large"
}

variable "ami_id" {
  description = "AMI Ubuntu 22.04 LTS (us-east-1)"
  type        = string
  default     = "ami-08c40ec9ead489470"
}

variable "master_count" {
  description = "Nombre de noeuds master (doit rester impair pour le quorum etcd)"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Nombre de noeuds worker"
  type        = number
  default     = 3
}

variable "az_count" {
  description = "Nombre de zones de disponibilite (AZ) sur lesquelles repartir masters et workers (round-robin). Avec la valeur par defaut (3) et master_count/worker_count=3, chaque noeud d'un role est dans une AZ distincte : la perte d'une AZ laisse 2 masters (quorum etcd toujours majoritaire) et 2 workers actifs."
  type        = number
  default     = 3
}

variable "volume_size_master" {
  description = "Taille du disque root en GB pour les masters (etcd est sensible aux I/O)"
  type        = number
  default     = 50
}

variable "volume_size_worker" {
  description = "Taille du disque root en GB pour les workers"
  type        = number
  default     = 50
}

variable "key_name" {
  description = "Nom de la cle SSH"
  type        = string
  default     = "ma-cle-ssh"
}

variable "project_name" {
  description = "Nom du projet (utilise pour les tags)"
  type        = string
  default     = "k3s-cluster"
}

variable "vpc_cidr" {
  description = "CIDR du VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR de base pour les subnets publics (masters). Decoupe automatiquement en un /26 par AZ (jusqu'a 4 AZ) via cidrsubnet() - doit rester coherent avec ansible/hosts (voir commentaires du fichier)."
  type        = string
  default     = "192.168.2.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR de base pour les subnets prives (workers). Decoupe automatiquement en un /26 par AZ (jusqu'a 4 AZ) via cidrsubnet() - doit rester coherent avec ansible/hosts (voir commentaires du fichier)."
  type        = string
  default     = "192.168.3.0/24"
}

# ============================================================
# Provider
# ============================================================
provider "aws" {
  region = var.region
}

# ============================================================
# Data source : AZ disponibles dans la region
# ============================================================
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Les az_count premieres AZ disponibles dans la region, utilisees
  # en round-robin pour repartir masters et workers.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.az_count, length(data.aws_availability_zones.available.names))
  )
  az_n = length(local.azs)
}

# ============================================================
# Reseau (MULTI-AZ)
# ============================================================
# HA reelle : un subnet public + un subnet prive par AZ utilisee
# (local.azs). Masters et workers sont repartis en round-robin sur
# ces AZ (voir aws_instance.master/worker plus bas). La perte d'une
# AZ AWS n'affecte donc plus qu'une fraction du cluster, au lieu de
# le mettre integralement hors service.
#
# - Subnets PUBLICS (masters) : IGW direct + EIP par master.
# - Subnets PRIVES (workers)  : pas d'IP publique, sortie Internet
#   via un NAT Gateway DEDIE PAR AZ (necessaire pour apt et curl
#   get.k3s.io lances par le playbook Ansible site.yml sur les
#   workers) - evite qu'un NAT Gateway unique devienne lui-meme un
#   point de defaillance partage entre AZ.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

resource "aws_subnet" "public" {
  count                   = local.az_n
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.subnet_cidr, 2, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-subnet-public-${count.index + 1}"
    Project = var.project_name
    AZ      = local.azs[count.index]
  }
}

resource "aws_subnet" "private" {
  count                   = local.az_n
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.private_subnet_cidr, 2, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name    = "${var.project_name}-subnet-private-${count.index + 1}"
    Project = var.project_name
    AZ      = local.azs[count.index]
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# Une seule table de routage publique (route IGW identique pour
# toutes les AZ) partagee par tous les subnets publics.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-rt-public"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  count          = local.az_n
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- NAT Gateway dedie par AZ : chaque subnet prive sort par SON
#     propre NAT Gateway (dans le subnet public de la meme AZ), pas
#     de dependance croisee entre AZ pour la sortie Internet ---
resource "aws_eip" "nat" {
  count  = local.az_n
  domain = "vpc"

  tags = {
    Name    = "${var.project_name}-nat-eip-${count.index + 1}"
    Project = var.project_name
  }
}

resource "aws_nat_gateway" "main" {
  count         = local.az_n
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id # NAT GW de l'AZ N vit dans le subnet public de l'AZ N

  tags = {
    Name    = "${var.project_name}-nat-${count.index + 1}"
    Project = var.project_name
  }

  depends_on = [aws_internet_gateway.main]
}

# Une table de routage privee PAR AZ, chacune pointant vers le NAT
# Gateway de sa propre AZ.
resource "aws_route_table" "private" {
  count  = local.az_n
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name    = "${var.project_name}-rt-private-${count.index + 1}"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "private" {
  count          = local.az_n
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ============================================================
# Security Group
# ============================================================
resource "aws_security_group" "k3s" {
  name        = "${var.project_name}-sg"
  description = "Regles pour cluster K3s HA multi-AZ (SSH, HTTP, HTTPS, API server, etcd, kubelet, VXLAN)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # K3s API server (kube-apiserver) - acces externe pour kubectl,
  # restreint au meme CIDR que SSH (allowed_ssh_cidr) : evite d'exposer
  # l'API Kubernetes a tout Internet. Le script scripts/update-ip.sh
  # positionne automatiquement ce CIDR sur l'IP publique de la machine
  # de controle a chaque run.
  ingress {
    description = "K3s API server (restreint a allowed_ssh_cidr)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Trafic interne complet entre les noeuds du cluster (etcd, kubelet,
  # flannel VXLAN, etc.). "self = true" couvre le trafic entre toutes
  # les instances attachees a ce SG, y compris entre AZ differentes
  # (le VPC route nativement entre ses propres subnets, quelle que
  # soit leur AZ).
  ingress {
    description = "Trafic interne cluster (etcd, kubelet, flannel, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# ============================================================
# Cle SSH
# ============================================================
resource "aws_key_pair" "main" {
  key_name   = var.key_name
  public_key = file("${path.module}/keys/${var.key_name}.pub")

  tags = {
    Project = var.project_name
  }
}

# ============================================================
# Instances EC2 - Masters (control plane + etcd, subnets publics)
#
# Repartition round-robin sur local.azs : master[i] va dans le
# subnet public d'index (i % az_n), a l'AZ correspondante. L'IP
# privee est calculee automatiquement (cidrhost) a l'interieur du
# subnet cible, hote 10 + N-ieme passage sur la meme AZ (pour
# rester compatible avec master_count > az_count sans collision).
# ============================================================
resource "aws_instance" "master" {
  count                  = var.master_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[count.index % local.az_n].id
  private_ip             = cidrhost(aws_subnet.public[count.index % local.az_n].cidr_block, 10 + floor(count.index / local.az_n))
  vpc_security_group_ids = [aws_security_group.k3s.id]
  key_name               = aws_key_pair.main.key_name

  # Pas de user_data : l'installation de k3s est entierement geree
  # par le playbook Ansible site.yml (ansible-playbook site.yml).
  # L'AMI Ubuntu standard embarque deja python3, requis par Ansible.

  root_block_device {
    volume_size           = var.volume_size_master
    volume_type            = "gp3"
    encrypted              = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-master-${count.index + 1}"
    Project = var.project_name
    Role    = "master"
    AZ      = local.azs[count.index % local.az_n]
  }
}

# ============================================================
# Instances EC2 - Workers (subnets prives, une par AZ, pas d'EIP)
# Meme logique de repartition round-robin que les masters.
# ============================================================
resource "aws_instance" "worker" {
  count                   = var.worker_count
  ami                     = var.ami_id
  instance_type           = var.instance_type
  subnet_id               = aws_subnet.private[count.index % local.az_n].id
  private_ip              = cidrhost(aws_subnet.private[count.index % local.az_n].cidr_block, 10 + floor(count.index / local.az_n))
  vpc_security_group_ids  = [aws_security_group.k3s.id]
  key_name                = aws_key_pair.main.key_name

  # Pas de user_data : le join k3s agent est entierement gere par
  # le playbook Ansible site.yml.

  root_block_device {
    volume_size           = var.volume_size_worker
    volume_type            = "gp3"
    encrypted              = true
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-worker-${count.index + 1}"
    Project = var.project_name
    Role    = "worker"
    AZ      = local.azs[count.index % local.az_n]
  }

  # Les workers demarrent apres les masters (le cluster doit exister
  # et master1 doit etre up pour servir de bastion SSH) et apres que
  # tous les NAT Gateway soient prets (sortie Internet necessaire).
  depends_on = [aws_instance.master, aws_nat_gateway.main]
}

# ============================================================
# Elastic IP - uniquement sur les masters (acces API + SSH admin)
# Les workers restent en IP privee (subnets prives, pas d'EIP)
# ============================================================
resource "aws_eip" "master" {
  count    = var.master_count
  instance = aws_instance.master[count.index].id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-master-${count.index + 1}-eip"
    Project = var.project_name
  }
}

# ============================================================
# Outputs
# ============================================================
output "masters" {
  description = "IP publiques, privees et AZ des masters"
  value = {
    for idx, inst in aws_instance.master :
    "master-${idx + 1}" => {
      private_ip = inst.private_ip
      public_ip  = aws_eip.master[idx].public_ip
      az         = local.azs[idx % local.az_n]
    }
  }
}

output "workers" {
  description = "IP privees et AZ des workers (pas d'IP publique, subnets prives)"
  value = {
    for idx, inst in aws_instance.worker :
    "worker-${idx + 1}" => {
      private_ip = inst.private_ip
      az         = local.azs[idx % local.az_n]
    }
  }
}

output "availability_zones" {
  description = "AZ utilisees par le cluster (round-robin masters/workers)"
  value       = local.azs
}

output "master1_public_ip" {
  description = "IP publique de master1 - a reporter dans hosts.ini a la place de <MASTER1_PUBLIC_IP>"
  value       = aws_eip.master[0].public_ip
}
