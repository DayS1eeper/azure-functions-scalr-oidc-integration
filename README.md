# POC: Azure Functions & Scalr Integration (OIDC)
## Architecture Overview
This solution replaces static API keys with Workload Identity Federation.
1. Azure Function starts (triggered by a timer or webhook).
1. It requests a Signed OIDC Token from Entra ID proving its identity.
1. It sends this token to Scalr.
1. Scalr validates the token against Entra ID's public keys.
1. Scalr returns a temporary Scalr Access Token to the function.

## `main.tofu`
This Terraform configuration performs two main tasks:
1. Azure Side: Deploys the Function App and the Python code.
1. Scalr Side: Configures the Trust (OIDC Provider) and the Service Account.
*Prerequisites: You must be authenticated to both Azure (az login) and Scalr.*

## How to Trigger and Test
```bash
curl -X GET "$(terraform output -raw function_url)"
```