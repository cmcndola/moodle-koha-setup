#!/bin/bash

# Koha + Moodle + Caddy Setup Script for Ubuntu 24.04
# https://github.com/yourusername/koha-moodle-setup
#
# Usage:
#   1. git clone https://github.com/yourusername/koha-moodle-setup.git
#   2. cd koha-moodle-setup
#   3. cp .env.example .env
#   4. edit .env with your configuration
#   5. sudo ./setup.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

info() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

# Check if .env file exists
if [ ! -f .env ]; then
    error ".env file not found! Please copy .env.example to .env and configure it."
fi

# Load environment variables
log "Loading environment configuration..."
source .env

# Validate required environment variables
required_vars=("DOMAIN_KOHA" "DOMAIN_MOODLE" "LETSENCRYPT_EMAIL" "DB_ROOT_PASSWORD" "KOHA_DB_PASSWORD" "MOODLE_DB_PASSWORD")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        error "Required environment variable $var is not set in .env file"
    fi
done

# Set defaults for optional variables
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-512M}
PHP_MAX_UPLOAD=${PHP_MAX_UPLOAD:-512M}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

# Display configuration
info "=== Configuration Summary ==="
echo "Koha Domain: $DOMAIN_KOHA"
echo "Moodle Domain: $DOMAIN_MOODLE"
echo "Let's Encrypt Email: $LETSENCRYPT_EMAIL"
echo "PHP Memory Limit: $PHP_MEMORY_LIMIT"
echo "================================"
echo
read -p "Continue with this configuration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    error "Setup cancelled by user"
fi

log "Starting Koha + Moodle + Caddy setup on Ubuntu 24.04"

# Install MariaDB
log "Installing MariaDB..."
apt install -y mariadb-server mariadb-client
systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB installation
log "Securing MariaDB..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';" 2>/dev/null || true
mysql -u root -p$DB_ROOT_PASSWORD -e "DELETE FROM mysql.user WHERE User='';" 2>/dev/null || true
mysql -u root -p$DB_ROOT_PASSWORD -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" 2>/dev/null || true
mysql -u root -p$DB_ROOT_PASSWORD -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
mysql -u root -p$DB_ROOT_PASSWORD -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" 2>/dev/null || true
mysql -u root -p$DB_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Create databases
log "Creating databases..."
mysql -u root -p$DB_ROOT_PASSWORD -e "CREATE DATABASE IF NOT EXISTS koha_library CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p$DB_ROOT_PASSWORD -e "CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p$DB_ROOT_PASSWORD -e "CREATE USER IF NOT EXISTS 'koha'@'localhost' IDENTIFIED BY '$KOHA_DB_PASSWORD';"
mysql -u root -p$DB_ROOT_PASSWORD -e "CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY '$MOODLE_DB_PASSWORD';"
mysql -u root -p$DB_ROOT_PASSWORD -e "GRANT ALL PRIVILEGES ON koha_library.* TO 'koha'@'localhost';"
mysql -u root -p$DB_ROOT_PASSWORD -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,CREATE TEMPORARY TABLES,DROP,INDEX,ALTER ON moodle.* TO 'moodle'@'localhost';"
mysql -u root -p$DB_ROOT_PASSWORD -e "FLUSH PRIVILEGES;"

# Install PHP and extensions for Moodle (based on official requirements)
log "Installing PHP and extensions..."
apt install -y php8.3-fpm php8.3-mysql php8.3-xml php8.3-xmlrpc php8.3-curl \
    php8.3-gd php8.3-imagick php8.3-cli php8.3-dev php8.3-imap php8.3-mbstring \
    php8.3-opcache php8.3-soap php8.3-zip php8.3-intl php8.3-ldap \
    php8.3-pspell php8.3-bcmath php8.3-exif graphviz aspell ghostscript clamav

