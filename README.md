# Koha + Moodle + Caddy Setup

Automated setup script for deploying Koha (Library Management System) and Moodle (Learning Management System) with Caddy web server on Ubuntu 24.04.

## System Requirements

This script is designed for **Ubuntu 24.04** with minimum specifications:

- **2 vCPU** (recommended)
- **4GB RAM** (minimum, 6GB+ recommended for production)
- **40GB SSD** (minimum storage)

### Memory Usage Breakdown

- **Operating System**: ~1GB
- **Koha**: 750MB-1GB at idle
- **Moodle**: 1-2GB typical usage
- **MariaDB**: 350-500MB
- **Caddy**: ~30MB
- **Swap**: 4GB configured automatically

### Supported Versions

- **Koha**: 24.11 LTS (Long Term Support)
- **Moodle**: 4.5 LTS (Latest stable)
- **Ubuntu**: 24.04 LTS
- **MariaDB**: 10.6+
- **PHP**: 8.3
- **Caddy**: Latest stable

## Requirements

- Ubuntu 24.04 VPS (minimum 2vCPU, 4GB RAM, 40GB SSD)
- Two subdomains pointed to your server IP
- Root access

## Quick Start

1. **Clone the repository**

   ```bash
   git clone https://github.com/yourusername/koha-moodle-setup.git
   cd koha-moodle-setup
   ```

2. **Configure environment**

   ```bash
   cp .env.example .env
   nano .env  # Edit with your settings
   ```

3. **Set up DNS**
   Point your subdomains to your server IP:

   - `library.yourdomain.com` → Your server IP
   - `lms.yourdomain.com` → Your server IP

4. **Run setup**
   ```bash
   sudo ./setup.sh
   ```

## Configuration

Edit `.env` with your settings:

```bash
# Domain Configuration
DOMAIN_KOHA=library.example.com
DOMAIN_MOODLE=lms.example.com

# Email for Let's Encrypt
LETSENCRYPT_EMAIL=admin@example.com

# Database Passwords (use strong passwords!)
DB_ROOT_PASSWORD=your_secure_root_password
KOHA_DB_PASSWORD=your_koha_password
MOODLE_DB_PASSWORD=your_moodle_password
```

## Post-Installation

### Access Your Applications

- **Koha Public**: https://library.yourdomain.com
- **Koha Staff**: https://library.yourdomain.com:8080
- **Moodle**: https://lms.yourdomain.com

### Koha Setup Process

After the script completes, you need to complete the Koha installation:

1. **Web Installer**: Visit https://library.yourdomain.com:8080

   - Use credentials from `koha-admin-password.txt`
   - Select MARC21 format (recommended)
   - Install sample data for easier setup
   - This creates database tables and basic configuration

2. **Onboarding Tool**: Automatically starts after web installer
   - Create your library/branch
   - Set up patron categories
   - Create superlibrarian user account
   - Define item types
   - Configure circulation rules

### Moodle Setup Process

1. **Web Installation**: Visit https://lms.yourdomain.com

   - Follow the installation wizard
   - Choose language and configure paths
   - Select improved MySQL driver
   - Database configuration is already completed
   - Accept license and verify server requirements
   - Create administrator account
   - Register your site

2. **Post-Installation Configuration**:
   - Configure system paths for better performance
   - Enable cron jobs (automatically configured)
   - Set up additional plugins as needed

### Technical Details

- **Koha Version**: 24.11 LTS (Long Term Support)
- **Moodle Version**: 4.5 LTS (installed via Git)
- **MARC Format**: MARC21 (can be changed during setup)
- **Search Engine**: Zebra (default, Elasticsearch optional)
- **Memory Usage**: ~750MB-1GB at idle (Koha) + ~350-500MB (MariaDB) + 1-2GB (Moodle)
- **Installation Method**: Git clone (recommended by both projects)
- **Security**: Restrictive file permissions, proper database privileges
- **Maintenance**: Automated cron jobs for both systems

## Resource Monitoring

Monitor your system resources:

```bash
# Check memory and CPU usage
htop

# Check disk usage
df -h

# Check service status
systemctl status koha-common caddy php8.3-fpm mariadb

# View logs
tail -f /var/log/caddy/koha.log
tail -f /var/log/caddy/moodle.log
```

## Backup Strategy

### Database Backups

```bash
# Backup Koha database
mysqldump -u root -p koha_library > koha_backup_$(date +%Y%m%d).sql

# Backup Moodle database
mysqldump -u root -p moodle > moodle_backup_$(date +%Y%m%d).sql
```

### File Backups

```bash
# Backup Moodle data
tar -czf moodledata_backup_$(date +%Y%m%d).tar.gz /var/moodledata

# Backup Moodle files
tar -czf moodle_backup_$(date +%Y%m%d).tar.gz /var/www/moodle
```

## Troubleshooting

### Common Issues

**SSL Certificate Issues**

```bash
# Check Caddy status
systemctl status caddy

# View Caddy logs
journalctl -u caddy -f

# Test Caddy config
caddy validate --config /etc/caddy/Caddyfile
```

**Database Connection Issues**

```bash
# Test database connectivity
mysql -u koha -p koha_library
mysql -u moodle -p moodle
```

**Memory Issues**

```bash
# Check swap usage
free -h

# Check memory usage by service
ps aux --sort=-%mem | head
```

### Log Locations

- Caddy: `/var/log/caddy/`
- Koha: `/var/log/koha/`
- PHP-FPM: `/var/log/php8.3-fpm.log`
- MariaDB: `/var/log/mysql/`

## Security Recommendations

- [ ] Change all default passwords
- [ ] Set up automated backups
- [ ] Configure fail2ban for SSH protection
- [ ] Regular system updates
- [ ] Monitor resource usage
- [ ] Review access logs regularly

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on a fresh Ubuntu 24.04 instance
5. Submit a pull request

## License

MIT License - see LICENSE file for details

## Support

- 📖 [Koha Documentation](https://koha-community.org/documentation/)
- 📖 [Moodle Documentation](https://docs.moodle.org/)
- 📖 [Caddy Documentation](https://caddyserver.com/docs/)

For issues with this setup script, please open a GitHub issue.
