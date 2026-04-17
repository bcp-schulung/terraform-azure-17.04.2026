# Exercise 3 — Databases: MySQL, Azure SQL, and DNS Management

**Estimated time:** 60–75 minutes

## Objective

Deploy two types of Azure managed databases — MySQL Flexible Server and Azure SQL (MSSQL) — using Terraform. Then create an Azure DNS zone and manage A and CNAME records to simulate production DNS management.

---

## Prerequisites

- Day 2 exercises completed
- Remote backend configured
- Service Principal environment variables set

---

## Background: Managed Databases in Azure

| Service | Terraform Resource | Notes |
|---|---|---|
| MySQL Flexible Server | `azurerm_mysql_flexible_server` | Latest generation, replaces Single Server |
| Azure SQL | `azurerm_mssql_server` + `azurerm_mssql_database` | Microsoft's fully managed SQL Server |
| PostgreSQL Flexible | `azurerm_postgresql_flexible_server` | Popular for open-source workloads |
| Cosmos DB | `azurerm_cosmosdb_account` | Multi-model NoSQL (not covered here) |

Key pre-planning decisions for any database:
1. **SKU / Compute tier** — burstable, general purpose, or memory optimised
2. **Storage size** — provisioned in GB; can grow but typically not shrink
3. **Backup retention** — days to retain automated backups
4. **Networking** — public endpoint with firewall rules, or private endpoint (VNet integration)
5. **High availability** — zone-redundant standby replica

---

## Part 1 — Project Setup (5 min)

```bash
mkdir ~/terraform-exercises/day3-exercise3
cd ~/terraform-exercises/day3-exercise3
touch main.tf variables.tf outputs.tf terraform.tfvars
```

---

## Part 2 — Variables (5 min)

### `variables.tf`

```hcl
variable "resource_group_name" {
  type    = string
  default = "rg-databases-training"
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "mysql_server_name" {
  type        = string
  description = "Must be globally unique."
}

variable "mysql_admin_username" {
  type    = string
  default = "mysqladmin"
}

variable "mysql_admin_password" {
  type      = string
  sensitive = true
}

variable "mysql_sku" {
  type    = string
  default = "B_Standard_B1ms"   # Burstable, 1 vCore, 2 GB RAM
}

variable "mysql_storage_gb" {
  type    = number
  default = 20
}

variable "mssql_server_name" {
  type        = string
  description = "Must be globally unique."
}

variable "mssql_admin_username" {
  type    = string
  default = "sqladmin"
}

variable "mssql_admin_password" {
  type      = string
  sensitive = true
}

variable "dns_zone_name" {
  type    = string
  default = "example-training.com"
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
# Generate unique names:  echo "mysql-train-$(openssl rand -hex 4)"
mysql_server_name    = "mysql-train-<unique>"
mysql_admin_password = "MySQLPassw0rd-Training!"

mssql_server_name    = "mssql-train-<unique>"
mssql_admin_password = "MSSQLPassw0rd-Training@1"
```

> Password requirements vary by service. MySQL requires: 8+ chars, uppercase, lowercase, number, symbol. Azure SQL: 8–128 chars, 3 of 4 categories.

---

## Part 3 — Provider and Resource Group (5 min)

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
    key                  = "day3-exercise3.tfstate"
  }
}

provider "azurerm" {
  features {}
}

# Get current client's public IP for firewall rules
data "http" "my_ip" {
  url = "https://api.ipify.org"
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}
```

The `http` provider (data source) queries a public IP service so we can add your IP to the database firewall automatically. Add it to `required_providers`:

```hcl
    hashicorp/http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
```

---

## Part 4 — MySQL Flexible Server (20 min)

```hcl
# ─── MySQL Flexible Server ───────────────────────────────
resource "azurerm_mysql_flexible_server" "main" {
  name                   = var.mysql_server_name
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  administrator_login    = var.mysql_admin_username
  administrator_password = var.mysql_admin_password
  sku_name               = var.mysql_sku
  version                = "8.0.21"
  tags                   = var.tags

  storage {
    size_gb           = var.mysql_storage_gb
    auto_grow_enabled = true
  }

  backup {
    backup_retention_days        = 7
    geo_redundant_backup_enabled = false
  }

  # For training: disable high availability to avoid extra cost
  # high_availability {
  #   mode = "ZoneRedundant"
  # }
}

