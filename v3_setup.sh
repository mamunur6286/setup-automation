#!/usr/bin/env bash
# =============================================================================
#  V3 ERP (Laravel) - Automated Server Setup
#  Based on V3_ENV_SETUP document.
#
#  Usage:   sudo bash v3_setup.sh
#  Tested target: Ubuntu 22.04 / 24.04
# =============================================================================
[ -z "$BASH_VERSION" ] && exec bash "$0" "$@"   # re-run with bash if started via `sh`
set -Eeuo pipefail

LOG_FILE="/var/log/v3_setup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- helpers ----------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
step()  { echo -e "\n${BLUE}==> $*${NC}"; }
ok()    { echo -e "${GREEN}✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
die()   { echo -e "${RED}✘ $*${NC}"; exit 1; }
trap 'die "Failed at line $LINENO. See log: $LOG_FILE"' ERR

ask() {            # ask VAR "Question" "default"
  local __var=$1 __q=$2 __def=${3:-} __ans
  if [[ -n $__def ]]; then read -rp "$__q [$__def]: " __ans; __ans=${__ans:-$__def}
  else while [[ -z ${__ans:-} ]]; do read -rp "$__q: " __ans; done; fi
  printf -v "$__var" '%s' "$__ans"
}
ask_secret() {     # ask_secret VAR "Question"
  local __var=$1 __q=$2 __a __b
  while true; do
    read -rsp "$__q: " __a; echo
    read -rsp "Confirm $__q: " __b; echo
    [[ -n $__a && $__a == "$__b" ]] && break
    warn "Empty or not matching, try again."
  done
  printf -v "$__var" '%s' "$__a"
}
ask_yn() {         # ask_yn "Question" default(y/n) -> returns 0 for yes
  local __a; read -rp "$1 [$2]: " __a; __a=${__a:-$2}; [[ $__a =~ ^[Yy] ]]
}
set_env() {        # set_env KEY VALUE FILE  (safe with special characters)
  local k=$1 v=$2 f=$3
  if grep -qE "^#?\s*${k}=" "$f"; then
    K="$k" V="$v" awk '$0 ~ "^#?[ \t]*"ENVIRON["K"]"=" {print ENVIRON["K"]"="ENVIRON["V"]; next} {print}' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    echo "${k}=${v}" >> "$f"
  fi
}
set_ini() {        # set_ini KEY VALUE FILE
  sed -i -E "s|^;?\s*${1}\s*=.*|${1} = ${2}|" "$3"
  grep -qE "^${1} =" "$3" || echo "${1} = ${2}" >> "$3"
}

[[ $EUID -eq 0 ]] || die "Run as root:  sudo bash $0"
REAL_USER=${SUDO_USER:-root}

# =============================================================================
#  1. COLLECT INFORMATION
# =============================================================================
clear
echo -e "${BLUE}=============== V3 Server Setup ===============${NC}"
echo "Answer the questions below (press Enter to accept default)."
echo

ask GIT_REPO     "Git repository (SSH URL, e.g. git@github.com:owner/repo.git)"
ask GIT_BRANCH   "Git branch"
ask PROJECT_DIR  "Project folder name inside /var/www"        "gormgv3"
ask APP_SUBDIR   "Laravel app subfolder inside repo ('.' = repo root)" "."
[[ $APP_SUBDIR == . ]] && APP_SUBDIR=""
ask DOMAIN       "Domain name (e.g. gormgv3-staging.skylarksoft.net)"
ask APP_PORT     "Extra port for the app"                     "8085"
ask PMA_PORT     "phpMyAdmin port"                            "7070"
ask PMA_VERSION  "phpMyAdmin version"                         "5.2.2"
ask DB_NAME      "Database name"                              "gormgv3"
ask DB_USER      "Database user"                              "dbAdmin"
ask_secret DB_PASS "Database password"
ask INNODB_POOL  "innodb_buffer_pool_size (≈50% of RAM)"      "2G"
ask SQL_DUMP     "Path to .sql dump on THIS server to import (blank = skip)" " "
SQL_DUMP=$(echo "$SQL_DUMP" | xargs)

INSTALL_SUPERVISOR=no; ask_yn "Setup Supervisor + Horizon?" y && INSTALL_SUPERVISOR=yes
INSTALL_CRON=no;       ask_yn "Setup cron for schedule:run?" y && INSTALL_CRON=yes
CRON_QUEUE=no;         ask_yn "Also add queue:work cron (not needed if Horizon runs)?" n && CRON_QUEUE=yes
RUN_PROTRACKER=no;     ask_yn "Run 'php artisan generate:protracker-views-table' at the end?" y && RUN_PROTRACKER=yes

REPO_PATH="/var/www/${PROJECT_DIR}"
APP_PATH="${REPO_PATH}${APP_SUBDIR:+/$APP_SUBDIR}"

echo
echo -e "${YELLOW}Summary:${NC}"
echo "  Repo        : $GIT_REPO ($GIT_BRANCH)"
echo "  Clone to    : $REPO_PATH"
echo "  Laravel app : $APP_PATH"
echo "  Domain      : $DOMAIN  (ports 80, $APP_PORT)"
echo "  phpMyAdmin  : port $PMA_PORT"
echo "  Database    : $DB_NAME / user $DB_USER"
echo "  SQL import  : ${SQL_DUMP:-skip}"
echo
ask_yn "Proceed?" y || die "Aborted by user."

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
#  2. SYSTEM UPDATE + BASE PACKAGES
# =============================================================================
step "Updating system"
apt-get update -y && apt-get upgrade -y
ok "System updated"

step "Creating /var/www"
mkdir -p /var/www
chown -R "$REAL_USER":www-data /var/www 2>/dev/null || true
chmod 775 /var/www
ok "/var/www ready"

step "Installing nginx, curl, unzip, git"
apt-get install -y nginx unzip curl git software-properties-common ca-certificates
if dpkg -l | grep -q '^ii\s*apache2 '; then
  warn "apache2 found - removing it (conflicts with nginx on port 80)"
  systemctl stop apache2 || true
  apt-get purge -y apache2 apache2-utils apache2-bin || true
  apt-get autoremove -y
fi
systemctl enable --now nginx
ok "Base packages installed"

# =============================================================================
#  3. SSH KEY FOR GITHUB
# =============================================================================
step "Setting up SSH key for GitHub"
KEY=/root/.ssh/id_ed25519
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[[ -f $KEY ]] || ssh-keygen -t ed25519 -N "" -f "$KEY" -C "$(hostname)-deploy"
GIT_HOST=$(echo "$GIT_REPO" | sed -E 's|^[^@]+@([^:]+):.*|\1|')
ssh-keyscan -H "$GIT_HOST" >> /root/.ssh/known_hosts 2>/dev/null
echo
echo -e "${YELLOW}Add this public key to GitHub (Repo > Settings > Deploy keys > Add deploy key, or your account Settings > SSH and GPG keys):${NC}"
echo "--------------------------------------------------------------------------"
cat "${KEY}.pub"
echo "--------------------------------------------------------------------------"
while true; do
  read -rp "Press Enter after adding the key to GitHub..."
  SSH_RESP=$(ssh -o BatchMode=yes -T "git@${GIT_HOST}" 2>&1 || true)
  echo "  $GIT_HOST says: $SSH_RESP"
  if grep -qiE "welcome|successfully" <<<"$SSH_RESP"; then
    ok "GitHub SSH access confirmed"; break
  fi
  warn "Cannot authenticate to $GIT_HOST yet. Check the key and try again."
done

# =============================================================================
#  4. CLONE REPOSITORY
# =============================================================================
step "Cloning repository"
if [[ -d $REPO_PATH/.git ]]; then
  warn "$REPO_PATH already exists - pulling latest"
  git -C "$REPO_PATH" fetch --all && git -C "$REPO_PATH" checkout "$GIT_BRANCH" && git -C "$REPO_PATH" pull
else
  git clone -b "$GIT_BRANCH" "$GIT_REPO" "$REPO_PATH"
fi
if [[ ! -f $APP_PATH/artisan && -f $REPO_PATH/artisan ]]; then
  warn "No artisan in $APP_PATH - using repo root $REPO_PATH instead"
  APP_SUBDIR=""; APP_PATH=$REPO_PATH
fi
[[ -f $APP_PATH/artisan ]] || die "No artisan file found in $APP_PATH - check the app subfolder name."
ok "Repository ready at $REPO_PATH"

# =============================================================================
#  5. PHP 8.3 + EXTENSIONS
# =============================================================================
step "Installing PHP 8.3"
PHP_PKGS=(php8.3 php8.3-cli php8.3-fpm php8.3-curl php8.3-mbstring php8.3-zip php8.3-xml \
          php8.3-gd php8.3-opcache php8.3-mysql php8.3-xsl php8.3-common php8.3-intl \
          php8.3-bcmath php8.3-sqlite3)
if ! apt-cache show php8.3-fpm >/dev/null 2>&1; then
  warn "PHP 8.3 not in default repo - adding ppa:ondrej/php"
  LC_ALL=C.UTF-8 add-apt-repository ppa:ondrej/php -y   # PPA needs a UTF-8 locale
  apt-get update -y
  apt-cache show php8.3-fpm >/dev/null 2>&1 \
    || die "PHP 8.3 still not found after adding the PPA. OS: $(. /etc/os-release; echo "$PRETTY_NAME"). ppa:ondrej/php only supports current Ubuntu LTS (22.04 / 24.04)."
fi
apt-get install -y "${PHP_PKGS[@]}"
apt-get install -y php8.3-redis || warn "php8.3-redis not available (fine if project uses predis)"
# make sure apache wasn't pulled in by the php meta-package
dpkg -l | grep -q '^ii\s*apache2 ' && { systemctl stop apache2 || true; apt-get purge -y apache2 apache2-bin || true; }
systemctl enable --now php8.3-fpm
ok "PHP $(php -r 'echo PHP_VERSION;') installed"

step "Tuning php.ini (fpm + cli)"
for INI in /etc/php/8.3/fpm/php.ini /etc/php/8.3/cli/php.ini; do
  set_ini max_input_vars      99999 "$INI"
  set_ini memory_limit        -1    "$INI"
  set_ini post_max_size       300M  "$INI"
  set_ini upload_max_filesize 300M  "$INI"
done
systemctl restart php8.3-fpm
ok "php.ini tuned"

# =============================================================================
#  6. COMPOSER
# =============================================================================
step "Installing Composer"
if ! command -v composer >/dev/null; then
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
fi
composer --version
ok "Composer ready"

# =============================================================================
#  7. MYSQL
# =============================================================================
step "Installing MySQL"
apt-get install -y mysql-server
systemctl enable --now mysql

DB_PASS_SQL=${DB_PASS//\'/\'\'}   # escape single quotes for SQL
mysql --user=root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
# Same as document (mysql_native_password) - ignored if server doesn't support it
mysql --user=root -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS_SQL}';" 2>/dev/null \
  || warn "mysql_native_password not available - using default auth plugin (works with PHP 8.3)"
ok "Database '${DB_NAME}' and user '${DB_USER}' ready"

step "Tuning MySQL config"
MYCNF=/etc/mysql/mysql.conf.d/mysqld.cnf
declare -A MYSQL_OPTS=(
  [max_allowed_packet]=1G [max_heap_table_size]=128M [max_connections]=500
  [table_open_cache]=1500 [tmp_table_size]=128M [innodb_file_per_table]=1
  [innodb_buffer_pool_size]=$INNODB_POOL [innodb_buffer_pool_instances]=8
)
for k in "${!MYSQL_OPTS[@]}"; do
  if grep -qE "^\s*#?\s*${k}\s*=" "$MYCNF"; then
    sed -i -E "s|^\s*#?\s*${k}\s*=.*|${k} = ${MYSQL_OPTS[$k]}|" "$MYCNF"
  else
    sed -i "/^\[mysqld\]/a ${k} = ${MYSQL_OPTS[$k]}" "$MYCNF"
  fi
done
systemctl restart mysql
ok "MySQL tuned and restarted"

# =============================================================================
#  8. PHPMYADMIN
# =============================================================================
step "Installing phpMyAdmin $PMA_VERSION"
if [[ ! -d /usr/share/phpmyadmin ]]; then
  cd /tmp
  wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
  tar -xzf "phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
  mv "phpMyAdmin-${PMA_VERSION}-all-languages" /usr/share/phpmyadmin
  rm -f "phpMyAdmin-${PMA_VERSION}-all-languages.tar.gz"
fi
cp -n /usr/share/phpmyadmin/config.sample.inc.php /usr/share/phpmyadmin/config.inc.php || true
BLOWFISH=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
sed -i "s|\$cfg\['blowfish_secret'\] = '.*';|\$cfg['blowfish_secret'] = '${BLOWFISH}';|" /usr/share/phpmyadmin/config.inc.php
mkdir -p /usr/share/phpmyadmin/tmp
chown -R www-data:www-data /usr/share/phpmyadmin
chmod -R 755 /usr/share/phpmyadmin
ln -sfn /usr/share/phpmyadmin /var/www/phpmyadmin

cat > /etc/nginx/sites-available/phpmyadmin <<NGINX
server {
    listen ${PMA_PORT};
    listen [::]:${PMA_PORT};
    root /var/www/phpmyadmin;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
NGINX
ln -sfn /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/phpmyadmin
ok "phpMyAdmin configured on port $PMA_PORT"

# =============================================================================
#  9. NGINX FOR PROJECT
# =============================================================================
step "Creating nginx config for $DOMAIN"
cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    listen ${APP_PORT};
    client_max_body_size 200M;

    server_name ${DOMAIN} www.${DOMAIN};
    root ${APP_PATH}/public;
    index index.html index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;

        fastcgi_connect_timeout 600s;
        fastcgi_send_timeout 600s;
        fastcgi_read_timeout 600s;

        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
        fastcgi_temp_file_write_size 256k;
    }
}
NGINX
ln -sfn "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
nginx -t
systemctl restart nginx
ok "nginx configured"

