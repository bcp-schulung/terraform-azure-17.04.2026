# Exercise 4 — Building a Reusable Terraform Module

**Estimated time:** 60–75 minutes

## Objective

Refactor infrastructure from the previous exercises into a structured, reusable Terraform module. By the end you will have a `modules/network/` child module with clean inputs and outputs, called twice from a root configuration to deploy two separate VNets — demonstrating how one module definition can create multiple instances.

---

## Prerequisites

- All previous exercises completed
- Remote backend configured

---

## Background: Why Modules?

As your infrastructure grows, copy-pasting Terraform blocks across environments creates drift and maintenance burden. Modules solve this by encapsulating a set of resources behind a clean interface (inputs/outputs), just like a function in programming.

**Benefits of modules:**
- **Reusability** — define once, instantiate many times
- **Encapsulation** — callers see inputs/outputs, not the internal complexity
- **Consistency** — all environments use the same, tested code
- **Collaboration** — teams publish and consume modules like shared libraries

**A module is just a directory with `.tf` files.** Terraform automatically treats any directory containing `.tf` files as a module.

---

## Part 1 — Understand Module Structure (5 min)

A well-structured module contains exactly three files:

```
modules/network/
├── main.tf        # Resource definitions
├── variables.tf   # Input variable declarations
└── outputs.tf     # Output value declarations
```

The root module (`main.tf` in your working directory) calls child modules using `module` blocks.

```
day3-exercise4/            ← Root module
├── main.tf                ← Calls child modules
├── variables.tf
├── outputs.tf
└── modules/
    └── network/           ← Child module
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## Part 2 — Create the Root Project (5 min)

```bash
mkdir -p ~/terraform-exercises/day3-exercise4/modules/network
cd ~/terraform-exercises/day3-exercise4
touch main.tf variables.tf outputs.tf terraform.tfvars
touch modules/network/main.tf modules/network/variables.tf modules/network/outputs.tf
```

---

## Part 3 — Write the Network Module (20 min)

### `modules/network/variables.tf`

```hcl
variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy the VNet into."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "vnet_name" {
  type        = string
  description = "Name of the Virtual Network."
}

variable "address_space" {
  type        = string
  description = "Address space for the VNet in CIDR notation (e.g., '10.0.0.0/16')."
}

variable "subnets" {
  type = list(object({
    name   = string
    prefix = string
  }))
  description = "List of subnets to create."
}

variable "nsg_rules" {
  type = list(object({
    name                       = string
    priority                   = number
    direction                  = string
    access                     = string
    protocol                   = string
    source_port_range          = string
    destination_port_range     = string
    source_address_prefix      = string
    destination_address_prefix = string
  }))
  description = "Security rules for the default NSG."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to all resources."
  default     = {}
}
```

### `modules/network/main.tf`

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

# Virtual Network
resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  address_space       = [var.address_space]
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Subnets
resource "azurerm_subnet" "this" {
  for_each = { for s in var.subnets : s.name => s }

  name                 = each.value.name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.prefix]
}

# Default NSG (only created when nsg_rules is non-empty)
resource "azurerm_network_security_group" "this" {
  count               = length(var.nsg_rules) > 0 ? 1 : 0
  name                = "nsg-${var.vnet_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  dynamic "security_rule" {
    for_each = var.nsg_rules
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = security_rule.value.direction
      access                     = security_rule.value.access
      protocol                   = security_rule.value.protocol
      source_port_range          = security_rule.value.source_port_range
      destination_port_range     = security_rule.value.destination_port_range
      source_address_prefix      = security_rule.value.source_address_prefix
      destination_address_prefix = security_rule.value.destination_address_prefix
    }
  }
}
```

### `modules/network/outputs.tf`

```hcl
output "vnet_id" {
  description = "The Azure resource ID of the Virtual Network."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "The name of the Virtual Network."
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID."
  value       = { for name, s in azurerm_subnet.this : name => s.id }
}

output "nsg_id" {
  description = "The ID of the NSG (null if no rules were defined)."
  value       = length(azurerm_network_security_group.this) > 0 ? azurerm_network_security_group.this[0].id : null
}
```

