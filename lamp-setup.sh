#!/bin/bash

# Log output for debugging
exec > /var/log/lamp-setup.log 2>&1
set -x

# Set AWS region
export AWS_DEFAULT_REGION=eu-west-1

# Function to check instance metadata availability
wait_for_metadata() {
  local max_attempts=12
  local wait_seconds=5
  local attempt=1
  local total_timeout=300
  local start_time=$(date +%s)

  echo "Checking for instance metadata availability..."
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt: Trying IMDSv2..."
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$TOKEN" ]; then
      INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
      if [ $? -eq 0 ] && [ -n "$INSTANCE_ID" ]; then
        echo "IMDSv2 succeeded. Instance ID: $INSTANCE_ID"
        return 0
      fi
    fi
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $total_timeout ]; then
      echo "Error: Metadata service not available after $total_timeout seconds"
      exit 1
    fi
    echo "IMDSv2 failed, retrying..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
    wait_seconds=$((wait_seconds * 2))
  done
  echo "Error: Failed to access metadata service"
  exit 1
}

# Function to check network connectivity using nslookup
wait_for_network() {
  local max_attempts=12
  local wait_seconds=5
  local attempt=1
  echo "Checking for network connectivity via DNS resolution..."
  until nslookup ssm.eu-west-1.amazonaws.com > /dev/null 2>&1; do
    if [ $attempt -ge $max_attempts ]; then
      echo "Error: DNS resolution for SSM endpoint failed after $max_attempts attempts"
      exit 1
    fi
    echo "Attempt $attempt: Waiting for DNS resolution..."
    sleep $wait_seconds
    attempt=$((attempt + 1))
    wait_seconds=$((wait_seconds * 2))
  done
  echo "DNS resolution for SSM endpoint succeeded"
}

# Wait for metadata and network
wait_for_metadata
wait_for_network

# Install dependencies
sudo yum update -y
sudo amazon-linux-extras enable php7.4
sudo yum install -y php php-mysqlnd php-mysqli awscli amazon-cloudwatch-agent aws-xray-daemon php-pear php-devel gcc
sudo yum install -y https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm
sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022 || {
  echo "Failed to import MySQL GPG key"
  exit 1
}
sudo yum install -y mysql-community-client || {
  echo "Failed to install mysql-community-client"
  exit 1
}
sudo pear install aws/aws-sdk-php
sudo mkdir -p /var/www/html/vendor
sudo mv /usr/share/pear/aws /var/www/html/vendor/

# Retrieve database credentials from SSM Parameter Store
get_ssm_parameter() {
  local param_name=$1
  local max_attempts=5
  local wait_seconds=5
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt: Retrieving SSM parameter $param_name"
    local value
    if [ "$param_name" == "/lamp/db/password" ]; then
      value=$(aws ssm get-parameter --name "$param_name" --with-decryption --query Parameter.Value --output text 2>/dev/null)
    else
      value=$(aws ssm get-parameter --name "$param_name" --query Parameter.Value --output text 2>/dev/null)
    fi
    if [ $? -eq 0 ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
    echo "Failed to retrieve $param_name"
    sleep $wait_seconds
    attempt=$((attempt + 1))
    wait_seconds=$((wait_seconds * 2))
  done
  echo "Error: Failed to retrieve $param_name after $max_attempts attempts"
  exit 1
}

DB_USER=$(get_ssm_parameter "/lamp/db/username")
DB_PASS=$(get_ssm_parameter "/lamp/db/password")

# Log credentials (for debugging, remove in production)
echo "DB_USER: $DB_USER"
echo "DB_PASS: [redacted]"

# Test MySQL connection
mysql -h lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com -u "$DB_USER" -p"$DB_PASS" --default-character-set=utf8mb4 lampdb -e "SELECT VERSION();" > /var/log/mysql-test.log 2>&1 || {
  echo "MySQL connection test failed"
  cat /var/log/mysql-test.log
  exit 1
}

# Initialize database
mysql -h lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com -u "$DB_USER" -p"$DB_PASS" --default-character-set=utf8mb4 lampdb -e "DROP TABLE IF EXISTS healthy_fruits;" || {
  echo "Failed to drop table"
  exit 1
}
mysql -h lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com -u "$DB_USER" -p"$DB_PASS" --default-character-set=utf8mb4 lampdb -e "CREATE TABLE healthy_fruits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL UNIQUE,
    benefits TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || {
  echo "Failed to create table"
  exit 1
}
mysql -h lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com -u "$DB_USER" -p"$DB_PASS" --default-character-set=utf8mb4 lampdb -e "
INSERT INTO healthy_fruits (name, benefits) VALUES
('Pineapple', 'Rich in Vitamin C and manganese, contains bromelain for anti-inflammatory properties.'),
('Mango', 'Packed with Vitamin C, Vitamin A, and fiber, contains various antioxidants.'),
('Banana', 'Excellent source of potassium, Vitamin B6, and Vitamin C, provides energy.'),
('Plantain', 'Starchy, good source of complex carbohydrates, vitamins, and minerals, often cooked.'),
('Soursop (Aluguntugui)', 'High in Vitamin C, known for potential antioxidant and anti-inflammatory properties.'),
('African Star Apple (Alasa)', 'Good source of calcium and Vitamin C, believed to aid digestion.'),
('Velvet Tamarind (Yooyi)', 'High in Vitamin C, iron, magnesium, and dietary fiber, tart-sweet.'),
('Guava', 'Rich in Vitamin C, dietary fiber, and antioxidants, supports immunity.'),
('Papaya', 'Rich in Vitamin C, Vitamin A, and the enzyme papain which aids digestion.');" || {
  echo "Failed to insert data"
  exit 1
}

# Configure CloudWatch Agent
cat <<EOF > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "agent": {
    "metrics_collection_interval": 60,
    "logfile": "/var/log/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/httpd/access_log",
            "log_group_name": "/aws/ec2/lamp",
            "log_stream_name": "{instance_id}/httpd-access"
          },
          {
            "file_path": "/var/log/httpd/error_log",
            "log_group_name": "/aws/ec2/lamp",
            "log_stream_name": "{instance_id}/httpd-error"
          },
          {
            "file_path": "/var/log/lamp-setup.log",
            "log_group_name": "/aws/ec2/lamp",
            "log_stream_name": "{instance_id}/lamp-setup"
          },
          {
            "file_path": "/var/log/mysql-test.log",
            "log_group_name": "/aws/ec2/lamp",
            "log_stream_name": "{instance_id}/mysql-test"
          }
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_active"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 60
      },
      "net": {
        "measurement": ["net_bytes_sent", "net_bytes_recv"],
        "metrics_collection_interval": 60
      }
    },
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    }
  }
}
EOF

sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Log versions
php -v >> /var/log/lamp-setup.log
mysql --version >> /var/log/lamp-setup.log

echo "Setup completed successfully"