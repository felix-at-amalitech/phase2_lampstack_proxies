# Comprehensive Documentation: SIMPLE LAMP Stack APP (Healthy Fruits in season (For Ghana)) on AWS

## 1. Overview

This document describes the deployment of a LAMP stack application (Apache, PHP 7.4, MySQL) on AWS EC2 instances, with Apache serving as both the web server and reverse proxy. The setup script runs as a `systemd` background service (`lamp-setup.service`) triggered by Apache startup, replacing the traditional user data approach for modularity. The application, a PHP page (`index.php`) displaying a table of healthy Ghanaian fruits, connects to an RDS MySQL database. An ALB distributes traffic, and CloudWatch and X-Ray provide monitoring, logging, and observability. Security measures protect the stack, and future improvements are proposed for performance and security.

### Objectives

- Deploy a reliable, scalable, and secure LAMP stack without containerization.
- Use Apache as the web server and reverse proxy, with setup tasks as a background service.
- Integrate observability for real-time performance and availability insights.
- Address past issues: MySQL GPG key errors, network check failures, `utf8mb4` charset.
- Provide a roadmap for performance testing and security enhancements.

### AWS Well-Architected Framework Alignment

- **Reliability**: Auto Scaling, ALB health checks, and `systemd` service retries.
- **Security**: IMDSv2, SSM Parameter Store, least privilege IAM, security groups.
- **Operational Excellence**: CloudWatch Logs, Metrics, Alarms, and X-Ray tracing.
- **Cost Optimization**: `t3.micro` instances, minimal CloudWatch usage.
- **Scalability**: ALB and Auto Scaling handle traffic spikes.

## 2. Architecture

### Components

- **Network**:
  - VPC: `LAMP-VPC` (CIDR: `10.0.0.0/16`).
  - Subnets: `LAMP-Public-Subnet-1` (`eu-west-1a`, `10.0.1.0/24`), `LAMP-Public-Subnet-2` (`eu-west-1b`, `10.0.2.0/24`).
- **Application**:
  - EC2 instances: `t3.micro`, Amazon Linux 2, in Auto Scaling group (`LAMP-ASG`).
  - Apache: Web server and reverse proxy (`mod_proxy`, port 80).
  - PHP 7.4: Runs `index.php` in `/var/www/html`.
  - MySQL client: Connects to RDS.
  - `systemd` service: `lamp-setup.service` runs `lamp-setup.sh` for setup tasks.
- **Load Balancer**:
  - ALB: `LAMP-ALB`, distributes HTTP traffic to `LAMP-TargetGroup`.
- **Database**:
  - RDS MySQL 8.0: `lampdb`, `db.t3.micro`, Multi-AZ optional, endpoint `lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com`.
- **Security**:
  - IAM role: `LAMP-EC2-SSM-Role` for SSM, CloudWatch, X-Ray.
  - Security groups: `LAMP-Web-SG` (HTTP 80 from ALB), `LAMP-DB-SG` (MySQL 3306 from EC2).
  - SSM Parameter Store: `/lamp/db/username`, `/lamp/db/password`.
- **Observability**:
  - CloudWatch Logs: `/aws/ec2/lamp` for Apache, setup, and MySQL logs.
  - CloudWatch Metrics: CPU, memory, disk, network.
  - CloudWatch Alarms: High CPU, HTTP 5xx, unhealthy hosts.
  - X-Ray: Traces PHP requests to RDS.

### Diagram

```
[Internet] --> [ALB: LAMP-ALB (HTTP:80)]
                    |
                    v
[LAMP-ASG: EC2 t3.micro (Apache, PHP, lamp-setup.service)]
                    |
                    v
[RDS MySQL: lampdb (MySQL:3306)]
                    |
[SSM Parameter Store: /lamp/db/*]
                    |
[Observability and Logging: CloudWatch Logs/Metrics/Alarms, X-Ray]
```

## 3. Prerequisites

