variable "prefix" {
  description = "Student prefix for resource"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-tf-lab"
}

variable "vm_name" {
  description = "Virtual machine name"
  type        = string
  default     = "demo-vm"
}