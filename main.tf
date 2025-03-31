resource "aws_vpc" "aws_vpc" {
  cidr_block           = var.aws_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "AWS VPC"
  })
}

resource "aws_subnet" "aws_subnet" {
  vpc_id            = aws_vpc.aws_vpc.id
  cidr_block        = var.aws_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = merge(var.tags, {
    Name = "AWS Workload Subnet"
  })
}

# Dedicated subnet for AWS Cisco Firewall
resource "aws_subnet" "aws_fw_subnet" {
  vpc_id            = aws_vpc.aws_vpc.id
  cidr_block        = var.aws_fw_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = merge(var.tags, {
    Name = "AWS Firewall Subnet"
  })
}

resource "aws_internet_gateway" "aws_igw" {
  vpc_id = aws_vpc.aws_vpc.id

  tags = merge(var.tags, {
    Name = "AWS Internet Gateway"
  })
}

resource "aws_route_table" "aws_rt" {
  vpc_id = aws_vpc.aws_vpc.id

  # Route for internet access
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.aws_igw.id
  }

  # Route to Azure through the Cisco firewall
  route {
    cidr_block           = var.azure_vnet_cidr
    network_interface_id = aws_instance.cisco_fw_aws.primary_network_interface_id
  }

  tags = merge(var.tags, {
    Name = "AWS Route Table"
  })
}

resource "aws_route_table_association" "aws_rta" {
  subnet_id      = aws_subnet.aws_subnet.id
  route_table_id = aws_route_table.aws_rt.id
}

resource "aws_security_group" "aws_sg" {
  name        = "allow_ssh_and_icmp"
  description = "Allow SSH and ICMP inbound traffic"
  vpc_id      = aws_vpc.aws_vpc.id

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ICMP from anywhere"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "allow_ssh_and_icmp"
  })
}

# Security group for AWS Cisco Firewall
resource "aws_security_group" "aws_fw_sg" {
  name        = "cisco-firewall-sg"
  description = "Security group for Cisco virtual firewall"
  vpc_id      = aws_vpc.aws_vpc.id

  ingress {
    description = "HTTPS Management Interface"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "All traffic from VPCs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.aws_vpc_cidr, var.azure_vnet_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "Cisco-Firewall-SG"
  })
}

resource "aws_instance" "aws_instance" {
  ami                         = var.aws_ubuntu_ami
  instance_type               = var.aws_instance_type
  subnet_id                   = aws_subnet.aws_subnet.id
  vpc_security_group_ids      = [aws_security_group.aws_sg.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              echo 'ubuntu:${var.aws_instance_password}' | chpasswd
              sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
              systemctl restart sshd
              EOF

  tags = merge(var.tags, {
    Name = "AWS Workload Instance"
  })
}

# AWS Cisco Firewall Instance
resource "aws_instance" "cisco_fw_aws" {
  ami                         = var.cisco_asav_ami
  instance_type               = var.aws_asav_instance_type
  subnet_id                   = aws_subnet.aws_fw_subnet.id
  vpc_security_group_ids      = [aws_security_group.aws_fw_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.asav_disk_size
  }

  tags = merge(var.tags, {
    Name = "Cisco-ASAv-Firewall"
  })
}

# ====================================================================================

# Azure Resources
resource "azurerm_resource_group" "azure_rg" {
  name     = var.resource_group_name
  location = var.azure_region
  tags     = var.tags
}

resource "azurerm_virtual_network" "azure_vnet" {
  name                = "azure-vnet"
  address_space       = [var.azure_vnet_cidr]
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name
  tags                = var.tags
}

resource "azurerm_subnet" "azure_subnet" {
  name                 = "azure-workload-subnet"
  resource_group_name  = azurerm_resource_group.azure_rg.name
  virtual_network_name = azurerm_virtual_network.azure_vnet.name
  address_prefixes     = [var.azure_subnet_cidr]
}

# Dedicated subnet for Azure Cisco Firewall
resource "azurerm_subnet" "azure_fw_subnet" {
  name                 = "azure-fw-subnet"
  resource_group_name  = azurerm_resource_group.azure_rg.name
  virtual_network_name = azurerm_virtual_network.azure_vnet.name
  address_prefixes     = [var.azure_fw_subnet_cidr]
}

# Network Security Group for regular instances
resource "azurerm_network_security_group" "azure_nsg" {
  name                = "azure-nsg"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "ICMP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = var.tags
}

# Network Security Group for Cisco Firewall
resource "azurerm_network_security_group" "azure_fw_nsg" {
  name                = "azure-fw-nsg"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name

  security_rule {
    name                       = "HTTPS-Management"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "VPC-Traffic"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = [var.aws_vpc_cidr, var.azure_vnet_cidr]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "ASDM"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = var.tags
}

# Regular Azure Instance
resource "azurerm_network_interface" "azure_instance_nic" {
  name                = "azure-instance-nic"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.azure_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.azure_instance_pip.id
  }
  tags = var.tags
}

resource "azurerm_public_ip" "azure_instance_pip" {
  name                = "azure-instance-pip"
  resource_group_name = azurerm_resource_group.azure_rg.name
  location            = azurerm_resource_group.azure_rg.location
  allocation_method   = "Dynamic"
  tags                = var.tags
}

resource "azurerm_linux_virtual_machine" "azure_instance" {
  name                            = "azure-instance"
  resource_group_name             = azurerm_resource_group.azure_rg.name
  location                        = azurerm_resource_group.azure_rg.location
  size                            = var.azure_vm_size
  admin_username                  = "azureuser"
  admin_password                  = var.azure_instance_password
  disable_password_authentication = false

  network_interface_ids = [
    azurerm_network_interface.azure_instance_nic.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = var.ubuntu_version
    version   = "latest"
  }
  tags = var.tags
}

# Cisco Firewall in Azure
resource "azurerm_network_interface" "azure_fw_nic" {
  name                = "azure-fw-nic"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.azure_fw_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.azure_fw_pip.id
  }
  tags = var.tags
}