- AWS account with access to `eu-west-1`.
- Existing setup:
  - VPC: `LAMP-VPC`, public subnets, internet gateway.
  - RDS: `lampdb`, MySQL 8.0, accessible from EC2.
  - SSM parameters: `/lamp/db/username`, `/lamp/db/password`.
  - ALB: `LAMP-ALB` with target group `LAMP-TargetGroup`.
  - Security groups: `LAMP-Web-SG`, `LAMP-DB-SG`.
  - IAM role: `LAMP-EC2-SSM-Role`.
- Basic AWS Management Console knowledge.

## 4. Deployment Steps

### 4.1 Update IAM Role

- **Goal**: Grant EC2 instances access to SSM, CloudWatch, and X-Ray.
- **Console Steps**:
  1. Go to IAM > Roles > `LAMP-EC2-SSM-Role` > Permissions > Edit policy.
  2. Replace with the following policy, updating `<account-id>`:

     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Action": [
             "ssm:GetParameter",
             "ssm:GetParameters"
           ],
           "Resource": "arn:aws:ssm:eu-west-1:<account-id>:parameter/lamp/db/*"
         },
         {
           "Effect": "Allow",
           "Action": [
             "cloudwatch:PutMetricData",
             "logs:CreateLogGroup",
             "logs:CreateLogStream",
             "logs:PutLogEvents",
             "logs:DescribeLogStreams"
           ],
           "Resource": "*"
         },
         {
           "Effect": "Allow",
           "Action": [
             "xray:PutTraceSegments",
             "xray:PutTelemetryRecords"
           ],
           "Resource": "*"
         }
       ]
     }
     ```

  3. Click “Update policy”.

### 4.2 Set-up Launch Template

- **Goal**: Configure EC2 instances with Apache, `systemd` service, and user data to create setup files.
- **Console Steps**:
  1. Go to EC2 > Launch Templates > `LAMP-LaunchTemplate` > Actions > Modify template (create new version) or create a new launch template.
  2. **Instance Type**: `t3.micro`, Amazon Linux 2 AMI (e.g., `ami-0c55b159cbfafe1f0`).
  3. **Network Settings**:
     - VPC: `LAMP-VPC`.
     - Subnets: `LAMP-Public-Subnet-1`, `LAMP-Public-Subnet-2`.
     - Security group: `LAMP-Web-SG`.
  4. **Advanced Details**:
     - IAM instance profile: `LAMP-EC2-SSM-Role`.
     - Metadata options: Enabled, IMDSv2 required, hop limit 2.
     - User data: please see the lamp-user-data.sh script.

  5. Click “Create template version”.
  6. Set as default version.

### 4.3 Update Auto Scaling Group

- **Goal**: Ensure instances use the Launch Template.
- **Console Steps**:
  1. Go to EC2 > Auto Scaling Groups > `LAMP-ASG` > Actions > Edit.
  2. Update Launch Template to the new version.
  3. Verify:
     - Desired capacity: 2.
     - Min: 1, Max: 4.
     - Subnets: `LAMP-Public-Subnet-1`, `LAMP-Public-Subnet-2`.
  4. Click “Update”.
  5. Terminate existing instances to force new ones.

### 4.4 Verify ALB Configuration

- **Goal**: Ensure ALB routes traffic correctly.
- **Console Steps**:
  1. Go to EC2 > Load Balancers > `LAMP-ALB`.
  2. Confirm:
     - Listener: HTTP:80, forwarding to `LAMP-TargetGroup`.
     - Health checks: Path `/`, HTTP 200, success codes 200.
     - Subnets: `LAMP-Public-Subnet-1`, `LAMP-Public-Subnet-2`.
  3. Update or recreate ALB if needed.

### 4.5 Verify RDS Parameter Group

- **Goal**: Ensure `utf8mb4` charset for database compatibility.
- **Console Steps**:
  1. Go to RDS > Parameter Groups.
  2. Check `lampdb` parameter group:
     - `character_set_client`, `character_set_connection`, `character_set_database`, `character_set_server`: `utf8mb4`
     - `collation_connection`, `collation_server`: `utf8mb4_unicode_ci`
  3. Modify `lampdb` instance to use this group if needed (may require reboot).

### 4.6 Configure CloudWatch

- **Goal**: Set up logging, metrics, and alarms.
- **Console Steps**:
  1. Go to CloudWatch > Logs > Log groups.
     - Verify `/aws/ec2/lamp` with streams: `<instance-id>/httpd-access`, `<instance-id>/httpd-error`, `<instance-id>/lamp-setup`, `<instance-id>/mysql-test`.
  2. Go to CloudWatch > Metrics > CWAgent.
     - Check metrics: `cpu_usage_active`, `mem_used_percent`, `disk_used_percent`, `net_bytes_sent`, `net_bytes_recv`.
  3. Create alarms:
     - **High CPU**:
       - Metric: `CWAgent > cpu_usage_active`, Average, 5 min, > 70%, 2 periods.
       - Action: SNS topic (create if needed).
       - Name: `LAMP-HighCPU`.
     - **HTTP 5xx Errors**:
       - Metric: `AWS/ApplicationELB > HTTPCode_ELB_5XX_Count`, Sum, 5 min, > 10, 2 periods.
       - Action: SNS topic.
       - Name: `LAMP-HTTP5xx`.
     - **Unhealthy Hosts**:
       - Metric: `AWS/ApplicationELB > UnHealthyHostCount`, Average, 5 min, > 0, 2 periods.
       - Action: SNS topic.
       - Name: `LAMP-UnhealthyHosts`.

### 4.7 Enable X-Ray Tracing

- **Goal**: Trace PHP requests to RDS.
- **Console Steps**:
  1. Go to X-Ray > Settings.
  2. Enable tracing for `LAMP-ALB`.
  3. Verify traces in X-Ray > Traces after accessing the application.

### 4.8 Verify Application

- **Goal**: Confirm functionality.
- **Steps**:
  1. Access ALB DNS (e.g., `http://lamp-alb-191503170.eu-west-1.elb.amazonaws.com/`).
  2. Verify “Healthy Ghanaian Fruits” table displays.
  3. Check CloudWatch Logs (`/aws/ec2/lamp`) and X-Ray traces for errors.