# =============================================================================
# 10. WKHTMLTOPDF
# =============================================================================
step "Installing wkhtmltopdf"
if ! command -v wkhtmltopdf >/dev/null; then
  cd /tmp
  CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
  if [[ $CODENAME == "focal" ]]; then
    wget -q http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
    dpkg -i libssl1.1_1.1.1f-1ubuntu2_amd64.deb || true
    WK_DEB=wkhtmltox_0.12.6-1.focal_amd64.deb
    WK_URL=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/$WK_DEB
  else
    # jammy package works on 22.04 and 24.04 without libssl1.1
    WK_DEB=wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    WK_URL=https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/$WK_DEB
  fi
  wget -q "$WK_URL"
  dpkg -i "$WK_DEB" || true
  apt-get --fix-broken install -y
fi
wkhtmltopdf --version || warn "wkhtmltopdf install failed - install manually"

# =============================================================================
# 11. REDIS
# =============================================================================
step "Installing Redis"
apt-get install -y redis-server
systemctl enable --now redis-server
redis-cli --version
ok "Redis ready"

# =============================================================================
# 12. LARAVEL: .env, composer, permissions, storage link
# =============================================================================
step "Configuring Laravel app"
cd "$APP_PATH"
[[ -f .env ]] || cp .env.example .env
set_env DB_CONNECTION mysql       .env
set_env DB_HOST       127.0.0.1   .env
set_env DB_PORT       3306        .env
set_env DB_DATABASE   "$DB_NAME"  .env
set_env DB_USERNAME   "$DB_USER"  .env
set_env DB_PASSWORD   "'${DB_PASS}'" .env
set_env APP_URL       "http://${DOMAIN}" .env

