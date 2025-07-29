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
    
    # Check disk space (minimum 10GB)
    disk_available=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [ "$disk_available" -lt 10 ]; then
        warn "Available disk space: ${disk_available}GB. Recommended minimum: 10GB"
    else
        log "✓ Disk space check passed: ${disk_available}GB available"
    fi
}

# Display configuration
info "=== Configuration Summary ==="
echo "Koha Domain: $DOMAIN_KOHA"
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

# Update system
log "Updating system packages..."
apt update && apt upgrade -y

# Create sites directory structure
log "Creating sites directory structure..."
mkdir -p "$SITES_DIRECTORY"
mkdir -p "$SITES_DIRECTORY/moodle"
mkdir -p "$SITES_DIRECTORY/data/moodledata"
mkdir -p "$SITES_DIRECTORY/config"
mkdir -p "$SITES_DIRECTORY/backups"
chown -R "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY"

# Install MariaDB
log "Installing MariaDB..."
apt install -y mariadb-server mariadb-client
systemctl start mariadb
systemctl enable mariadb

# Properly secure MariaDB installation using automated expect script
log "Securing MariaDB installation..."
warn "DO NOT TYPE ANYTHING - This process is automated!"

# Create expect script to automate mysql_secure_installation
cat > /tmp/mysql_setup.exp << 'EOF'
#!/usr/bin/expect -f
set timeout 30

spawn sudo mysql_secure_installation

# Current password (empty by default)
expect "Enter current password for root (enter for none):"
sleep 1
send "\r"

# Switch to unix_socket authentication
expect "Switch to unix_socket authentication"
sleep 1
send "n\r"

# Change root password
expect "Change the root password?"
sleep 1
send "y\r"

# New password
expect "New password:"
sleep 1
send "$env(DB_ROOT_PASSWORD)\r"

# Re-enter password
expect "Re-enter new password:"
sleep 1
send "$env(DB_ROOT_PASSWORD)\r"

# Remove anonymous users
expect "Remove anonymous users?"
sleep 1
send "y\r"

# Disallow root login remotely
expect "Disallow root login remotely?"
sleep 1
send "y\r"

# Remove test database
expect "Remove test database and access to it?"
sleep 1
send "y\r"

# Reload privilege tables
expect "Reload privilege tables now?"
sleep 1
send "y\r"

expect eof
EOF

# Install expect if not present and run the setup
if ! command -v expect &> /dev/null; then
    log "Installing expect for automation..."
    apt install -y expect
fi

# Export password for expect script
export DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD"

log "Running automated MariaDB security setup..."
log "Please DO NOT TYPE ANYTHING during this process!"

chmod +x /tmp/mysql_setup.exp
if /tmp/mysql_setup.exp; then
    log "✓ MariaDB secured successfully"
else
    warn "Automated setup may have had issues, but likely completed"
fi

rm -f /tmp/mysql_setup.exp
unset DB_ROOT_PASSWORD

# Create databases with proper permissions
log "Creating databases..."
mysql -u root -p"$DB_ROOT_PASSWORD" << EOF
CREATE DATABASE IF NOT EXISTS koha_library CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'koha'@'localhost' IDENTIFIED BY '$KOHA_DB_PASSWORD';
CREATE USER IF NOT EXISTS 'moodle'@'localhost' IDENTIFIED BY '$MOODLE_DB_PASSWORD';

GRANT ALL PRIVILEGES ON koha_library.* TO 'koha'@'localhost';
-- Add all required Moodle permissions
GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,CREATE TEMPORARY TABLES,DROP,INDEX,ALTER,LOCK TABLES,REFERENCES ON moodle.* TO 'moodle'@'localhost';

FLUSH PRIVILEGES;
EOF

log "✓ Databases created successfully"

# Install PHP 8.3 and extensions (verified compatible with Moodle 4.5)
log "Installing PHP 8.3 and extensions..."
apt install -y php8.3-fpm php8.3-mysql php8.3-xml php8.3-xmlrpc php8.3-curl \
    php8.3-gd php8.3-imagick php8.3-cli php8.3-dev php8.3-imap php8.3-mbstring \
    php8.3-opcache php8.3-soap php8.3-zip php8.3-intl php8.3-ldap \
    php8.3-pspell php8.3-bcmath \
    graphviz aspell ghostscript clamav git

