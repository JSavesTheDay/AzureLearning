# Authentication comes from your `az login` session.
# The subscription comes from the ARM_SUBSCRIPTION_ID environment variable,
# which keeps the subscription ID out of source control.
provider "azurerm" {
  features {}

  # azurerm 5.x no longer auto-registers resource providers (default is "none").
  # Register only what this configuration uses.
  resource_providers_to_register = [
    "Microsoft.Compute",
    "Microsoft.Network",
    "Microsoft.DevTestLab", # auto-shutdown schedules
  ]
}
