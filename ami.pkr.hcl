packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ------------------------------------------------------------------------------
# Source Configuration (Amazon EBS)
# ------------------------------------------------------------------------------
source "amazon-ebs" "go_app_with_cloudwatch" {
  region  = "us-west-2"

  # We'll use a filter to pick the latest Amazon Linux 2 AMI
  source_ami_filter {
    filters = {
      name                = "amzn2-ami-hvm-2.0.*-x86_64-gp2"
      "virtualization-type" = "hvm"
      "root-device-type"    = "ebs"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  instance_type    = "t3.micro"
  ssh_username     = "ec2-user"
  ami_name         = "go-app-with-cloudwatch-{{timestamp}}"
  ami_description  = "Pre-baked AMI with Go and CloudWatch agent"

  tags = {
    Name = "go-app-with-cloudwatch"
  }
}

# ------------------------------------------------------------------------------
# Build Block: Provisioners
# ------------------------------------------------------------------------------
build {
  name    = "build-go-app-with-cloudwatch"
  sources = [
    "source.amazon-ebs.go_app_with_cloudwatch"
  ]

  # ----------------------------------------------------------------------------
  # First shell provisioner: install dependencies, clone, build
  # ----------------------------------------------------------------------------
  provisioner "shell" {
    # Comments in HCL are placed outside the array
    inline = [
      # 0) (Optional) Kill background yum so it doesn't lock:
      "sudo pkill -9 yum || true",
      "sudo rm -f /var/run/yum.pid || true",

      # 1) Now run yum update
      "sudo yum update -y",

      # 2) Install Go
      "curl -OL https://go.dev/dl/go1.24.0.linux-amd64.tar.gz",
      "sudo tar -C /usr/local -xzf go1.24.0.linux-amd64.tar.gz",
      "echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh",
      "sudo chmod 644 /etc/profile.d/go.sh",              # Ensure read permission
      "source /etc/profile.d/go.sh",                      # Now you can safely source it

      # 3) Install Git
      "sudo yum install -y git",

      # 4) Clone your Go server code
      "git clone https://github.com/centralperkcafe/CS6650HW6_GO.git /home/ec2-user/go-server",
      "cd /home/ec2-user/go-server",

      # 5) Build the server
      "/usr/local/go/bin/go build -o /home/ec2-user/go-server/CS6650HW6_GO main.go",

      # 6) Install CloudWatch agent
      "sudo yum install -y amazon-cloudwatch-agent"
    ]
  }

  # ----------------------------------------------------------------------------
  # File provisioner: upload CloudWatch agent config
  # ----------------------------------------------------------------------------
  provisioner "file" {
    source      = "cloudwatch-agent-config.json"
    destination = "/tmp/cloudwatch-agent-config.json"
  }

  # ----------------------------------------------------------------------------
  # Second shell provisioner: configure CloudWatch Agent + systemd service
  # ----------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      # 6) Move config and set up the agent to start at boot
      "sudo cp /tmp/cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json",
      "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a stop",
      "sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -m ec2",

      # 7) Create a Systemd service for the Go app to start on boot
      "cat << 'EOF' | sudo tee /etc/systemd/system/go-demo.service\n[Unit]\nDescription=Go Demo Server\nAfter=network.target\n[Service]\nType=simple\nExecStart=/home/ec2-user/go-server/CS6650HW6_GO\nRestart=always\nUser=ec2-user\n[Install]\nWantedBy=multi-user.target\nEOF",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable go-demo.service",

      # Stop the service so it doesn't keep running during image creation
      "sudo systemctl stop go-demo.service"
    ]
  }
}
