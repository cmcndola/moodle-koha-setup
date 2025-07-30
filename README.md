# Moodle + Koha Setup Script

Automated installation script for deploying Moodle (Learning Management System) and Koha (Library Management System) on Ubuntu 24.04.

[![ShellCheck](https://github.com/cmcndola/moodle-koha-setup/actions/workflows/main.yml/badge.svg)](https://github.com/cmcndola/moodle-koha-setup/actions/workflows/main.yml)

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Quick Start](#quick-start)
- [Requirements](#requirements)
- [What Gets Installed](#what-gets-installed)
- [Configuration](#configuration)
- [After Installation](#after-installation)
- [File Structure](#file-structure)
- [Architecture](#architecture)
  - [Technical Notes](#technical-notes)
- [Backup](#backup)
- [Troubleshooting](#troubleshooting)
- [Resources](#resources)
- [Security Notes](#security-notes)
  - [Credential Storage](#credential-storage)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Quick Start

```bash
git clone https://github.com/cmcndola/moodle-koha-setup.git
cd moodle-koha-setup
cp .env.example .env
nano .env  # Configure your domains and passwords
sudo ./setup_moodle_and_koha.sh
```

## Requirements

- **Ubuntu 24.04** VPS (minimum 2 vCPU, 4GB RAM, 40GB SSD)
- **Three domains** pointed to your server IP:
  - `library.example.com` → Koha public catalog
  - `staff.example.com` → Koha staff interface
  - `lms.example.com` → Moodle
- **Root access**

## What Gets Installed

- **Koha 24.11 LTS** - Library management system
- **Moodle 4.5 LTS** - Learning management system (patched for Caddy compatibility)
- **MariaDB** - Database server
- **PHP 8.3** - With all required extensions (configured for Moodle requirements)
- **Apache** - Serves Koha (ports 8000/8080)
- **Caddy** - Reverse proxy with automatic SSL

## Configuration

Edit `.env` with your settings:

```bash
# Domains
DOMAIN_KOHA=library.example.com
DOMAIN_KOHA_STAFF=staff.example.com
DOMAIN_MOODLE=lms.example.com

# Email for SSL certificates
LETSENCRYPT_EMAIL=admin@example.com

# Database passwords (use strong passwords!)
DB_ROOT_PASSWORD=your_secure_root_password
KOHA_DB_PASSWORD=your_koha_password
MOODLE_DB_PASSWORD=your_moodle_password

# Optional: Custom sites directory (defaults to /var/www)
SITES_DIRECTORY=/path/to/your/sites
```

## After Installation

1. **Complete Koha setup** at `https://staff.example.com`

   - Credentials in `/var/www/config/koha-admin-password.txt` (or your configured SITES_DIRECTORY)
   - Choose MARC21 format and install sample data

2. **Complete Moodle setup** at `https://lms.example.com`
   - Follow the web installer
   - Database is already configured
   - All server requirements checks should pass

## File Structure

```
/var/www/  (or your configured SITES_DIRECTORY)
├── moodle/                 # Moodle application
├── data/moodledata/        # Moodle data files
├── config/                 # All configuration files
│   ├── Caddyfile
│   ├── koha-admin-password.txt
│   ├── database-credentials.txt
│   └── moodle-server-patch.sh
└── backups/                # For your backup scripts
```

## Architecture

```
Internet → Caddy (SSL) → {
  library.example.com → Apache:8000 (Koha OPAC)
  staff.example.com → Apache:8080 (Koha Staff)
  lms.example.com → PHP-FPM (Moodle)
}
```

### Technical Notes

- **Moodle Compatibility**: Moodle doesn't officially support Caddy, but the script patches Moodle to accept it. Caddy acts as a reverse proxy while PHP-FPM serves Moodle.
- **PHP Configuration**: Configured with `max_input_vars=5000` as required by Moodle
- **SSL Certificates**: Automatically managed by Caddy via Let's Encrypt

## Backup

```bash
# Files
tar -czf backup-$(date +%Y%m%d).tar.gz /var/www/

# Databases
mysqldump -u root -p koha_library > /var/www/backups/koha-$(date +%Y%m%d).sql
mysqldump -u root -p moodle > /var/www/backups/moodle-$(date +%Y%m%d).sql
```

## Troubleshooting

**Check services:**

```bash
sudo systemctl status apache2 caddy mariadb koha-common php8.3-fpm
```

**View logs:**

```bash
# Caddy logs
sudo journalctl -u caddy -f
sudo journalctl -u caddy --since today

# Apache logs
sudo journalctl -u apache2 -f

# PHP-FPM logs
sudo journalctl -u php8.3-fpm -f

# Export logs for analysis
sudo journalctl -u caddy > caddy-logs.txt
```

**Verify DNS:**

```bash
dig library.example.com
dig staff.example.com
dig lms.example.com
```

**Moodle-specific troubleshooting:**

```bash
# Check PHP configuration
php -i | grep max_input_vars  # Should show 5000

# Re-apply Moodle server patch if needed
sudo /var/www/config/moodle-server-patch.sh /var/www/moodle

# Test file permissions
sudo -u www-data ls -la /var/www/moodle/
```

**Other useful commands:**

```bash
# Validate Caddy configuration
sudo caddy validate --config /etc/caddy/Caddyfile

# Access Koha shell
sudo koha-shell library

# Restart services
sudo systemctl restart apache2 caddy php8.3-fpm
```

## Resources

- [Koha Documentation](https://koha-community.org/documentation/)
- [Moodle Documentation](https://docs.moodle.org/)
- [Caddy Documentation](https://caddyserver.com/docs/)

## Security Notes

### Credential Storage

After installation, sensitive credentials are stored in:

- `/var/www/config/koha-admin-password.txt`
- `/var/www/config/database-credentials.txt`

These files have restricted permissions (`600`, root-only access), but for production environments, consider:

1. **Moving credentials to a more secure location** outside the web directory:

   ```bash
   sudo mkdir -p /etc/moodle-koha-secure
   sudo mv /var/www/config/*-password.txt /etc/moodle-koha-secure/
   sudo mv /var/www/config/database-credentials.txt /etc/moodle-koha-secure/
   sudo chmod 700 /etc/moodle-koha-secure
   ```

2. **Using a password manager** to store credentials and removing the files:

   ```bash
   sudo shred -vfz /var/www/config/*-password.txt
   sudo shred -vfz /var/www/config/database-credentials.txt
   ```

3. **Excluding credential files from backups** to prevent accidental exposure

Remember: The Koha admin password is only shown once during installation. Make sure to save it securely!
