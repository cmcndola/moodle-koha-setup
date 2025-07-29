#!/bin/bash

# Koha + Moodle + Caddy Setup Script for Ubuntu 24.04
# Corrected version with fixed Caddy configuration and proper Koha installation
#
# Usage:
#   1. git clone <your-repo>
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
required_vars=("DOMAIN_KOHA" "DOMAIN_KOHA_STAFF" "DOMAIN_MOODLE" "LETSENCRYPT_EMAIL" "DB_ROOT_PASSWORD" "KOHA_DB_PASSWORD" "MOODLE_DB_PASSWORD")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        error "Required environment variable $var is not set in .env file"
    fi
done

# Set defaults for optional variables
PHP_MEMORY_LIMIT=${PHP_MEMORY_LIMIT:-512M}
PHP_MAX_UPLOAD=${PHP_MAX_UPLOAD:-512M}
SITES_DIRECTORY=${SITES_DIRECTORY:-"/home/$SUDO_USER/sites"}

# Ensure running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
fi

# Check system requirements
check_system_requirements() {
    log "Checking system requirements..."
    
    # Check memory
    mem_total=$(free -m | awk 'NR==2{printf "%.0f", $2}')
    if [ "$mem_total" -lt 4000 ]; then
        warn "System has ${mem_total}MB RAM. Recommended minimum is 4GB for both Koha and Moodle."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Installation cancelled due to insufficient memory"
        fi
    else
        log "✓ Memory check passed: ${mem_total}MB available"
    fi
    
    # Check disk space (minimum 20GB for both systems)
    disk_available=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$disk_available" -lt 20 ]; then
        warn "Available disk space: ${disk_available}GB. Recommended minimum: 20GB"
    else
        log "✓ Disk space check passed: ${disk_available}GB available"
    fi
}

# Display configuration summary
info "=== Configuration Summary ==="
echo "Koha OPAC Domain: $DOMAIN_KOHA"
echo "Koha Staff Domain: $DOMAIN_KOHA_STAFF"
echo "Moodle Domain: $DOMAIN_MOODLE"
echo "Let's Encrypt Email: $LETSENCRYPT_EMAIL"
echo "Sites Directory: $SITES_DIRECTORY"
echo "PHP Memory Limit: $PHP_MEMORY_LIMIT"
echo "================================"
echo

read -p "Continue with this configuration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    error "Setup cancelled by user"
fi

check_system_requirements

log "Starting Koha + Moodle + Caddy setup on Ubuntu 24.04"

# Update system packages
log "Updating system packages..."
apt update && apt upgrade -y

# Create sites directory structure
log "Creating sites directory structure..."
mkdir -p "$SITES_DIRECTORY"/{moodle,data/moodledata,config,backups}
chown -R "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY"

# Install and secure MariaDB
log "Installing MariaDB..."
apt install -y mariadb-server mariadb-client
systemctl start mariadb
systemctl enable mariadb

# Secure MariaDB installation
log "Securing MariaDB installation..."
if ! command -v expect &> /dev/null; then
    apt install -y expect
fi

# Create automated mysql_secure_installation script
cat > /tmp/mysql_setup.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 30
spawn sudo mysql_secure_installation

expect "Enter current password for root (enter for none):"
send "\r"

expect "Switch to unix_socket authentication"
send "n\r"

expect "Change the root password?"
send "y\r"

expect "New password:"
send "$env(DB_ROOT_PASSWORD)\r"

expect "Re-enter new password:"
send "$env(DB_ROOT_PASSWORD)\r"

expect "Remove anonymous users?"
send "y\r"

expect "Disallow root login remotely?"
send "y\r"

expect "Remove test database and access to it?"
send "y\r"

expect "Reload privilege tables now?"
send "y\r"

expect eof
EOF

export DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD"
chmod +x /tmp/mysql_setup.exp

