variable "aws_region" {
  description = "Región de AWS donde se desplegará la infraestructura."
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "Rango de IP para la VPC."
  default     = "10.0.0.0/16"
}

variable "public_subnets_cidr" {
  description = "CIDRs para las subredes públicas (mínimo 2)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "min_instances" {
  description = "Número mínimo de instancias en el Auto Scaling Group."
  default     = 4
}

variable "max_instances" {
  description = "Número máximo de instancias en el Auto Scaling Group."
  default     = 6
}

variable "instance_type" {
  description = "Tipo de instancia EC2."
  default     = "t2.micro"
}

# Usaremos una AMI de Amazon Linux 2 (ajusta el ID si cambias la región)
variable "ami_id" {
  description = "ID de la AMI para las instancias EC2."
  default     = "ami-0eb26c4832560b45d" 
}