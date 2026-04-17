# Exercise 2 — Dependencies, Count, and Multiple Variable Files

**Estimated time:** 45–60 minutes

## Objective

Learn how Terraform models relationships between resources, use `count` to create multiple instances from a single block, and manage environment-specific configuration using multiple `.tfvars` files.

---

## Prerequisites

- Exercise 1 completed — you have Terraform installed and Azure CLI authenticated
- A clean working directory for this exercise

---

## Part 1 — Implicit Dependencies (10 min)

### Step 1 — Create the working directory

```bash
mkdir ~/terraform-exercises/day1-exercise2
cd ~/terraform-exercises/day1-exercise2
```

### Step 2 — Write the configuration

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
  name     = "rg-deps-training"
  location = "westeurope"
  tags = { managed_by = "terraform" }
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-training"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}
```

**Key observation:** The virtual network references the resource group using `azurerm_resource_group.main.location` and `azurerm_resource_group.main.name`. This creates an **implicit dependency** — Terraform automatically knows the VNet must be created *after* the resource group.

### Step 3 — Visualise the dependency graph

Initialise and then generate the dependency graph:

```bash
terraform init
terraform graph
```

The output is in DOT language. If you have Graphviz installed (`brew install graphviz`), you can render it:

```bash
terraform graph | dot -Tsvg > graph.svg
open graph.svg
```

You will see a directed acyclic graph (DAG) with an arrow from `azurerm_virtual_network.main` pointing to `azurerm_resource_group.main` — confirming the dependency.

### Step 4 — Plan and apply

```bash
terraform plan
terraform apply -auto-approve
```

Notice that Terraform creates the resource group **first**, then the VNet. It respects the dependency order automatically.

---

## Part 2 — Explicit `depends_on` (5 min)

Sometimes you need to express a dependency that Terraform cannot infer from attribute references. This is rare but important to understand.

Add a subnet to `main.tf`:

```hcl
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.255.0/27"]

  depends_on = [azurerm_virtual_network.main]
}
```

Even though the reference to `azurerm_virtual_network.main.name` already creates an implicit dependency, the `depends_on` line makes the relationship explicit and visible at a glance. It is most useful when a resource depends on a **side effect** (e.g., a role assignment completing before a VM can read a Key Vault secret).

Run plan and apply again:

```bash
terraform plan
terraform apply -auto-approve
```

Terraform will add the subnet without touching the resource group or VNet (they already exist in state).

---

## Part 3 — Using `count` to Create Multiple Subnets (15 min)

### Step 1 — Add a count-based subnet

Add the following to `main.tf`, keeping the bastion subnet you already created:

```hcl
variable "subnet_count" {
  type    = number
  default = 3
}

resource "azurerm_subnet" "app" {
  count                = var.subnet_count
  name                 = "subnet-app-${count.index}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.${count.index}.0/24"]
}
```

**What this does:**
- `count = var.subnet_count` tells Terraform to create 3 instances of this resource.
- `count.index` is 0, 1, or 2 for each instance.
- The name becomes `subnet-app-0`, `subnet-app-1`, `subnet-app-2`.
- The address ranges become `10.0.0.0/24`, `10.0.1.0/24`, `10.0.2.0/24`.

### Step 2 — Plan and inspect the output

```bash
terraform plan
```

Notice how Terraform lists each instance separately:
```
  + resource "azurerm_subnet" "app" {
      ...
    }
  + resource "azurerm_subnet" "app[1]" {
      ...
    }
  + resource "azurerm_subnet" "app[2]" {
      ...
    }
```

Apply the changes:

```bash
terraform apply -auto-approve
```

### Step 3 — Reference a specific instance by index

Add an output to demonstrate index-based references:

```hcl
output "first_app_subnet_id" {
  value = azurerm_subnet.app[0].id
}

output "all_app_subnet_ids" {
  value = [for s in azurerm_subnet.app : s.id]
}
```

Run apply again and observe the outputs:

```bash
terraform apply -auto-approve
terraform output all_app_subnet_ids
```

### Step 4 — The `count` pitfall — understand it now

Change `subnet_count` to `2` and run plan:

```bash
terraform plan -var="subnet_count=2"
```

Terraform wants to **destroy** `subnet-app-2`. This is expected. Now imagine you had 10 subnets and removed `subnet-app-4` from the middle — Terraform would need to shift indices and destroy/recreate every subnet above index 4.

This is why `for_each` (using a map or set) is preferred over `count` for resources where identity matters. `count` is fine for identical, interchangeable resources.

---

## Part 4 — Multiple Variable Files for Environments (15 min)

### Step 1 — Create environment variable files

Create `dev.tfvars`:

```hcl
subnet_count         = 2
vnet_address_space   = "10.0.0.0/16"
environment          = "dev"
```

Create `prod.tfvars`:

```hcl
subnet_count         = 4
vnet_address_space   = "10.1.0.0/16"
environment          = "prod"
```

### Step 2 — Update `main.tf` to use the new variables

Add variable declarations at the top of `main.tf` (after the provider block):

```hcl
variable "vnet_address_space" {
  type    = string
  default = "10.0.0.0/16"
}

variable "environment" {
  type    = string
  default = "dev"
}
```

Update the resource group and VNet to use variables:

```hcl
resource "azurerm_resource_group" "main" {
  name     = "rg-deps-${var.environment}"
  location = "westeurope"
  tags = {
    managed_by  = "terraform"
    environment = var.environment
  }
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.environment}"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}
```

### Step 3 — Destroy the existing dev environment

First destroy what you have:

```bash
terraform destroy -auto-approve
```

### Step 4 — Apply the dev environment

```bash
terraform apply -var-file="dev.tfvars" -auto-approve
```

Inspect what was created — resource group named `rg-deps-dev`, VNet `vnet-dev`, 2 subnets.

Check the state to see how many subnets exist:

```bash
terraform state list
```

### Step 5 — Destroy and apply the prod environment

```bash
terraform destroy -var-file="dev.tfvars" -auto-approve
terraform apply -var-file="prod.tfvars" -auto-approve
```

Now you should have `rg-deps-prod`, `vnet-prod`, and 4 subnets (`10.1.0.0/24` through `10.1.3.0/24`).

> In a real team workflow, each environment would have its own Terraform workspace or its own state file (in a separate directory or backend path). You would never share a state file between dev and prod.

---

## Part 5 — Clean Up

```bash
terraform destroy -var-file="prod.tfvars" -auto-approve
```

---

## Checkpoint Questions

1. What is the difference between an implicit and explicit dependency in Terraform?
2. When would you use `depends_on`? Give a realistic Azure example.
3. What is `count.index` and how is it used?
4. What is the drawback of using `count` when resources have unique identities? What is the alternative?
5. What is the purpose of having separate `.tfvars` files per environment?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| Implicit dependency | Created automatically when one resource references another's attribute |
| Explicit `depends_on` | Used when a dependency cannot be expressed through attribute references |
| `count` | Creates N identical (or near-identical) instances of a resource |
| `count.index` | Zero-based index available in count-based resource blocks |
| `.tfvars` files | External variable definitions; applied with `-var-file` flag |
| Multiple environments | Achieved by passing different `.tfvars` files at apply time |
