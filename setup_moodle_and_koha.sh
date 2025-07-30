#!/bin/bash

# Koha + Moodle + Caddy Setup Script for Ubuntu 24.04
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
# shellcheck source=.env.example
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
SITES_DIRECTORY=${SITES_DIRECTORY:-"/var/www"}

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
    error "Installation cancelled by user"
fi

# Run system requirements check
check_system_requirements

# Update system first
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y

# Install essential packages
log "Installing essential packages..."
apt install -y \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    software-properties-common \
    net-tools \
    git \
    unzip \
    htop \
    ncdu

# Create sites directory structure
log "Creating directory structure..."
mkdir -p "$SITES_DIRECTORY"/{moodle,data/moodledata,config,backups}
chmod -R 755 "$SITES_DIRECTORY"

# Install MariaDB
log "Installing MariaDB..."
apt install -y mariadb-server mariadb-client

# Secure MariaDB installation
log "Securing MariaDB installation..."

# Use mysql_secure_installation equivalent commands
# First connect without password (default for fresh install)
mysql <<EOF
-- Set root password
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
-- Remove anonymous users
DELETE FROM mysql.user WHERE User='';
-- Disallow root login remotely
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
-- Remove test database
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
-- Reload privilege tables
FLUSH PRIVILEGES;
EOF

# Create Moodle database (now using the password we just set)
log "Creating Moodle database..."
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY '$MOODLE_DB_PASSWORD';
GRANT ALL PRIVILEGES ON moodle.* TO 'moodle'@'localhost';
FLUSH PRIVILEGES;
EOF

# Install Apache (for Koha)
log "Installing Apache and required modules..."
apt install -y apache2 apache2-utils libapache2-mpm-itk

# Configure Apache for Koha
log "Configuring Apache for Koha..."
# Disable any conflicting MPM modules first
for mpm in event worker; do
    if a2query -m mpm_$mpm 2>/dev/null; then
        a2dismod mpm_$mpm
    fi
done

# Enable mpm_prefork (required for mpm_itk)
a2enmod mpm_prefork

# Enable all required modules for Koha
a2enmod rewrite
a2enmod headers
a2enmod proxy
a2enmod proxy_http
a2enmod deflate
a2enmod cgi
a2enmod mpm_itk

# Restart Apache to apply all module changes
systemctl restart apache2

# Verify required modules are loaded
log "Verifying Apache modules..."
for module in rewrite cgi mpm_itk; do
    if /usr/sbin/apachectl -M 2>/dev/null | grep -q "${module}_module"; then
        log "✓ Apache module $module is enabled"
    else
        error "Apache module $module failed to enable"
    fi
done

# Change Apache ports for Koha
cat > /etc/apache2/ports.conf << 'EOF'
Listen 8000
Listen 8080

<IfModule ssl_module>
    Listen 8443
    Listen 8444
</IfModule>

<IfModule mod_gnutls.c>
    Listen 8443
    Listen 8444
</IfModule>
EOF

# Install PHP 8.3 and extensions
log "Installing PHP 8.3..."
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y \
    php8.3 \
    php8.3-fpm \
    php8.3-cli \
    php8.3-common \
    php8.3-mysql \
    php8.3-xml \
    php8.3-xmlrpc \
    php8.3-curl \
    php8.3-gd \
    php8.3-imagick \
    php8.3-cli \
    php8.3-dev \
    php8.3-imap \
    php8.3-mbstring \
    php8.3-opcache \
    php8.3-soap \
    php8.3-zip \
    php8.3-intl \
    php8.3-bcmath \
    php8.3-redis \
    php8.3-ldap \
    libapache2-mod-php8.3

# Configure PHP
log "Configuring PHP..."
PHP_INI_DIR="/etc/php/8.3"
for ini in "$PHP_INI_DIR"/{fpm,cli}/php.ini; do
    sed -i "s/memory_limit = .*/memory_limit = $PHP_MEMORY_LIMIT/" "$ini"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = $PHP_MAX_UPLOAD/" "$ini"
    sed -i "s/post_max_size = .*/post_max_size = $PHP_MAX_UPLOAD/" "$ini"
    sed -i "s/max_execution_time = .*/max_execution_time = 300/" "$ini"
    sed -i "s/max_input_time = .*/max_input_time = 300/" "$ini"
    sed -i "s/;date.timezone.*/date.timezone = UTC/" "$ini"
    sed -i "s/;opcache.enable=.*/opcache.enable=1/" "$ini"
    sed -i "s/;opcache.memory_consumption=.*/opcache.memory_consumption=256/" "$ini"
