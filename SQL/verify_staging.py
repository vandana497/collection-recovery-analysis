import duckdb


# Connect to the DuckDB database
connection = duckdb.connect("raw.duckdb")


# Read the staging SQL file
with open("sql/01_staging.sql", "r", encoding="utf-8") as sql_file:
    staging_sql = sql_file.read()


# Run all staging queries
connection.execute(staging_sql)


# List of staging tables created by the SQL script
staging_tables = [
    "stg_accounts",
    "stg_borrowers",
    "stg_agents",
    "stg_calls",
    "stg_call_attempts",
    "stg_call_dispositions",
    "stg_payments",
    "stg_promises_to_pay",
    "stg_field_visits",
    "stg_whatsapp_events",
    "stg_sms_events",
    "stg_complaints",
    "stg_account_status_history",
    "stg_daily_targeting",
    "stg_campaigns",
    "stg_agent_sessions",
]


# Check how many records were created in each staging table
for table_name in staging_tables:
    row_count = connection.execute(
        f"SELECT COUNT(*) FROM {table_name}"
    ).fetchone()[0]

    print(f"{table_name}: {row_count} rows")


# Close the database connection
connection.close()