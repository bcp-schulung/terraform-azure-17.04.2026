# Exercise 3 — Virtual Machines: Attributes, Blocks, and Configuration

**Estimated time:** 55–70 minutes

## Objective

Deploy both a Linux and a Windows Virtual Machine in Azure, understanding the exact structure of VM resource blocks — `source_image_reference`, `os_disk`, `admin_ssh_key`, and `boot_diagnostics`. Learn how Terraform decides between an in-place update and a resource replacement when VM attributes change.

---

## Prerequisites

- Day 2 Exercise 2 completed (VNet and subnets already deployed)
- SSH key pair generated (`~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub`)

---

## Background: How Azure VMs Are Composed

An Azure VM is not a single API object. It is composed of multiple linked resources:

```
azurerm_resource_group
└── azurerm_virtual_network
    └── azurerm_subnet (web)
        └── azurerm_network_interface (Linux NIC)
            └── azurerm_linux_virtual_machine
                └── (implicit) managed OS disk
```

Terraform models each of these as separate resource blocks. This gives you fine-grained control — you can replace the NIC without touching the VM, or attach data disks as independent resources.

---

## Part 1 — Project Setup (5 min)

### Step 1 — Reuse the network from Exercise 2

Rather than recreating the network, read it with data sources:

```bash
mkdir ~/terraform-exercises/day2-exercise3
cd ~/terraform-exercises/day2-exercise3
touch main.tf variables.tf outputs.tf terraform.tfvars
```

### `main.tf` — provider and data sources

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
    key                  = "day2-exercise3.tfstate"
  }
}

provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}

data "azurerm_resource_group" "network" {
  name = "rg-network-training"
}

data "azurerm_subnet" "web" {
  name                 = "snet-web"
  virtual_network_name = "vnet-training"
  resource_group_name  = data.azurerm_resource_group.network.name
}

