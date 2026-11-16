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
REPL_PASS='Pass@#$00rTy'   # single quotes: "$0" would expand to the script name

# IP Address Configuration
PRIMARY_IP="172.18.20.11"        # Primary DC Server IP
DR_IP="172.18.21.11"             # DR DC Server IP
DR_SSH_USER="root"               # dump-primary এর scp এর জন্য
DR_SSH_PORT="22022"

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

    # Re-run safe: আগের রান থেকে যোগ করা block মুছে ফেলা (block টি সবসময় ফাইলের শেষে থাকে)
    sudo sed -i '/^# --- Primary DC (DC1) Configuration ---/,$d' "$CONFIG_FILE"

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

    echo "[INFO] Removing old '${REPL_USER}' accounts (any host) on Primary..."
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -N -e \
        "SELECT host FROM mysql.user WHERE user='${REPL_USER}';" |
    while IFS= read -r old_host; do
        echo "[INFO] Dropping '${REPL_USER}'@'${old_host}'"
        mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SET sql_log_bin=0; DROP USER IF EXISTS '${REPL_USER}'@'${old_host}';"
    done

    # sql_log_bin=0: account changes must not replicate, DR lacks the mysql schema (Error 1396)
    echo "[INFO] Creating RESTRICTED replication user on Primary..."
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "
        SET sql_log_bin=0;
        CREATE USER IF NOT EXISTS '${REPL_USER}'@'${DR_ALLOWED_HOST}' IDENTIFIED BY '${REPL_PASS}';
        GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${DR_ALLOWED_HOST}';
        ALTER USER '${REPL_USER}'@'${DR_ALLOWED_HOST}' REQUIRE SSL;
        FLUSH PRIVILEGES;
    "

    echo "[INFO] Primary DC configured successfully with Restricted User & SSL Requirement."
}

# ------------------------------------------------------------------------------
# 1b. DUMP PRIMARY DATA (run on Primary, then copy the file to DR)
# DR কে Primary এর বর্তমান data + GTID position দিয়ে শুরু করতে হবে, নাহলে
# আগে থেকে থাকা database এর জন্য replication Error 1049 (Unknown database) দেয়
# ------------------------------------------------------------------------------
dump_primary() {
    local out="${1:-/tmp/dc_dump.sql}"
    # System schemas বাদ: DR এর নিজস্ব users/root login অক্ষত থাকবে
    local dbs
    dbs=$(mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -N -e \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema');")
    [ -n "$dbs" ] || { echo "[ERROR] No application databases found on Primary"; exit 1; }

    echo "[INFO] Dumping databases: $(echo $dbs)"
    # shellcheck disable=SC2086
    mysqldump -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} \
        --single-transaction --triggers --routines --events \
        --set-gtid-purged=ON --add-drop-database --databases $dbs > "$out"

    echo "[INFO] Dump written to $out ($(grep -c '^CREATE TABLE' "$out") tables)"
    echo "[INFO] Copying dump to DR (${DR_SSH_USER}@${DR_IP}:${DR_SSH_PORT})..."
    scp -P "${DR_SSH_PORT}" "$out" "${DR_SSH_USER}@${DR_IP}:/tmp/dc_dump.sql" ||
        echo "[WARN] Auto copy failed. Copy manually: scp -P ${DR_SSH_PORT} $out ${DR_SSH_USER}@${DR_IP}:/tmp/dc_dump.sql"
    echo "[NEXT] On DR: $0 setup-dr <dc_db> <dr_db>   (e.g. setup-dr gormgv3 gormgv3_dr)"
}

