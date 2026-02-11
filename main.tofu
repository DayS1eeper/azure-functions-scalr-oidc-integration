terraform {
  required_providers {
    azuread = {
      source  = "opentofu/azuread"
      version = "~> 3.0"
    }
    azurerm = {
      source  = "opentofu/azurerm"
      version = "~> 4.0"
    }
    scalr = {
      source  = "scalr/scalr"
      version = "~> 3.0"
    }
  }
}
locals {
  scalr_audience = "api://${data.azurerm_client_config.current.tenant_id}/${var.scalr_hostname}"
  tenant_id      = data.azurerm_client_config.current.tenant_id
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}
provider "scalr" {
  hostname = var.scalr_hostname
  token    = var.scalr_api_token
}

variable "prefix" {
  default = "scalr-oidc-demo"
}
variable "location" {
  default = "West US 3"
}
variable "scalr_hostname" {
  default = "my.scalr.io"
}
variable "scalr_api_token" {
  type      = string
  sensitive = true
}
variable "scalr_account_id" {
  type = string
}

variable "azure_subscription_id" {
  type = string
}
# ==============================================================================
# AZURE INFRASTRUCTURE
# ==============================================================================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_storage_account" "sa" {
  name                     = replace("${var.prefix}sa", "-", "")
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_service_plan" "plan" {
  name                = "${var.prefix}-plan"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"
}

resource "azurerm_user_assigned_identity" "func_id" {
  location            = azurerm_resource_group.rg.location
  name                = "${var.prefix}-identity"
  resource_group_name = azurerm_resource_group.rg.name
}

data "archive_file" "app_package" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/function_app.zip"
}

resource "azuread_application" "scalr_federation" {
  display_name = "${var.prefix}-federation"
  
  identifier_uris = [
    local.scalr_audience
  ]
}

resource "azuread_service_principal" "scalr_federation_sp" {
  client_id = azuread_application.scalr_federation.client_id
}

resource "azurerm_linux_function_app" "func" {
  name                = "${var.prefix}-func"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  service_plan_id            = azurerm_service_plan.plan.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.func_id.id]
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    "SCALR_HOSTNAME"                 = var.scalr_hostname
    "SCALR_AUDIENCE"                 = local.scalr_audience
    "SCALR_SERVICE_ACCOUNT_EMAIL"    = scalr_service_account.sa.email
    "AZURE_CLIENT_ID"                = azurerm_user_assigned_identity.func_id.client_id
    "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = azurerm_storage_account.sa.primary_connection_string
    "WEBSITE_CONTENTSHARE"                     = "${var.prefix}-content-share"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
    "ENABLE_ORYX_BUILD"              = "true"
  }
}

resource "null_resource" "function_deployment" {
  triggers = {
    file_hash = data.archive_file.app_package.output_sha
  }

  provisioner "local-exec" {
    command = <<EOT
      az functionapp deployment source config-zip \
        --resource-group ${azurerm_resource_group.rg.name} \
        --name ${azurerm_linux_function_app.func.name} \
        --src ${data.archive_file.app_package.output_path} \
        --build-remote true
    EOT
  }
  
  depends_on = [azurerm_linux_function_app.func]
}

# ==============================================================================
# SCALR OIDC CONFIGURATION
# ==============================================================================

resource "scalr_workload_identity_provider" "azure_oidc" {
  name = "azure-entra-${local.tenant_id}"
  url = "https://sts.windows.net/${local.tenant_id}"

  allowed_audiences = [local.scalr_audience]
}

resource "scalr_service_account" "sa" {
  name        = "azure-func-automation"
  account_id  = var.scalr_account_id
  description = "Automated account for Azure Function integration"
  status      = "Active"
}

resource "scalr_assume_service_account_policy" "binding" {
  name               = "bind-azure-func"
  service_account_id = scalr_service_account.sa.id
  provider_id        = scalr_workload_identity_provider.azure_oidc.id

  # Security Condition: ONLY this specific Azure Function Identity is allowed
  claim_condition {
    claim    = "sub"
    operator = "eq"
    value    = azurerm_user_assigned_identity.func_id.principal_id
  }
}

output "function_url" {
  value = "https://${azurerm_linux_function_app.func.default_hostname}/api/scalr_trigger"
}