export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-interaction --prefer-dist --optimize-autoloader
grep -qE '^APP_KEY=.+' .env || php artisan key:generate --force

step "Setting permissions"
chown -R www-data:www-data "$REPO_PATH"
chmod -R 775 "$APP_PATH/storage" "$APP_PATH/bootstrap/cache"
chmod 640 "$APP_PATH/.env"
[[ $REAL_USER != root ]] && usermod -a -G www-data "$REAL_USER"
git config --global --add safe.directory "$REPO_PATH"
sudo -u www-data php artisan storage:link || warn "storage link already exists"
ok "Laravel configured"

# =============================================================================
# 13. DATABASE IMPORT (optional)
# =============================================================================
if [[ -n $SQL_DUMP ]]; then
  step "Importing $SQL_DUMP into $DB_NAME"
  [[ -f $SQL_DUMP ]] || die "SQL file not found: $SQL_DUMP"
  MYSQL_PWD="$DB_PASS" mysql -u"$DB_USER" "$DB_NAME" < "$SQL_DUMP"
  ok "Database imported"
fi

# =============================================================================
# 14. SUPERVISOR (Horizon)
# =============================================================================
if [[ $INSTALL_SUPERVISOR == yes ]]; then
  step "Installing Supervisor for Horizon"
  apt-get install -y supervisor
  cat > /etc/supervisor/conf.d/kingfisher-worker.conf <<CONF