## 5. Security Measures

### 5.1 Network Security

- **Security Groups**:
  - `LAMP-Web-SG`:
    - Inbound: HTTP 80 from `LAMP-ALB-SG`, SSH 22 (optional, restricted to admin IP).
    - Outbound: All traffic (for SSM, RDS, CloudWatch).
  - `LAMP-DB-SG`:
    - Inbound: MySQL 3306 from `LAMP-Web-SG`.
    - Outbound: None (RDS doesn’t initiate connections).
  - `LAMP-ALB-SG`:
    - Inbound: HTTP 80 from 0.0.0.0/0 (public access).
    - Outbound: HTTP 80 to `LAMP-Web-SG`.
- **VPC**: Public subnets for EC2 and ALB, with internet gateway for external access.

### 5.2 Identity and Access Management

- **IAM Role (`LAMP-EC2-SSM-Role`)**:
  - Least privilege: Grants only necessary permissions (SSM, CloudWatch, X-Ray).
  - Scoped to specific SSM parameters (`/lamp/db/*`).
- **SSM Parameter Store**:
  - Stores DB credentials securely (`/lamp/db/username`, `/lamp/db/password`).
  - Password encrypted with AWS-managed KMS key.
- **IMDSv2**: Enforces token-based metadata access to prevent SSRF attacks.

### 5.3 Application Security

- **PHP Input Sanitization**:
  - `index.php` uses `htmlspecialchars` to prevent XSS when displaying database results.
- **Database Security**:
  - RDS credentials retrieved dynamically from SSM, not hardcoded.
  - `utf8mb4` charset ensures consistent character encoding, preventing injection risks.
  - MySQL user has minimal privileges (e.g., `SELECT`, `INSERT`, `CREATE`, `DROP` on `lampdb`).
