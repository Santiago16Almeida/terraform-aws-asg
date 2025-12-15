# --- Configuración del Proveedor ---
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ----------------------------------------------------
# 1. RED (VPC, Subredes y Gateway)
# ----------------------------------------------------

resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "AppVPC-Distribuida"
  }
}

# Mapeamos las subredes a las AZs de la región
resource "aws_subnet" "public" {
  count                   = length(var.public_subnets_cidr)
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = var.public_subnets_cidr[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet-${count.index}"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_internet_gateway" "app_gw" {
  vpc_id = aws_vpc.app_vpc.id
  tags = { Name = "AppIGW" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_gw.id
  }
}

resource "aws_route_table_association" "public_rta" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}


# ----------------------------------------------------
# 2. SEGURIDAD (Security Groups)
# ----------------------------------------------------

# SG para el Load Balancer (permite tráfico 80 desde Internet)
resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.app_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "LBSecurityGroup" }
}

# SG para las Instancias (solo permite tráfico del LB en puerto 80)
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.app_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.lb_sg.id] # Referencia al SG del LB
  }
  # Aquí agregarías la regla para la DB si estuviera definida (ej. puerto 3306)
  tags = { Name = "AppSecurityGroup" }
}

# ----------------------------------------------------
# 3. CONFIGURACIÓN DEL DEPLOY (Launch Template)
# ----------------------------------------------------

# Script de inicio (user_data) para instalar y desplegar el "hola mundo"
data "template_file" "user_data" {
  template = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y httpd
    echo "<h1>Hola Mundo Distribuido desde $(hostname)</h1>" | sudo tee /var/www/html/index.html
    sudo systemctl start httpd
    sudo systemctl enable httpd
  EOF
}

# Launch Template (Plantilla para las instancias)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-lt"
  image_id      = var.ami_id
  instance_type = var.instance_type
  
  # Asigna el SG que solo permite tráfico del LB
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app_sg.id]
  }

  user_data = base64encode(data.template_file.user_data.rendered)
  tags = { Name = "AppLaunchTemplate" }
}

# ----------------------------------------------------
# 4. LOAD BALANCER (ALB)
# ----------------------------------------------------

resource "aws_lb" "app_lb" {
  name               = "app-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  # Asigna a las subredes públicas
  subnets            = aws_subnet.public.*.id 
  tags = { Name = "AppALB" }
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.app_vpc.id
  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# ----------------------------------------------------
# 5. AUTO SCALING GROUP (ASG)
# ----------------------------------------------------

resource "aws_autoscaling_group" "app_asg" {
  name                      = "app-asg"
  # Asigna a las subredes públicas para simplificar
  vpc_zone_identifier       = aws_subnet.public.*.id 
  target_group_arns         = [aws_lb_target_group.app_tg.arn]

  min_size                  = var.min_instances # Mínimo 4
  max_size                  = var.max_instances # Máximo 6
  desired_capacity          = var.min_instances

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }
}

# Puedes añadir una política de escalado basada en CPU para la prueba
resource "aws_autoscaling_policy" "cpu_scale_out" {
  name                   = "cpu-scale-out"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
}