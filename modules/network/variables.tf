variable "prefix" {
  description = "Student prefix for resource"
  type = string
}

variable "vm_name" {
  description = "Virtual machine name"
  type        = string
  default     = "demo-vm"
}

variable "rg_location" {
  description = "Resource group location"
  type = string
}

variable "rg_name" {
  description = "Resource group name"
  type = string
}