# Configure PHP for Moodle (following official recommendations)
log "Configuring PHP..."
sed -i "s/max_execution_time = 30/max_execution_time = 300/" /etc/php/8.3/fpm/php.ini
sed -i "s/max_input_vars = 1000/max_input_vars = 5000/" /etc/php/8.3/fpm/php.ini
sed -i "s/post_max_size = 8M/post_max_size = $PHP_MAX_UPLOAD/" /etc/php/8.3/fpm/php.ini
sed -i "s/upload_max_filesize = 2M/upload_max_filesize = $PHP_MAX_UPLOAD/" /etc/php/8.3/fpm/php.ini
sed -i "s/memory_limit = 128M/memory_limit = $PHP_MEMORY_LIMIT/" /etc/php/8.3/fpm/php.ini

# Also update CLI version for command line operations
sed -i "s/max_execution_time = 30/max_execution_time = 300/" /etc/php/8.3/cli/php.ini
sed -i "s/max_input_vars = 1000/max_input_vars = 5000/" /etc/php/8.3/cli/php.ini
sed -i "s/post_max_size = 8M/post_max_size = $PHP_MAX_UPLOAD/" /etc/php/8.3/cli/php.ini
sed -i "s/upload_max_filesize = 2M/upload_max_filesize = $PHP_MAX_UPLOAD/" /etc/php/8.3/cli/php.ini
sed -i "s/memory_limit = 128M/memory_limit = $PHP_MEMORY_LIMIT/" /etc/php/8.3/cli/php.ini

systemctl restart php8.3-fpm

# Install Koha dependencies (following official documentation)
log "Installing Koha..."
# Set up keys for Koha packages (as per official docs)
mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://debian.koha-community.org/koha/gpg.asc -o /etc/apt/keyrings/koha.asc

# Use new sources format and specific version (24.11 LTS recommended)
tee /etc/apt/sources.list.d/koha.sources <<EOF
Types: deb
URIs: https://debian.koha-community.org/koha/
Suites: 24.11
Components: main
Signed-By: /etc/apt/keyrings/koha.asc
EOF

apt update
apt install -y koha-common

# Configure Koha (following official documentation)
log "Configuring Koha..."
cat > /etc/koha/koha-sites.conf << EOF
DOMAIN="$DOMAIN_KOHA"
INTRAPORT="8080"
INTRAPREFIX=""
INTRASUFFIX="-intra"
DEFAULTSQL="mysql"
MYSQL_HOST="localhost"
MYSQL_USER="koha"
MYSQL_PASS="$KOHA_DB_PASSWORD"
PASSWDFILE="/etc/koha/passwd"
ZEBRA_MARC_FORMAT="marc21"
ZEBRA_LANGUAGE="en"
EOF

# Enable required Apache modules (as per official docs)
log "Configuring Apache modules for Koha..."
a2enmod rewrite cgi headers proxy_http

# Create Koha instance
log "Creating Koha instance..."
koha-create --create-db library
koha-plack --enable library
koha-plack --start library

# Get admin password and save it
koha-passwd library > ./koha-admin-password.txt
chmod 600 ./koha-admin-password.txt

log "Koha admin password saved to ./koha-admin-password.txt"

# Enable email for Koha (as per docs)
log "Enabling email for Koha..."
koha-email-enable library

# Download and install Moodle (using Git as recommended)
log "Installing Moodle..."
cd ~
if [ ! -d "moodle" ]; then
    # Clone Moodle repository (recommended method)
    git clone https://github.com/moodle/moodle.git
    cd moodle
    # Switch to stable branch (MOODLE_405_STABLE is current LTS)
    git checkout MOODLE_405_STABLE
    git config pull.ff only
else
    cd moodle
fi

# Copy Moodle to web directory (excluding .git for security)
rsync -a --delete --exclude='.git' ~/moodle/ /var/www/html/moodle/
chown -R www-data:www-data /var/www/html/moodle