log "Running automated MariaDB security setup..."
if /tmp/mysql_setup.exp; then
    log "✓ MariaDB secured successfully"
else
    warn "MariaDB security setup completed with possible warnings"
fi

rm -f /tmp/mysql_setup.exp
unset DB_ROOT_PASSWORD

# Create Moodle database (Koha will create its own)
log "Creating Moodle database..."
mysql -u root -p"$DB_ROOT_PASSWORD" << EOF
CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY '$MOODLE_DB_PASSWORD';
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,CREATE TEMPORARY TABLES,DROP,INDEX,ALTER,LOCK TABLES,REFERENCES ON moodle.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
EOF

log "✓ Moodle database created successfully"

# Install PHP 8.3 and required extensions
log "Installing PHP 8.3 and extensions..."
apt install -y php8.3-fpm php8.3-mysql php8.3-xml php8.3-xmlrpc php8.3-curl \
    php8.3-gd php8.3-imagick php8.3-cli php8.3-dev php8.3-imap php8.3-mbstring \
    php8.3-opcache php8.3-soap php8.3-zip php8.3-intl php8.3-ldap \
    php8.3-pspell php8.3-bcmath php8.3-bz2 php8.3-common \
    graphviz aspell ghostscript clamav git unzip

# Configure PHP for optimal performance
log "Configuring PHP..."
for ini_file in /etc/php/8.3/fpm/php.ini /etc/php/8.3/cli/php.ini; do
    if [ -f "$ini_file" ]; then
        sed -i "s/max_execution_time = 30/max_execution_time = 300/" "$ini_file"
        sed -i "s/max_input_vars = 1000/max_input_vars = 5000/" "$ini_file"
        sed -i "s/post_max_size = 8M/post_max_size = $PHP_MAX_UPLOAD/" "$ini_file"
        sed -i "s/upload_max_filesize = 2M/upload_max_filesize = $PHP_MAX_UPLOAD/" "$ini_file"
        sed -i "s/memory_limit = 128M/memory_limit = $PHP_MEMORY_LIMIT/" "$ini_file"
    fi
done

systemctl restart php8.3-fpm

# Install and configure Koha following official documentation
log "Installing Koha following official documentation..."

# Set up Koha package repository
mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings
curl -fsSL https://debian.koha-community.org/koha/gpg.asc -o /etc/apt/keyrings/koha.asc

tee /etc/apt/sources.list.d/koha.sources <<EOF
Types: deb
URIs: https://debian.koha-community.org/koha/
Suites: 24.11
Components: main
Signed-By: /etc/apt/keyrings/koha.asc
EOF

apt update
apt install -y koha-common

# Configure Apache for Koha (before creating instance)
log "Configuring Apache for Koha..."
cp /etc/apache2/ports.conf /etc/apache2/ports.conf.backup

cat > /etc/apache2/ports.conf << 'EOF'
# Koha Apache configuration
# Using ports 8000/8080 to avoid conflict with Caddy

Listen 8000
Listen 8080

<IfModule ssl_module>
    Listen 8443 ssl
</IfModule>

<IfModule mod_gnutls.c>
    Listen 8443 ssl
</IfModule>
EOF

# Enable required Apache modules
a2enmod rewrite cgi headers proxy_http ssl

# Configure Koha sites configuration
log "Configuring Koha sites..."
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
ADMINUSER="1"
EOF

# Clean up any previous Koha installation
log "Cleaning up any previous Koha installation..."
koha-remove library 2>/dev/null || true
rm -rf /etc/koha/sites/library 2>/dev/null || true

# Create Koha instance (this handles database creation automatically)
log "Creating Koha instance..."
if koha-create --create-db library; then
    log "✓ Koha instance 'library' created successfully"
else
    # Try alternative approach if --create-db fails
    warn "Direct creation failed, trying without database creation..."
    if koha-create library; then
        log "✓ Koha instance created (database will be set up via web installer)"
    else
        error "Failed to create Koha instance"
    fi
