# Exercise 2 — Storage Accounts: Blobs, Files, Disks, and Tables

**Estimated time:** 50–65 minutes

## Objective

Provision an Azure Storage Account and explore the four primary storage offerings available inside it — Blob Storage (object store), Azure Files (SMB shares), Managed Disks (VM volumes), and Table Storage (NoSQL key-value). Understand when each is appropriate and how to configure access tiers and replication.

---

## Prerequisites

- Day 2 exercises completed
- Remote backend configured

---

## Background: Azure Storage Types

Azure wraps multiple storage technologies in a single service. The Storage Account is the parent resource; each storage type is a child:

| Type | Terraform Resource | Use Case |
|---|---|---|
| Blob Storage | `azurerm_storage_container` + `azurerm_storage_blob` | Unstructured objects, backups, static websites |
| Azure Files | `azurerm_storage_share` | SMB/NFS file shares mountable on VMs |
| Managed Disks | `azurerm_managed_disk` | OS and data disks attached to VMs |
| Table Storage | `azurerm_storage_table` | Semi-structured NoSQL key-value data |
| Queue Storage | `azurerm_storage_queue` | Message queuing (not covered in this exercise) |

Replication options (most common):
- `Standard_LRS` — locally redundant (3 copies in one datacenter). Cheapest.
- `Standard_GRS` — geo-redundant (6 copies across 2 regions). Recommended for most workloads.
- `Standard_ZRS` — zone redundant (3 copies across 3 availability zones in one region).
- `Premium_LRS` — premium performance, SSD-backed. Required for some disk sizes.

---

## Part 1 — Project Setup (5 min)

```bash
mkdir ~/terraform-exercises/day3-exercise2
cd ~/terraform-exercises/day3-exercise2
touch main.tf variables.tf outputs.tf terraform.tfvars
```

---

## Part 2 — Variables (5 min)

### `variables.tf`

```hcl
variable "resource_group_name" {
  type    = string
  default = "rg-storage-training"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "storage_account_name" {
  type        = string
  description = "Must be globally unique, 3–24 lowercase alphanumeric chars."
}

variable "replication_type" {
  type    = string
  default = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "ZRS", "RAGRS"], var.replication_type)
    error_message = "replication_type must be one of: LRS, GRS, ZRS, RAGRS."
  }
}

variable "tags" {
  type = map(string)
  default = {
    environment = "training"
    managed_by  = "terraform"
  }
}
```

### `terraform.tfvars`

```hcl
# Storage account names must be globally unique — use your initials + random suffix
storage_account_name = "sttrain<your-initials><random>"
```

Generate a unique name:

```bash
echo "sttraining$(openssl rand -hex 4)"
```

---

## Part 3 — Storage Account and Blob Storage (15 min)

### `main.tf`

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
    storage_account_name = "<YOUR_STATE_STORAGE_ACCOUNT>"
    container_name       = "tfstate"
    key                  = "day3-exercise2.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# ─── Resource Group ──────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─── Storage Account ─────────────────────────────────────
resource "azurerm_storage_account" "main" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = var.replication_type

  # Security hardening
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Access tier — Cool reduces IOPS cost for infrequently accessed data
  access_tier = "Hot"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 7
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# ─── Blob Container ───────────────────────────────────────
resource "azurerm_storage_container" "uploads" {
  name                  = "uploads"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"  # Never use "blob" or "container" (public)
}

resource "azurerm_storage_container" "backups" {
  name                  = "backups"
  storage_account_name  = azurerm_storage_account.main.name
  container_access_type = "private"
}

# ─── Sample Blob ──────────────────────────────────────────
# Create a local sample file first
resource "local_file" "sample" {
  content  = "This file was created and uploaded by Terraform on ${timestamp()}"
  filename = "${path.module}/sample.txt"

  lifecycle {
    ignore_changes = [content]  # Don't update on every apply (timestamp changes)
  }
}

resource "azurerm_storage_blob" "sample" {
  name                   = "sample/readme.txt"
  storage_account_name   = azurerm_storage_account.main.name
  storage_container_name = azurerm_storage_container.uploads.name
  type                   = "Block"
  source                 = local_file.sample.filename
}
```

> The `local` provider is used here to create a sample file. Add it to the `required_providers` block:

```hcl
    hashicorp/local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
```

Apply:

```bash
terraform init
terraform apply -auto-approve
```

### Verify the blob exists

```bash
SA_NAME=$(terraform output -raw storage_account_name)

az storage blob list \
  --account-name "$SA_NAME" \
  --container-name uploads \
  --auth-mode login \
  --output table
```

### Download and inspect

```bash
az storage blob download \
  --account-name "$SA_NAME" \
  --container-name uploads \
  --name "sample/readme.txt" \
  --file /tmp/downloaded-sample.txt \
  --auth-mode login

cat /tmp/downloaded-sample.txt
```

---

## Part 4 — Azure Files (File Shares) (10 min)

Azure Files provides fully managed SMB and NFS file shares. Common use cases: lift-and-shift of Windows file servers, shared configuration files across VMs.

```hcl
# ─── File Share ───────────────────────────────────────────
resource "azurerm_storage_share" "config" {
  name                 = "config-share"
  storage_account_name = azurerm_storage_account.main.name
  quota                = 5   # GB

  # Access tier — Transaction Optimized is good for general-purpose file shares
  # access_tier = "TransactionOptimized"
}

