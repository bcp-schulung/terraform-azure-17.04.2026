# Exercise 1 — Install Terraform and Create Your First Resource

**Estimated time:** 45–60 minutes

## Objective

Install the Terraform CLI, configure it to talk to Azure, and deploy your very first resource. By the end of this exercise you will have gone through the full Terraform lifecycle — `init`, `plan`, `apply`, and `destroy` — and will understand the role the state file plays.

---

## Prerequisites

- An active Azure subscription (free tier is fine)
- The [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)
- A text editor (VS Code recommended)

---

## Part 1 — Install Terraform (10 min)

### Step 1 — Download the Terraform CLI

Choose the method that matches your operating system:

**macOS (Homebrew):**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

**Windows (Chocolatey):**
```powershell
choco install terraform
```

**Linux (Ubuntu/Debian):**
```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**Manual download:** Visit [https://developer.hashicorp.com/terraform/downloads](https://developer.hashicorp.com/terraform/downloads), download the binary for your OS, and place it somewhere on your `PATH`.

### Step 2 — Verify the installation

Open a new terminal and run:

```bash
terraform version
```

You should see output similar to:
```
Terraform v1.7.x
on darwin_arm64
```

If the command is not found, ensure the binary is on your `PATH`. On macOS/Linux you can check with `echo $PATH` and on Windows with `$env:PATH`.

### Step 3 — Explore the CLI help

Run these commands to get familiar with the available sub-commands:

```bash
terraform --help
terraform plan --help
```

Notice the main commands: `init`, `validate`, `fmt`, `plan`, `apply`, `destroy`, `output`, `state`. You will use all of these throughout the course.

---

## Part 2 — Configure Azure CLI Authentication (5 min)

Terraform uses the Azure CLI's active login by default during development. Make sure you are authenticated:

```bash
az login
```

A browser window will open. Sign in with your Azure account. Once complete, run:

```bash
az account show
```

You should see your subscription details. Note down the **subscriptionId** and **tenantId** — you will need them later. If you have multiple subscriptions, set the correct one:

```bash
az account set --subscription "<your-subscription-id>"
```

Confirm the correct subscription is active:

```bash
az account show --query "{name:name, id:id, isDefault:isDefault}" -o table
```

---

## Part 3 — Create Your First Terraform Configuration (15 min)

### Step 1 — Create a working directory

```bash
mkdir ~/terraform-exercises/day1-exercise1
cd ~/terraform-exercises/day1-exercise1
```

Keep each exercise in its own directory. This keeps state files isolated.

### Step 2 — Create the provider configuration

Create a file called `main.tf` and add the following:

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
```

**What this does:**
- The `terraform` block pins the minimum Terraform version and declares the `azurerm` provider.
- `version = "~> 3.0"` means: accept any version `>= 3.0.0` and `< 4.0.0`.
- The `provider "azurerm"` block initialises the provider. The `features {}` block is required (even when empty) by the azurerm provider.

### Step 3 — Add a Resource Group resource

Below the provider block in the same `main.tf`, add:

```hcl
resource "azurerm_resource_group" "main" {
  name     = "rg-terraform-training-dev"
  location = "westeurope"

  tags = {
    environment = "training"
    managed_by  = "terraform"
  }
}
```

**Anatomy of a resource block:**
- `resource` — keyword
- `"azurerm_resource_group"` — resource type (maps to an Azure Resource Manager API call)
- `"main"` — local name used to reference this resource elsewhere in your code
- The arguments inside the block (`name`, `location`, `tags`) are resource-specific

Save the file. Your directory should look like:
```
day1-exercise1/
└── main.tf
```

---

## Part 4 — Run the Terraform Workflow (15 min)

### Step 1 — `terraform init`

```bash
terraform init
```

This command:
1. Downloads the `azurerm` provider plugin from the Terraform Registry into `.terraform/providers/`
2. Creates a `.terraform.lock.hcl` file that pins the exact provider version

Expected output (abbreviated):
```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 3.0"...
- Installing hashicorp/azurerm v3.x.x...

Terraform has been successfully initialized!
```

Look at what was created:
```bash
ls -la
cat .terraform.lock.hcl
```

The lock file records the exact version and checksum of the provider. **Commit this file to version control** to ensure your team uses the same provider version.

### Step 2 — `terraform fmt`

Format your code to canonical style before planning:

```bash
terraform fmt
```

If the file was already correctly formatted, nothing happens. If Terraform changed anything, it prints the filename. Run `git diff` (if in a repo) to see what changed. Always run `fmt` before committing.

