#!/bin/bash

set -euo pipefail

# === ✅ Automatically cleanup temp file on exit ===
trap 'rm -f __temp.sql' EXIT

echo "🚀 Starting deploy..."
echo "🔑 DB Host: $DB_HOST"
echo "🗄️  DB Name: $DB_NAME"
echo "👤 DB User: $DB_USER"

# === ✅ Check if any files were passed ===
if [ $# -eq 0 ]; then
  echo "❌ No SQL files passed. Nothing to deploy."
  exit 0
fi

echo "📂 Files to deploy: $@"

# === ✅ Loop over each file passed as argument ===
for SQL_FILE in "$@"; do
  echo -e "\n---------------------------------------"
  echo "➡️  Processing File: $SQL_FILE"

  # === ✅ Extract type and name ===
  META=$(grep -iE 'CREATE[[:space:]]+(DEFINER[[:space:]]*=[^ ]+[[:space:]]*)?(PROCEDURE|FUNCTION)[[:space:]]+`?[^` (]+`?' "$SQL_FILE" | head -n1 || true)

  if [[ -z "$META" ]]; then
    echo "⚠️  No PROCEDURE or FUNCTION found — skipping."
    continue
  fi

  TYPE=$(echo "$META" | grep -iEo 'PROCEDURE|FUNCTION' | tr '[:lower:]' '[:upper:]')
  NAME=$(echo "$META" | sed -E 's/.*(PROCEDURE|FUNCTION)[[:space:]]+`?([^` (]+)`?.*/\2/I')

  if [[ -z "$TYPE" || -z "$NAME" ]]; then
    echo "❌ Failed to extract TYPE or NAME from $SQL_FILE — skipping."
    continue
  fi

  TEMP_NAME="${NAME}_temp"
  TEMP_SQL_FILE="__temp.sql"

  echo "➡️  SP/FN Name: $NAME"
  echo "📚 Detected TYPE: $TYPE"
  echo "📤 Creating TEMP routine for validation: ${TEMP_NAME}"

  # === ✅ Replace all occurrences of the original name with the temp name ===
  sed -E "s/\`?${NAME}\`?/\`${TEMP_NAME}\`/gI" "$SQL_FILE" > "$TEMP_SQL_FILE"

  # === ✅ Validate the temp version ===
  VALIDATE_OUTPUT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>&1 < "$TEMP_SQL_FILE") || {
    echo "❌ Temp validation failed for: $NAME"
    echo "📄 Error output:"
    echo "$VALIDATE_OUTPUT"
    echo "📝 Debug: Contents of temp SQL:"
    cat "$TEMP_SQL_FILE"
    continue
  }

  echo "✅ Temp routine validated successfully"

  # === ✅ Drop the temp routine after validation ===
  echo "🧹 Dropping temp routine: ${TEMP_NAME}"
  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "DROP $TYPE IF EXISTS \`${TEMP_NAME}\`;"

  # === ✅ Deploy the original routine ===
  echo "🚀 Deploying original routine: $NAME"
  DEPLOY_OUTPUT=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" 2>&1 < "$SQL_FILE") || {
    echo "❌ Deployment failed for: $NAME"
    echo "📄 Error output:"
    echo "$DEPLOY_OUTPUT"
    echo "📝 Debug: Contents of original SQL file:"
    cat "$SQL_FILE"
    continue
  }

  echo "✅ Successfully deployed: $NAME"
done

echo -e "\n🎉 All stored procedures/functions processed with validation!"
