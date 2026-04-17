# Exercise 2 — Virtual Network and Subnets

**Estimated time:** 50–65 minutes

## Objective

Design and deploy a production-realistic Azure Virtual Network topology with multiple purpose-specific subnets, configure Network Security Groups at the subnet level, and validate the deployment by connecting a lightweight Linux VM.

---

## Prerequisites

- Day 2 Exercise 1 completed (remote backend is configured)
- Service Principal environment variables set (`ARM_*`)
- Clean working directory

---

## Background: Azure Networking Concepts

Before writing code, take 5 minutes to review the topology you will build:

```
Resource Group: rg-network-training
└── Virtual Network: vnet-training (10.0.0.0/16)
    ├── Subnet: snet-web    (10.0.1.0/24)  — Public-facing workloads
    ├── Subnet: snet-app    (10.0.2.0/24)  — Application tier (private)
    ├── Subnet: snet-data   (10.0.3.0/24)  — Database tier (private)
    └── Subnet: snet-mgmt   (10.0.4.0/24)  — Bastion / management
```

Key Azure networking terms:
- **VNet**: An isolated network within Azure. Like a VPC in AWS.
- **Subnet**: A sub-range within the VNet. Resources (VMs, databases) live in subnets.
- **NSG (Network Security Group)**: A stateful firewall applied to a subnet or NIC.
- **Address space**: The CIDR block range claimed by the VNet. Subnets must fit within it.

---

## Part 1 — Project Structure (5 min)

### Step 1 — Create and structure the directory

```bash
mkdir ~/terraform-exercises/day2-exercise2
cd ~/terraform-exercises/day2-exercise2
touch main.tf variables.tf outputs.tf terraform.tfvars
```

Good projects separate concerns across files:
- `main.tf` — resource definitions
- `variables.tf` — all variable declarations
- `outputs.tf` — all output declarations
- `terraform.tfvars` — variable values for this environment

---

## Part 2 — Variables and Provider Setup (5 min)

### `variables.tf`

```hcl
variable "resource_group_name" {
  type        = string
  description = "Name of the resource group."
  default     = "rg-network-training"
}

variable "location" {
  type        = string
  description = "Azure region."
  default     = "westeurope"
}

variable "vnet_name" {
  type        = string
  description = "Name of the Virtual Network."
  default     = "vnet-training"
}

variable "vnet_address_space" {
  type        = string
  description = "Address space for the VNet in CIDR notation."
  default     = "10.0.0.0/16"
}

variable "subnets" {
  type = list(object({
    name   = string
    prefix = string
  }))
  description = "List of subnets to create within the VNet."
  default = [
    { name = "snet-web",  prefix = "10.0.1.0/24" },
    { name = "snet-app",  prefix = "10.0.2.0/24" },
    { name = "snet-data", prefix = "10.0.3.0/24" },
    { name = "snet-mgmt", prefix = "10.0.4.0/24" },
  ]
}

variable "admin_username" {
  type        = string
  description = "Admin username for the test VM."
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for VM authentication."
}

variable "tags" {
  type        = map(string)
  default = {
    environment = "training"
    managed_by  = "terraform"
  }
}
```

### `terraform.tfvars`

```hcl
admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2E... your-public-key-here"
```

To get your SSH public key:
```bash
cat ~/.ssh/id_rsa.pub
# If you don't have one, create it:
ssh-keygen -t rsa -b 4096 -C "training@example.com"
cat ~/.ssh/id_rsa.pub
```

---

## Part 3 — Network Resources (15 min)

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
    storage_account_name = "<YOUR_STORAGE_ACCOUNT_NAME>"
    container_name       = "tfstate"
    key                  = "day2-exercise2.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# ─── Resource Group ────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ─── Virtual Network ──────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# ─── Subnets ──────────────────────────────────────────────
