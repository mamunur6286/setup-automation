# V3 ERP Server Setup

`v3_setup.sh` sets up a fresh Ubuntu server for the V3 ERP (Laravel) app. It asks a few questions, then installs and configures everything it needs.

Tested on Ubuntu 22.04 and 24.04.

## Usage

```bash
sudo bash v3_setup.sh
```

The script must run as root. Press Enter to accept a default. Partway through, it prints an SSH public key. Add that key to GitHub (as a repo deploy key or an account SSH key) so the script can clone the repo.

## Prompts

| Prompt | Default |
|---|---|
| Git repository (SSH URL) | *(required)* |
| Git branch | *(required)* |
| Project folder in `/var/www` | `gormgv3` |
| Laravel app subfolder in repo | `.` (repo root) |
| Domain name | *(required)* |
| Extra app port | `8085` |
| phpMyAdmin port | `7070` |
| phpMyAdmin version | `5.2.2` |
| Database name / user | `gormgv3` / `dbAdmin` |
| Database password | *(required, asked twice)* |
| `innodb_buffer_pool_size` | `2G` (about 50% of RAM) |
| SQL dump to import | blank = skip |

Then yes/no questions: Supervisor + Horizon, cron for `schedule:run`, cron for `queue:work`, and running `generate:protracker-views-table`.

## What it does

1. Updates the system and installs nginx, git, curl and unzip. Removes Apache if present.
2. Creates an SSH key for GitHub and waits until access works.
3. Clones the repo into `/var/www/<project>`.
4. Installs PHP 8.3 with FPM and its extensions (uses `ppa:ondrej/php` if needed), then tunes `php.ini`.
5. Installs Composer.
6. Installs MySQL, creates the database and user, and tunes the config.
7. Installs phpMyAdmin on its own port.
8. Sets up an nginx site for the domain and the extra port.
9. Installs wkhtmltopdf and Redis.
10. Configures Laravel: writes `.env`, runs `composer install`, generates the app key, sets permissions and runs `storage:link`.
11. Optionally imports the SQL dump, sets up Supervisor/Horizon and cron, and runs `generate:protracker-views-table`.

The full output is logged to `/var/log/v3_setup_<timestamp>.log`.

## After setup

- Point the domain's DNS to the server IP.
- Check `<app>/.env` for mail, Redis and queue settings.
- Log out and back in so your user picks up the `www-data` group.
- Optional SSL:
  ```bash
  apt install certbot python3-certbot-nginx && certbot --nginx -d <domain>
  ```
