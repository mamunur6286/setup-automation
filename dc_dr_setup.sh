#!/usr/bin/env bash
# ==============================================================================
# MySQL 1-DC to 1-DR Secure GTID Replication Setup Script
# Architecture:
#   - Primary DC (DC1): Single Active MySQL Node (Read/Write)
#   - DR DC (DC2): Single Passive MySQL Replica (Read-Only)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION VARIABLES (আপনার পরিবেশ অনুযায়ী পরিবর্তন করুন)
# ------------------------------------------------------------------------------
MYSQL_USER="root"
MYSQL_PASS=""

REPL_USER="repl_user"
REPL_PASS="Pass@#$00rTy"

# IP Address Configuration
PRIMARY_IP="172.18.20.11"        # Primary DC Server IP
DR_IP="172.18.21.11"             # DR DC Server IP

# সিকিউরিটির জন্য DR IP / Subnet Restricted IP pattern
DR_ALLOWED_HOST="172.18.21.11"   # '%' এর পরিবর্তে নির্দিষ্ট DR IP ব্যবহার করা হয়েছে

CONFIG_FILE="/etc/mysql/mysql.conf.d/mysqld.cnf"

# ------------------------------------------------------------------------------
# 1. CONFIGURE PRIMARY DC NODE
# ------------------------------------------------------------------------------
configure_primary() {
    echo "[INFO] Configuring Primary DC Node ($PRIMARY_IP)..."

    # MySQL Configuration Backup
    sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"

    # Append Secure Replication Configurations
    sudo bash -c "cat >> $CONFIG_FILE" <<EOF

# --- Primary DC (DC1) Configuration ---
server_id                       = 101
bind-address                    = ${PRIMARY_IP}
gtid_mode                       = ON
enforce_gtid_consistency        = ON
binlog_format                   = ROW
log_bin                         = mysql-bin
log_replica_updates             = ON
binlog_transaction_dependency_tracking = WRITESET
EOF

    echo "[INFO] Restarting MySQL service on Primary..."
    sudo systemctl restart mysql
    
    # Verification: MySQL active (running) এবং bind-address সঠিকভাবে সেট হয়েছে
    systemctl is-active --quiet mysql || { echo "[ERROR] MySQL is not running on Primary"; exit 1; }
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SELECT @@server_id, @@bind_address, @@gtid_mode, @@log_bin;"

    echo "[INFO] Creating RESTRICTED replication user on Primary..."
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "
        CREATE USER IF NOT EXISTS '${REPL_USER}'@'${DR_ALLOWED_HOST}' IDENTIFIED BY '${REPL_PASS}';
        GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${DR_ALLOWED_HOST}';
        ALTER USER '${REPL_USER}'@'${DR_ALLOWED_HOST}' REQUIRE SSL;
        FLUSH PRIVILEGES;
    "

    echo "[INFO] Primary DC configured successfully with Restricted User & SSL Requirement."
}

# ------------------------------------------------------------------------------
# 2. CONFIGURE DR DC NODE
# ------------------------------------------------------------------------------
configure_dr() {
    echo "[INFO] Configuring DR DC Node ($DR_IP)..."

    # MySQL Configuration Backup
    sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"

    sudo bash -c "cat >> $CONFIG_FILE" <<EOF

# --- DR DC (DC2) Configuration ---
server_id                       = 201
bind-address                    = ${DR_IP}
gtid_mode                       = ON
enforce_gtid_consistency        = ON
binlog_format                   = ROW
log_bin                         = mysql-bin
log_replica_updates             = ON
read_only                       = ON
super_read_only                 = ON
EOF

    echo "[INFO] Restarting MySQL service on DR..."
    sudo systemctl restart mysql

    echo "[INFO] Pointing DR Node to Primary DC securely..."
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "
        CHANGE REPLICATION SOURCE TO
            SOURCE_HOST='${PRIMARY_IP}',
            SOURCE_PORT=3306,
            SOURCE_USER='${REPL_USER}',
            SOURCE_PASSWORD='${REPL_PASS}',
            SOURCE_AUTO_POSITION=1,
            SOURCE_SSL=1,
            SOURCE_RETRY_COUNT=86400,
            SOURCE_CONNECT_RETRY=60;
        START REPLICA;
    "

    echo "[INFO] DR DC configured. Current Replica Status:"
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SHOW REPLICA STATUS\G"
}

# ------------------------------------------------------------------------------
# 3. VERIFY REPLICATION STATUS
# ------------------------------------------------------------------------------
check_status() {
    echo "=== DR Replication Status Check ==="
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SHOW REPLICA STATUS\G"
}

# ------------------------------------------------------------------------------
# ENTRY POINT
# ------------------------------------------------------------------------------
case "${1:-}" in
    setup-primary)
        configure_primary
        ;;
    setup-dr)
        configure_dr
        ;;
    status)
        check_status
        ;;
    *)
        echo "Usage: $0 {setup-primary|setup-dr|status}"
        exit 1
        ;;
esac