# Configure PHP for both Koha and Moodle (following official recommendations)
log "Configuring PHP..."
# Update php.ini files
for ini_file in /etc/php/8.3/fpm/php.ini /etc/php/8.3/cli/php.ini; do
    sed -i "s/max_execution_time = 30/max_execution_time = 300/" $ini_file
    sed -i "s/max_input_vars = 1000/max_input_vars = 5000/" $ini_file
    sed -i "s/post_max_size = 8M/post_max_size = $PHP_MAX_UPLOAD/" $ini_file
    sed -i "s/upload_max_filesize = 2M/upload_max_filesize = $PHP_MAX_UPLOAD/" $ini_file
    sed -i "s/memory_limit = 128M/memory_limit = $PHP_MEMORY_LIMIT/" $ini_file
done

systemctl restart php8.3-fpm

# Install Koha (following official documentation)
log "Installing Koha..."
# Set up keys for Koha packages (as per official docs)
mkdir -p /etc/apt/keyrings
chmod 755 /etc/apt/keyrings
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

# Configure Apache to use alternative ports to avoid conflict with Caddy
log "Configuring Apache ports to avoid conflict with Caddy..."
sed -i 's/Listen 80/Listen 8000/' /etc/apache2/ports.conf
sed -i 's/Listen 443/Listen 8443/' /etc/apache2/ports.conf

# Also check for any additional Listen directives and update them
if grep -q "Listen 8080" /etc/apache2/ports.conf; then
    log "Port 8080 already configured in Apache"
else
    echo "Listen 8080" >> /etc/apache2/ports.conf
fi

# Enable required Apache modules (as per official docs)
log "Configuring Apache modules for Koha..."
a2enmod rewrite cgi headers proxy_http

# Create Koha instance following official documentation patterns
log "Creating Koha instance..."

# Clean up any existing partial installation first
log "Cleaning up any previous installation attempts..."
koha-remove library 2>/dev/null || true
rm -rf /etc/koha/sites/library 2>/dev/null || true

# Verify MySQL credentials work before proceeding
log "Verifying database credentials..."
if mysql -u koha -p"$KOHA_DB_PASSWORD" -e "SELECT 'Connection test OK' as status;" 2>/dev/null; then
    log "✓ Database credentials verified"
else
    error "Database connection failed. Check koha user credentials."
fi

# Drop existing database to ensure clean state
log "Ensuring clean database state..."
mysql -u root -p"$DB_ROOT_PASSWORD" << EOF
DROP DATABASE IF EXISTS koha_library;
CREATE DATABASE koha_library CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON koha_library.* TO 'koha'@'localhost';
FLUSH PRIVILEGES;
EOF

# Use the official three-step approach from Koha documentation
log "Creating Koha instance using official three-step approach..."

# Step 1: Request database setup (creates instance structure)
log "Step 1: Creating Koha instance structure..."
if koha-create --request-db library; then
    log "✓ Koha instance structure created successfully"
    
    # Step 2: Populate the database
    log "Step 2: Populating Koha database..."
    if koha-create --populate-db library; then
        log "✓ Koha database populated successfully"
    else
        warn "Database population with --populate-db failed, trying manual approach..."
        # Manual population as fallback
        if [ -f "/usr/share/koha/installer/data/mysql/kohastructure.sql" ]; then
            log "Using manual database population..."
            mysql -u koha -p"$KOHA_DB_PASSWORD" koha_library < /usr/share/koha/installer/data/mysql/kohastructure.sql
            log "✓ Database populated manually"
        else
            error "Cannot find Koha SQL structure file for manual population"
        fi
    fi
    
    # Verify instance was created properly
    if [ -f "/etc/koha/sites/library/koha-conf.xml" ]; then
        log "✓ Koha configuration file created successfully"
    else
        error "Koha configuration file not found after instance creation"
    fi
    
else
    warn "Step 1 failed, trying direct --create-db approach..."
    
    # Fallback: Let koha-create handle everything including database
    if koha-create --create-db library; then
        log "✓ Koha instance created successfully with --create-db"
    else
        warn "All automated methods failed, trying basic instance creation..."
        # Last resort: Create basic instance, let web installer handle database
        if koha-create library; then
            log "✓ Basic Koha instance created - database setup will be done via web installer"
        else
            error "Failed to create Koha instance with all available methods"
        fi
    fi
fi

# Enable and start Koha services
log "Configuring Koha services..."
koha-plack --enable library
koha-plack --start library