# ------------------------------------------------------------------------------
# 2. CONFIGURE DR DC NODE
# ------------------------------------------------------------------------------
configure_dr() {
    echo "[INFO] Configuring DR DC Node ($DR_IP)..."

    # DR নিজে কোনো database তৈরি করে না: DC এর dump import বাধ্যতামূলক (কিছু বদলানোর আগেই check)
    # Command থেকে database নাম: setup-dr <dc_db> <dr_db> [dump_file]
    local dc_db="${1:-}" dr_db="${2:-}" dump_file="${3:-/tmp/dc_dump.sql}"
    [ -n "$dc_db" ] && [ -n "$dr_db" ] || { echo "[ERROR] Usage: $0 setup-dr <dc_db> <dr_db> [dump_file]"; exit 1; }
    # শুধু নিরাপদ নাম: এগুলো SQL, sed এবং mysqld.cnf এ বসানো হয়
    [[ "$dc_db" =~ ^[A-Za-z0-9_]+$ && "$dr_db" =~ ^[A-Za-z0-9_]+$ ]] ||
        { echo "[ERROR] Database names may contain only letters, digits and _"; exit 1; }
    [ -s "$dump_file" ] || { echo "[ERROR] DC dump '$dump_file' not found or empty. First run on Primary: $0 dump-primary"; exit 1; }
    grep -qx "USE \`${dc_db}\`;" "$dump_file" ||
        { echo "[ERROR] Database '${dc_db}' not in dump. Found: $(sed -n 's/^USE `\(.*\)`;$/\1/p' "$dump_file" | xargs)"; exit 1; }
    echo "[INFO] DC database '${dc_db}' -> DR database '${dr_db}'"

    # Dump থেকে শুধু dc_db অংশ (header + GTID_PURGED সহ) রেখে নাম বদলে dr_db করা
    local db_dump
    db_dump=$(mktemp)
    awk -v want="-- Current Database: \`${dc_db}\`" \
        '/^-- Current Database: `/ { started=1; keep=($0 == want) } !started || keep' "$dump_file" |
        sed -E '/^(\/\*!40000 DROP DATABASE|CREATE DATABASE|USE `)/ s/`[^`]+`/`'"${dr_db}"'`/' > "$db_dump"

    # MySQL Configuration Backup
    sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"

    # Re-run safe: আগের রান থেকে যোগ করা block মুছে ফেলা
    sudo sed -i '/^# --- DR DC (DC2) Configuration ---/,$d' "$CONFIG_FILE"

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
# DC এর dc_db change গুলো DR এর dr_db তে, DC এর অন্য database replicate হবে না
replicate-rewrite-db            = ${dc_db}->${dr_db}
replicate-do-db                 = ${dr_db}
EOF

    echo "[INFO] Restarting MySQL service on DR..."
    sudo systemctl restart mysql

    # Replace any previous replication config (e.g. pointing to a wrong IP)
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "STOP REPLICA; RESET REPLICA ALL;"

    local dump_tables
    dump_tables=$(grep -c '^CREATE TABLE' "$db_dump" || true)
    echo "[INFO] Dump file: $(ls -l "$dump_file") | tables in '${dc_db}': ${dump_tables}"
    [ "$dump_tables" -gt 0 ] || { echo "[ERROR] Dump has no tables. Re-run on Primary: $0 dump-primary"; exit 1; }
    echo "[INFO] Importing DC database dump '$dump_file' into DR..."
    # Dump এর GTID_PURGED সেট করতে DR এর gtid_executed খালি থাকতে হবে
    # MySQL 8.4+: RESET BINARY LOGS AND GTIDS; পুরোনো version: RESET MASTER
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "RESET BINARY LOGS AND GTIDS;" 2>/dev/null ||
        mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "RESET MASTER;"
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SET GLOBAL super_read_only = OFF;"

    # DR এর সব পুরোনো application database মুছে ফেলা, যাতে DR শুধু DC এর data দিয়ে নতুন করে তৈরি হয়
    # sql_log_bin=0: drop গুলো DR এর binlog/GTID এ যাবে না
    local old_db
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -N -e \
        "SELECT schema_name FROM information_schema.schemata
         WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema');" |
    while IFS= read -r old_db; do
        echo "[INFO] Dropping DR database '${old_db}'"
        mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SET sql_log_bin=0; DROP DATABASE \`${old_db}\`;"
    done

    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} < "$db_dump"
    rm -f "$db_dump"
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SET GLOBAL super_read_only = ON;"
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SELECT @@gtid_executed AS dr_gtid_after_load;"
    local dr_tables
    dr_tables=$(mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${dr_db}' AND table_type='BASE TABLE';")
    echo "[INFO] Tables in DR '${dr_db}' after import: ${dr_tables} (dump: ${dump_tables})"
    [ "$dr_tables" -eq "$dump_tables" ] || { echo "[ERROR] Import incomplete: DR has fewer tables than the dump"; exit 1; }

    echo "[INFO] Testing replication login to Primary..."
    if ! MYSQL_PWD="${REPL_PASS}" mysql -h"${PRIMARY_IP}" -u"${REPL_USER}" --ssl-mode=REQUIRED -e "SELECT 1;" >/dev/null; then
        echo "[ERROR] DR cannot log in to Primary as '${REPL_USER}'. Copy this same script to Primary and run: $0 setup-primary"
        exit 1
    fi

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
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e "SHOW REPLICA STATUS\G" |
        grep -E "Source_Host|Replica_(IO|SQL)_Running:|Last_(IO_|SQL_)?Error|Seconds_Behind_Source" ||
        echo "[WARN] Replication not configured on this server"
    echo "=== Tables per database ==="
    mysql -u"${MYSQL_USER}" ${MYSQL_PASS:+-p"${MYSQL_PASS}"} -e \
        "SELECT table_schema AS db, COUNT(*) AS tables FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema') GROUP BY 1;"
}

# ------------------------------------------------------------------------------
# ENTRY POINT
# ------------------------------------------------------------------------------
case "${1:-}" in
    setup-primary)
        configure_primary
        ;;
    dump-primary)
        dump_primary "${2:-}"
        ;;
    setup-dr)
        configure_dr "${2:-}" "${3:-}" "${4:-}"
        ;;
    status)
        check_status
        ;;
    *)
        echo "Usage: $0 {setup-primary|dump-primary [out_file]|setup-dr <dc_db> <dr_db> [dump_file, default /tmp/dc_dump.sql]|status}"
        exit 1
        ;;
esac