output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "node_security_group_id" {
  value = aws_security_group.node.id
}

output "ingress_nlb_dns" {
  description = "Public entry point. In AWS this resolves to the NLB; locally it is metadata and scripts/demo.sh port-forwards instead."
  value       = aws_lb.ingress.dns_name
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}
