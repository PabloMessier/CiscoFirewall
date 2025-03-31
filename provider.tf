terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    ciscoasa = {
      source  = "CiscoDevNet/ciscoasa"
      version = "1.3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.azure_subscription_id
}

provider "ciscoasa" {
  api_url  = var.cisco_api_url
  username = var.cisco_username
  password = var.cisco_password
}