fi

# Verify Koha instance was created
if [ ! -f "/etc/koha/sites/library/koha-conf.xml" ]; then
    error "Koha configuration file not found. Instance creation failed."
fi

# Update Koha Apache configuration for custom ports
log "Updating Koha Apache configuration..."
if [ -f "/etc/apache2/sites-available/library.conf" ]; then
    sed -i 's/:80>/:8000>/g' /etc/apache2/sites-available/library.conf
    sed -i 's/:443>/:8443>/g' /etc/apache2/sites-available/library.conf
    log "✓ Koha Apache configuration updated"
fi

# Enable and start Koha services
log "Starting Koha services..."
koha-plack --enable library
koha-plack --start library
koha-email-enable library

# Restart Apache to load configuration
systemctl restart apache2

# Save Koha admin credentials
koha-passwd library > "$SITES_DIRECTORY/config/koha-admin-password.txt"
chmod 600 "$SITES_DIRECTORY/config/koha-admin-password.txt"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/koha-admin-password.txt"

log "✓ Koha admin credentials saved"

# Install and configure Moodle
log "Installing Moodle..."
cd "$SITES_DIRECTORY"

if [ ! -d "moodle/.git" ]; then
    sudo -u "$SUDO_USER" git clone https://github.com/moodle/moodle.git moodle
    cd moodle
    sudo -u "$SUDO_USER" git checkout MOODLE_405_STABLE
    sudo -u "$SUDO_USER" git config pull.ff only
else
    cd moodle
    log "Moodle repository exists, updating..."
    sudo -u "$SUDO_USER" git pull
fi

# Set Moodle permissions
chown -R www-data:www-data "$SITES_DIRECTORY/moodle"
chmod -R 755 "$SITES_DIRECTORY/moodle"

# Configure Moodle data directory
chown -R www-data:www-data "$SITES_DIRECTORY/data/moodledata"
find "$SITES_DIRECTORY/data/moodledata" -type d -exec chmod 700 {} \;
find "$SITES_DIRECTORY/data/moodledata" -type f -exec chmod 600 {} \; 2>/dev/null || true

# Set up Moodle cron
log "Setting up Moodle cron job..."
echo "*/1 * * * * /usr/bin/php $SITES_DIRECTORY/moodle/admin/cli/cron.php >> /var/log/moodle-cron.log 2>&1" | crontab -u www-data -

# Install and configure Caddy
log "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Configure Caddy with corrected configuration (no invalid log encoders or redundant headers)
log "Configuring Caddy reverse proxy..."
cat > "$SITES_DIRECTORY/config/Caddyfile" << EOF
{
    email $LETSENCRYPT_EMAIL
    servers {
        trusted_proxies static private_ranges
    }
}

