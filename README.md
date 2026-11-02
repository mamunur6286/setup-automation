# V3 ERP Server Setup

`v3_setup.sh` sets up a fresh Ubuntu server for the V3 ERP (Laravel) app. It asks a few questions, then installs and configures everything it needs.

Requires Ubuntu 22.04 (24.04 also works). On 22.04 it installs the latest PHP 8.3.x from `ppa:ondrej/php`.

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

Then yes/no questions:

- **Fresh install** with `php artisan boot:application`. This **wipes the main and report databases**. It asks for company and unit details, seeds the data and runs protracker. If you choose it, the script skips the SQL import, migrate and protracker questions.
- Supervisor + Horizon, cron for `schedule:run`, cron for `queue:work`.
- Otherwise: `php artisan migrate --force` and `generate:protracker-views-table`.

## What it does

1. Updates the system and installs nginx, git, curl and unzip. Removes Apache if present.
2. Creates an SSH key for GitHub and waits until access works.
3. Clones the repo into `/var/www/<project>`.
4. Installs PHP 8.3 (FPM, no Apache) and its extensions, then tunes `php.ini`.
5. Installs Composer.
6. Installs MySQL, creates the database and user, and tunes the config.
7. Installs phpMyAdmin on its own port.
8. Sets up an nginx site for the domain and the extra port.
9. Installs wkhtmltopdf and Redis.
10. Configures Laravel: writes `.env` (DB, report DB and Redis point to this server; creates the report DB), runs `composer install`, generates the app key, sets permissions and runs `storage:link`.
11. Boots the app: either `boot:application` (fresh install), or the SQL import followed by `migrate --force`. Then it runs `optimize:clear`.
12. Optionally sets up Supervisor/Horizon and cron, and runs `generate:protracker-views-table`.

Packages already installed at the same version are skipped, and so is phpMyAdmin if the same version is already there. Anything missing or at a different version is installed.

The full output is logged to `/var/log/v3_setup_<timestamp>.log`.

## Resume after an error

Your answers and each finished step are saved in `.v3_setup_cache/` next to the script. If a step fails, fix the problem and run the script again. Answer **y** to "Resume it?" and it continues from the failed step without asking the questions again. Answer **n** to start over.

The cache holds the database password (file mode 600). It is deleted automatically when setup finishes.

## After setup

- Point the domain's DNS to the server IP.
- Check `<app>/.env` for mail, Redis and queue settings.
- Log out and back in so your user picks up the `www-data` group.
- Optional SSL:
  ```bash
  apt install certbot python3-certbot-nginx && certbot --nginx -d <domain>
  ```
