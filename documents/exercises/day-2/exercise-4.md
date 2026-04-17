# Exercise 4 — Network Security Groups, Dynamic Blocks, and Azure Monitor

**Estimated time:** 55–70 minutes

## Objective

Replace repetitive inline NSG rules with an elegant `dynamic` block driven by a variable. Then integrate Azure Monitor by creating an action group and metric alert that notifies you when VM CPU exceeds a threshold.

---

## Prerequisites

- Day 2 Exercises 1–3 completed
- The Linux VM from Exercise 3 is running (or will be recreated here)

---

## Background: The Problem with Repetition

In Exercise 2 you wrote individual `security_rule` blocks inside the NSG resource. If you have 10 rules, that is 10 blocks with nearly identical structure. When the rule set is driven by configuration (varies per environment), repeating blocks becomes unmaintainable.

**Dynamic blocks** solve this: you define the block template once and Terraform generates one block per item in your collection.

---

## Part 1 — Project Setup (5 min)

```bash
mkdir ~/terraform-exercises/day2-exercise4
cd ~/terraform-exercises/day2-exercise4
touch main.tf variables.tf outputs.tf terraform.tfvars
```

Reuse the network from Exercise 2 via data sources.

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
    key                  = "day2-exercise4.tfstate"
  }
}

provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }
}

data "azurerm_subnet" "web" {
  name                 = "snet-web"
  virtual_network_name = "vnet-training"
  resource_group_name  = "rg-network-training"
}

