# Exercise 4 — Outputs, Data Sources, and Lifecycle Meta-Arguments

**Estimated time:** 45–60 minutes

## Objective

Use output values to expose resource attributes, query existing Azure infrastructure with data sources, and control resource lifecycle behaviour with meta-arguments (`lifecycle`, `prevent_destroy`, `ignore_changes`).

---

## Prerequisites

- Exercises 1–3 completed
- Clean working directory
- The Azure CLI authenticated (`az login`)

---

## Part 1 — Outputs in Depth (10 min)

### Step 1 — Set up the project

```bash
mkdir ~/terraform-exercises/day1-exercise4
cd ~/terraform-exercises/day1-exercise4
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
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "rg-outputs-training"
  location = "westeurope"

  tags = {
    environment = "training"
    managed_by  = "terraform"
  }
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-outputs-training"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}
```

Create `outputs.tf`:

```hcl
output "resource_group_name" {
  description = "The name of the resource group."
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "Full Azure resource ID for the resource group."
  value       = azurerm_resource_group.main.id
}

output "vnet_address_space" {
  description = "The VNet's address space list."
  value       = azurerm_virtual_network.main.address_space
}
```

```bash
terraform init
terraform apply -auto-approve
```

### Step 2 — Query outputs

```bash
# Show all outputs in human-readable format
terraform output

# Show all outputs as JSON (useful in scripts)
terraform output -json

# Show a single output value (no surrounding JSON)
terraform output resource_group_name

# Use an output in a shell script
RG_NAME=$(terraform output -raw resource_group_name)
echo "The resource group is: $RG_NAME"
az group show --name "$RG_NAME" --query location -o tsv
```

### Step 3 — Sensitive outputs

Some outputs like connection strings or passwords must not be printed in plain text in CI logs. Add to `outputs.tf`:

```hcl
output "example_secret" {
  description = "Simulated sensitive output."
  value       = "super-secret-value"
  sensitive   = true
}
```

Apply and observe:

```bash
terraform apply -auto-approve
terraform output
```

The sensitive output shows `<sensitive>` in the table. However it **is** stored in state in plain text — remote state with encryption at rest is essential when handling secrets.

To see the raw value anyway (requires explicit access to state):

```bash
terraform output -raw example_secret
```

---

## Part 2 — Data Sources (15 min)

Data sources let you read information about existing Azure resources without managing them. Think of them as "read-only queries" to Azure.

### Step 1 — Query the current subscription

Add to `main.tf`:

```hcl
data "azurerm_subscription" "current" {}

data "azurerm_client_config" "current" {}
```

Add outputs to expose the values:

```hcl
output "subscription_id" {
  value = data.azurerm_subscription.current.subscription_id
}

output "subscription_display_name" {
  value = data.azurerm_subscription.current.display_name
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "current_object_id" {
  value = data.azurerm_client_config.current.object_id
}
```

Apply and inspect the outputs — these come directly from Azure without creating anything.

### Step 2 — Read an existing resource group

Create a resource group outside of Terraform to simulate pre-existing infrastructure:

```bash
az group create --name rg-preexisting --location westeurope \
  --tags "owner=ops" "created_by=azure_cli"
```

Now reference it in Terraform as a data source:

```hcl
data "azurerm_resource_group" "preexisting" {
  name = "rg-preexisting"
}
```

Add outputs:

```hcl
output "preexisting_rg_location" {
  value = data.azurerm_resource_group.preexisting.location
}

output "preexisting_rg_tags" {
  value = data.azurerm_resource_group.preexisting.tags
}
```

Apply and observe:

```bash
terraform apply -auto-approve
terraform output preexisting_rg_tags
```

Terraform reads the tags you set via the CLI and exposes them — without ever managing (or destroying) that resource group.

### Step 3 — Data source vs resource distinction

Run a deliberate experiment:

```bash
terraform state list
```

You will see `data.azurerm_resource_group.preexisting` is tracked in state, but if you run `terraform destroy`, it will **not** be deleted — Terraform only destroys resources it manages, not data sources.

```bash
# Destroy and verify the preexisting RG is untouched
terraform destroy -auto-approve
az group show --name rg-preexisting --query name -o tsv
# Should still print: rg-preexisting
```

### Step 4 — Use a data source result in a resource

