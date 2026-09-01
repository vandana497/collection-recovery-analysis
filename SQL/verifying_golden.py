import os

import duckdb
import pandas as pd


# Set a wider display so query results are easier to read
pd.set_option("display.width", 200)


# Connect to the DuckDB database
connection = duckdb.connect("raw.duckdb")


# --------------------------------------------------
# Run the staging and golden SQL transformations
# --------------------------------------------------

with open("sql/01_staging.sql", "r", encoding="utf-8") as sql_file:
    staging_sql = sql_file.read()

connection.execute(staging_sql)


with open("sql/02_golden.sql", "r", encoding="utf-8") as sql_file:
    golden_sql = sql_file.read()

connection.execute(golden_sql)


# --------------------------------------------------
# Review contact performance by communication channel
# --------------------------------------------------

channel_metrics = connection.execute(
    """
    SELECT
        channel,
        COUNT(*) AS total_touches,
        COUNT(DISTINCT account_id) AS unique_accounts,
        SUM(is_contact::INT) AS successful_contacts,

        ROUND(
            100.0 * SUM(is_contact::INT) / COUNT(*),
            2
        ) AS contact_rate_pct

    FROM golden_interactions

    GROUP BY channel
    ORDER BY channel;
    """
).fetchdf()


print("\n=== Contact performance by channel ===")
print(channel_metrics.to_string(index=False))


# --------------------------------------------------
# Review the monthly golden metrics
# --------------------------------------------------

monthly_metrics = connection.execute(
    """
    SELECT *
    FROM golden_monthly_metrics
    ORDER BY month;
    """
).fetchdf()


print("\n=== Golden monthly metrics ===")
print(monthly_metrics.to_string(index=False))


# --------------------------------------------------
# Export important golden datasets as CSV files
# --------------------------------------------------

# Create the golden output folder if it doesn't already exist
os.makedirs("golden", exist_ok=True)


datasets_to_export = [
    "stg_accounts",
    "stg_borrowers",
    "stg_agents",
    "golden_interactions",
    "golden_ptp",
    "stg_payments",
    "golden_monthly_metrics",
]


# Export each dataset as a CSV file
for table_name in datasets_to_export:
    output_file = f"golden/{table_name}.csv"

    connection.execute(
        f"""
        COPY {table_name}
        TO '{output_file}'
        (HEADER, DELIMITER ',');
        """
    )

    print(f"Exported: {output_file}")


# Close the database connection
connection.close()


print("\nAll golden datasets have been exported successfully.")