resource "azurerm_public_ip" "azure_fw_pip" {
  name                = "azure-fw-pip"
  resource_group_name = azurerm_resource_group.azure_rg.name
  location            = azurerm_resource_group.azure_rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_virtual_machine" "cisco_fw_azure" {
  name                = "cisco-asav-azure"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name
  vm_size             = var.asav_vm_size
  tags                = var.tags

  plan {
    name      = "asav-azure-payg"
    publisher = "cisco"
    product   = "cisco-asav"
  }

  storage_image_reference {
    publisher = "cisco"
    offer     = "cisco-asav"
    sku       = "asav-azure-payg"
    version   = var.asav_version
  }

  storage_os_disk {
    name              = "cisco-fw-disk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  os_profile {
    computer_name  = "cisco-asav"
    admin_username = var.cisco_username
    admin_password = var.cisco_password
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  network_interface_ids = [
    azurerm_network_interface.azure_fw_nic.id,
  ]
}

# Route Tables for Cross-Cloud Communication
resource "azurerm_route_table" "azure_rt" {
  name                = "azure-rt"
  location            = azurerm_resource_group.azure_rg.location
  resource_group_name = azurerm_resource_group.azure_rg.name
  tags                = var.tags

  route {
    name                   = "to-aws"
    address_prefix         = var.aws_vpc_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_network_interface.azure_fw_nic.private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "azure_rta" {
  subnet_id      = azurerm_subnet.azure_subnet.id
  route_table_id = azurerm_route_table.azure_rt.id
}

resource "azurerm_network_interface_security_group_association" "azure_instance_nsg" {
  network_interface_id      = azurerm_network_interface.azure_instance_nic.id
  network_security_group_id = azurerm_network_security_group.azure_nsg.id
}

resource "azurerm_network_interface_security_group_association" "azure_fw_nsg" {
  network_interface_id      = azurerm_network_interface.azure_fw_nic.id
  network_security_group_id = azurerm_network_security_group.azure_fw_nsg.id
}

# Outputs
output "aws_instance_public_ip" {
  description = "Public IP address of AWS workload instance"
  value       = aws_instance.aws_instance.public_ip
}

output "aws_firewall_public_ip" {
  description = "Public IP address of AWS Cisco ASAv firewall"
  value       = aws_instance.cisco_fw_aws.public_ip
}

output "azure_instance_public_ip" {
  description = "Public IP address of Azure workload instance"
  value       = azurerm_public_ip.azure_instance_pip.ip_address
}

output "azure_firewall_public_ip" {
  description = "Public IP address of Azure Cisco ASAv firewall"
  value       = azurerm_public_ip.azure_fw_pip.ip_address
}