# Exercise 1 — Virtual Machine Scale Sets and Azure Load Balancer

**Estimated time:** 60–75 minutes

## Objective

Deploy an Azure Virtual Machine Scale Set (VMSS) with a `cloud-init` startup script behind a Standard Azure Load Balancer. Validate that traffic distributes across instances, then scale out and back in using only a variable change.

---

## Prerequisites

- Day 1 and Day 2 exercises completed
- Remote backend configured
- SSH key pair available
- Service Principal environment variables set

---

## Background: When to Use VMSS vs Individual VMs

| Scenario | Use |
|---|---|
| Single workload, fixed capacity | `azurerm_linux_virtual_machine` |
| Horizontally scalable, stateless workload | `azurerm_linux_virtual_machine_scale_set` |
| Auto-scaling based on metrics | VMSS with autoscale profile |
| Spot/burst capacity | VMSS with Spot priority |

A VMSS manages a group of identically-configured VMs. You define the template once and Azure creates N instances. Scaling is done by changing the count — no manual VM management.

---

## Part 1 — Project Setup (5 min)

```bash
mkdir ~/terraform-exercises/day3-exercise1
cd ~/terraform-exercises/day3-exercise1
touch main.tf variables.tf outputs.tf terraform.tfvars
```

---

## Part 2 — Variables (5 min)

### `variables.tf`

```hcl
variable "resource_group_name" {
  type    = string
  default = "rg-vmss-lb-training"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "instance_count" {
  type        = number
  description = "Number of VMSS instances."
  default     = 2

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 10
    error_message = "instance_count must be between 1 and 10."
  }
}

variable "vm_size" {
  type    = string
  default = "Standard_B1s"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  type      = string
  sensitive = true
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
admin_ssh_public_key = "ssh-rsa AAAA... your-key"
instance_count       = 2
```

---

## Part 3 — Networking for the Scale Set (10 min)

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
    key                  = "day3-exercise1.tfstate"
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

# ─── VNet and Subnet ─────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "vnet-vmss"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_subnet" "vmss" {
  name                 = "snet-vmss"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
}
```

---

## Part 4 — Azure Load Balancer (15 min)

An Azure Standard Load Balancer distributes incoming TCP/UDP traffic across the VMSS instances. It has four main components:

1. **Public IP** — the frontend address the internet connects to
2. **Frontend IP Configuration** — associates the public IP with the LB
3. **Backend Pool** — the VMSS instances that receive traffic
4. **Health Probe** — checks if each instance is healthy
5. **Load Balancing Rule** — maps frontend port to backend port

```hcl
# ─── Public IP for Load Balancer ─────────────────────────
resource "azurerm_public_ip" "lb" {
  name                = "pip-lb-vmss"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ─── Load Balancer ────────────────────────────────────────
resource "azurerm_lb" "main" {
  name                = "lb-vmss-training"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "PublicFrontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

# ─── Backend Pool ─────────────────────────────────────────
resource "azurerm_lb_backend_address_pool" "main" {
  name            = "bap-vmss"
  loadbalancer_id = azurerm_lb.main.id
}

# ─── Health Probe (HTTP on port 80) ───────────────────────
resource "azurerm_lb_probe" "http" {
  name            = "probe-http"
  loadbalancer_id = azurerm_lb.main.id
  protocol        = "Http"
  port            = 80
  request_path    = "/"
  interval_in_seconds = 5
  number_of_probes    = 2
}

# ─── Load Balancing Rule ──────────────────────────────────
resource "azurerm_lb_rule" "http" {
  name                           = "lbrule-http"
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicFrontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main.id]
  probe_id                       = azurerm_lb_probe.http.id
  disable_outbound_snat          = true
}

# ─── Outbound rule for VMSS internet access ──────────────
resource "azurerm_lb_outbound_rule" "main" {
  name                    = "outbound-rule"
  loadbalancer_id         = azurerm_lb.main.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main.id

  frontend_ip_configuration {
    name = "PublicFrontend"
  }
}
```

> **Note:** `disable_outbound_snat = true` on the inbound rule is required when you also define an outbound rule. This gives separate control over inbound and outbound traffic.

---

## Part 5 — Virtual Machine Scale Set (15 min)

```hcl
# ─── NSG for VMSS ────────────────────────────────────────
resource "azurerm_network_security_group" "vmss" {
  name                = "nsg-vmss"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-LB-Probes"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

# ─── VMSS ─────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine_scale_set" "main" {
  name                = "vmss-training"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = var.vm_size
  instances           = var.instance_count
  admin_username      = var.admin_username
  upgrade_mode        = "Automatic"
  tags                = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "nic-vmss"
    primary = true

    network_security_group_id = azurerm_network_security_group.vmss.id

    ip_configuration {
      name                                   = "internal"
      primary                                = true
      subnet_id                              = azurerm_subnet.vmss.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.main.id]
    }
  }

  # Install nginx on first boot using cloud-init
  custom_data = base64encode(<<-EOT
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
    HOSTNAME=$(hostname)
    echo "<h1>Hello from VMSS instance: $HOSTNAME</h1>" > /var/www/html/index.html
  EOT
  )

  boot_diagnostics {}
}
```

Apply:

```bash
terraform init
terraform apply -auto-approve
```

The VMSS instances take 3–5 minutes to boot and run the cloud-init script.

---

## Part 6 — Validate Load Balancing (10 min)

### Step 1 — Get the LB public IP

```bash
terraform output lb_public_ip
```

### Step 2 — Test HTTP traffic

Wait until nginx is running (about 3–5 minutes after apply), then:

```bash
LB_IP=$(terraform output -raw lb_public_ip)