# Create Moodle data directory with proper permissions
if [ ! -d "/var/moodledata" ]; then
    mkdir -p /var/moodledata
    chown -R www-data:www-data /var/moodledata
    # Set restrictive permissions - only web server can access
    find /var/moodledata -type d -exec chmod 700 {} \;
    find /var/moodledata -type f -exec chmod 600 {} \;
fi

# Set up Moodle cron job for maintenance tasks
echo "* * * * * /usr/bin/php /var/www/html/moodle/admin/cli/cron.php >/dev/null" | crontab -u www-data -

# Install Caddy
log "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Configure Caddy
log "Configuring Caddy..."
cat > /etc/caddy/Caddyfile << EOF
{
    email $LETSENCRYPT_EMAIL
}

$DOMAIN_KOHA {
    reverse_proxy localhost:8080
    encode gzip
    log {
        output file /var/log/caddy/koha.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}

$DOMAIN_MOODLE {
    root * /var/www/moodle
    php_fastcgi unix//run/php/php8.3-fpm.sock
    encode gzip
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }
    
    # Handle Moodle specific paths
    @notAllowed {
        path *.log *.sql *.txt
        path /config.php /install.php /admin/cli/*
    }
    respond @notAllowed 403
    
    log {
        output file /var/log/caddy/moodle.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
EOF

# Create log directory
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Start services (following proper sequence)
log "Starting services..."
systemctl enable koha-common
systemctl start koha-common
systemctl restart apache2  # Required after Koha setup
systemctl enable caddy
systemctl restart caddy

# Go back to script directory
cd "$(dirname "$0")"

# Create Moodle config file
log "Creating Moodle configuration..."
cat > /var/www/moodle/config.php << EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = 'mariadb';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = 'localhost';
\$CFG->dbname    = 'moodle';
\$CFG->dbuser    = 'moodle';
\$CFG->dbpass    = '$MOODLE_DB_PASSWORD';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array(
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => '',
    'dbhandlesoptions' => false,
    'dbcollation' => 'utf8mb4_unicode_ci',
);

\$CFG->wwwroot   = 'https://$DOMAIN_MOODLE';
\$CFG->dataroot  = '/var/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

require_once(__DIR__ . '/lib/setup.php');
EOF

chown www-data:www-data /var/www/moodle/config.php
chmod 644 /var/www/moodle/config.php

# Final instructions
log "Setup completed successfully!"
echo
echo "=============================================="
echo -e "${GREEN}Installation Summary${NC}"
echo "=============================================="
echo "Koha Library System:"
echo "  - Public URL: https://$DOMAIN_KOHA"
echo "  - Staff URL: https://$DOMAIN_KOHA:8080"
echo "  - Admin credentials: ./koha-admin-password.txt"
echo "  - Version: 24.11 LTS (recommended production version)"
echo
echo "Moodle LMS:"
echo "  - URL: https://$DOMAIN_MOODLE"
echo "  - Complete setup by visiting the URL"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. ✅ Point DNS records to this server's IP:"
echo "     $DOMAIN_KOHA -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "     $DOMAIN_MOODLE -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "2. 🌐 Complete Moodle setup via web interface"
echo "3. 📚 Complete Koha web installer at: https://$DOMAIN_KOHA:8080"
echo "4. 🔧 Run Koha onboarding tool after web installer"
echo "5. 🔍 Check logs: /var/log/caddy/"
echo
echo -e "${BLUE}Koha Setup Notes:${NC}"
echo "• Use credentials from ./koha-admin-password.txt for web installer"
echo "• Choose MARC21 format (default) during setup"
echo "• Install sample data for easier setup"
echo "• Create superlibrarian user during onboarding"
echo
echo -e "${RED}Important Security Notes:${NC}"
echo "• Change default passwords after setup"
echo "• Set up regular database backups"
echo "• Monitor resource usage (htop, df -h)"
echo "• Keep systems updated (apt update && apt upgrade)"
echo "=============================================="
