###########################################
############## Cache Server ###############
###########################################

resource "aws_elasticache_subnet_group" "cache_server" {
  name = "${var.global_prefix}-cache-server"
  subnet_ids = aws_subnet.private_subnet[*].id
  description = "${var.global_prefix}-cache-server"
}

resource "aws_elasticache_replication_group" "cache_server" {
  replication_group_id = "${var.global_prefix}-cache-server"
  replication_group_description = "Cache server for the APIs"
  subnet_group_name = aws_elasticache_subnet_group.cache_server.name
  availability_zones = data.aws_availability_zones.available.names
  number_cache_clusters = length(data.aws_availability_zones.available.names)
  security_group_ids = [aws_security_group.cache_server.id]
  automatic_failover_enabled = true
  node_type = "cache.m4.large"
  parameter_group_name = "default.redis6.x"
  port = 6379
}

###########################################
########## Cache Server Bastion ###########
###########################################

variable "cache_server_bastion_enabled" {
  type = bool
  default = false
}

resource "tls_private_key" "private_key" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "private_key" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  key_name = var.global_prefix
  public_key = tls_private_key.private_key[0].public_key_openssh
}

resource "local_file" "private_key" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  content  = tls_private_key.private_key[0].private_key_pem
  filename = "cert.pem"
}

resource "null_resource" "private_key_permissions" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  depends_on = [local_file.private_key]
  provisioner "local-exec" {
    command = "chmod 600 cert.pem"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }
}

data "aws_ami" "amazon_linux_2" {
 most_recent = true
 owners = ["amazon"]
 filter {
   name = "owner-alias"
   values = ["amazon"]
 }
 filter {
   name = "name"
   values = ["amzn2-ami-hvm*"]
 }
}

data "template_file" "cache_server_bastion_bootstrap" {
  template = file("../util/cache-server-bastion.sh")
  vars = {
    cache_server = aws_elasticache_replication_group.cache_server.primary_endpoint_address
  }
}

resource "aws_instance" "cache_server_bastion" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  depends_on = [aws_elasticache_replication_group.cache_server]
  ami = data.aws_ami.amazon_linux_2.id
  instance_type = "t2.micro"
  key_name = aws_key_pair.private_key[0].key_name
  subnet_id = aws_subnet.cache_server_bastion[0].id
  vpc_security_group_ids = [aws_security_group.cache_server_bastion[0].id]
  user_data = data.template_file.cache_server_bastion_bootstrap.rendered
  root_block_device {
    volume_type = "gp2"
    volume_size = 100
  }
  tags = {
    Name = "${var.global_prefix}-cache-server-bastion"
  }
}

resource "local_file" "ssh_cache_server_bastion_readme" {
  count = var.cache_server_bastion_enabled == true ? 1 : 0
  depends_on = [aws_instance.cache_server_bastion]
  content  = "ssh ec2-user@${aws_instance.cache_server_bastion[0].public_ip} -i cert.pem"
  filename = "ssh-cache-server-bastion.readme"
}