---

## Part 4 — Write the Root Module (15 min)

### `variables.tf`

```hcl
variable "location" {
  type    = string
  default = "westeurope"
}

variable "tags" {
  type = map(string)
  default = {
    environment = "training"
    managed_by  = "terraform"
  }
}
```

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
    key                  = "day3-exercise4.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# ─── Resource Groups ─────────────────────────────────────
resource "azurerm_resource_group" "dev" {
  name     = "rg-module-dev"
  location = var.location
  tags     = merge(var.tags, { environment = "dev" })
}

resource "azurerm_resource_group" "prod" {
  name     = "rg-module-prod"
  location = var.location
  tags     = merge(var.tags, { environment = "prod" })
}

# ─── Module Call 1: Dev VNet ─────────────────────────────
module "dev_network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.dev.name
  location            = azurerm_resource_group.dev.location
  vnet_name           = "vnet-dev"
  address_space       = "10.0.0.0/16"
  tags                = merge(var.tags, { environment = "dev" })

  subnets = [
    { name = "snet-web",  prefix = "10.0.1.0/24" },
    { name = "snet-app",  prefix = "10.0.2.0/24" },
  ]

  nsg_rules = [
    {
      name                       = "Allow-HTTP"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      name                       = "Allow-SSH"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
  ]
}

# ─── Module Call 2: Prod VNet ────────────────────────────
module "prod_network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  vnet_name           = "vnet-prod"
  address_space       = "10.1.0.0/16"
  tags                = merge(var.tags, { environment = "prod" })

  subnets = [
    { name = "snet-web",  prefix = "10.1.1.0/24" },
    { name = "snet-app",  prefix = "10.1.2.0/24" },
    { name = "snet-data", prefix = "10.1.3.0/24" },
    { name = "snet-mgmt", prefix = "10.1.4.0/24" },
  ]

  # Prod has stricter NSG rules
  nsg_rules = [
    {
      name                       = "Allow-HTTP"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      name                       = "Allow-HTTPS"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "443"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
    {
      name                       = "Deny-All-Inbound"
      priority                   = 4000
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    },
  ]
}
```

### `outputs.tf`

```hcl
output "dev_vnet_id" {
  value = module.dev_network.vnet_id
}

output "dev_subnet_ids" {
  value = module.dev_network.subnet_ids
}

output "prod_vnet_id" {
  value = module.prod_network.vnet_id
}

output "prod_subnet_ids" {
  value = module.prod_network.subnet_ids
}
```

---

## Part 5 — Plan, Apply, and Inspect (10 min)

```bash
terraform init
terraform plan
```

Study the plan output carefully. Notice:
- Resources are prefixed with `module.dev_network.*` and `module.prod_network.*`
- Terraform shows 8 resources from the dev module and 11 from prod (2 RGs + subnets + VNets + NSGs)
- The module boundary is transparent — you see all resources clearly

Apply:

```bash
terraform apply -auto-approve
```

Inspect the state tree:

```bash
terraform state list
```

Output:
```
azurerm_resource_group.dev
azurerm_resource_group.prod
module.dev_network.azurerm_network_security_group.this[0]
module.dev_network.azurerm_subnet.this["snet-app"]
module.dev_network.azurerm_subnet.this["snet-web"]
module.dev_network.azurerm_virtual_network.this
module.prod_network.azurerm_network_security_group.this[0]
module.prod_network.azurerm_subnet.this["snet-app"]
module.prod_network.azurerm_subnet.this["snet-data"]
module.prod_network.azurerm_subnet.this["snet-mgmt"]
module.prod_network.azurerm_subnet.this["snet-web"]
module.prod_network.azurerm_virtual_network.this
```

Read module outputs:

```bash
terraform output prod_subnet_ids
```

---

## Part 6 — Explore a Public Registry Module (10 min)

The Terraform Registry (`registry.terraform.io`) hosts thousands of community and verified modules. Let's use the official Azure VNet module as a learning reference.

```bash
# Browse the module in a browser or inspect the source
open "https://registry.terraform.io/modules/Azure/network/azurerm/latest"
```

Add a registry module call to `main.tf` to see how it compares:

```hcl
# This uses the official Azure VNet module from the registry
module "registry_vnet" {
  source  = "Azure/network/azurerm"
  version = "~> 5.0"

