output "load_balancer_dns_name" {
  description = "DNS Name del Application Load Balancer"
  value       = aws_lb.app_lb.dns_name
}