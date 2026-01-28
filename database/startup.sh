#!/bin/bash

# Minimal PostgreSQL startup script with full paths
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5001"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
    
    # Check if connection info file exists
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi
    
    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    
    # Try to connect and verify the database exists
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 5

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- If you want the user to be able to create objects without restrictions,
-- you can make them the owner of the public schema (optional but effective)
-- ALTER SCHEMA public OWNER TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

# ----------------------------
# Schema + seed initialization
# ----------------------------
# We prefer DATABASE_URL if provided; otherwise we fall back to db_connection.txt.
# This makes it easy for other containers (backend) and local tooling to share the same connection string.
DATABASE_URL_DEFAULT="postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
DATABASE_URL="${DATABASE_URL:-$DATABASE_URL_DEFAULT}"

# psql invocation (non-interactive, stops on error)
PSQL="psql ${DATABASE_URL} -v ON_ERROR_STOP=1"

echo ""
echo "Initializing schema (idempotent) on ${DATABASE_URL} ..."

# Tables
${PSQL} -c "CREATE TABLE IF NOT EXISTS phone_brands (id BIGSERIAL PRIMARY KEY, name TEXT NOT NULL UNIQUE);"
${PSQL} -c "CREATE TABLE IF NOT EXISTS issues (id BIGSERIAL PRIMARY KEY, brand_id BIGINT REFERENCES phone_brands(id) ON DELETE CASCADE, name TEXT NOT NULL, CONSTRAINT issues_brand_name_unique UNIQUE (brand_id, name));"
${PSQL} -c "CREATE TABLE IF NOT EXISTS repair_offerings (id BIGSERIAL PRIMARY KEY, brand_id BIGINT NOT NULL REFERENCES phone_brands(id) ON DELETE CASCADE, issue_id BIGINT NOT NULL REFERENCES issues(id) ON DELETE CASCADE, price NUMERIC(10,2) NOT NULL CHECK (price >= 0), eta_days INTEGER NOT NULL CHECK (eta_days >= 0), CONSTRAINT repair_offerings_brand_issue_unique UNIQUE (brand_id, issue_id));"
${PSQL} -c "CREATE TABLE IF NOT EXISTS bookings (id BIGSERIAL PRIMARY KEY, customer_name TEXT NOT NULL, phone TEXT NOT NULL, brand_id BIGINT NOT NULL REFERENCES phone_brands(id) ON DELETE RESTRICT, issue_id BIGINT NOT NULL REFERENCES issues(id) ON DELETE RESTRICT, status TEXT NOT NULL DEFAULT 'pending', created_at TIMESTAMPTZ NOT NULL DEFAULT now(), updated_at TIMESTAMPTZ NOT NULL DEFAULT now(), notes TEXT);"
${PSQL} -c "CREATE TABLE IF NOT EXISTS admin_users (id BIGSERIAL PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT 'admin', created_at TIMESTAMPTZ NOT NULL DEFAULT now());"

# Indexes (safe/idempotent)
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_issues_brand_id ON issues(brand_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_repair_offerings_brand_id ON repair_offerings(brand_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_repair_offerings_issue_id ON repair_offerings(issue_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_bookings_brand_id ON bookings(brand_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_bookings_issue_id ON bookings(issue_id);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_bookings_status ON bookings(status);"
${PSQL} -c "CREATE INDEX IF NOT EXISTS idx_bookings_created_at ON bookings(created_at);"

echo "Seeding demo data (idempotent) ..."

# Brands
${PSQL} -c "INSERT INTO phone_brands(name) VALUES ('Apple') ON CONFLICT (name) DO NOTHING;"
${PSQL} -c "INSERT INTO phone_brands(name) VALUES ('Samsung') ON CONFLICT (name) DO NOTHING;"
${PSQL} -c "INSERT INTO phone_brands(name) VALUES ('Google') ON CONFLICT (name) DO NOTHING;"

# Issues (per brand)
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Screen' FROM phone_brands WHERE name='Apple' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Battery' FROM phone_brands WHERE name='Apple' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Camera' FROM phone_brands WHERE name='Apple' ON CONFLICT DO NOTHING;"

${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Screen' FROM phone_brands WHERE name='Samsung' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Battery' FROM phone_brands WHERE name='Samsung' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Camera' FROM phone_brands WHERE name='Samsung' ON CONFLICT DO NOTHING;"

${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Screen' FROM phone_brands WHERE name='Google' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Battery' FROM phone_brands WHERE name='Google' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO issues(brand_id, name) SELECT id, 'Camera' FROM phone_brands WHERE name='Google' ON CONFLICT DO NOTHING;"

# Repair offerings (sample prices/ETA)
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 199.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Apple' AND i.name='Screen' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 129.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Apple' AND i.name='Battery' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 149.00, 3 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Apple' AND i.name='Camera' ON CONFLICT DO NOTHING;"

${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 179.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Samsung' AND i.name='Screen' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 109.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Samsung' AND i.name='Battery' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 139.00, 3 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Samsung' AND i.name='Camera' ON CONFLICT DO NOTHING;"

${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 189.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Google' AND i.name='Screen' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 119.00, 2 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Google' AND i.name='Battery' ON CONFLICT DO NOTHING;"
${PSQL} -c "INSERT INTO repair_offerings(brand_id, issue_id, price, eta_days) SELECT b.id, i.id, 129.00, 3 FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Google' AND i.name='Camera' ON CONFLICT DO NOTHING;"

# Demo bookings (a few rows, idempotent-ish: avoid duplicates by matching tuple)
${PSQL} -c "INSERT INTO bookings(customer_name, phone, brand_id, issue_id, status, notes) SELECT 'Jordan Lee', '+1-555-0101', b.id, i.id, 'pending', 'Cracked screen after drop' FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Apple' AND i.name='Screen' AND NOT EXISTS (SELECT 1 FROM bookings bk WHERE bk.customer_name='Jordan Lee' AND bk.phone='+1-555-0101' AND bk.brand_id=b.id AND bk.issue_id=i.id);"
${PSQL} -c "INSERT INTO bookings(customer_name, phone, brand_id, issue_id, status, notes) SELECT 'Avery Kim', '+1-555-0102', b.id, i.id, 'in_progress', 'Battery drains quickly' FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Samsung' AND i.name='Battery' AND NOT EXISTS (SELECT 1 FROM bookings bk WHERE bk.customer_name='Avery Kim' AND bk.phone='+1-555-0102' AND bk.brand_id=b.id AND bk.issue_id=i.id);"
${PSQL} -c "INSERT INTO bookings(customer_name, phone, brand_id, issue_id, status, notes) SELECT 'Sam Patel', '+1-555-0103', b.id, i.id, 'completed', 'Rear camera not focusing' FROM phone_brands b JOIN issues i ON i.brand_id=b.id WHERE b.name='Google' AND i.name='Camera' AND NOT EXISTS (SELECT 1 FROM bookings bk WHERE bk.customer_name='Sam Patel' AND bk.phone='+1-555-0103' AND bk.brand_id=b.id AND bk.issue_id=i.id);"

echo "Schema + seed complete."
echo ""

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"
