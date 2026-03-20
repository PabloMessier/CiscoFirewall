packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

# Discover latest RHEL 10.1 base AMI — same filter as Terraform
data "amazon-ami" "rhel" {
  filters = {
    name                = "RHEL-10.1*-x86_64-*"
    virtualization-type = "hvm"
    architecture        = "x86_64"
  }
  owners      = ["309956199498"]
  most_recent = true
  region      = var.region
}

source "amazon-ebs" "workload" {
  ami_name      = "workload-rhel10-podman-{{timestamp}}"
  ami_description = "RHEL 10.1 with Podman and nginx:alpine pre-installed"
  instance_type = var.instance_type
  region        = var.region
  source_ami    = data.amazon-ami.rhel.id

  ssh_username = "ec2-user"

  tags = {
    Name        = "Workload Golden AMI"
    Base_AMI    = data.amazon-ami.rhel.id
    Environment = "Development"
    Project     = "CiscoFirewall-Infrastructure"
    ManagedBy   = "Packer"
  }
}

build {
  sources = ["source.amazon-ebs.workload"]

  # Install Podman and pre-pull the nginx image
  provisioner "shell" {
    script = "${path.root}/scripts/provision.sh"
  }
}