resource "azurerm_resource_group" "main" {
  name     = "rg-nsg-monitor-training"
  location = "westeurope"
  tags     = var.tags
}
```

---

## Part 2 — The NSG Rules Variable (5 min)

### `variables.tf`

```hcl
variable "tags" {
  type = map(string)
  default = {
    environment = "training"
    managed_by  = "terraform"
  }
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  type      = string
  sensitive = true
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
  description = "List of NSG security rules."
  default = [
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
      name                       = "Allow-SSH"
      priority                   = 120
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
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

variable "alert_email" {
  type        = string
  description = "Email address for Azure Monitor alerts."
  default     = "ops-team@example.com"
}

variable "cpu_alert_threshold" {
  type        = number
  description = "CPU percentage threshold to trigger an alert."
  default     = 80
}
```

### `terraform.tfvars`

```hcl
admin_ssh_public_key = "ssh-rsa AAAA... your-key"
alert_email          = "your-email@example.com"
```

---

## Part 3 — Dynamic NSG Block (15 min)

### Add the NSG with a dynamic block

In `main.tf`:

```hcl
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web-dynamic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
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

**Anatomy of a dynamic block:**

```
dynamic "<block_type>" {           # "security_rule" matches the nested block name
  for_each = <collection>          # Iterate over a list or map
  content {                        # Template for each generated block
    <attribute> = <iterator>.value.<field>
    # The iterator defaults to the block type name ("security_rule")
    # You can rename it: iterator = "rule" → rule.value.name
  }
}
```

### Associate the NSG with the web subnet

```hcl
resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = data.azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}
```

### Add a VM to monitor

```hcl
resource "azurerm_public_ip" "vm" {
  name                = "pip-monitored-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-monitored-vm"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "main" {
  name                  = "vm-monitored"
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  size                  = "Standard_B1s"
  admin_username        = var.admin_username
  tags                  = var.tags

  network_interface_ids = [azurerm_network_interface.vm.id]

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

  boot_diagnostics {}
}
```

Apply and inspect:

```bash
terraform init
terraform apply -auto-approve
```

Verify the NSG rules in the portal: **Resource Groups → rg-nsg-monitor-training → nsg-web-dynamic → Inbound security rules**. You should see all 4 rules exactly as defined in your variable.

### Experiment — add a rule at runtime

Add a new rule to `terraform.tfvars` without touching `main.tf`:

```hcl
nsg_rules = [
  # ... keep existing rules ...
  {
    name                       = "Allow-Custom-App"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }
]
```

Run plan — Terraform will add a single security rule without touching anything else. This is the power of dynamic blocks.

---

## Part 4 — Azure Monitor: Action Group and Metric Alert (20 min)

Azure Monitor lets you collect metrics from Azure resources and trigger actions when thresholds are crossed.

### Step 1 — Create an Action Group

An Action Group is a reusable set of notification targets (email, SMS, webhook, etc.):

```hcl
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-ops-team"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "ops-team"
  tags                = var.tags

  email_receiver {
    name          = "ops-email"
    email_address = var.alert_email
  }
}
```

### Step 2 — Create a CPU Metric Alert

```hcl
resource "azurerm_monitor_metric_alert" "cpu_high" {
  name                = "alert-cpu-high-${azurerm_linux_virtual_machine.main.name}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_linux_virtual_machine.main.id]
  description         = "Alert when VM CPU exceeds ${var.cpu_alert_threshold}%"
  severity            = 2    # 0=Critical, 1=Error, 2=Warning, 3=Informational
  frequency           = "PT5M"   # Evaluate every 5 minutes
  window_size         = "PT15M"  # Over a 15-minute window
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.cpu_alert_threshold
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}
```

**Key parameters:**
- `frequency` — how often the alert evaluates (PT5M = every 5 minutes)
- `window_size` — must be >= `frequency`; the time range over which the metric is aggregated
- `severity` — controls visual display in Azure Monitor; does not affect notification
- `aggregation` — Average, Maximum, Minimum, Count, Total

### Step 3 — Disk metric alert

Add a second alert for disk I/O:

```hcl
resource "azurerm_monitor_metric_alert" "disk_read_high" {
  name                = "alert-disk-high-${azurerm_linux_virtual_machine.main.name}"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_linux_virtual_machine.main.id]
  description         = "Alert when disk read IOPS exceeds the threshold."
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "Disk Read Operations/Sec"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 500
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}
```

Apply everything:

```bash
terraform apply -auto-approve
```

### Step 4 — Verify in Azure Portal

1. Navigate to **Monitor → Alerts → Alert rules**
2. Both alerts should appear under `rg-nsg-monitor-training`
3. Click one alert to inspect its criteria, frequency, and linked action group
4. Navigate to **Monitor → Action groups** and verify your email is listed

### Step 5 — Outputs

### `outputs.tf`

```hcl
output "nsg_id" {
  value = azurerm_network_security_group.web.id
}

output "vm_public_ip" {
  value = azurerm_public_ip.vm.ip_address
}

output "cpu_alert_rule_name" {
  value = azurerm_monitor_metric_alert.cpu_high.name
}

output "action_group_id" {
  value = azurerm_monitor_action_group.ops.id
}
```

---

## Part 5 — Understanding Dynamic Blocks vs Static Blocks

Run this experiment to reinforce the difference:

Open the [Terraform documentation for `azurerm_network_security_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) and locate the `security_rule` block description.

Notice that `security_rule` is listed as an **optional block that can be repeated**. Any block that is repeatable can be replaced with a `dynamic` block.

Dynamic blocks can also be **nested**:

```hcl
dynamic "outer_block" {
  for_each = var.outer_list
  content {
    name = outer_block.value.name

    dynamic "inner_block" {
      for_each = outer_block.value.inner_items
      content {
        setting = inner_block.value
      }
    }
  }
}
```

This pattern is used extensively in Terraform modules for Azure Policy, Firewall rules, and RBAC configurations.

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Checkpoint Questions

1. What is the syntax of a `dynamic` block? What does `for_each` iterate over?
2. What is the default name of the iterator inside a `dynamic` block? How do you change it?
3. What is an Azure Monitor Action Group? Why is it separate from the alert rule?
4. What is the difference between `frequency` and `window_size` in a metric alert?
5. What Azure permission is needed to create and manage Monitor alerts?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `dynamic` block | Generates repeated nested blocks from a collection |
| `for_each` in dynamic | Iterates over a list or map to produce blocks |
| `content {}` | Template block inside `dynamic` |
| Iterator name | Defaults to block type name; override with `iterator` |
| `azurerm_monitor_action_group` | Reusable set of notification targets |
| `azurerm_monitor_metric_alert` | Alert rule based on an Azure resource metric |
| `criteria` block | Defines the metric, operator, and threshold |
| `severity` | Alert severity level (0=Critical, 3=Informational) |
