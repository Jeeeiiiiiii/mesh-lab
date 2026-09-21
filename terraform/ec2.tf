# ---------------------------------------------------------------------------
# Bastion.
#
# The cluster API endpoint is private, so an operator needs a foothold inside
# the VPC to run kubectl. That is all the bastion is: a small instance in a
# public subnet with SSH open to admin_cidr and nothing else listening.
#
# Locally, Floci runs this as a real Amazon Linux container and executes the
# user data.
# ---------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.bastion_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/../scripts/bastion-bootstrap.sh", {
    cluster_name = var.name
    region       = var.region
  })

  tags = {
    Name = "${var.name}-bastion"
    Role = "bastion"
  }
}
