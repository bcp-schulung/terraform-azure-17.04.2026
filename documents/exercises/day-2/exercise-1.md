# Exercise 1 — Service Principal and Remote State Setup

**Estimated time:** 45–60 minutes

## Objective

Move from personal Azure CLI authentication to a Service Principal — the correct authentication method for CI/CD and shared team environments. Then migrate your Terraform state from a local file to a remote backend using Azure Blob Storage, enabling state locking and team collaboration.

---

## Prerequisites

- Day 1 exercises completed
- Azure CLI authenticated (`az login`)
- Contributor or Owner role on your Azure subscription
- A clean working directory

---

## Part 1 — Understand Service Principals (5 min)

When you run `terraform apply` on your laptop, Terraform uses your Azure CLI login token. This is fine for personal development, but it has serious problems in team/CI environments:

| Problem | Explanation |
|---|---|
| Personal credentials | CI pipelines cannot use your account's MFA |
| No audit trail | All API calls show as "your name" in Azure Activity Log |
| Over-privileged | Your account role may exceed what Terraform needs |
| Token expiry | CLI tokens expire, breaking long-running pipelines |

A **Service Principal** (SP) is an Azure AD application identity. It has its own credentials, its own role assignments, and is purpose-built for non-interactive automation.

---

## Part 2 — Create a Service Principal (10 min)

### Step 1 — Create the SP

Run this command, substituting your actual subscription ID:

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az ad sp create-for-rbac \
  --name "sp-terraform-training" \
  --role "Contributor" \
  --scopes "/subscriptions/$SUBSCRIPTION_ID" \
  --output json
```

You will see output like:

```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "displayName": "sp-terraform-training",
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

> **Security note:** This password is only shown once. Save it somewhere secure (e.g., a password manager or Azure Key Vault). Never commit it to source control.

### Step 2 — Record the values

Map the SP output to Terraform's expected environment variable names:

| SP output field | Environment variable |
|---|---|
| `appId` | `ARM_CLIENT_ID` |
| `password` | `ARM_CLIENT_SECRET` |
| `tenant` | `ARM_TENANT_ID` |
| *(subscription id)* | `ARM_SUBSCRIPTION_ID` |

### Step 3 — Set environment variables

For the current terminal session:

```bash
export ARM_CLIENT_ID="<appId>"
export ARM_CLIENT_SECRET="<password>"
export ARM_TENANT_ID="<tenant>"
export ARM_SUBSCRIPTION_ID="<subscription_id>"
```

> For persistent use, add these to your shell profile (`~/.zshrc`, `~/.bashrc`) or a `.env` file sourced at the start of pipelines. Never hard-code them in `.tf` files.

### Step 4 — Verify the SP works

```bash
az login --service-principal \
  --username "$ARM_CLIENT_ID" \
  --password "$ARM_CLIENT_SECRET" \
  --tenant "$ARM_TENANT_ID"

az account show
```

You should see your subscription details authenticated as the service principal. Log back out and return to your personal session:

```bash
az logout
az login
az account set --subscription "$ARM_SUBSCRIPTION_ID"
```

---

## Part 3 — Bootstrap the Remote State Infrastructure (15 min)

Remote state requires an Azure Storage Account and Blob Container. This bootstrap infrastructure is typically created **once per project** and managed separately from the main Terraform code (often with a small bootstrap script or manually).

### Step 1 — Create a resource group for state

```bash
az group create \
  --name rg-terraform-state \
  --location westeurope \
  --tags managed_by=manual purpose=terraform-state
```

### Step 2 — Create the Storage Account

Storage account names must be globally unique and 3–24 lowercase alphanumeric characters:

```bash
# Generate a unique name using your initials and a random suffix
SUFFIX=$(openssl rand -hex 4)
SA_NAME="sttfstate${SUFFIX}"
echo "Storage Account name: $SA_NAME"

az storage account create \
  --name "$SA_NAME" \
  --resource-group rg-terraform-state \
  --location westeurope \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false
```

The security flags (`--https-only`, `--min-tls-version`, `--allow-blob-public-access false`) are best practices for any storage account holding Terraform state.

### Step 3 — Create the Blob Container

```bash
az storage container create \
  --name tfstate \
  --account-name "$SA_NAME" \
  --auth-mode login
```

### Step 4 — Enable versioning (recommended for production)

Blob versioning allows you to restore previous state files if something goes wrong:

```bash
az storage account blob-service-properties update \
  --account-name "$SA_NAME" \
  --enable-versioning true
```

Note down your storage account name — you will need it in the next part.

---

## Part 4 — Configure the Remote Backend (15 min)

### Step 1 — Create a new Terraform project

```bash
mkdir ~/terraform-exercises/day2-exercise1
cd ~/terraform-exercises/day2-exercise1
```

Create `main.tf`:

```hcl
terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "<YOUR_STORAGE_ACCOUNT_NAME>"
    container_name       = "tfstate"
    key                  = "day2-exercise1.tfstate"
  }
}

provider "azurerm" {
  features {}

  # Explicit SP credentials (alternative to env vars — for illustration only)
  # client_id       = var.client_id
  # client_secret   = var.client_secret
  # tenant_id       = var.tenant_id
  # subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "main" {
  name     = "rg-day2-training"
  location = "westeurope"
  tags = {
    managed_by  = "terraform"
    environment = "training"
  }
}
```

Replace `<YOUR_STORAGE_ACCOUNT_NAME>` with the name you created in Part 3.

> **Best practice:** Never put credentials directly in `.tf` files. Use environment variables (`ARM_*`) or a managed identity in CI. The provider block will automatically pick up the `ARM_*` environment variables you set earlier.

### Step 2 — Initialise with the remote backend

```bash
terraform init
```

Terraform connects to Azure, finds the storage account and container, and configures the backend. Output:

```
Initializing the backend...
Successfully configured the backend "azurerm"!
...
Terraform has been successfully initialized!
```

### Step 3 — Apply

```bash
terraform apply -auto-approve
```

### Step 4 — Verify state is in Azure Blob Storage

```bash
az storage blob list \
  --container-name tfstate \
  --account-name "$SA_NAME" \
  --auth-mode login \
  --output table
```

You should see `day2-exercise1.tfstate` listed. Download and inspect it:

```bash
az storage blob download \
  --container-name tfstate \
  --account-name "$SA_NAME" \
  --name day2-exercise1.tfstate \
  --file /tmp/remote-state.json \
  --auth-mode login

cat /tmp/remote-state.json | python3 -m json.tool | head -60
```

The content is identical to a local `terraform.tfstate` file — it is JSON, it records all your resources — but it now lives in Azure.

---

## Part 5 — State Locking (5 min)

Azure Blob Storage uses **lease-based locking**. When Terraform starts an operation that modifies state, it acquires an exclusive lease on the blob. Any concurrent `terraform apply` on the same state file will wait or fail, preventing state corruption.

To observe this, you would need two terminals running `terraform apply` simultaneously on the same state file. The second one would display:

```
│ Error: Error acquiring the state lock
│
│ Error message: state blob is already locked
│ Lock Info:
│   ID:        <uuid>
│   Path:      tfstate/day2-exercise1.tfstate
│   Operation: OperationTypeApply
│   Who:       user@machine
│   Created:   2026-01-01 10:00:00
```

If a lock is stuck (e.g., Terraform crashed mid-apply), you can force-unlock it:

```bash
terraform force-unlock <lock-id>
```

---

## Part 6 — Migrate Local State to Remote (bonus)

If you have a project with existing local state that you want to move to the remote backend:

1. Add the `backend "azurerm"` block to the configuration.
2. Run `terraform init -migrate-state`.
3. Terraform will prompt you to confirm copying local state to the backend.
4. Once confirmed, the local `terraform.tfstate` file can be deleted.

```bash
terraform init -migrate-state
```

---

## Clean Up

Leave the resource group and storage account for use in later Day 2 exercises. You will build on this backend in Exercises 2–4.

---

## Checkpoint Questions

1. Why is a Service Principal preferred over personal CLI credentials for CI/CD?
2. What four environment variables does the `azurerm` provider read for SP authentication?
3. What happens if two engineers run `terraform apply` at the same time against the same remote state?
4. What is a state lock? How does Azure Blob Storage implement it?
5. Why should the Terraform state storage account be bootstrapped separately from the main Terraform code?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| Service Principal | Azure AD identity for non-interactive automation |
| `ARM_CLIENT_ID/SECRET/TENANT_ID` | Environment variables for SP authentication |
| Remote backend | Stores state file outside local filesystem |
| `backend "azurerm"` | Terraform block pointing to Azure Blob Storage |
| State locking | Prevents concurrent modifications to state |
| `terraform init -migrate-state` | Moves local state to a remote backend |
