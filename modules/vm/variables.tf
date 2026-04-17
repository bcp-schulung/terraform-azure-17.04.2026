variable "prefix" {
  description = "Student prefix for resource"
  type        = string
}

variable "vm_name" {
  description = "Virtual machine name"
  type        = string
  default     = "demo-vm"
}

variable "admin_username" {
  description = "Admin username for the VM"
  type        = string
  default     = "azureuser"
}

variable "public_key_path" {
  description = "Path to the SSH public key"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "vm_size" {
  description = "Azure VM size for the scale set instances"
  type        = string
  default     = "Standard_B1s"
}

variable "instance_count" {
  description = "Initial number of Linux VM scale set instances"
  type        = number
  default     = 2
}

variable "min_instances" {
  description = "Minimum number of autoscaled instances"
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Maximum number of autoscaled instances"
  type        = number
  default     = 5
}

variable "rg_location" {
  description = "Resource group location"
  type        = string
}

variable "rg_name" {
  description = "Resource group name"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}