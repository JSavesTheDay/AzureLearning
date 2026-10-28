# Pin Terraform and provider versions so the code behaves the same on any machine.
# "~> 5.11" allows 5.11.x and later 5.x releases, but never 6.0 (a breaking major).
terraform {
  required_version = ">= 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
