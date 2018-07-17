variable "region" {
  default = "eu-west-1"
}

provider "aws" {
  region  = "${var.region}"
}

resource "aws_vpc" "kube" {
  cidr_block = "10.240.0.0/24"

  tags {
    Name = "kubernetes-the-hard-way"
  }
}

resource "aws_flow_log" "test_flow_log" {
  log_group_name = "${aws_cloudwatch_log_group.test_log_group.name}"
  iam_role_arn   = "${aws_iam_role.test_role.arn}"
  vpc_id         = "${aws_vpc.kube.id}"
  traffic_type   = "ALL"
}

resource "aws_cloudwatch_log_group" "test_log_group" {
  name = "test_log_group"
}

resource "aws_iam_role" "test_role" {
  name = "AWSFlowLogsRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "vpc-flow-logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "test_policy" {
  name = "test_policy"
  role = "${aws_iam_role.test_role.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_subnet" "kube" {
  vpc_id     = "${aws_vpc.kube.id}"
  cidr_block = "10.240.0.0/24"

  tags {
    Name = "kube"
  }
}

resource "aws_internet_gateway" "kube" {
  vpc_id = "${aws_vpc.kube.id}"

  tags {
    Name = "kube"
  }
}

resource "aws_route_table" "r" {
  vpc_id = "${aws_vpc.kube.id}"

  tags {
    Name = "kube"
  }
}

resource "aws_route" "default" {
  route_table_id         = "${aws_route_table.r.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.kube.id}"
}

resource "aws_route_table_association" "a" {
  subnet_id      = "${aws_subnet.kube.id}"
  route_table_id = "${aws_route_table.r.id}"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_security_group" "kube" {
  name        = "allow_all"
  description = "Allow all inbound traffic"
  vpc_id      = "${aws_vpc.kube.id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "controller" {
  count = 3

  ami                    = "${data.aws_ami.ubuntu.id}"
  instance_type          = "t2.micro"
  key_name               = "leo"
  subnet_id              = "${aws_subnet.kube.id}"
  vpc_security_group_ids = ["${aws_security_group.kube.id}"]

  private_ip = "10.240.0.1${count.index}"

  user_data = "name=controller-${count.index}"

  associate_public_ip_address = true

  root_block_device {
    volume_size = "200"
  }

  tags {
    Name = "controller-${count.index}"
  }
}

resource "aws_instance" "worker" {
  count = 3

  ami                    = "${data.aws_ami.ubuntu.id}"
  instance_type          = "t2.micro"
  key_name               = "leo"
  subnet_id              = "${aws_subnet.kube.id}"
  vpc_security_group_ids = ["${aws_security_group.kube.id}"]

  private_ip = "10.240.0.2${count.index}"

  user_data = "name=worker-${count.index}|pod-cidr=10.200.${count.index}.0/24"

  source_dest_check = "false"

  associate_public_ip_address = true

  root_block_device {
    volume_size = "200"
  }

  tags {
    Name     = "worker-${count.index}"
  }
}

resource "aws_route" "kube" {
  count = 3

  route_table_id         = "${aws_route_table.r.id}"
  destination_cidr_block = "10.200.${count.index}.0/24"
  network_interface_id   = "${element(aws_instance.worker.*.network_interface_id, count.index)}"
}

resource "aws_eip" "lb" {}

resource "aws_lb" "kube" {
  name               = "kthw-lb"
  load_balancer_type = "network"

  //subnets = ["${aws_subnet.kube.id}"]

  subnet_mapping {
    subnet_id     = "${aws_subnet.kube.id}"
    allocation_id = "${aws_eip.lb.id}"
  }
}

resource "aws_lb_target_group" "tg" {
  name     = "kthw-lb-tg"
  port     = 6443
  protocol = "TCP"
  vpc_id   = "${aws_vpc.kube.id}"
}

resource "aws_lb_target_group_attachment" "test" {
  count = "3"

  target_group_arn = "${aws_lb_target_group.tg.arn}"
  target_id        = "${element(aws_instance.controller.*.id, count.index)}"
  port             = 6443
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = "${aws_lb.kube.arn}"
  port              = "6443"
  protocol          = "TCP"

  default_action {
    target_group_arn = "${aws_lb_target_group.tg.arn}"
    type             = "forward"
  }
}

output "lb_dns_name" {
  value = "${aws_lb.kube.dns_name}"
}

output "lb_eip" {
  value = "${aws_eip.lb.public_ip}"
}

output "controllers_public_ips" {
  value = "${zipmap(
    aws_instance.controller.*.id, aws_instance.controller.*.public_ip
  )}"
}

output "controllers_private_ips" {
  value = "${zipmap(
    aws_instance.controller.*.id, aws_instance.controller.*.private_ip
  )}"
}

output "workers_public_ips" {
  value = "${zipmap(
    aws_instance.worker.*.id, aws_instance.worker.*.public_ip
  )}"
}

output "workers_private_ips" {
  value = "${zipmap(
    aws_instance.controller.*.id, aws_instance.worker.*.private_ip
  )}"
}
