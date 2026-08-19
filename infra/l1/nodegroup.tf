# ---------------------------------------------------------------------------
# IAM role for the NODES.
#
# Separate from the cluster role, and trusted by a different principal: EC2,
# because a node IS an EC2 instance. The cluster role is worn by the EKS
# service; this one is worn by your instances.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${local.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# Three policies, three distinct jobs. Miss any one and the node fails in a
# different, confusing way.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    # Lets the kubelet register with the control plane and report status.
    # Without it the instance boots, runs, and never appears in `kubectl get nodes`.
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",

    # Lets the VPC CNI attach ENIs and assign pod IPs.
    # Without it nodes join, but every pod sits in ContainerCreating forever
    # because it can never be given an IP address.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",

    # Lets the node pull images from ECR.
    # Without it: ImagePullBackOff on your own images, with an auth error.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# Managed node group — an Auto Scaling Group of EC2 instances that AWS keeps
# registered with the cluster.
#
# "Managed" means AWS handles the AMI, the bootstrap script, draining during
# upgrades, and rolling replacement. Self-managed node groups exist and give
# more control, at the cost of owning all of that yourself.
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node.arn

  # PRIVATE subnets. Nodes reach the internet outbound via the NAT gateway and
  # are unreachable from outside. Putting them in public subnets would work and
  # save the $32/month NAT, at the cost of every node having a public IP.
  subnet_ids = local.l0.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type

  # AL2023 is the current default. AL2 is deprecated; BOTTLEROCKET is a
  # minimal, immutable, container-only OS worth knowing about — no shell,
  # no package manager, updates by image replacement.
  ami_type = "AL2023_x86_64_STANDARD"

  disk_size = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # During an upgrade, replace one node at a time. With 2 nodes that means
    # capacity never drops below 1.
    max_unavailable = 1
  }

  labels = {
    role = "general"
  }

  tags = local.common_tags

  # The role must have its policies BEFORE nodes launch. Without this, nodes
  # can boot before the CNI policy is attached and never get pod networking.
  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    # The cluster autoscaler (or you, manually) changes desired_size at
    # runtime. Without this, the next `terraform apply` would scale it back
    # and fight whatever did the scaling.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