  resource_group_name = azurerm_resource_group.dev.name
  vnet_name           = "vnet-from-registry"
  address_spaces      = ["10.2.0.0/16"]

  subnet_prefixes = ["10.2.1.0/24", "10.2.2.0/24"]
  subnet_names    = ["web", "app"]

  tags = var.tags
}
```

Run init to download the registry module:

```bash
terraform init
terraform plan
```

Notice how `terraform init` downloads the registry module into `.terraform/modules/`. Inspect its source:

```bash
cat .terraform/modules/registry_vnet/main.tf | head -60
```

Compare the registry module's structure with yours. Real-world modules often have 300+ lines and handle many edge cases.

> For production, always pin modules to a specific version (`version = "5.1.0"`) — never use unpinned versions.

---

## Part 7 — Module Best Practices

Review these patterns in your module:

### 1 — No provider block in child modules

Child modules should **never** declare a `provider` block. They inherit the provider from the root module. This allows the same module to be called with providers configured for different subscriptions.

### 2 — Document all inputs with descriptions

Every `variable` in a module should have a `description` and (where appropriate) a `type` constraint. Module consumers rely on this to understand what to pass.

### 3 — Don't hard-code locations or naming

All location, naming, and configuration decisions belong in the root module as variables. The child module should accept them as inputs.

### 4 — Outputs should expose what callers need

Think about what downstream resources need from your module. A network module should expose `vnet_id` and `subnet_ids` because other modules (VMs, databases) will need to reference them.

### 5 — Use `this` as the resource name inside modules

When a module creates exactly one of a resource type, name it `this` (e.g., `azurerm_virtual_network.this`). This is a widely adopted convention.

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Checkpoint Questions

1. What is the difference between a root module and a child module?
2. Why should a child module never declare a `provider` block?
3. How does Terraform distinguish between two module instances with the same source?
4. What command downloads module dependencies from the Registry?
5. How would you pass a module's output to another module? Show the syntax.
6. When would you use a registry module vs writing your own?

---

## Final Course Reflection

You have now completed all 12 exercises across 3 days. Take 5 minutes to review what you have built:

| Day | Topic | Key Skills |
|---|---|---|
| 1 | Foundations & Variables | CLI workflow, types, outputs, data sources, lifecycle |
| 2 | Azure Networking & VMs | VNets, subnets, NSGs, Linux/Windows VMs, dynamic blocks, monitoring |
| 3 | Scaling, Storage & Modules | VMSS, LB, Storage Account, databases, DNS, reusable modules |

At this point you should be able to:
- Provision production-grade Azure infrastructure using Terraform
- Structure configs using variables, outputs, and data sources
- Use remote state and Service Principals for team workflows
- Build and consume reusable modules
- Apply security best practices (NSGs, private endpoints, TLS, sensitive outputs)

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| Module | A directory of `.tf` files that encapsulates a set of resources |
| Root module | The top-level directory where `terraform` commands are run |
| Child module | A module called from another module via a `module` block |
| `source` argument | Points to the module location (local path, registry, or Git URL) |
| `version` argument | Pins the registry module version |
| Module outputs | Expose internal values for callers to consume |
| Module inputs | Variables declared in `variables.tf` of the child module |
| Registry module | A community or verified module hosted on `registry.terraform.io` |
| `.terraform/modules/` | Local cache of downloaded registry modules |
