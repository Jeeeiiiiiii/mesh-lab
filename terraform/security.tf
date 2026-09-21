# ---------------------------------------------------------------------------
# Security groups.
#
# Four groups, one per role. Rules reference other groups rather than CIDRs
# wherever the peer is something we own, so the rule survives an IP change.
#
#   internet --80--> nlb --30080--> node <--443--> cluster <--443-- bastion
#                                    ^                 |
#                                    +-- 1025-65535 ---+   (kubelet, webhooks)
# ---------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion"
  description = "Bastion: SSH from operators only"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-bastion" }
}

resource "aws_security_group" "nlb" {
  name        = "${var.name}-nlb"
  description = "Internet-facing NLB in front of the Istio ingress gateway"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-nlb" }
}

resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster"
  description = "EKS control plane"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-cluster" }
}

resource "aws_security_group" "node" {
  name        = "${var.name}-node"
  description = "EKS worker nodes"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name}-node"
    # The load balancer controller and cluster autoscaler look for this tag
    # to find the nodes that belong to a cluster.
    "kubernetes.io/cluster/${var.name}" = "owned"
  }
}

# --- bastion ---------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from admin_cidr"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_cidr
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  security_group_id = aws_security_group.bastion.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- nlb -------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "nlb_http" {
  security_group_id = aws_security_group.nlb.id
  description       = "HTTP from anywhere"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_nodes" {
  security_group_id            = aws_security_group.nlb.id
  description                  = "Forward to the ingress gateway NodePort"
  from_port                    = var.ingress_node_port
  to_port                      = var.ingress_node_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node.id
}

# --- cluster (control plane) ----------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "Kubelets and pods talk to the API server"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.node.id
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_bastion" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "kubectl from the bastion"
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.bastion.id
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- node ------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "node_self" {
  security_group_id            = aws_security_group.node.id
  description                  = "Node-to-node and pod-to-pod: sidecar mTLS traffic, and every sidecar reaching istiod on 15012"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.node.id
}

# This is the rule people forget when they put Istio on EKS. The API server
# calls the istiod sidecar-injection webhook on 15017; if the control plane
# cannot reach that port, every pod created in an injected namespace fails
# admission with a timeout.
resource "aws_vpc_security_group_ingress_rule" "node_from_cluster" {
  security_group_id            = aws_security_group.node.id
  description                  = "API server to kubelet (10250) and admission webhooks such as istiod 15017"
  from_port                    = 1025
  to_port                      = 65535
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.cluster.id
}

resource "aws_vpc_security_group_ingress_rule" "node_from_nlb" {
  security_group_id            = aws_security_group.node.id
  description                  = "Istio ingress gateway NodePort from the NLB"
  from_port                    = var.ingress_node_port
  to_port                      = var.ingress_node_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.nlb.id
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