- **Apache Configuration**:
  - `mod_proxy` configured securely with `ProxyPreserveHost On`.
  - Default Apache settings hardened (e.g., disable directory listing).

### 5.4 Data Protection

- **RDS Encryption**:
  - At rest: Enabled with AWS-managed KMS key.
  - In transit: MySQL connections use SSL (optional, can be enforced).
- **CloudWatch Logs**:
  - Encrypted at rest with AWS-managed keys.
  - Access restricted via IAM role.

### 5.5 Logging and Monitoring

- **CloudWatch Logs**: Captures Apache, setup, and MySQL logs for auditability.
- **X-Ray**: Traces requests to detect anomalies or unauthorized access.
- **CloudWatch Alarms**: Alerts on suspicious activity (e.g., HTTP 5xx spikes).

## 6. Monitoring and Observability

### 6.1 CloudWatch Logs

- **Log Group**: `/aws/ec2/lamp`.
- **Streams**:
  - `<instance-id>/httpd-access`: Apache access logs.
  - `<instance-id>/httpd-error`: Apache error logs.
  - `<instance-id>/lamp-setup`: Setup service logs.
  - `<instance-id>/mysql-test`: MySQL connection test logs.
- **Usage**: Debug application errors, track HTTP requests, audit setup failures.

### 6.2 CloudWatch Metrics

- **Namespace**: `CWAgent`.
- **Metrics**:
  - `cpu_usage_active`: CPU utilization (%).
  - `mem_used_percent`: Memory usage (%).
  - `disk_used_percent`: Disk usage (%).
  - `net_bytes_sent`, `net_bytes_recv`: Network traffic.
- **ALB Metrics**:
  - `AWS/ApplicationELB > HTTPCode_ELB_5XX_Count`: Server errors.
  - `AWS/ApplicationELB > UnHealthyHostCount`: Failed health checks.
- **Usage**: Monitor resource utilization and application health.

### 6.3 CloudWatch Alarms

- **High CPU**: Triggers at > 70% for 10 min, notifies via SNS.
- **HTTP 5xx Errors**: Triggers at > 10 errors in 10 min.
- **Unhealthy Hosts**: Triggers if any hosts fail health checks for 10 min.
- **Usage**: Proactive alerting for performance or availability issues.

### 6.4 X-Ray Tracing

- **Enabled**: For `LAMP-ALB` and `index.php` (via AWS SDK).
- **Traces**: PHP requests to RDS, including query latency and errors.
- **Usage**: Diagnose slow queries, connection issues, or bottlenecks.

## 7. Troubleshooting

### 7.1 User Data or File Creation Issues

- **Symptom**: `lamp-setup.sh` or `lamp-setup.service` missing.
- **Check**:
  - `cat /var/log/user-data.log`
  - `cat /var/log/cloud-init-output.log`
  - `ls -l /usr/local/bin/lamp-setup.sh`
  - `ls -l /etc/systemd/system/lamp-setup.service`
- **Fix**: Ensure user data script is correctly pasted in Launch Template. Redeploy instances.

### 7.2 Setup Service Failure

- **Symptom**: Application fails to load, database not initialized.
- **Check**:
  - `cat /var/log/lamp-setup.log`
  - `systemctl status lamp-setup.service`
  - `journalctl -u lamp-setup.service`
- **Fix**:
  - Restart service: `sudo systemctl restart lamp-setup.service`
  - Check for errors in `lamp-setup.log` (e.g., SSM access, MySQL connection).

### 7.3 Apache/Proxy Issues

- **Symptom**: HTTP 500 or no response.
- **Check**:
  - `cat /var/log/httpd/error_log`
  - `httpd -M | grep proxy`
  - `cat /etc/httpd/conf.d/proxy.conf`
  - `curl http://localhost`
