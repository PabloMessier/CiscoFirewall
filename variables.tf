variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "azure_region" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "cisco_api_url" {
  description = "The URL of the Cisco ASA API"
  type        = string
}

variable "cisco_username" {
  description = "Username for Cisco ASA authentication"
  type        = string
}

variable "cisco_password" {
  description = "Password for Cisco ASA authentication"
  type        = string
  sensitive   = true
}

variable "cisco_asav_ami" {
  description = "AMI ID for Cisco ASAv in AWS"
  type        = string
}

variable "cisco_asav_azure_sku" {
  description = "SKU for Cisco ASAv in Azure"
  type        = string
}

variable "aws_instance_password" {
  description = "Password for AWS instance"
  type        = string
  sensitive   = true
}

variable "azure_instance_password" {
  description = "Password for Azure instance"
  type        = string
  sensitive   = true
}

# VM Sizes
variable "azure_vm_size" {
  description = "Size of the Azure VM"
  type        = string
  default     = "Standard_B1s"
}

variable "asav_vm_size" {
  description = "Size of the Cisco ASAv"
  type        = string
  default     = "Standard_D3_v2"
}

# Operating System Versions
variable "ubuntu_version" {
  description = "Ubuntu Server version"
  type        = string
  default     = "18.04-LTS"
}

variable "asav_version" {
  description = "Cisco ASAv version"
  type        = string
  default     = "920210.0.0"
}

# Network Configuration
variable "enable_accelerated_networking" {
  description = "Enable accelerated networking for supported interfaces"
  type        = bool
  default     = true
}

# Resource Tagging
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "Development"
    Project     = "CrossCloud"
    ManagedBy   = "Terraform"
  }
}

# VNET Address Space
variable "azure_vnet_cidr" {
  description = "CIDR block for Azure VNet"
  type        = string
  default     = "10.2.0.0/16"
}

variable "azure_subnet_cidr" {
  description = "CIDR block for Azure subnet"
  type        = string
  default     = "10.2.0.0/24"
}

variable "azure_fw_subnet_cidr" {
  description = "CIDR block for Azure firewall subnet"
  type        = string
  default     = "10.2.1.0/24"
}

variable "aws_vpc_cidr" {
  description = "CIDR block for AWS VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "aws_subnet_cidr" {
  description = "CIDR block for AWS workload subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "aws_fw_subnet_cidr" {
  description = "CIDR block for AWS firewall subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "aws_instance_type" {
  description = "Instance type for AWS workload VM"
  type        = string
  default     = "t2.micro"
}

variable "aws_asav_instance_type" {
  description = "Instance type for AWS ASAv"
  type        = string
  default     = "c4.large"
}

variable "aws_ubuntu_ami" {
  description = "AMI ID for Ubuntu in AWS"
  type        = string
  default     = "ami-0c614dee691cbbf37"
}

variable "resource_group_name" {
  description = "Name of Azure resource group"
  type        = string
  default     = "azure-cisco-fw-rg"
}

variable "asav_disk_size" {
  description = "Disk size in GB for Cisco ASAv"
  type        = number
  default     = 50
}