terraform {
  required_version = ">= 1.11.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.7"
    }
  }
}

variable "name_base" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "address_space" {
  description = "VNet CIDR. Pods use an overlay CIDR, so the VNet only needs node IPs."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.address_space, 0))
    error_message = "address_space must be a valid CIDR."
  }
}

variable "node_subnet_prefix" {
  description = "Node subnet. /24 = 251 usable IPs: plenty for nodes + surge with Azure CNI Overlay."
  type        = string
  default     = "10.20.0.0/24"

  validation {
    condition     = can(cidrhost(var.node_subnet_prefix, 0))
    error_message = "node_subnet_prefix must be a valid CIDR."
  }
}

variable "ingress_ports" {
  description = "TCP ports opened from the Internet to the public Gateway load balancer."
  type        = list(number)
  default     = [80]
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_base}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_network_security_group" "nodes" {
  name                = "nsg-${var.name_base}-nodes"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # AKS does not manage an NSG attached to a BYO subnet, so public ingress to
  # the Gateway LoadBalancer Service must be allowed explicitly. Destination is
  # "*" because AKS load-balancer rules use floating IP (dst = frontend IP).
  security_rule {
    name                       = "allow-gateway-ingress"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "Internet"
    source_port_range          = "*"
    destination_address_prefix = "*"
    destination_port_ranges    = [for p in var.ingress_ports : tostring(p)]
  }
}

resource "azurerm_subnet" "nodes" {
  name                 = "snet-${var.name_base}-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.node_subnet_prefix]
  # Egress goes through the AKS-managed Standard LB outbound rule, never the
  # implicit "default outbound access" Azure is retiring.
  default_outbound_access_enabled = false
}

resource "azurerm_subnet_network_security_group_association" "nodes" {
  subnet_id                 = azurerm_subnet.nodes.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "node_subnet_id" {
  # Consumers must not race the NSG association (AKS would start on an open subnet).
  value      = azurerm_subnet.nodes.id
  depends_on = [azurerm_subnet_network_security_group_association.nodes]
}