resource "azurerm_subnet" "main" {
  for_each = { for s in var.subnets : s.name => s }

  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [each.value.prefix]
}
```

> **Note:** We use `for_each` instead of `count` here. Each subnet has a unique name (identity). With `for_each`, the key (`snet-web`, `snet-app`, etc.) is stable — removing `snet-app` only removes that one subnet. With `count`, removing item [1] would cascade-destroy subnets [2] and [3].

The `for_each` expression `{ for s in var.subnets : s.name => s }` converts the list into a map keyed by subnet name — exactly what `for_each` expects.

### Initialise and plan

```bash
terraform init
terraform plan
```

Inspect the plan. You should see 6 resources: 1 RG + 1 VNet + 4 subnets. Apply:

```bash
terraform apply -auto-approve
```

---

## Part 4 — Network Security Groups (10 min)

Subnets without an NSG accept all traffic by default. Add basic NSGs:

```hcl
# ─── NSG for Web Subnet ───────────────────────────────────
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTPS"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-All-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.main["snet-web"].id
  network_security_group_id = azurerm_network_security_group.web.id
}

# ─── NSG for Management Subnet ────────────────────────────
resource "azurerm_network_security_group" "mgmt" {
  name                = "nsg-mgmt"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"   # Replace with your IP in production
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id                 = azurerm_subnet.main["snet-mgmt"].id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}
```

Apply:

```bash
terraform apply -auto-approve
```

---

## Part 5 — Deploy a Test VM (15 min)

### Add NIC and VM resources

```hcl
# ─── Public IP for Test VM ────────────────────────────────
resource "azurerm_public_ip" "vm" {
  name                = "pip-vm-test"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ─── Network Interface ────────────────────────────────────
resource "azurerm_network_interface" "vm" {
  name                = "nic-vm-test"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main["snet-mgmt"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ─── Linux VM ─────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "test" {
  name                = "vm-network-test"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_B1s"
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [
    azurerm_network_interface.vm.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Verify the VM is reachable

```bash
# Get the public IP
terraform output vm_public_ip

# SSH into the VM
ssh -i ~/.ssh/id_rsa azureuser@$(terraform output -raw vm_public_ip)

# Inside the VM, verify internet connectivity
curl https://api.ipify.org
exit
```

---

## Part 6 — Outputs

### `outputs.tf`

```hcl
output "resource_group_id" {
  value = azurerm_resource_group.main.id
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID."
  value = { for name, subnet in azurerm_subnet.main : name => subnet.id }
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "vm_private_ip" {
  value = azurerm_network_interface.vm.private_ip_address
}
```

Apply once more to display the outputs:

```bash
terraform apply -auto-approve
terraform output subnet_ids
```

---

## Part 7 — Verify in Azure Portal

1. Go to the Azure Portal → Resource Groups → `rg-network-training`
2. Click on the VNet and review the subnets tab — all 4 subnets should appear
3. Check the NSGs are associated with the web and mgmt subnets
4. Click the VM and observe it is Running in the mgmt subnet

---

## Clean Up

Leave these resources running — you will build on them in Exercise 3. If you need to clean up:

```bash
terraform destroy -auto-approve
```

---

## Checkpoint Questions

1. Why is `for_each` preferred over `count` for subnets?
2. What does `azurerm_subnet_network_security_group_association` do? Why is it a separate resource?
3. What is the difference between an `Inbound` and `Outbound` NSG rule? Which has higher priority — 100 or 4000?
4. Why does the VNet show as depending on the resource group in the Terraform plan?
5. What would happen if you tried to delete the VNet while a VM's NIC was still attached to one of its subnets?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `azurerm_virtual_network` | The top-level IP address space in Azure |
| `azurerm_subnet` | A slice of the VNet CIDR for a specific tier |
| `for_each` with map | Creates per-key resources with stable identity |
| `azurerm_network_security_group` | Stateful firewall rules for a subnet or NIC |
| NSG rule priority | Lower number = higher priority (100 wins over 4000) |
| Public IP + NIC | Required to give a VM connectivity |
| `azurerm_linux_virtual_machine` | IaaS Linux VM on Azure |
