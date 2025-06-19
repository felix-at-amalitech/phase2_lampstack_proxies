#!/bin/bash

# Log output
exec > /var/log/user-data.log 2>&1
set -x

# Install Apache
sudo yum update -y
sudo yum install -y httpd
sudo systemctl start httpd
sudo systemctl enable httpd

# Copy setup scripts
cat <<EOF > /usr/local/bin/lamp-setup.sh
$(cat lamp-setup.sh)
EOF
chmod +x /usr/local/bin/lamp-setup.sh

cat <<EOF > /etc/systemd/system/lamp-setup.service
$(cat lamp-setup.service)
EOF
sudo systemctl enable lamp-setup.service

# Configure Apache as reverse proxy
cat <<EOF > /etc/httpd/conf.d/proxy.conf
<VirtualHost *:80>
    ProxyPreserveHost On
    ProxyPass / http://localhost:80/
    ProxyPassReverse / http://localhost:80/
    <Proxy *>
        Order deny,allow
        Allow from all
    </Proxy>
</VirtualHost>
EOF

# Enable proxy modules
sudo sed -i 's/#LoadModule proxy_module/LoadModule proxy_module/' /etc/httpd/conf.modules.d/00-proxy.conf
sudo sed -i 's/#LoadModule proxy_http_module/LoadModule proxy_http_module/' /etc/httpd/conf.modules.d/00-proxy.conf

# Create index.php
cat <<EOF > /var/www/html/index.php
<html>
<head>
    <title>Healthy Ghanaian Fruits</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
        h1, h2 { color: #0056b3; }
        table {
            width: 80%;
            border-collapse: collapse;
            margin-top: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            background-color: #fff;
        }
        th, td {
            padding: 12px 15px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #e9e9e9;
            color: #555;
            font-weight: bold;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        p {
            margin: 5px 0;
        }
        .error-message {
            color: red;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <h1>Welcome to the Healthy Ghanaian Fruits App!</h1>
    <h2>Fruits in Season:</h2>
    <table>
        <thead>
            <tr>
                <th>Fruit</th>
                <th>Benefits</th>
            </tr>
        </thead>
        <tbody>
            <?php
            require 'vendor/autoload.php';
            use Aws\XRay\XRayClient;
            \$xray = new XRayClient(['version' => 'latest', 'region' => 'eu-west-1']);
            \$xray->beginSegment(['name' => 'HealthyFruitsApp']);

            \$conn = new mysqli('lampdb.czaiaq68azf6.eu-west-1.rds.amazonaws.com', '$DB_USER', '$DB_PASS', 'lampdb');
            if (!\$conn->set_charset('utf8mb4')) {
                echo '<tr><td colspan="2" class="error-message">Failed to set charset: ' . \$conn->error . '</td></tr>';
            }
            if (\$conn->connect_error) {
                echo '<tr><td colspan="2" class="error-message">Connection failed: ' . \$conn->connect_error . '</td></tr>';
            } else {
                \$result = \$conn->query('SELECT name, benefits FROM healthy_fruits');
                if (\$result && \$result->num_rows > 0) {
                    while(\$row = \$result->fetch_assoc()) {
                        echo '<tr><td>' . htmlspecialchars(\$row['name']) . '</td><td>' . htmlspecialchars(\$row['benefits']) . '</td></tr>';
                    }
                } else {
                    echo '<tr><td colspan="2">No healthy fruits found in the database.</td></tr>';
                }
                \$conn->close();
            }
            \$xray->endSegment();
            ?>
        </tbody>
    </table>
</body>
</html>
EOF

# Restart Apache to apply changes
sudo systemctl restart httpd

echo "User data script completed successfully"