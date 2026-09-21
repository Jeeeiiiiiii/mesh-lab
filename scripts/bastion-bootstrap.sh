#!/usr/bin/env bash
# EC2 user data for the bastion. Rendered by Terraform (templatefile), so the
# dollar-brace placeholders below are Terraform's, not the shell's.
#
# The bastion exists so an operator can reach the private cluster endpoint.
# It gets kubectl and the AWS CLI; the kubeconfig is fetched on first login
# with `aws eks update-kubeconfig`, which needs the instance profile or the
# operator's own credentials -- neither is baked in here on purpose.
set -euo pipefail

dnf install -y -q curl-minimal jq >/dev/null 2>&1 || true

# kubectl, matching the cluster's minor version.
curl -fsSL -o /usr/local/bin/kubectl \
  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

cat > /etc/profile.d/mesh-lab.sh <<EOF
export AWS_REGION=${region}
export MESH_LAB_CLUSTER=${cluster_name}
alias kube-login='aws eks update-kubeconfig --name ${cluster_name} --region ${region}'
EOF

echo "mesh-lab bastion ready for cluster ${cluster_name}" > /etc/motd