### Step 3 — `terraform validate`

```bash
terraform validate
```

This checks the configuration for syntax errors and internal consistency — without connecting to Azure. It should print:
```
Success! The configuration is valid.
```

Introduce a deliberate typo — for example, rename `location` to `locatio` — then run `validate` again to see the error message. Fix it before continuing.

### Step 4 — `terraform plan`

```bash
terraform plan
```

Terraform will:
1. Authenticate to Azure
2. Compare your HCL configuration against the current state (which is empty right now)
3. Print a diff of what **will** be created, changed, or destroyed

Read the plan output carefully. You should see:
```
Plan: 1 to add, 0 to change, 0 to destroy.
```

The `+` prefix on each line means "this will be created". Lines with a known value are shown directly; lines with `(known after apply)` will be determined by Azure once the resource exists.

### Step 5 — `terraform apply`

```bash
terraform apply
```

Terraform shows the plan again and then prompts:
```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value:
```

Type `yes` and press Enter. Terraform will call the Azure API to create the resource group. This typically takes 10–30 seconds.

Verify in the Azure Portal: navigate to **Resource Groups** and confirm `rg-terraform-training-dev` appears in West Europe.

---

## Part 5 — Inspect the State File (5 min)

After a successful `apply`, Terraform writes a `terraform.tfstate` file in your working directory.

```bash
cat terraform.tfstate
```

Open it in your editor. It is a JSON file that Terraform uses to track what it manages. Notice:
- The `resources` array contains an entry for your resource group
- Each property (id, name, location, tags) is recorded
- The `id` is the Azure resource ID (e.g., `/subscriptions/.../resourceGroups/rg-terraform-training-dev`)

> **Important:** Never edit `.tfstate` by hand. Never commit it to a public repository — it can contain sensitive secrets. In production, always use remote state (covered on Day 2).

---

## Part 6 — Observe Idempotency (5 min)

Run `terraform apply` again without changing anything:

```bash
terraform apply
```

Terraform reads the state file, queries Azure, finds no drift, and prints:
```
No changes. Your infrastructure matches the configuration.
```

This is **idempotency** — running apply multiple times has the same effect as running it once. Terraform only changes what is different from the desired state.

---

## Part 7 — Modify and Re-apply (5 min)

Open `main.tf` and add a new tag to the resource group:

```hcl
  tags = {
    environment = "training"
    managed_by  = "terraform"
    cost_centre = "engineering"   # <-- new tag
  }
```

Run plan to see the diff:

```bash
terraform plan
```

Notice the `~` prefix — this means an **in-place update** (no destroy/recreate needed):
```
  ~ resource "azurerm_resource_group" "main" {
      ~ tags = {
          + "cost_centre" = "engineering"
            # (2 unchanged elements hidden)
        }
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

Apply the change:
```bash
terraform apply -auto-approve
```

The `-auto-approve` flag skips the interactive prompt. Use it with caution — it is handy in learner environments but should be avoided in production pipelines where human review is required.

Verify the new tag appears in the Azure Portal.

---

## Part 8 — Clean Up (5 min)

```bash
terraform destroy
```

Terraform will show you everything it intends to delete (the resource group and everything inside it) and ask for confirmation. Type `yes`.

After destroy completes, confirm the resource group no longer exists:

```bash
az group show --name rg-terraform-training-dev
```

You should see an error like `ResourceGroupNotFound`. The state file will now contain an empty resources array.

---

## Checkpoint Questions

Answer these in your own words before moving on:

1. What is the purpose of `terraform init`? What would happen if you skipped it?
2. What does the `.terraform.lock.hcl` file do, and why should it be committed to version control?
3. What is the difference between `terraform plan` and `terraform apply`?
4. Why is the state file important? What risks arise from storing it locally?
5. What does "idempotency" mean in the context of Terraform?

---

## Key Concepts Summary

| Concept | Description |
|---|---|
| `terraform init` | Downloads providers and sets up the backend |
| `terraform fmt` | Formats code to canonical HCL style |
| `terraform validate` | Checks syntax and internal consistency without contacting APIs |
| `terraform plan` | Shows what will change, without making changes |
| `terraform apply` | Makes changes to match the desired configuration |
| `terraform destroy` | Destroys all resources managed by the current state |
| State file | JSON record of all resources Terraform manages |
| Idempotency | Applying the same config repeatedly produces the same result |
| Resource block | Declares a piece of infrastructure to create and manage |