done

# Restart PHP-FPM
systemctl restart php8.3-fpm

# Install Koha
log "Installing Koha 24.11..."
wget -qO - https://debian.koha-community.org/koha/gpg.asc | gpg --dearmor -o /usr/share/keyrings/koha-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/koha-keyring.gpg] https://debian.koha-community.org/koha 24.11 main" | tee /etc/apt/sources.list.d/koha-24.11.list
apt update
apt install -y koha-common

# Configure Koha
log "Configuring Koha..."
sed -i 's/DOMAIN=".myDNSname.org"/DOMAIN=""/' /etc/koha/koha-sites.conf
sed -i 's/INTRAPORT="80"/INTRAPORT="8080"/' /etc/koha/koha-sites.conf
sed -i 's/OPACPORT="80"/OPACPORT="8000"/' /etc/koha/koha-sites.conf

# Configure MySQL credentials for koha-create
log "Configuring MySQL credentials for Koha..."

# Create .my.cnf for root user so koha-create can connect
cat > /root/.my.cnf << EOF
[client]
user=root
password=$DB_ROOT_PASSWORD
EOF

chmod 600 /root/.my.cnf

# Create Koha instance
log "Creating Koha instance..."
koha-create --create-db library

# Remove the credentials file for security
rm -f /root/.my.cnf

# Disable default Apache site
a2dissite 000-default
# koha-create already enabled the site, just restart
systemctl restart apache2

# Generate secure Koha admin password
KOHA_ADMIN_PASS=$(openssl rand -base64 16)
echo "Koha Admin Password: $KOHA_ADMIN_PASS" > "$SITES_DIRECTORY/config/koha-admin-password.txt"
chmod 600 "$SITES_DIRECTORY/config/koha-admin-password.txt"

# Set Koha admin password
koha-passwd library "$KOHA_ADMIN_PASS"

# Install Moodle
log "Installing Moodle 4.5..."
cd "$SITES_DIRECTORY"

if [ ! -d "moodle/.git" ]; then
    # Clone Moodle directly as www-data to avoid permission issues
    sudo -u www-data git clone https://github.com/moodle/moodle.git moodle
    cd moodle
    sudo -u www-data git checkout MOODLE_405_STABLE
    sudo -u www-data git config pull.ff only
else
    cd moodle
    log "Moodle repository exists, updating..."
    sudo -u www-data git pull
fi

# Ensure proper Moodle permissions
chown -R www-data:www-data "$SITES_DIRECTORY/moodle"
chmod -R 755 "$SITES_DIRECTORY/moodle"

# Configure Moodle data directory with secure permissions
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

# Configure Caddy with systemd logging
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
        format json
        # No output directive - logs go to systemd/journald
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
        format json
        # No output directive - logs go to systemd/journald
    }
}

