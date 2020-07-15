# Provide Credentials
 
provider "aws" {
  region = "ap-south-1"
  profile = "admin"
}

# Create VPC and Subnets:

resource "aws_vpc" "myvpc" {
  cidr_block = "10.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "myvpc"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public-sn" {
  vpc_id = aws_vpc.myvpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "public-sn"
  }
}

# Create IGW and association of Subnet in RT:

resource "aws_internet_gateway" "my-igw" {
  vpc_id = aws_vpc.myvpc.id

  tags = {
    Name = "my-igw"
  }
}

resource "aws_route_table" "public-rt" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.my-igw.id
  }

  tags = {
    Name = "public-rt"
  } 
}

resource "aws_route_table_association" "pub-sn-assoc" {
  subnet_id = aws_subnet.public-sn.id
  route_table_id = aws_route_table.public-rt.id
}

# Create SG for EFS & Webserver:

resource "aws_security_group" "efs-sg" {
  name = "efs-sg"
  description = "Security Group for EFS"
  vpc_id = aws_vpc.myvpc.id

  ingress {
    description  = "Allow HTTP port"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH port"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow NFS port"
    from_port  = 2049
    to_port = 2049
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow ICMP port"
    from_port = 0
    to_port =0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "efs-sg"
  }
}

# Create a Key-Pair:

resource "tls_private_key" "webappkey" {
  algorithm = "RSA"
  rsa_bits = 4096
}

resource "local_file" "private_key" {
  content = tls_private_key.webappkey.private_key_pem
  filename = "${path.module}/webappkey.pem"
  file_permission = 0400
}

resource "aws_key_pair" "webappkey" {
  key_name = "webappkey"
  public_key = tls_private_key.webappkey.public_key_openssh
}

variable "key" {
  type = string
}

# Create EFS:

resource "aws_efs_file_system" "myefs" {
  creation_token = "myefs"
  performance_mode = "generalPurpose"

  tags = {
    Name = "myefs"
  }
}

# Create EFS Mount Target:

resource "aws_efs_mount_target" "myefs-mount" {
  file_system_id = aws_efs_file_system.myefs.id
  subnet_id = aws_subnet.public-sn.id
  security_groups = [ aws_security_group.efs-sg.id ]
}

# Create EC2 Instance:

resource "aws_instance" "webserver-os" {
  depends_on = [ aws_efs_mount_target.myefs-mount ]
  ami = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  key_name = var.key
  subnet_id = aws_subnet.public-sn.id
  vpc_security_group_ids = [ aws_security_group.efs-sg.id ]
  
  tags = {
    Name = "Webserver-os"
  }
}

resource "null_resource" "nullremote1" {
  depends_on = [
    aws_instance.webserver-os
  ]
  connection {
    type = "ssh"
    user= "ec2-user"
    private_key = tls_private_key.webappkey.private_key_pem
    host = aws_instance.webserver-os.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd php git amazon-efs-utils nfs-utils -y",
      "sudo setenforce 0",
      "sudo systemctl start httpd",
      "sudo systemctl enable httpd",
      "sudo mount -t efs ${aws_efs_file_system.myefs.id}:/ /var/www/html",
      "sudo echo '${aws_efs_file_system.myefs.id}:/ /var/www/html efs defaults,_netdev 0 0' >> /etc/fstab",
      "sudo rm -rf /var/www/html/*",
      "sudo git clone https://github.com/paulpriyanka101/aws-efs.git /var/www/html/"
    ]
  }
}

# Create S3 bucket & copy the image from Git Hub repo:

resource "aws_s3_bucket" "image-bucket" {
  bucket = "webserver-os-image-bucket"
  acl = "public-read"
  region = "ap-south-1"

  tags = {
    Name = "webserver-os-image-bucket"
  }

  provisioner "local-exec" {
   command = "git clone https://github.com/paulpriyanka101/aws-efs.git /Users/priyanka/Desktop/tera-code/task2/repo/"
  }

  provisioner "local-exec" {
    when = destroy
    command = "rm -rf Users/priyanka/Desktop/tera-code/task2/repo"
  }
}

resource "aws_s3_bucket_object" "image-object" {
  depends_on = [ aws_s3_bucket.image-bucket ]
  bucket = aws_s3_bucket.image-bucket.bucket
  key = "download.jpg"
  source = "/Users/priyanka/Desktop/tera-code/task2/repo/download.jpg"
  content_type = "image/jpg"
  acl = "public-read"
}

locals {
    s3_origin_id = "myS3origin-id"
}
resource "aws_cloudfront_origin_access_identity" "origin-access-id" {
    comment = "CloudFront to S3 sync"
}

# Create Cloud-Front using S3:

resource "aws_cloudfront_distribution" "cf-s3-dist" {
  depends_on = [
    aws_key_pair.webappkey, aws_instance.webserver-os
  ]

  origin {
    domain_name = aws_s3_bucket.image-bucket.bucket_regional_domain_name
    origin_id = local.s3_origin_id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin-access-id.cloudfront_access_identity_path
    }
  }

  enabled = true
  is_ipv6_enabled = true
  comment = "Cloudfront to S3 sync"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Cache behavior with precedence 0

  ordered_cache_behavior {
    path_pattern     = "/content/immutable/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD", "OPTIONS"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false
      headers      = ["Origin"]

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  # Cache behavior with precedence 1
  ordered_cache_behavior {
    path_pattern     = "/content/*"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
    compress               = true
    viewer_protocol_policy = "redirect-to-https"
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

}

resource "null_resource" "nullresource" {
  depends_on = [
    aws_cloudfront_distribution.cf-s3-dist
  ]
  connection {
        type = "ssh"
        user = "ec2-user"
        private_key = tls_private_key.webappkey.private_key_pem
        host = aws_instance.webserver-os.public_ip
    }
  provisioner "remote-exec" {
        inline = [
            "sudo su << EOF",
            "echo \"<img src='https://${aws_cloudfront_distribution.cf-s3-dist.domain_name}/${aws_s3_bucket_object.image-object.key }'>\" >> /var/www/html/index.php",
       "EOF"
    ]
  }
    provisioner "local-exec" {
      command = "open http://${aws_instance.webserver-os.public_ip}"
    }
}