- **Fix**:
  - Verify proxy modules enabled.
  - Restart Apache: `sudo systemctl restart httpd`

### 7.4 MySQL Connection Issues

- **Symptom**: “Connection failed” or charset errors in `index.php`.
- **Check**:
  - `cat /var/log/mysql-test.log`
  - Test connection:

    ```bash
    DB_USER=$(aws ssm get-parameter --name "/lamp/db/username" --region eu-west-1 --query Parameter.Value --output text)
    DB_PASS=$(aws ssm get-parameter --name "/lamp/db/password" --region eu-west-1 --with-decryption --query Parameter.Value --output text)
    mysql -h lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com -u "$DB_USER" -p"$DB_PASS" --default-character-set=utf8mb4 lampdb
    ```

- **Fix**:
  - Verify RDS endpoint, security group (`LAMP-DB-SG`), and SSM parameters.
  - Try `utf8` charset if `utf8mb4` fails.

### 7.5 Observability Issues

- **Symptom**: Missing logs, metrics, or traces.
- **Check**:
  - Logs: `cat /var/log/amazon-cloudwatch-agent.log`
  - Metrics: CloudWatch > Metrics > CWAgent
  - X-Ray: `systemctl status aws-xray-daemon`
- **Fix**:
  - Verify IAM role permissions.
  - Restart agent: `sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start`
  - Restart X-Ray: `sudo systemctl restart aws-xray-daemon`

## 8. Future Improvements

### 8.1 Performance Testing

- **Goal**: Ensure the application handles expected load (~100–500 users/day) and identify bottlenecks.
- **Tools**:
  - **Apache JMeter**:
    - Simulate concurrent users accessing `index.php`.
    - Test plan:
      - Thread Group: 100–500 threads, ramp-up 60s.
      - HTTP Request: GET `http://lamp-alb-191503170.eu-west-1.elb.amazonaws.com/`.
      - Assertions: Response code 200, response time < 500ms.
      - Listeners: Summary Report, View Results Tree.
    - Run locally or on an EC2 instance.
  - **AWS CloudWatch Synthetics**:
    - Create canaries to monitor `index.php` availability every 5 min.
    - Alert on HTTP 5xx or latency > 1s.
  - **AWS X-Ray**:
    - Analyze traces for slow MySQL queries or PHP processing.
- **Metrics to Monitor**:
  - Response time: Target < 500ms.
  - Throughput: Requests per second.
  - Error rate: HTTP 4xx/5xx.
  - Resource utilization: CPU, memory, database connections.
- **Steps**:
  1. Set up JMeter on a local machine or EC2 instance.
  2. Create a test plan targeting the ALB DNS.
  3. Run tests with increasing load (100, 250, 500 users).
  4. Monitor CloudWatch Metrics and X-Ray traces during tests.
  5. Analyze results for bottlenecks (e.g., slow queries, high CPU).
- **Optimizations**:
  - Enable PHP opcode caching (e.g., OPcache).
  - Optimize MySQL queries with indexes (e.g., on `healthy_fruits.name`).
  - Increase EC2 instance type (e.g., `t3.medium`) if CPU/memory constrained.
  - Enable ALB caching for static assets (if added).

### 8.2 Additional Security Considerations

- **HTTPS Enablement**:
  - Configure ALB with an ACM certificate for HTTPS.
  - Redirect HTTP to HTTPS in ALB listener rules.
  - Update health checks to HTTPS:443.
- **Web Application Firewall (WAF)**:
  - Deploy AWS WAF on ALB.
  - Enable rules for SQL injection, XSS, and common vulnerabilities (e.g., AWS Managed Rules).
  - Monitor WAF logs in CloudWatch.
- **RDS SSL/TLS**:
  - Enforce SSL for MySQL connections:
    - Download RDS CA certificate: `wget https://s3.amazonaws.com/rds-downloads/rds-combined-ca-bundle.pem`.
    - Update `index.php` to use SSL:
    - Set RDS parameter `require_secure_transport` to `ON`.