# Moodle Learning Management System
$DOMAIN_MOODLE {
    root * $SITES_DIRECTORY/moodle
    
    # CRITICAL: Handle PHP files FIRST (before file_server)
    php_fastcgi unix//run/php/php8.3-fpm.sock {
        try_files {path} {path}/index.php index.php
    }
    
    # Then handle static files that PHP didn't catch
    file_server
    
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
    
    # Block only truly sensitive files (less restrictive than before)
    @blocked {
        path /config.php
        path /.git/*
        path /vendor/composer.*
        path *.log
    }
    respond @blocked 403
    
    # Basic error handling
    handle_errors {
        @404 expression {http.error.status_code} == 404
        handle @404 {
            rewrite * /error/index.php
            php_fastcgi unix//run/php/php8.3-fpm.sock
        }
        respond "Error {http.error.status_code}: {http.error.status_text}" {http.error.status_code}
    }
    
    log {
        format console  # More readable format for Moodle logs
        # No output directive - logs go to systemd/journald
    }
}
EOF

# Install Caddy configuration
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup 2>/dev/null || true
cp "$SITES_DIRECTORY/config/Caddyfile" /etc/caddy/Caddyfile

# Format the Caddyfile to fix any formatting issues
caddy fmt --overwrite /etc/caddy/Caddyfile

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

== Logging ==
All Caddy logs are managed by systemd/journald.
View logs with: sudo journalctl -u caddy -f

== Next Steps ==
1. Point DNS records to this server
2. Complete Koha web installer at: https://$DOMAIN_KOHA_STAFF
3. Complete Moodle web installer at: https://$DOMAIN_MOODLE

== Important Files ==
Koha Config: /etc/koha/sites/library/koha-conf.xml
Koha Apache: /etc/apache2/sites-available/library.conf
Moodle Files: $SITES_DIRECTORY/moodle/
Moodle Data: $SITES_DIRECTORY/data/moodledata/
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

# Secure configuration files
chmod 600 "$SITES_DIRECTORY/config"/*.txt
chown root:root "$SITES_DIRECTORY/config"/*.txt

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

# Check file permissions
log "Verifying file permissions..."
if [ -r "$SITES_DIRECTORY/moodle/index.php" ]; then
    log "✓ Moodle files are accessible"
else
    warn "✗ Moodle files may have permission issues"
fi

# Test PHP-FPM access to Moodle
if sudo -u www-data test -r "$SITES_DIRECTORY/moodle/index.php"; then
    log "✓ PHP-FPM can access Moodle files"
else
    warn "✗ PHP-FPM cannot access Moodle files"
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
echo "Moodle Files: $SITES_DIRECTORY/moodle/"
echo "Moodle Data: $SITES_DIRECTORY/data/moodledata/"
echo "Configuration: $SITES_DIRECTORY/config/"
echo "Documentation: $SITES_DIRECTORY/config/setup-summary.txt"
echo "Credentials: $SITES_DIRECTORY/config/koha-admin-password.txt"
echo "Database Info: $SITES_DIRECTORY/config/database-credentials.txt"
echo
echo -e "${BLUE}📊 Viewing Logs:${NC}"
echo "• View Caddy logs: sudo journalctl -u caddy -f"
echo "• View today's logs: sudo journalctl -u caddy --since today"
echo "• View Apache logs: sudo journalctl -u apache2 -f"
echo "• View PHP-FPM logs: sudo journalctl -u php8.3-fpm -f"
echo "• Export logs: sudo journalctl -u caddy > caddy-logs.txt"
echo
if [ "$all_services_ok" = true ]; then
    echo -e "${GREEN}✅ All services are running correctly!${NC}"
else
    echo -e "${YELLOW}⚠️  Some services need attention - check logs above${NC}"
fi
echo
echo -e "${BLUE}🔧 Troubleshooting Commands:${NC}"
echo "• Check services: sudo systemctl status apache2 caddy mariadb koha-common"
echo "• View Caddy logs: sudo journalctl -u caddy --no-pager -n 50"
echo "• Restart services: sudo systemctl restart apache2 caddy"
echo "• Koha shell: sudo koha-shell library"
echo "• Validate Caddy config: sudo caddy validate --config /etc/caddy/Caddyfile"
echo "• Test Moodle permissions: sudo -u www-data ls -la $SITES_DIRECTORY/moodle/"
echo
echo -e "${GREEN}🏗️ Architecture Summary:${NC}"
echo "• Files stored in: $SITES_DIRECTORY (owned by www-data)"
echo "• Caddy (ports 80/443) → Reverse proxy with automatic SSL"
echo "• Apache (ports 8000/8080) → Serves Koha"
echo "• PHP-FPM (socket) → Processes Moodle"
echo "• MariaDB (port 3306) → Database for both systems"
echo "• Logs managed by systemd/journald (no file-based logging)"
echo
echo -e "${RED}🔒 Security Reminders:${NC}"
echo "• Change default passwords after setup"
echo "• Set up regular backups"
echo "• Keep systems updated"
echo "• Monitor resource usage"
echo "• Credentials are secured in $SITES_DIRECTORY/config/"
echo "=============================================="

log "Installation completed successfully! Follow the next steps above to finish setup."
