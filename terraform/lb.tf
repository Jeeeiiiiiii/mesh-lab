# ---------------------------------------------------------------------------
# Load balancer.
#
# An internet-facing NLB in the public subnets is the only way in. It forwards
# TCP 80 to the Istio ingress gateway, which is exposed on every node as a
# NodePort. Everything after that -- routing, TLS between services, who may
# call whom -- is the mesh's job, not the load balancer's.
#
# An NLB rather than an ALB because the mesh wants the raw connection: Istio
# terminates HTTP itself, and layering an ALB in front means two proxies
# rewriting the same headers.
#
# In a real account the AWS Load Balancer Controller would register the nodes
# into the target group (a TargetGroupBinding). Locally the NLB is metadata
# only; scripts/demo.sh reaches the gateway with a port-forward instead.
# ---------------------------------------------------------------------------

resource "aws_lb" "ingress" {
  name               = "${var.name}-ingress"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true

  tags = { Name = "${var.name}-ingress" }
}

resource "aws_lb_target_group" "ingress" {
  name        = "${var.name}-ingress"
  vpc_id      = aws_vpc.this.id
  port        = var.ingress_node_port
  protocol    = "TCP"
  target_type = "instance"

  tags = { Name = "${var.name}-ingress" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ingress.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress.arn
  }
}