- **VPC Endpoints**:
  - Create SSM VPC endpoint to avoid internet access for parameter retrieval.
  - Use private subnets for EC2 with NAT Gateway for outbound traffic.
- **Security Headers**:
  - Add to Apache (`/etc/httpd/conf.d/security.conf`):
  - Restart Apache: `sudo systemctl restart httpd`.
- **Automated Patching**:
  - Use AWS Systems Manager Patch Manager to apply OS and application patches.
  - Schedule weekly patch scans and installations.
- **Penetration Testing**:
  - Conduct regular tests using tools like OWASP ZAP or AWS Inspector.
  - Focus on XSS, SQL injection, and misconfigurations.
- **Backup and Recovery**:
  - Enable RDS automated backups with 7-day retention.
  - Test restore process to ensure data recovery.

### 8.3 Scalability Enhancements

- **Database Scaling**:
  - Enable RDS read replicas for read-heavy workloads.
  - Upgrade to `db.t3.medium` or Aurora MySQL for higher performance.
- **Application Scaling**:
  - Adjust Auto Scaling policies based on CloudWatch metrics (e.g., CPU > 70% for 5 min).
  - Consider Elastic Beanstalk for managed scaling if complexity grows.
- **Caching**:
  - Deploy Amazon ElastiCache (Redis) for session storage or query caching.
  - Cache static assets with CloudFront CDN (if added).

### 8.4 Operational Improvements

- **Infrastructure as Code (IaC)**:
  - Migrate to AWS CloudFormation or Terraform for reproducible deployments.
  - Template example: VPC, EC2, ALB, RDS, IAM roles.
- **CI/CD Pipeline**:
  - Use AWS CodePipeline and CodeDeploy to automate `index.php` updates.
  - Store code in CodeCommit or GitHub.
- **Enhanced Monitoring**:
  - Create CloudWatch Dashboards for key metrics (CPU, latency, error rates).
  - Integrate AWS Trusted Advisor for cost and security recommendations.

## 9. Clean Up

To avoid costs, delete resources when no longer needed:

1. **SSM Parameters**:
   - Go to Systems Manager > Parameter Store.
   - Delete `/lamp/db/username`, `/lamp/db/password`.
2. **CloudWatch Log Group**:
   - Go to CloudWatch > Logs > Log groups.
   - Delete `/aws/ec2/lamp`.
3. **Auto Scaling Group**:
   - Go to EC2 > Auto Scaling Groups > `LAMP-ASG` > Actions > Delete.
   - Wait for instances to terminate.
4. **ALB**:
   - Go to EC2 > Load Balancers > `LAMP-ALB` > Actions > Delete.
5. **Launch Template**:
   - Go to EC2 > Launch Templates > `LAMP-LaunchTemplate` > Actions > Delete.
6. **RDS Instance**:
   - Go to RDS > Databases > `lampdb` > Actions > Delete.
   - Disable final snapshot (optional).
7. **VPC and Subnets**:
   - Go to VPC > Your VPCs > `LAMP-VPC` > Actions > Delete.
   - Delete subnets, internet gateway, route tables.

## 10. Notes

- **Region/Endpoint**: Configured for `eu-west-1`, `lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com`.
- **Assumptions**: Existing VPC, RDS, ALB, and SSM parameters match prior setup.
- **Cost Estimate**: ~$20/month for 2 `t3.micro`, `db.t3.micro`, ALB, and minimal CloudWatch/X-Ray usage.

## 11. Conclusion

This deployment provides a secure, reliable, and observable LAMP stack application using Apache as the web server and reverse proxy, with setup tasks managed by a `systemd` service. The solution is cost-effective, scalable, and aligned with AWS best practices. Future improvements, including performance testing with JMeter and security enhancements like WAF and HTTPS, ensure the application can evolve with growing demands. For issues,open issues on this github repo and share logs and relevant information and further assistance will be provided.
