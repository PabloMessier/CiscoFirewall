# Cross-Cloud Cisco Firewall Standardization

## Project Overview
This project demonstrates a proof of concept for standardizing Cisco ASAv (Adaptive Security Virtual Appliance) firewall deployment and configuration across multiple cloud providers - specifically AWS and Azure. The implementation uses Terraform to create a consistent infrastructure setup that enables secure cross-cloud communication.

## Architecture

The architecture consists of the following components:

### AWS Environment
- VPC with CIDR block `10.0.0.0/16`
- Two subnets:
  - Workload subnet (`10.0.1.0/24`)
  - Firewall subnet (`10.0.2.0/24`)
- Internet Gateway for external connectivity
- Route tables configured for both internet access and cross-cloud communication
- Security groups for both workload and firewall instances
- Ubuntu workload instance
- Cisco ASAv firewall instance

### Azure Environment
- VNet with CIDR block `10.2.0.0/16`
- Two subnets:
  - Workload subnet (`10.2.0.0/24`)
  - Firewall subnet (`10.2.1.0/24`)
- Network Security Groups for both workload and firewall instances
- Route tables for cross-cloud communication
- Ubuntu workload instance
- Cisco ASAv firewall instance

### Cross-Cloud Connectivity
- AWS route to Azure VNet CIDR through the AWS Cisco firewall
- Azure route to AWS VPC CIDR through the Azure Cisco firewall
- Both firewalls configured to allow traffic between the clouds

## Key Features

1. **Standardized Firewall Deployment**: Consistent deployment of Cisco ASAv across both AWS and Azure
2. **Cross-Cloud Security**: Traffic between clouds is securely routed through the firewall instances
3. **Infrastructure as Code**: Entire setup is defined using Terraform for reproducibility
4. **Consistent Security Policies**: Same security approach across different cloud providers
5. **Public and Private Communication**: Both environments support public internet access and private cross-cloud communication

## Prerequisites

- AWS account with appropriate permissions
- Azure subscription
- Terraform installed
- Cisco ASAv AMI access in AWS
- Cisco ASAv image access in Azure Marketplace

## Configuration

### Required Variables

The following variables must be set before deployment:

- `azure_subscription_id`: Your Azure subscription ID
- `cisco_api_url`: API URL for your Cisco ASA configuration
- `cisco_username`: Username for Cisco ASA authentication
- `cisco_password`: Password for Cisco ASA authentication
- `cisco_asav_ami`: AMI ID for Cisco ASAv in AWS
- `aws_instance_password`: Password for AWS instance
- `azure_instance_password`: Password for Azure instance

### Optional Variables

The project has sensible defaults for most configuration options, including:

- Region settings
- CIDR blocks
- Instance types
- OS versions
- Network configuration

These can be customized as needed by modifying the variables in `variables.tf`.

## Deployment

1. Initialize Terraform:
   ```
   terraform init
   ```

2. Create a `terraform.tfvars` file with your required variables:
   ```
   azure_subscription_id = "your-subscription-id"
   cisco_api_url = "https://your-cisco-asa-api-url"
   cisco_username = "your-username"
   cisco_password = "your-password"
   cisco_asav_ami = "ami-xxxxxxxxxx"
   aws_instance_password = "your-aws-password"
   azure_instance_password = "your-azure-password"
   ```

3. Apply the Terraform configuration:
   ```
   terraform apply
   ```

4. After deployment, the public IP addresses of all instances will be output for easy access.

## Security Considerations

- The current configuration allows SSH access from any IP address for demonstration purposes. In a production environment, this should be restricted to specific IP ranges.
- Password authentication is enabled for simplicity. Consider using SSH keys in production.
- For production use, additional security hardening should be applied to the Cisco ASAv configurations.

## Future Enhancements

- Add high availability configurations for firewalls
- Implement more advanced routing scenarios
- Add monitoring and logging infrastructure
- Incorporate automated testing for the infrastructure
- Add support for additional cloud providers (GCP, Oracle Cloud, etc.)

## Troubleshooting

Common issues and solutions:

1. **Connectivity Problems**: Ensure security groups and NSGs allow the required traffic
2. **Firewall Configuration**: Verify that the Cisco ASAv instances are properly configured
3. **Route Tables**: Check that route tables are correctly associated with the appropriate subnets

## License

This project is provided as-is under the [MIT License](LICENSE).

## Contributors

- [Your Name]

## Acknowledgments

- Cisco for providing the ASAv virtual appliance
- HashiCorp for the Terraform tooling
- AWS and Azure for their cloud platforms