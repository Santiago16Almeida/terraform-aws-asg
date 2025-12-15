# main.tf

# ----------------------------------------------------
# 1. Configuraciones de AWS
# ----------------------------------------------------

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
# 2. VPC y Redes
# ----------------------------------------------------

# VPC
resource "aws_vpc" "app_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "AppVPC-Distribuida"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "app_gw" {
  vpc_id = aws_vpc.app_vpc.id

  tags = {
    Name = "AppIGW"
  }
}

# Subredes Públicas (en dos zonas de disponibilidad)
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.app_vpc.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # Permitir asignación automática de IP pública para que las instancias puedan salir a Internet
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet-${count.index}"
  }
}

# Tabla de Rutas Públicas
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_gw.id
  }
}

# Asociar Tablas de Rutas a Subredes
resource "aws_route_table_association" "public_rta" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# ----------------------------------------------------
# 3. Seguridad
# ----------------------------------------------------

# Grupo de Seguridad para el Load Balancer (permite tráfico HTTP desde cualquier lugar)
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

  tags = {
    Name = "LBSecurityGroup"
  }
}

# Grupo de Seguridad para las Instancias (solo permite tráfico HTTP desde el Load Balancer)
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.app_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    # Solo permite tráfico desde el Grupo de Seguridad del Load Balancer
    security_groups = [aws_security_group.lb_sg.id] 
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSecurityGroup"
  }
}

# ----------------------------------------------------
# 4. Configuración de la Aplicación (Load Balancer, ASG)
# ----------------------------------------------------

# Load Balancer (Application Load Balancer - ALB)
resource "aws_lb" "app_lb" {
  name               = "app-balancer"
  internal           = false
  load_balancer_type = "application"
  subnets            = [for subnet in aws_subnet.public : subnet.id]
  security_groups    = [aws_security_group.lb_sg.id]

  tags = {
    Name = "AppALB"
  }
}

# Target Group (Grupo Objetivo)
resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.app_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# Listener (Escuchador en el puerto 80 que envía al Target Group)
resource "aws_lb_listener" "http_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Template File para User Data (Instalación de Apache)
data "template_file" "user_data" {
  template = file("${path.module}/user_data.sh")
}

# Launch Template (Plantilla para las instancias)
# Este bloque corrige todos los errores de sintaxis HCL anteriores.
resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-lt"
  # **AMI CORRECTA PARA us-east-1**
  image_id      = "ami-0019c8bbda361f500" 
  instance_type = "t2.micro"

  # Script de instalación de Apache
  user_data     = base64encode(data.template_file.user_data.rendered) 
  
  # Configuración de Red: Asociar IP pública y SG de la aplicación
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app_sg.id]
  }

  # Tags para el recurso Launch Template
  tags = {
    Name = "AppLaunchTemplate"
  }
  
  # Especificación de Tags para las instancias que cree el ASG
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "AppInstance"
      Environment = "Dev"
    }
  }
}

# Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "app_asg" {
  name                      = "app-asg"
  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]
  target_group_arns         = [aws_lb_target_group.app_tg.arn]
  
  # Capacidad deseada, mínima y máxima
  desired_capacity          = 4
  min_size                  = 4
  max_size                  = 6
  
  # Conexión a la plantilla de lanzamiento
  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300
}

# ----------------------------------------------------
# 5. Salidas (Outputs)
# ----------------------------------------------------

output "load_balancer_dns_name" {
  description = "El DNS name del Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}