# Koha OPAC (Public Catalog)
$DOMAIN_KOHA {
    reverse_proxy localhost:8000 {
        header_up Host {upstream_hostport}
        # X-Forwarded-For and X-Forwarded-Proto are set automatically by Caddy
    }
    encode gzip
    log {
        output file /var/log/caddy/koha-opac.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}

# Koha Staff Interface
$DOMAIN_KOHA_STAFF {
    reverse_proxy localhost:8080 {
        header_up Host {upstream_hostport}
        # X-Forwarded-For and X-Forwarded-Proto are set automatically by Caddy
    }
    encode gzip
    log {
        output file /var/log/caddy/koha-staff.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}

# Moodle Learning Management System
$DOMAIN_MOODLE {
    root * $SITES_DIRECTORY/moodle
    
    # Serve static files (CSS, JS, images, etc.)
    file_server {
        hide *.php
    }
    
    # Handle PHP files
    php_fastcgi unix//run/php/php8.3-fpm.sock {
        try_files {path} {path}/index.php index.php
        root $SITES_DIRECTORY/moodle
    }
    
    encode gzip zstd
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }
    
    # Block sensitive files
    @blocked {
        path *.log *.sql *.txt *.md *.ini
        path /config.php /install.php /admin/cli/* /lib/* /vendor/*
        path /.git/* /node_modules/* /composer.* /behat/* /phpunit.xml
        path */cache/* */temp/* */sessions/*
    }
    respond @blocked 403
    
    # Error handling
    handle_errors {
        @404 expression {http.error.status_code} == 404
        handle @404 {
            rewrite * /error/index.php
            php_fastcgi unix//run/php/php8.3-fpm.sock {
                root $SITES_DIRECTORY/moodle
            }
        }
        respond "Error {http.error.status_code}: {http.error.status_text}" {http.error.status_code}
    }
    
    log {
        output file /var/log/caddy/moodle.log {
            roll_size 10mb
            roll_keep 5
        }
        # Using standard format instead of invalid 'transform' encoder
        format console
    }
}
EOF

# Install Caddy configuration
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup 2>/dev/null || true
cp "$SITES_DIRECTORY/config/Caddyfile" /etc/caddy/Caddyfile

# Create log directories
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Validate Caddy configuration before starting
log "Validating Caddy configuration..."
if caddy validate --config /etc/caddy/Caddyfile; then
    log "✓ Caddy configuration is valid"
else
    error "Caddy configuration validation failed. Check the Caddyfile syntax."
fi

# Start all services
log "Starting all services..."
services=("mariadb" "apache2" "php8.3-fpm" "koha-common")

for service in "${services[@]}"; do
    systemctl enable "$service"
    if systemctl restart "$service"; then
        log "✓ $service started successfully"
    else
        warn "✗ $service failed to start"
        systemctl status "$service" --no-pager -l
    fi
done

# Start Caddy last
systemctl enable caddy
if systemctl restart caddy; then
    log "✓ Caddy started successfully"
else
    error "Caddy failed to start. Check the configuration and logs."
fi

# Create configuration documentation
log "Creating configuration documentation..."
cat > "$SITES_DIRECTORY/config/setup-summary.txt" << EOF
# Koha + Moodle Installation Summary
# Generated: $(date)

== System Information ==
Server: Ubuntu 24.04
Installation Directory: $SITES_DIRECTORY
PHP Version: 8.3
Database: MariaDB

== Koha Configuration ==
Version: 24.11 LTS
Instance: library
OPAC URL: https://$DOMAIN_KOHA
Staff URL: https://$DOMAIN_KOHA_STAFF
Admin credentials: $SITES_DIRECTORY/config/koha-admin-password.txt

== Moodle Configuration ==
Version: 4.5 LTS
URL: https://$DOMAIN_MOODLE
Data Directory: $SITES_DIRECTORY/data/moodledata
Database: moodle
Database User: moodle

== Service Ports ==
Apache: 8000 (Koha OPAC), 8080 (Koha Staff)
Caddy: 80, 443 (Reverse proxy with SSL)
MariaDB: 3306
PHP-FPM: Socket /run/php/php8.3-fpm.sock

== Next Steps ==
1. Point DNS records to this server
2. Complete Koha web installer at: https://$DOMAIN_KOHA_STAFF
3. Complete Moodle web installer at: https://$DOMAIN_MOODLE

== Important Files ==
Koha Config: /etc/koha/sites/library/koha-conf.xml
Koha Apache: /etc/apache2/sites-available/library.conf
Moodle Config: Create via web installer
Caddy Config: $SITES_DIRECTORY/config/Caddyfile
EOF

# Save database credentials securely
cat > "$SITES_DIRECTORY/config/database-credentials.txt" << EOF
# Database Credentials - Keep Secure!
# Generated: $(date)

MariaDB Root:
Username: root
Password: $DB_ROOT_PASSWORD

Koha Database:
Database: koha_library
Username: koha_library (auto-created by Koha)
Password: (auto-generated by Koha)

Moodle Database:
Database: moodle
Username: moodle
Password: $MOODLE_DB_PASSWORD
EOF

chmod 600 "$SITES_DIRECTORY/config"/*.txt
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config"/*.txt

# Final verification
log "Performing final system verification..."

# Check services
all_services_ok=true
for service in mariadb apache2 caddy koha-common php8.3-fpm; do
    if systemctl is-active --quiet "$service"; then
        log "✓ $service is running"
    else
        warn "✗ $service is not running"
        all_services_ok=false
    fi
done

# Check ports
log "Checking port configuration..."
if ss -tlnp | grep -q ":8000.*apache2"; then
    log "✓ Apache listening on port 8000 (Koha OPAC)"
else
    warn "✗ Apache not listening on port 8000"
fi

if ss -tlnp | grep -q ":8080.*apache2"; then
    log "✓ Apache listening on port 8080 (Koha Staff)"
else
    warn "✗ Apache not listening on port 8080"
fi

if ss -tlnp | grep -q ":80.*caddy\|:443.*caddy"; then
    log "✓ Caddy listening on ports 80/443"
else
    warn "✗ Caddy not listening on ports 80/443"
fi

# Final status report
echo
echo "=============================================="
echo -e "${GREEN}🎉 Installation Complete!${NC}"
echo "=============================================="
echo
echo -e "${BLUE}📚 Koha Library Management System${NC}"
echo "Public Catalog: https://$DOMAIN_KOHA"
echo "Staff Interface: https://$DOMAIN_KOHA_STAFF"
echo "Version: 24.11 LTS"
echo
echo -e "${BLUE}🎓 Moodle Learning Management System${NC}"
echo "Learning Portal: https://$DOMAIN_MOODLE"
echo "Version: 4.5 LTS"
echo
echo -e "${YELLOW}📋 Next Steps:${NC}"
echo "1. 🌐 Configure DNS records:"
echo "   $DOMAIN_KOHA → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "   $DOMAIN_KOHA_STAFF → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "   $DOMAIN_MOODLE → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo
echo "2. 📚 Complete Koha setup:"
echo "   • Visit: https://$DOMAIN_KOHA_STAFF"
echo "   • Use credentials from: $SITES_DIRECTORY/config/koha-admin-password.txt"
echo "   • Follow web installer steps"
echo "   • Choose MARC21 format and install sample data"
echo
echo "3. 🎓 Complete Moodle setup:"
echo "   • Visit: https://$DOMAIN_MOODLE"
echo "   • Follow web installer"
echo "   • Database settings are pre-configured"
echo
echo -e "${BLUE}📁 Important Files:${NC}"
echo "Configuration: $SITES_DIRECTORY/config/"
echo "Documentation: $SITES_DIRECTORY/config/setup-summary.txt"
echo "Credentials: $SITES_DIRECTORY/config/koha-admin-password.txt"
echo "Database Info: $SITES_DIRECTORY/config/database-credentials.txt"
echo
if [ "$all_services_ok" = true ]; then
    echo -e "${GREEN}✅ All services are running correctly!${NC}"
else
    echo -e "${YELLOW}⚠️  Some services need attention - check logs above${NC}"
fi
echo
echo -e "${BLUE}🔧 Troubleshooting Commands:${NC}"
echo "• Check services: sudo systemctl status apache2 caddy mariadb koha-common"
echo "• View logs: sudo tail -f /var/log/caddy/*.log"
echo "• Restart services: sudo systemctl restart apache2 caddy"
echo "• Koha shell: sudo koha-shell library"
echo "• Validate Caddy config: sudo caddy validate --config /etc/caddy/Caddyfile"
echo
echo -e "${RED}🔒 Security Reminders:${NC}"
echo "• Change default passwords after setup"
echo "• Set up regular backups"
echo "• Keep systems updated"
echo "• Monitor resource usage"
echo "=============================================="

log "Installation completed successfully! Follow the next steps above to finish setup."