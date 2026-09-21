# ---------------------------------------------------------------------------
# EKS.
#
# The cluster lives entirely in the private subnets. Its API endpoint is
# private-only: kubectl goes through the bastion (or a VPN) in a real account.
# The node group is in the same subnets and reaches the internet -- image
# pulls, the Istio chart -- through the NAT gateway.
#
# Locally, Floci backs this with a real single-node k3s container and exposes
# its API on the host; scripts/kubeconfig.sh fetches the credentials.
# ---------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  # The role must be attached before the cluster tries to use it, and it must
  # stay attached until the cluster is gone or teardown leaks ENIs.
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "worker"
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