Re-create `main.tf` (after the destroy) to deploy a VNet into the **pre-existing** resource group, using the data source to look it up:

```hcl
resource "azurerm_virtual_network" "shared" {
  name                = "vnet-shared"
  address_space       = ["192.168.0.0/16"]
  location            = data.azurerm_resource_group.preexisting.location
  resource_group_name = data.azurerm_resource_group.preexisting.name
}
```

This pattern is very common in real-world projects: the network team manages the resource group and VNet foundations, and your Terraform code deploys application resources into them.

```bash
terraform init
terraform apply -auto-approve
```

---

## Part 3 — Lifecycle Meta-Arguments (15 min)

The `lifecycle` block controls how Terraform handles create/update/destroy events for a resource.

### Step 1 — `prevent_destroy`

The most important lifecycle setting: it prevents accidental deletion of critical resources.

Add a new resource group protected from deletion:

```hcl
resource "azurerm_resource_group" "critical" {
  name     = "rg-critical-do-not-delete"
  location = "westeurope"

  lifecycle {
    prevent_destroy = true
  }
}
```

Apply:

```bash
terraform apply -auto-approve
```

Now try to destroy it:

```bash
terraform destroy -auto-approve
```

You will see:
```
│ Error: Instance cannot be destroyed
│
│ Resource azurerm_resource_group.critical has lifecycle.prevent_destroy
│ set, but the plan calls for this resource to be destroyed.
```

This protects against accidentally running `terraform destroy` on production infrastructure or accidentally deleting a database when removing its dependent resources.

To actually delete it, you must first remove `prevent_destroy`, then destroy.

### Step 2 — `ignore_changes`

Sometimes Azure (or other tools) modify attributes that Terraform would otherwise want to revert. A common example is auto-scaling, where Azure adjusts instance counts.

Add an example:

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-lifecycle-demo"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = {
    environment = "training"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}
```

Apply, then manually add a tag via the Azure CLI:

```bash
terraform apply -auto-approve
az network vnet update \
  --name vnet-lifecycle-demo \
  --resource-group rg-outputs-training \
  --set tags.manually_added=true
```

Now run plan:

```bash
terraform plan
```

Even though the state and Azure differ on tags (Azure has `manually_added=true`, the config does not), Terraform shows **no change** for the VNet — because `ignore_changes = [tags]` tells it to leave tags alone.

> Use `ignore_changes` sparingly. It makes drift invisible and can lead to unexpected state divergence. Common valid uses: auto-scaling attributes, tags managed by external governance tools.

### Step 3 — `create_before_destroy`

By default, when Terraform needs to replace a resource (destroy old, create new), it destroys first. This can cause downtime. Setting `create_before_destroy = true` reverses the order.

```hcl
resource "azurerm_resource_group" "blue_green" {
  name     = "rg-bluegreen-demo"
  location = "westeurope"

  lifecycle {
    create_before_destroy = true
  }
}
```

This is most valuable for VMs, load balancer rules, and DNS records where you need the replacement to be running before the old one is removed.

---

## Part 4 — Clean Up

Remove `prevent_destroy` from the critical resource group first, then destroy everything:

```hcl
# In main.tf - remove the lifecycle block from azurerm_resource_group.critical
```

```bash
terraform apply -auto-approve  # re-apply without prevent_destroy
terraform destroy -auto-approve
az group delete --name rg-preexisting --yes --no-wait
```

---

## Checkpoint Questions

1. What is the difference between `terraform output` and `terraform output -json`? When would you use each?
2. What does `sensitive = true` on an output actually protect? What does it **not** protect?
3. What is the difference between a `resource` block and a `data` block?
4. If a data source refers to a resource that doesn't exist yet, what happens?
5. Explain `prevent_destroy`. Can it ever be bypassed? How?
6. When would `ignore_changes` be appropriate in a production environment?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `output` block | Exposes resource attributes after apply |
| `sensitive = true` | Hides value in terminal output; still in state file |
| `data` source | Reads existing infrastructure without managing it |
| `azurerm_subscription` | Data source for current subscription metadata |
| `azurerm_client_config` | Data source for current authentication context |
| `prevent_destroy` | Blocks destroy operations on a resource |
| `ignore_changes` | Prevents Terraform from reverting externally-made changes |
| `create_before_destroy` | Creates replacement before destroying original (reduces downtime) |
