#!/usr/bin/env bash
set -euo pipefail

HEAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$HEAL_DIR/lib/common.sh"

need_root

[ -d "$PANEL_DIR" ] || { echo "Panel is not installed yet - nothing to reset." >&2; exit 1; }
[ -f "$PANEL_DIR/.env" ] || { echo "Panel .env missing - nothing to reset." >&2; exit 1; }

PHP_VER=$(panel_php_version)
PHP_BIN="php$PHP_VER"
[ -x "$(command -v "$PHP_BIN" 2>/dev/null || echo /usr/bin/php)" ] || PHP_BIN=php

ADMIN_EMAIL=${1:-}
if [ -z "$ADMIN_EMAIL" ]; then
  if [ -f "$SECRETS_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    set +a
    ADMIN_EMAIL=${ADMIN_EMAIL:-${ADMIN_USERNAME:-admin}}
  else
    ADMIN_EMAIL=admin
  fi
fi

NEW_PASS=$(random_hex 10)
NEW_EMAIL="${ADMIN_EMAIL}"
NEW_USER="${ADMIN_USERNAME:-admin}"

echo "Resetting Pelican admin access..."
cd "$PANEL_DIR" || exit 1

TINKER_OUT=$(COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" artisan tinker --execute="
use Spatie\Permission\Models\Permission;
try {
    \$role = \App\Models\Role::getRootAdmin();
    \$perms = [];
    foreach (\App\Models\Role::getPermissionList() as \$model => \$prefixes) {
        foreach (\$prefixes as \$prefix) {
            \$perms[] = Permission::findOrCreate(\$prefix . ' ' . \$model, 'web')->name;
        }
    }
    \$role->syncPermissions(\$perms);
    \$user = \App\Models\User::where('username', '$NEW_USER')->first()
          ?? \App\Models\User::where('email', '$NEW_EMAIL')->first()
          ?? \App\Models\User::first();
    if (\$user) {
        \$user->forceFill(['password' => \Illuminate\Support\Facades\Hash::make('$NEW_PASS')])->save();
        if (!\$user->hasRole(\$role)) { \$user->assignRole(\$role); }
        \$user->update(['mfa_app_secret' => null, 'mfa_app_recovery_codes' => null, 'mfa_email_enabled' => false]);
        echo 'RESET_OK username=' . \$user->username . ' email=' . \$user->email . ' admin=' . (\$user->isRootAdmin() ? 'yes' : 'no') . ' perms=' . \$role->permissions()->count() . PHP_EOL;
    } else {
        echo 'NO_USER' . PHP_EOL;
    }
} catch (\Throwable \$e) {
    echo 'RESET_ERR ' . \$e->getMessage() . PHP_EOL;
}
" 2>&1 || true)
RESULT=$(echo "$TINKER_OUT" | grep -E 'RESET_OK|NO_USER|RESET_ERR' | head -1 || true)

if echo "$RESULT" | grep -q 'NO_USER'; then
  echo "No user found - creating a fresh admin instead..."
  COMPOSER_ALLOW_SUPERUSER=1 "$PHP_BIN" artisan p:user:make --email="$NEW_EMAIL@$(hostname 2>/dev/null || echo localhost)" \
    --username="$NEW_USER" --password="$NEW_PASS" --admin=1 --no-interaction >/dev/null 2>&1 || {
    echo "Could not create admin. Run manually: php artisan p:user:make --admin=1" >&2
    exit 1
  }
  RESULT="RESET_OK username=$NEW_USER email=$NEW_EMAIL"
fi

if echo "$RESULT" | grep -q 'RESET_OK'; then
  {
    echo "ADMIN_EMAIL=$ADMIN_EMAIL"
    echo "ADMIN_USERNAME=$NEW_USER"
    echo "ADMIN_PASSWORD=$NEW_PASS"
  } > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  echo ""
  echo "  ADMIN LOGIN RESET:"
  echo "    URL:      https://$PANEL_FQDN"
  echo "    Username: $NEW_USER"
  echo "    Password: $NEW_PASS"
  echo "  (2FA cleared; credentials also saved in $SECRETS_FILE)"
  exit 0
fi

echo "Reset failed - check the panel logs." >&2
exit 1