data "azurerm_subnet" "app" {
  name                 = "snet-app"
  virtual_network_name = "vnet-training"
  resource_group_name  = data.azurerm_resource_group.network.name
}
```

The `features { virtual_machine { delete_os_disk_on_deletion = true } }` block tells Terraform to automatically delete the managed disk when the VM is destroyed. Without this, the disk remains as an orphaned resource.

---

## Part 2 — Variable and tfvars Setup (5 min)

### `variables.tf`

```hcl
variable "resource_group_name" {
  type    = string
  default = "rg-vms-training"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "linux_vm_size" {
  type        = string
  description = "VM SKU for the Linux instance."
  default     = "Standard_B1s"
}

variable "windows_vm_size" {
  type        = string
  description = "VM SKU for the Windows instance."
  default     = "Standard_B2s"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  type      = string
  sensitive = true
}

variable "windows_admin_password" {
  type        = string
  sensitive   = true
  description = "Password for the Windows VM admin account. Min 12 chars, upper+lower+number+symbol."
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
admin_ssh_public_key   = "ssh-rsa AAAA... your-key"
windows_admin_password = "P@ssw0rd-Training123!"
```

> **Security note:** In a real project, passwords would come from Azure Key Vault or CI secrets — never stored in `.tfvars` files committed to version control.

---

## Part 3 — Linux VM (20 min)

Add the following to `main.tf`:

```hcl
# ─── Resource Group ──────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─── Linux VM Public IP ───────────────────────────────────
resource "azurerm_public_ip" "linux" {
  name                = "pip-linux-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ─── Linux VM NIC ─────────────────────────────────────────
resource "azurerm_network_interface" "linux" {
  name                = "nic-linux-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.linux.id
  }
}

# ─── Linux Virtual Machine ────────────────────────────────
resource "azurerm_linux_virtual_machine" "main" {
  name                  = "vm-linux-training"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.linux_vm_size
  admin_username        = var.admin_username
  tags                  = var.tags

  # VM must reference one or more NICs
  network_interface_ids = [
    azurerm_network_interface.linux.id,
  ]

  # SSH key authentication (preferred over password auth)
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  # OS Disk — the root volume
  os_disk {
    name                 = "osdisk-linux-training"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  # Image to boot from — Ubuntu 22.04 LTS
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Enable boot diagnostics (stores serial console output in a managed SA)
  boot_diagnostics {}

  # Custom startup script — cloud-init format
  custom_data = base64encode(<<-EOT
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
    echo "<h1>Deployed by Terraform</h1>" > /var/www/html/index.html
  EOT
  )
}
```

### Initialise and apply

```bash
terraform init
terraform apply -auto-approve
```

### Verify

```bash
# Get the public IP
terraform output linux_vm_public_ip

# Confirm nginx is serving traffic
curl http://$(terraform output -raw linux_vm_public_ip)
# Should print: <h1>Deployed by Terraform</h1>

# SSH in to explore
ssh -i ~/.ssh/id_rsa azureuser@$(terraform output -raw linux_vm_public_ip)
systemctl status nginx
exit
```

### Explore image options

To find other Ubuntu/RHEL/SUSE images for `source_image_reference`:

```bash
# List all Ubuntu publishers
az vm image list --publisher Canonical --output table --all | head -20

# Find the latest Ubuntu 22.04 SKU
az vm image list \
  --publisher Canonical \
  --offer "0001-com-ubuntu-server-jammy" \
  --sku "22_04-lts-gen2" \
  --output table --all | tail -5
```

---

## Part 4 — Windows VM (15 min)

Add to `main.tf`:

```hcl
# ─── Windows VM Public IP ─────────────────────────────────
resource "azurerm_public_ip" "windows" {
  name                = "pip-windows-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ─── Windows VM NIC ───────────────────────────────────────
resource "azurerm_network_interface" "windows" {
  name                = "nic-windows-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.app.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.windows.id
  }
}

# ─── Windows Virtual Machine ──────────────────────────────
resource "azurerm_windows_virtual_machine" "main" {
  name                  = "vm-win-training"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = var.windows_vm_size
  admin_username        = var.admin_username
  admin_password        = var.windows_admin_password
  tags                  = var.tags

  network_interface_ids = [
    azurerm_network_interface.windows.id,
  ]

  os_disk {
    name                 = "osdisk-windows-training"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 127
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter-Azure-Edition"
    version   = "latest"
  }

  boot_diagnostics {}

  # Timezone for Windows VMs
  timezone = "W. Europe Standard Time"
}
```

Apply:

```bash
terraform apply -auto-approve
```

> Windows VMs take 5–10 minutes to provision (longer than Linux). While it is provisioning, move on to Part 5.

---

## Part 5 — Understanding Updates vs Replacements (10 min)

Not all changes are equal. Some can be applied in-place; others require Terraform to destroy and recreate the resource. This is called a **replacement** and causes downtime.

### Experiment 1 — In-place update (tags)

Add a tag to the Linux VM:

```hcl
tags = merge(var.tags, { updated = "true" })
```

Run plan:

```bash
terraform plan
```

You should see `~ update in-place`. Apply it:

```bash
terraform apply -auto-approve
```

No downtime, no restart.

### Experiment 2 — Forced replacement (os_disk change)

Change the OS disk type:

```hcl
os_disk {
  caching              = "ReadWrite"
  storage_account_type = "Premium_LRS"   # Changed from Standard_LRS
  disk_size_gb         = 30
}
```

Run plan:

```bash
terraform plan
```

You will see:
```
-/+ resource "azurerm_linux_virtual_machine" "main" {
    # forces replacement
    ~ os_disk {
        ~ storage_account_type = "Standard_LRS" -> "Premium_LRS" # forces replacement
      }
  }
```

The `-/+` symbol means destroy + recreate. This causes downtime. Revert the change before applying:

```hcl
storage_account_type = "Standard_LRS"
```

### In-place vs replacement reference

| Change | Result |
|---|---|
| Tags | In-place update |
| VM size (`size`) | In-place (deallocate and resize) |
| OS disk type | **Replacement** (destroy + recreate) |
| Source image | **Replacement** |
| NIC attachment | **Replacement** |
| Admin SSH key | **Replacement** |

---

## Part 6 — Outputs

### `outputs.tf`

```hcl
output "linux_vm_id" {
  value = azurerm_linux_virtual_machine.main.id
}

output "linux_vm_public_ip" {
  value = azurerm_public_ip.linux.ip_address
}

output "linux_vm_private_ip" {
  value = azurerm_network_interface.linux.private_ip_address
}

output "windows_vm_id" {
  value = azurerm_windows_virtual_machine.main.id
}

output "windows_vm_public_ip" {
  value = azurerm_public_ip.windows.ip_address
}
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

The `delete_os_disk_on_deletion = true` provider feature ensures managed disks are cleaned up automatically.

---

## Checkpoint Questions

1. What is the role of `source_image_reference` in a VM configuration?
2. Why does the `admin_ssh_key` block only apply to `azurerm_linux_virtual_machine`?
3. What is the difference between `Standard_LRS`, `Premium_LRS`, and `UltraSSD_LRS` OS disk types?
4. What does `custom_data = base64encode(...)` do? At what point in the VM lifecycle does the script run?
5. How do you connect to a Windows VM deployed by Terraform? What port must be open in the NSG?
6. What does `-/+` in a Terraform plan output mean?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `azurerm_linux_virtual_machine` | Linux IaaS VM resource |
| `azurerm_windows_virtual_machine` | Windows IaaS VM resource |
| `source_image_reference` | Specifies the Marketplace image (publisher/offer/sku/version) |
| `os_disk` block | Configures the root volume type, size, and caching |
| `admin_ssh_key` | SSH public key authentication for Linux VMs |
| `custom_data` | Cloud-init script run on first boot (must be base64-encoded) |
| `boot_diagnostics` | Stores serial console output for troubleshooting |
| In-place update | Resource is modified without destroy/recreate |
| Forced replacement | Certain attribute changes require destroy + recreate |