[program:kingfisher-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${APP_PATH}/artisan horizon
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=/dev/null
stderr_logfile=/dev/null
stopwaitsecs=3600
CONF
  systemctl enable --now supervisor
  supervisorctl reread
  supervisorctl update
  supervisorctl start all || true
  ok "Supervisor running"
fi

# =============================================================================
# 15. CRON
# =============================================================================
if [[ $INSTALL_CRON == yes ]]; then
  step "Setting up cron"
  {
    echo "* * * * * www-data cd ${APP_PATH} && php artisan schedule:run >> /dev/null 2>&1"
    [[ $CRON_QUEUE == yes ]] && echo "* * * * * www-data cd ${APP_PATH} && php artisan queue:work --stop-when-empty >> /dev/null 2>&1"
  } > /etc/cron.d/${PROJECT_DIR}-laravel
  chmod 644 /etc/cron.d/${PROJECT_DIR}-laravel
  service cron reload
  ok "Cron installed (/etc/cron.d/${PROJECT_DIR}-laravel)"
fi

# =============================================================================
# 16. FINAL ARTISAN COMMANDS
# =============================================================================
if [[ $RUN_PROTRACKER == yes ]]; then
  step "Running generate:protracker-views-table"
  cd "$APP_PATH"
  sudo -u www-data php artisan generate:protracker-views-table || warn "Command failed - run it manually after DB import"
fi
cd "$APP_PATH"
sudo -u www-data php artisan optimize:clear || true

# =============================================================================
echo
echo -e "${GREEN}=================== SETUP COMPLETE ===================${NC}"
IP=$(hostname -I | awk '{print $1}')
echo "  App         : http://${DOMAIN}   or   http://${IP}:${APP_PORT}"
echo "  phpMyAdmin  : http://${IP}:${PMA_PORT}"
echo "  App path    : ${APP_PATH}"
echo "  Log file    : ${LOG_FILE}"
echo "  SSH key     : ${KEY}.pub"
echo "                $(cat "${KEY}.pub")"
echo
echo "  Next steps:"
echo "   - Point DNS for ${DOMAIN} to ${IP}"
echo "   - Review ${APP_PATH}/.env (mail, redis, queue settings)"
echo "   - Log out and back in so '${REAL_USER}' gets the www-data group"
echo "   - Optional SSL: apt install certbot python3-certbot-nginx && certbot --nginx -d ${DOMAIN}"
echo -e "${GREEN}======================================================${NC}"