# ─── MySQL Firewall Rule ─────────────────────────────────
resource "azurerm_mysql_flexible_server_firewall_rule" "allow_my_ip" {
  name                = "AllowMyIP"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main.name
  start_ip_address    = trimspace(data.http.my_ip.response_body)
  end_ip_address      = trimspace(data.http.my_ip.response_body)
}

resource "azurerm_mysql_flexible_server_firewall_rule" "allow_azure_services" {
  name                = "AllowAzureServices"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# ─── MySQL Database ───────────────────────────────────────
resource "azurerm_mysql_flexible_database" "app" {
  name                = "appdb"
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}
```

Apply (MySQL provisioning takes 5–10 minutes):

```bash
terraform init
terraform apply -auto-approve
```

### Connect to MySQL

```bash
MYSQL_HOST=$(terraform output -raw mysql_fqdn)
mysql -h "$MYSQL_HOST" -u "${var.mysql_admin_username}" -p"${var.mysql_admin_password}" --ssl-mode=REQUIRED

# Inside MySQL:
SHOW DATABASES;
USE appdb;
CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100), email VARCHAR(100));
INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
SELECT * FROM users;
EXIT;
```

If `mysql` client is not installed: `brew install mysql-client` (macOS) or `apt-get install mysql-client` (Linux).

---

## Part 5 — Azure SQL (MSSQL) (15 min)

Azure SQL (managed Microsoft SQL Server) uses a two-resource model: a Server (logical container) and one or more Databases.

```hcl
# ─── Azure SQL Server ─────────────────────────────────────
resource "azurerm_mssql_server" "main" {
  name                         = var.mssql_server_name
  resource_group_name          = azurerm_resource_group.main.name
  location                     = azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = var.mssql_admin_username
  administrator_login_password = var.mssql_admin_password
  minimum_tls_version          = "1.2"
  tags                         = var.tags
}

# ─── Azure SQL Firewall Rule ──────────────────────────────
resource "azurerm_mssql_firewall_rule" "allow_my_ip" {
  name             = "AllowMyIP"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = trimspace(data.http.my_ip.response_body)
  end_ip_address   = trimspace(data.http.my_ip.response_body)
}