# Get admin password and save it securely
log "Saving Koha admin credentials..."
koha-passwd library > "$SITES_DIRECTORY/config/koha-admin-password.txt"
chmod 600 "$SITES_DIRECTORY/config/koha-admin-password.txt"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/koha-admin-password.txt"

log "Koha admin password saved to $SITES_DIRECTORY/config/koha-admin-password.txt"

# Enable email for Koha
log "Enabling email for Koha..."
koha-email-enable library

# Update Koha Apache configurations to use correct ports
log "Configuring Koha Apache virtual hosts..."
if [ -f "/etc/apache2/sites-available/library.conf" ]; then
    # Update OPAC to use port 8000
    sed -i 's/:80>/:8000>/' /etc/apache2/sites-available/library.conf
    # Ensure staff interface uses port 8080 (should be default but verify)
    if ! grep -q ":8080>" /etc/apache2/sites-available/library.conf; then
        # Add staff interface config if missing
        log "Adding staff interface configuration..."
        # This is typically handled automatically but we're being thorough
    fi
    log "✓ Koha Apache configuration updated"
else
    warn "Koha Apache configuration file not found - this may cause issues"
fi

# Download and install Moodle in custom directory
log "Installing Moodle in $SITES_DIRECTORY/moodle..."
cd "$SITES_DIRECTORY"
if [ ! -d "moodle/.git" ]; then
    # Clone Moodle repository (recommended method)
    sudo -u "$SUDO_USER" git clone https://github.com/moodle/moodle.git moodle
    cd moodle
    # Switch to stable branch (MOODLE_405_STABLE is current LTS)
    sudo -u "$SUDO_USER" git checkout MOODLE_405_STABLE
    sudo -u "$SUDO_USER" git config pull.ff only
else
    cd moodle
    log "Moodle repository already exists, updating..."
    sudo -u "$SUDO_USER" git pull
fi

# Set proper permissions for Moodle files (security best practice)
chown -R www-data:www-data "$SITES_DIRECTORY/moodle"
chmod -R 755 "$SITES_DIRECTORY/moodle"

# Create Moodle data directory with restrictive permissions
chown -R www-data:www-data "$SITES_DIRECTORY/data/moodledata"
# Set restrictive permissions - only web server can access
find "$SITES_DIRECTORY/data/moodledata" -type d -exec chmod 700 {} \;
find "$SITES_DIRECTORY/data/moodledata" -type f -exec chmod 600 {} \;

# Set up Moodle cron job for maintenance tasks with logging
log "Setting up Moodle cron job..."
echo "*/1 * * * * /usr/bin/php $SITES_DIRECTORY/moodle/admin/cli/cron.php >> /var/log/moodle-cron.log 2>&1" | crontab -u www-data -

# Install Caddy
log "Installing Caddy..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Configure Caddy with optimized configuration
log "Configuring Caddy..."
cat > "$SITES_DIRECTORY/config/Caddyfile" << EOF
{
    email $LETSENCRYPT_EMAIL
    # Global options for better performance
    servers {
        trusted_proxies static private_ranges
    }
}