# Send 10 requests and observe which instance responds each time
for i in $(seq 1 10); do
  curl -s "http://$LB_IP" | grep -o "instance:.*"
done
```

You should see responses from different hostnames — confirming the load balancer is distributing traffic. Azure LB uses a 5-tuple hash (source IP, source port, destination IP, destination port, protocol) so consecutive requests from the same client may go to the same instance. Use different source ports or a different client to see both instances.

### Step 3 — Scale out to 3 instances

Change `instance_count` in `terraform.tfvars`:

```hcl
instance_count = 3
```

Apply:

```bash
terraform apply -auto-approve
```

Watch the VMSS in the Azure Portal: **Resource Groups → rg-vmss-lb-training → vmss-training → Instances**. A third instance will appear.

After it boots, run the curl loop again — you should eventually see the third hostname appear in responses.

### Step 4 — Scale back to 2

```hcl
instance_count = 2
```

```bash
terraform apply -auto-approve
```

Terraform terminates one instance. The remaining two continue serving traffic without interruption (the LB detects the instance is gone via the health probe and stops sending traffic to it).

---

## Part 7 — Outputs

### `outputs.tf`

```hcl
output "lb_public_ip" {
  value = azurerm_public_ip.lb.ip_address
}

output "lb_id" {
  value = azurerm_lb.main.id
}

output "vmss_id" {
  value = azurerm_linux_virtual_machine_scale_set.main.id
}

output "vmss_instance_count" {
  value = azurerm_linux_virtual_machine_scale_set.main.instances
}
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

---

## Checkpoint Questions

1. What is the difference between a VMSS and multiple individually defined VMs in Terraform?
2. What is the purpose of the health probe on the load balancer?
3. Why do we set `disable_outbound_snat = true` on the inbound LB rule?
4. What does `upgrade_mode = "Automatic"` mean on a VMSS?
5. How would you configure auto-scaling (scale out when CPU > 70%) on this VMSS?
6. What happens to traffic during a scale-in event? Does the LB stop sending traffic to an instance before it's terminated?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `azurerm_linux_virtual_machine_scale_set` | Manages a group of identically configured VMs |
| `instances` | Desired number of VM instances; change to scale |
| `azurerm_lb` | Azure Load Balancer resource |
| Frontend IP configuration | Associates the LB with a public IP |
| Backend pool | The group of VMs that receive load-balanced traffic |
| Health probe | Continuously checks each instance; unhealthy instances are removed from rotation |
| Load balancing rule | Maps frontend port to backend port |
| `custom_data` | Cloud-init script that runs on VMSS instance first boot |
| `upgrade_mode` | How config changes are applied to running instances |
