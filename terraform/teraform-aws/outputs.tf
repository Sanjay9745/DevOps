
output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.my_ec2.id
}

output "public_ip" {
  description = "EC2 Public IP"
  value       = aws_instance.my_ec2.public_ip
}

output "private_ip" {
  description = "EC2 Private IP"
  value       = aws_instance.my_ec2.private_ip
}

output "instance_state" {
  description = "EC2 Instance State"
  value       = aws_instance.my_ec2.instance_state
}