resource "azurerm_mssql_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# ─── Azure SQL Database ───────────────────────────────────
resource "azurerm_mssql_database" "app" {
  name         = "appdb"
  server_id    = azurerm_mssql_server.main.id
  collation    = "SQL_Latin1_General_CP1_CI_AS"
  license_type = "LicenseIncluded"
  sku_name     = "Basic"    # Low-cost tier for training; use S1/S2 for production
  max_size_gb  = 1
  tags         = var.tags
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Connect to Azure SQL

Using `sqlcmd` or Azure Data Studio:

```bash
# Install sqlcmd (macOS)
brew install sqlcmd

MSSQL_HOST=$(terraform output -raw mssql_fqdn)
sqlcmd -S "$MSSQL_HOST" -U "${var.mssql_admin_username}" -P "${var.mssql_admin_password}" -Q "SELECT @@VERSION"
```

Or connect via the **Azure Portal → SQL databases → appdb → Query editor** (web-based SQL client).

---

## Part 6 — Azure DNS Zone and Records (15 min)

Azure DNS lets you manage DNS records for your domain within Azure. This is useful when your domain is registered elsewhere but you want to manage records through Terraform.

```hcl
# ─── DNS Zone ─────────────────────────────────────────────
resource "azurerm_dns_zone" "main" {
  name                = var.dns_zone_name
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

# ─── A Record (points domain to an IP) ───────────────────
resource "azurerm_dns_a_record" "app" {
  name                = "app"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = ["203.0.113.10"]   # Example IP — replace with real LB IP
}

resource "azurerm_dns_a_record" "root" {
  name                = "@"   # @ = the zone apex (example-training.com itself)
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = ["203.0.113.10"]
}

# ─── CNAME Record (alias) ─────────────────────────────────
resource "azurerm_dns_cname_record" "www" {
  name                = "www"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  record              = "app.${var.dns_zone_name}"  # points www → app
}

# ─── MX Record (email) ────────────────────────────────────
resource "azurerm_dns_mx_record" "mail" {
  name                = "@"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 3600

  record {
    preference = 10
    exchange   = "mail.example-training.com."
  }
}

# ─── TXT Record (domain verification) ────────────────────
resource "azurerm_dns_txt_record" "verification" {
  name                = "@"
  zone_name           = azurerm_dns_zone.main.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300

  record {
    value = "v=spf1 include:spf.protection.outlook.com ~all"
  }
}
```

Apply:

```bash
terraform apply -auto-approve
```

### Inspect the name servers

```bash
terraform output dns_name_servers
```

Azure assigns 4 name server addresses to your zone. In a real deployment, you would update your domain registrar to delegate to these name servers. For this training exercise, the zone is created in Azure — you do not need to modify any real domain.

### Query the zone directly

```bash
DNS_ZONE=$(terraform output -raw dns_zone_name)
NS1=$(terraform output -json dns_name_servers | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")

# Query the A record directly against Azure's nameserver
dig app.${DNS_ZONE} @${NS1} A

# Check the CNAME
dig www.${DNS_ZONE} @${NS1} CNAME
```

---

## Part 7 — Outputs

### `outputs.tf`

```hcl
output "mysql_fqdn" {
  value = azurerm_mysql_flexible_server.main.fqdn
}

output "mysql_connection_string" {
  value     = "mysql://${var.mysql_admin_username}@${azurerm_mysql_flexible_server.main.name}:${var.mysql_admin_password}@${azurerm_mysql_flexible_server.main.fqdn}/appdb?ssl=true"
  sensitive = true
}

output "mssql_fqdn" {
  value = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "mssql_connection_string" {
  value     = "Server=${azurerm_mssql_server.main.fully_qualified_domain_name};Database=appdb;User Id=${var.mssql_admin_username};Password=${var.mssql_admin_password};"
  sensitive = true
}

output "dns_zone_name" {
  value = azurerm_dns_zone.main.name
}

output "dns_name_servers" {
  value = azurerm_dns_zone.main.name_servers
}
```

---

## Clean Up

```bash
terraform destroy -auto-approve
```

> Database and DNS resource cleanup is straightforward since the resources have no dependencies outside this project.

---

## Checkpoint Questions

1. What is the difference between `azurerm_mysql_flexible_server` and the older `azurerm_mysql_server`? Why should you always use the Flexible version?
2. Why is `start_ip_address = "0.0.0.0"` and `end_ip_address = "0.0.0.0"` a special rule in Azure SQL firewall?
3. Why would you use the `http` data source to get your IP address instead of hard-coding it?
4. What does TTL mean in DNS? What would happen if you set `ttl = 60` vs `ttl = 86400`?
5. What are the Azure DNS name servers used for? What step would you take in production to make your domain use them?
6. A developer says "I'll just hard-code the database password in `main.tf` for simplicity." What are the risks and how would you fix this?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `azurerm_mysql_flexible_server` | MySQL 8 managed server |
| `azurerm_mysql_flexible_database` | A database within the MySQL server |
| `azurerm_mssql_server` | Azure SQL logical server (container) |
| `azurerm_mssql_database` | An Azure SQL database |
| Firewall rules | Control which IP ranges can connect to the database |
| `azurerm_dns_zone` | An authoritative DNS zone hosted in Azure |
| `azurerm_dns_a_record` | Maps a name to an IPv4 address |
| `azurerm_dns_cname_record` | Alias record pointing to another DNS name |
| `data "http"` | HTTP data source to query external APIs |
| Name servers | Azure-assigned DNS servers; configure at your registrar to delegate |
