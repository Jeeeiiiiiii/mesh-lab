variable "region" {
  type    = string
  default = "us-east-1"
}

variable "endpoint_url" {
  description = "Floci endpoint. Everything in providers.tf points here."
  type        = string
  default     = "http://localhost:4566"
}

variable "name" {
  description = "Prefix for every resource name and the EKS cluster name."
  type        = string
  default     = "mesh-lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# Two AZs: an ALB/NLB refuses to be created with subnets in fewer, and EKS
# wants its control plane ENIs spread across at least two as well.
variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "admin_cidr" {
  description = "Who may SSH to the bastion. Narrow this to your own address in a real account."
  type        = string
  default     = "0.0.0.0/0"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

# The Istio ingress gateway is exposed as a NodePort and the NLB's target group
# points at it. Keep this in sync with mesh/values/gateway.yaml.
variable "ingress_node_port" {
  type    = number
  default = 30080
}