resource "azurerm_storage_share_file" "app_config" {
  name             = "app.config"
  storage_share_id = azurerm_storage_share.config.id
  source           = local_file.sample.filename
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Mount the share on Linux (optional — requires a Linux machine in the same VNet)

Azure provides a mount script. Get it from the Portal: **Storage Account → File shares → config-share → Connect**.

For reference, the command looks like:

```bash
sudo mount -t cifs //sttrain<xxx>.file.core.windows.net/config-share /mnt/config \
  -o "vers=3.0,username=sttrain<xxx>,password=<key>,dir_mode=0777,file_mode=0777"
```

---

## Part 5 — Managed Disks (10 min)

Managed Disks are block storage attached to VMs. Unlike OS disks (automatically created with the VM), data disks are independent `azurerm_managed_disk` resources.

```hcl
# ─── Managed Disk ─────────────────────────────────────────
resource "azurerm_managed_disk" "data" {
  name                 = "disk-data-training"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 32
  tags                 = var.tags
}

# ─── Premium SSD for comparison ───────────────────────────
resource "azurerm_managed_disk" "premium" {
  name                 = "disk-premium-training"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 64
  tags                 = var.tags
}
```

**Disk types reference:**

| Type | `storage_account_type` | Use Case |
|---|---|---|
| Standard HDD | `Standard_LRS` | Dev/test, cold storage |
| Standard SSD | `StandardSSD_LRS` | General workloads |
| Premium SSD | `Premium_LRS` | Production databases, I/O intensive |
| Ultra Disk | `UltraSSD_LRS` | Highest IOPS (SAP HANA, SQL Server) |

To attach a disk to an existing VM, add `azurerm_virtual_machine_data_disk_attachment` (not shown here — covered in the VM exercises).

Apply:

```bash
terraform apply -auto-approve
```

Verify:

```bash
az disk list --resource-group rg-storage-training --output table
```

---

## Part 6 — Table Storage (10 min)

Azure Table Storage is a NoSQL key-value store — great for semi-structured data that doesn't need full relational capabilities. Common uses: audit logs, telemetry, user session data.

```hcl
# ─── Storage Table ────────────────────────────────────────
resource "azurerm_storage_table" "events" {
  name                 = "events"
  storage_account_name = azurerm_storage_account.main.name
}

resource "azurerm_storage_table" "sessions" {
  name                 = "sessions"
  storage_account_name = azurerm_storage_account.main.name
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Insert and query table data (via CLI)

```bash
SA_NAME=$(terraform output -raw storage_account_name)
SA_KEY=$(az storage account keys list \
  --account-name "$SA_NAME" \
  --resource-group rg-storage-training \
  --query '[0].value' -o tsv)

# Insert a row
az storage entity insert \
  --account-name "$SA_NAME" \
  --account-key "$SA_KEY" \
  --table-name events \
  --entity PartitionKey=2026 RowKey=001 EventType=login UserId=user_42

# Query all rows
az storage entity query \
  --account-name "$SA_NAME" \
  --account-key "$SA_KEY" \
  --table-name events \
  --output table
```

---

## Part 7 — Outputs

### `outputs.tf`

```hcl
output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "storage_account_primary_connection_string" {
  value     = azurerm_storage_account.main.primary_connection_string
  sensitive = true
}

output "blob_url" {
  description = "URL of the sample blob."
  value       = azurerm_storage_blob.sample.url
}

output "file_share_url" {
  value = azurerm_storage_share.config.url
}

output "managed_disk_ids" {
  value = {
    standard = azurerm_managed_disk.data.id
    premium  = azurerm_managed_disk.premium.id
  }
}
```

Apply and inspect:

```bash
terraform apply -auto-approve
terraform output
terraform output -raw storage_account_primary_connection_string
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Checkpoint Questions

1. What is the difference between `Standard_LRS` and `Standard_GRS` replication?
2. Why should `allow_nested_items_to_be_public = false` always be set on storage accounts?
3. What is the `access_tier` setting on a storage account and when would you set it to `Cool`?
4. What is the difference between Azure Blob Storage and Azure Files? When would you use each?
5. A Managed Disk is created with `create_option = "Empty"`. What other `create_option` values exist and when are they used?
6. What is the role of the `primary_connection_string` output? Why is it sensitive?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `azurerm_storage_account` | Parent resource for all Azure storage types |
| `account_replication_type` | LRS, GRS, ZRS — controls data durability |
| `azurerm_storage_container` | Logical grouping for blobs within a storage account |
| `azurerm_storage_blob` | An individual file uploaded to a container |
| `azurerm_storage_share` | SMB/NFS file share mountable on VMs |
| `azurerm_managed_disk` | Block storage disk (OS or data) for VMs |
| `azurerm_storage_table` | NoSQL key-value store with PartitionKey/RowKey |
| `blob_properties` | Configures versioning, soft delete, and other blob behaviors |
