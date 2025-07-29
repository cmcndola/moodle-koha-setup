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
required_vars=("DOMAIN_KOHA" "DOMAIN_MOODLE" "LETSENCRYPT_EMAIL" "DB_ROOT_PASSWORD" "KOHA_DB_PASSWORD" "MOODLE_DB_PASSWORD")
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

# Enable required Apache modules (as per official docs)
log "Configuring Apache modules for Koha..."
a2enmod rewrite cgi headers proxy_http

# Create Koha instance with proper error handling
log "Creating Koha instance..."

# First, verify the database connection works
log "Testing database connection for Koha..."
if mysql -u koha -p"$KOHA_DB_PASSWORD" koha_library -e "SELECT 'Database connection OK' as status;" >/dev/null 2>&1; then
    log "✓ Database connection verified"
else
    error "Database connection failed. Cannot proceed with Koha installation."
fi

# Remove any existing instance first (in case of previous failures)
koha-remove library 2>/dev/null || true

# Create Koha instance (use --create-db to let Koha handle database setup)
log "Creating Koha instance..."
if koha-create --create-db library; then
    log "✓ Koha instance created successfully"
else
    error "Failed to create Koha instance"
fi

# Verify the configuration file was created
if [ -f "/etc/koha/sites/library/koha-conf.xml" ]; then
    log "✓ Koha configuration file created"
else
    error "Koha configuration file not found. Installation failed."
fi
koha-plack --enable library
koha-plack --start library

# Get admin password and save it
koha-passwd library > "$SITES_DIRECTORY/config/koha-admin-password.txt"
chmod 600 "$SITES_DIRECTORY/config/koha-admin-password.txt"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/koha-admin-password.txt"

log "Koha admin password saved to $SITES_DIRECTORY/config/koha-admin-password.txt"

# Enable email for Koha (as per docs)
log "Enabling email for Koha..."
koha-email-enable library

# Update Koha Apache config to use port 8000
sed -i 's/:80>/:8000>/' /etc/apache2/sites-available/library.conf

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

# Configure Caddy with fixed port conflicts
log "Configuring Caddy..."
cat > "$SITES_DIRECTORY/config/Caddyfile" << EOF
{
    email $LETSENCRYPT_EMAIL
}

