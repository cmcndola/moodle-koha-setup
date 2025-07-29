# Koha + Moodle Setup Script

Automated installation script for deploying Koha (Library Management System) and Moodle (Learning Management System) on Ubuntu 24.04.

## Quick Start

```bash
git clone https://github.com/yourusername/koha-moodle-setup.git
cd koha-moodle-setup
cp .env.example .env
nano .env  # Configure your domains and passwords
sudo ./setup.sh
```

## Requirements

- **Ubuntu 24.04** VPS (minimum 2 vCPU, 4GB RAM, 40GB SSD)
- **Two domains** pointed to your server IP:
  - `library.example.com` → Koha public catalog
  - `staff.example.com` → Koha staff interface
  - `lms.example.com` → Moodle
- **Root access**

## What Gets Installed

- **Koha 24.11 LTS** - Library management system
- **Moodle 4.5 LTS** - Learning management system
- **MariaDB** - Database server
- **PHP 8.3** - With all required extensions
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

# Optional: Custom sites directory
SITES_DIRECTORY=/path/to/your/sites
```

## After Installation

1. **Complete Koha setup** at `https://$DOMAIN_KOHA_STAFF`

   - Credentials in `~/sites/config/koha-admin-password.txt`
   - Choose MARC21 format and install sample data

2. **Complete Moodle setup** at `https://lms.example.com`
   - Follow the web installer
   - Database is already configured

## File Structure

```
~/sites/
├── moodle/                 # Moodle application
├── data/moodledata/        # Moodle data files
├── config/                 # All configuration files
│   ├── Caddyfile
│   ├── koha-admin-password.txt
│   └── database-credentials.txt
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

## Backup

```bash
# Files
tar -czf backup-$(date +%Y%m%d).tar.gz ~/sites/

# Databases
mysqldump -u root -p koha_library > ~/sites/backups/koha-$(date +%Y%m%d).sql
mysqldump -u root -p moodle > ~/sites/backups/moodle-$(date +%Y%m%d).sql
```

## Troubleshooting

**Check services:**

```bash
sudo systemctl status apache2 caddy mariadb koha-common php8.3-fpm
```

**View logs:**

```bash
sudo tail -f /var/log/caddy/koha.log
sudo tail -f /var/log/caddy/moodle.log
```

**Verify DNS:**

```bash
dig library.example.com
dig staff.example.com
dig lms.example.com
```

## Resources

- [Koha Documentation](https://koha-community.org/documentation/)
- [Moodle Documentation](https://docs.moodle.org/)
