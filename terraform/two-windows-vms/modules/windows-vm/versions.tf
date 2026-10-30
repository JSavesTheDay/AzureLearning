# A child module declares the providers it needs, but never configures them.
# The root module's provider "azurerm" block is passed in automatically.
terraform {
  required_version = ">= 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
  }
}