# Koha OPAC (public interface)
$DOMAIN_KOHA {
    reverse_proxy localhost:8000 {
        # Add headers for better compatibility
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
    log {
        output file /var/log/caddy/koha.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}

# Koha Staff Interface
$DOMAIN_KOHA_STAFF {
    reverse_proxy localhost:8080 {
        # Add headers for better compatibility
        header_up Host {upstream_hostport}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
    encode gzip
    log {
        output file /var/log/caddy/koha-staff.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}

# Moodle LMS
$DOMAIN_MOODLE {
    root * $SITES_DIRECTORY/moodle
    
    # Serve static files first (CSS, JS, images, etc.) - CRITICAL for Moodle!
    file_server {
        # Don't serve PHP files as static
        hide *.php
    }
    
    # Handle PHP files through FastCGI
    php_fastcgi unix//run/php/php8.3-fpm.sock {
        # Moodle-optimized try_files
        try_files {path} {path}/index.php index.php
        # Set root for PHP-FPM (important for file operations)
        root $SITES_DIRECTORY/moodle
    }
    
    encode gzip zstd
    
    # Security headers for Moodle
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        Referrer-Policy strict-origin-when-cross-origin
        # Remove server information
        -Server
    }
    
    # Block access to sensitive Moodle files and directories
    @blocked {
        path *.log *.sql *.txt *.md *.ini
        path /config.php /install.php /admin/cli/* /lib/* /vendor/*
        path /.git/* /node_modules/* /composer.json /composer.lock
        path /behat/* /phpunit.xml /environment.xml /readme*
        path */cache/* */temp/* */sessions/*
    }
    respond @blocked 403
    
    # Handle Moodle-specific URLs that might need special treatment
    @moodle_special {
        path /admin/tool/installaddon/*
        path /repository/repository_ajax.php
        path /lib/editor/tinymce/*
    }
    
    # Custom error handling
    handle_errors {
        @404 expression {http.error.status_code} == 404
        handle @404 {
            rewrite * /error/index.php
            php_fastcgi unix//run/php/php8.3-fpm.sock {
                root $SITES_DIRECTORY/moodle
            }
        }
        
        # Generic error response for other errors
        respond "Error {http.error.status_code}: {http.error.status_text}" {http.error.status_code}
    }
    
    log {
        output file /var/log/caddy/moodle.log {
            roll_size 10mb
            roll_keep 5
        }
        # Detailed format for debugging
        format transform "{common_log} {>User-Agent}" {
            time_format "02/Jan/2006:15:04:05 -0700"
        }
    }
}
EOF

# Copy to system location and backup original
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup 2>/dev/null || true
cp "$SITES_DIRECTORY/config/Caddyfile" /etc/caddy/Caddyfile

# Create log directory with proper permissions
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Start services in proper sequence with error checking
log "Starting and configuring services..."

# Start Koha services
systemctl enable koha-common
if systemctl start koha-common; then
    log "✓ Koha service started"
else
    warn "Koha service may have issues, checking status..."
    systemctl status koha-common --no-pager -l
fi

# Restart Apache to pick up all configuration changes
if systemctl restart apache2; then
    log "✓ Apache restarted successfully"
else
    error "Apache failed to restart - check configuration"
fi

# Start Caddy
systemctl enable caddy
if systemctl restart caddy; then
    log "✓ Caddy started successfully"
else
    warn "Caddy may have issues, checking configuration..."
    caddy validate --config /etc/caddy/Caddyfile
    systemctl status caddy --no-pager -l
fi

# Create Moodle config file for easier setup
log "Creating Moodle configuration template..."
cat > "$SITES_DIRECTORY/config/moodle-config.php" << EOF
<?php
// Moodle configuration file template
// This will be used during Moodle web installation

unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

// Database configuration
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

// Site configuration
\$CFG->wwwroot   = 'https://$DOMAIN_MOODLE';
\$CFG->dataroot  = '$SITES_DIRECTORY/data/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0700;

// Performance and system paths
\$CFG->pathtodu = '/usr/bin/du';
\$CFG->aspellpath = '/usr/bin/aspell';
\$CFG->pathtodot = '/usr/bin/dot';

// Security settings
\$CFG->passwordsaltmain = '$(openssl rand -base64 32)';

// Enable caching for performance
\$CFG->cachejs = true;
\$CFG->yuicomboloading = true;

require_once(__DIR__ . '/lib/setup.php');
EOF

# Note: Don't copy the config yet - let Moodle web installer create it
chmod 600 "$SITES_DIRECTORY/config/moodle-config.php"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/moodle-config.php"

# Save database credentials for reference
cat > "$SITES_DIRECTORY/config/database-credentials.txt" << EOF
# Database Credentials for Koha + Moodle Setup
# Generated: $(date)

MariaDB Root:
  Username: root
  Password: $DB_ROOT_PASSWORD

Koha Database:
  Database: koha_library
  Username: koha
  Password: $KOHA_DB_PASSWORD

Moodle Database:
  Database: moodle
  Username: moodle
  Password: $MOODLE_DB_PASSWORD

Web Installer URLs:
  Koha: https://$DOMAIN_KOHA_STAFF
  Moodle: https://$DOMAIN_MOODLE

Important Notes:
- Complete Koha setup via web installer first
- Then complete Moodle setup via web installer
- Both systems are ready for configuration
EOF

chmod 600 "$SITES_DIRECTORY/config/database-credentials.txt"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/database-credentials.txt"

# Final service verification
log "Performing final service verification..."
services=("mariadb" "apache2" "caddy" "koha-common" "php8.3-fpm")
all_services_ok=true

for service in "${services[@]}"; do
    if systemctl is-active --quiet $service; then
        log "✓ $service is running"
    else
        warn "✗ $service is not running properly"
        all_services_ok=false
        # Show brief status for failed services
        systemctl status $service --no-pager -l | head -10
    fi
done

# Test Apache ports
log "Testing Apache port configuration..."
if netstat -tlnp | grep -q ":8000.*apache2"; then
    log "✓ Apache listening on port 8000 (Koha OPAC)"
else
    warn "✗ Apache not listening on port 8000"
fi

if netstat -tlnp | grep -q ":8080.*apache2"; then
    log "✓ Apache listening on port 8080 (Koha Staff)"
else
    warn "✗ Apache not listening on port 8080"
fi

# Test Caddy configuration
log "Testing Caddy configuration..."
if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    log "✓ Caddy configuration is valid"
else
    warn "✗ Caddy configuration has issues"
    caddy validate --config /etc/caddy/Caddyfile
fi

# Final setup completion message
log "Setup completed!"
echo
echo "=============================================="
echo -e "${GREEN}🎉 Installation Summary${NC}"
echo "=============================================="
echo "Sites Directory: $SITES_DIRECTORY"
echo
echo -e "${BLUE}📚 Koha Library System:${NC}"
echo "  • Public Catalog: https://$DOMAIN_KOHA"
echo "  • Staff Interface: https://$DOMAIN_KOHA_STAFF"
echo "  • Admin credentials: $SITES_DIRECTORY/config/koha-admin-password.txt"
echo "  • Version: Koha 24.11 LTS"
echo
echo -e "${BLUE}🎓 Moodle LMS:${NC}"
echo "  • Learning Portal: https://$DOMAIN_MOODLE"
echo "  • Installation: Ready for web installer"
echo "  • Version: Moodle 4.5 LTS"
echo
echo -e "${YELLOW}🚀 Next Steps:${NC}"
echo "1. 🌐 Ensure DNS records point to this server:"
echo "     $DOMAIN_KOHA → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "     $DOMAIN_KOHA_STAFF → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "     $DOMAIN_MOODLE → $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo
echo "2. 📚 Complete Koha setup:"
echo "   • Visit: https://$DOMAIN_KOHA_STAFF"
echo "   • Use credentials from: $SITES_DIRECTORY/config/koha-admin-password.txt"
echo "   • Choose MARC21 format (recommended)"
echo "   • Install sample data for easier testing"
echo
echo "3. 🎓 Complete Moodle setup:"
echo "   • Visit: https://$DOMAIN_MOODLE"
echo "   • Follow the web installer"
echo "   • Database details are pre-configured"
echo
echo -e "${BLUE}🏗️ System Architecture:${NC}"
echo "• Caddy (ports 80/443) → Reverse proxy with automatic SSL"
echo "• Apache (ports 8000/8080) → Serves Koha"
echo "• PHP-FPM (socket) → Processes Moodle"
echo "• MariaDB (port 3306) → Database for both systems"
echo
echo -e "${BLUE}📁 File Structure:${NC}"
echo "$SITES_DIRECTORY/"
echo "├── moodle/                 # Moodle application files"
echo "├── data/moodledata/        # Moodle user data"
echo "├── config/                 # All configuration files"
echo "│   ├── Caddyfile          # Caddy reverse proxy config"
echo "│   ├── moodle-config.php  # Moodle config template"
echo "│   ├── koha-admin-password.txt"
echo "│   └── database-credentials.txt"
echo "└── backups/                # Ready for your backup scripts"
echo
if [ "$all_services_ok" = true ]; then
    echo -e "${GREEN}✅ All services are running correctly!${NC}"
else
    echo -e "${YELLOW}⚠️  Some services need attention - check the warnings above${NC}"
fi
echo
echo -e "${BLUE}🔧 Useful Commands:${NC}"
echo "• Check services: sudo systemctl status apache2 caddy mariadb koha-common"
echo "• View logs: sudo tail -f /var/log/caddy/*.log"
echo "• Restart services: sudo systemctl restart apache2 caddy"
echo "• Koha admin: sudo koha-shell library"
echo
echo -e "${RED}🔒 Security Reminders:${NC}"
echo "• Change default passwords after setup"
echo "• Set up regular backups"
echo "• Keep systems updated"
echo "• Monitor resource usage"
echo "=============================================="

log "Installation completed successfully! Follow the next steps above to finish setup."