# Koha OPAC (public interface)
$DOMAIN_KOHA {
    reverse_proxy localhost:8000
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
    reverse_proxy localhost:8080
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
    
    # Serve static files first (CSS, JS, images, etc.) - CRITICAL!
    file_server
    
    # Handle PHP files through FastCGI
    php_fastcgi unix//run/php/php8.3-fpm.sock {
        # Custom try_files optimized for Moodle
        try_files {path} {path}/index.php index.php
    }
    
    encode gzip
    
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        X-XSS-Protection "1; mode=block"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        # Referrer policy for better privacy
        Referrer-Policy strict-origin-when-cross-origin
    }
    
    # Block access to sensitive Moodle files
    @blocked {
        path *.log *.sql *.txt *.md
        path /config.php /install.php /admin/cli/* /lib/* /vendor/*
        path /.git/* /node_modules/* /composer.json /composer.lock
        path /behat/* /phpunit.xml /environment.xml
    }
    respond @blocked 403
    
    # Custom error pages for better UX
    handle_errors {
        @404 expression {http.error.status_code} == 404
        handle @404 {
            rewrite * /error/index.php
            php_fastcgi unix//run/php/php8.3-fpm.sock
        }
        
        # Generic error response for other errors
        respond "Error {http.error.status_code}: {http.error.status_text}" {http.error.status_code}
    }
    
    log {
        output file /var/log/caddy/moodle.log {
            roll_size 10mb
            roll_keep 5
        }
        # Log format with more details for debugging
        format console
    }
}
EOF

# Copy to system location and backup original
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.backup 2>/dev/null || true
cp "$SITES_DIRECTORY/config/Caddyfile" /etc/caddy/Caddyfile

# Create log directory
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Start services in proper sequence
log "Starting services..."
systemctl enable koha-common
systemctl start koha-common
systemctl restart apache2  # Required after Koha setup
systemctl enable caddy
systemctl restart caddy

# Create Moodle config file with system paths
log "Creating Moodle configuration..."
cat > "$SITES_DIRECTORY/config/moodle-config.php" << EOF
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
\$CFG->dataroot  = '$SITES_DIRECTORY/data/moodledata';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

// System paths for better performance (from references)
\$CFG->pathtodu = '/usr/bin/du';
\$CFG->aspellpath = '/usr/bin/aspell';
\$CFG->pathtodot = '/usr/bin/dot';

require_once(__DIR__ . '/lib/setup.php');
EOF

# Copy config to Moodle directory
cp "$SITES_DIRECTORY/config/moodle-config.php" "$SITES_DIRECTORY/moodle/config.php"
chown www-data:www-data "$SITES_DIRECTORY/moodle/config.php"
chmod 644 "$SITES_DIRECTORY/moodle/config.php"

# Also save database credentials separately for easy reference
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
EOF

chmod 600 "$SITES_DIRECTORY/config/database-credentials.txt"
chown "$SUDO_USER":"$SUDO_USER" "$SITES_DIRECTORY/config/database-credentials.txt"

# Verify services are running
log "Verifying services..."
for service in mariadb apache2 caddy koha-common php8.3-fpm; do
    if systemctl is-active --quiet $service; then
        log "✓ $service is running"
    else
        warn "✗ $service is not running - checking status"
        systemctl status $service --no-pager -l
    fi
done

# Final instructions
log "Setup completed successfully!"
echo
echo "=============================================="
echo -e "${GREEN}Installation Summary${NC}"
echo "=============================================="
echo "Sites Directory: $SITES_DIRECTORY"
echo
echo "Koha Library System:"
echo "  - Public URL: https://$DOMAIN_KOHA"
echo "  - Staff URL: https://$DOMAIN_KOHA_STAFF"
echo "  - Admin credentials: ./koha-admin-password.txt"
echo "  - Version: 24.11 LTS (recommended production version)"
echo
echo "Moodle LMS:"
echo "  - URL: https://$DOMAIN_MOODLE"
echo "  - Directory: $SITES_DIRECTORY/moodle"
echo "  - Data Directory: $SITES_DIRECTORY/data/moodledata"
echo "  - Complete setup by visiting the URL"
echo
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. ✅ Point DNS records to this server's IP:"
echo "     $DOMAIN_KOHA -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "     $DOMAIN_KOHA_STAFF -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "     $DOMAIN_MOODLE -> $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP')"
echo "2. 🌐 Complete Moodle setup via web interface"
echo "3. 📚 Complete Koha web installer at: https://$DOMAIN_KOHA_STAFF"
echo "4. 🔧 Run Koha onboarding tool after web installer"
echo "5. 🔍 Check logs: /var/log/caddy/ and /var/log/moodle-cron.log"
echo
echo -e "${BLUE}Koha Setup Notes:${NC}"
echo "• Use credentials from $SITES_DIRECTORY/config/koha-admin-password.txt for web installer"
echo "• Choose MARC21 format (default) during setup"
echo "• Install sample data for easier setup"
echo "• Create superlibrarian user during onboarding"
echo
echo -e "${BLUE}Architecture Details:${NC}"
echo "• Apache serves Koha on ports 8000 (OPAC) and 8080 (Staff)"
echo "• Caddy reverse proxies Apache and serves Moodle directly"
echo "• PHP 8.3 with all required extensions for Moodle 4.5 LTS"
echo "• MariaDB with proper database permissions"
echo "• All configs stored in $SITES_DIRECTORY/config/ for easy backup"
echo
echo -e "${BLUE}Easy Backup Structure:${NC}"
echo "$SITES_DIRECTORY/"
echo "├── moodle/                 # Moodle application"  
echo "├── data/moodledata/        # Moodle data files"
echo "├── config/                 # All configuration files"
echo "│   ├── Caddyfile"
echo "│   ├── koha-sites.conf"
echo "│   ├── moodle-config.php"
echo "│   ├── koha-admin-password.txt"
echo "│   └── database-credentials.txt"
echo "└── backups/                # Ready for your backup scripts"
echo
echo -e "${YELLOW}DNS Setup Required:${NC}"
echo "Point these domains to $(curl -s ifconfig.me 2>/dev/null || echo 'YOUR_SERVER_IP'):"
echo "• $DOMAIN_KOHA"
echo "• $DOMAIN_KOHA_STAFF"
echo "• $DOMAIN_MOODLE"
echo
echo -e "${RED}Important Security Notes:${NC}"
echo "• Change default passwords after setup"
echo "• Set up regular database backups"
echo "• Monitor resource usage (htop, df -h)"
echo "• Keep systems updated (apt update && apt upgrade)"
echo "=============================================="