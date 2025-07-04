#!/bin/bash

set -euo pipefail

echo "🔍 Searching for *.sql files..."

SQL_FILES=$(find . -type f -name "*.sql")

if [[ -z "$SQL_FILES" ]]; then
  echo "❌ No .sql files found!"
  exit 0
fi

for SQL_FILE in $SQL_FILES; do
  echo "---------------------------------------"
  echo ➡️ File: $SQL_FILE"

  SP_LINE=$(grep -iE 'CREATE[[:space:]]+(DEFINER[[:space:]]*=[^ ]+[[:space:]]*)?(PROCEDURE|FUNCTION)[[:space:]]+`?[^`( ]+`?' "$SQL_FILE" | head -n 1 || true)

  if [[ -z "$SP_LINE" ]]; then
    echo "⚠️  No PROCEDURE or FUNCTION found — skipping."
    continue
  fi

  TYPE=$(echo "$SP_LINE" | grep -ioE 'PROCEDURE|FUNCTION')
  NAME=$(echo "$SP_LINE" | sed -E "s/.*${TYPE}[[:space:]]+\`?([^\\`( ]+)\`?.*/\\1/I")

  echo "📚 Detected TYPE: $TYPE"
  echo "📛 Name: $NAME"

  # 1️⃣ Check if exists
  EXISTS=$(mysql -N -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
    SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES 
    WHERE ROUTINE_SCHEMA = '$DB_NAME' 
    AND ROUTINE_TYPE = UPPER('$TYPE') 
    AND ROUTINE_NAME = '$NAME';
  ")

  if [[ "$EXISTS" -eq 1 ]]; then
    echo "✅ $TYPE $NAME exists — comparing definitions..."

    mysql -N -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
      -e "SHOW CREATE $TYPE \`$NAME\`\\G" > "__db_create.sql"

    grep -i -A 1000 'CREATE' "$SQL_FILE" | sed '/^DELIMITER/Id' > "__file_create.sql"

    sed -i -E 's/DEFINER=`[^`]+`@`[^`]+`//g; s/[[:space:]]+/ /g' __db_create.sql
    sed -i -E 's/DEFINER=`[^`]+`@`[^`]+`//g; s/[[:space:]]+/ /g' __file_create.sql

    if diff -q __db_create.sql __file_create.sql >/dev/null; then
      echo "✅ No changes detected — skipping deploy for $NAME"
      rm -f __db_create.sql __file_create.sql
      continue
    else
      echo "🔄 Changes detected — dropping $TYPE $NAME"
      mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -e "DROP $TYPE IF EXISTS \`$NAME\`;"
      rm -f __db_create.sql __file_create.sql
    fi
  else
    echo "🆕 $TYPE $NAME does not exist — will create new."
  fi

  # 2️⃣ Validate with TEMP
  TEMP_NAME="${NAME}_temp"
  TEMP_SQL="__temp.sql"

  sed -E "s/(${TYPE}[[:space:]]+\`?$NAME\`?)/${TYPE} \`${TEMP_NAME}\`/I" "$SQL_FILE" > "$TEMP_SQL"

  echo "📤 Testing temp: $TEMP_NAME"
  if ! mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$TEMP_SQL"; then
    echo "❌ Temp $TYPE failed for $SQL_FILE"
    rm -f "$TEMP_SQL"
    continue
  fi

  echo "✅ Temp $TYPE OK — dropping temp"
  mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
    -e "DROP $TYPE IF EXISTS \`$TEMP_NAME\`;"

  rm -f "$TEMP_SQL"

  echo "🚀 Deploying original: $NAME"
  if mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_FILE"; then
    echo "✅ Deployed: $NAME"
  else
    echo "❌ Deploy failed: $NAME"
  fi

done

echo "🎉 All done!"
