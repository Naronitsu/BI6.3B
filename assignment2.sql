-- Part 1

DROP VIEW IF EXISTS dw.vw_product_revenue_rank;
DROP VIEW IF EXISTS dw.vw_monthly_revenue;
DROP TABLE IF EXISTS dw.fact_orders;
DROP TABLE IF EXISTS dw.dim_product;
DROP TABLE IF EXISTS dw.dim_facility;
DROP TABLE IF EXISTS dw.dim_date;

CREATE SCHEMA IF NOT EXISTS dw;

CREATE TABLE dw.dim_date (
    date_key        INTEGER PRIMARY KEY,
    full_date       DATE NOT NULL UNIQUE,
    year            INTEGER NOT NULL,
    quarter         INTEGER NOT NULL,
    month           INTEGER NOT NULL,
    month_name      VARCHAR(20) NOT NULL,
    day_of_month    INTEGER NOT NULL,
    day_of_week     INTEGER NOT NULL,
    is_weekend      BOOLEAN NOT NULL,
    last_updated    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE dw.dim_facility (
    facility_key        INTEGER PRIMARY KEY,
    facility_id_source  INTEGER NOT NULL UNIQUE,
    facility_name       VARCHAR(200) NOT NULL,
    facility_type       VARCHAR(50) NOT NULL,
    country_name        VARCHAR(100),
    region_name         VARCHAR(50),
    last_updated        TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE dw.dim_product (
    product_key         INTEGER PRIMARY KEY,
    product_id_source   INTEGER NOT NULL,
    product_name        VARCHAR(100) NOT NULL,
    category_name       VARCHAR(100),
    unit_price          NUMERIC(10,2) NOT NULL,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    row_start_date      DATE NOT NULL DEFAULT DATE '2000-01-01',
    row_end_date        DATE,
    is_current          BOOLEAN NOT NULL DEFAULT TRUE,
    last_updated        TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE dw.fact_orders (
    order_line_key      INTEGER PRIMARY KEY,
    date_key            INTEGER NOT NULL REFERENCES dw.dim_date (date_key),
    facility_key        INTEGER NOT NULL REFERENCES dw.dim_facility (facility_key),
    product_key         INTEGER NOT NULL REFERENCES dw.dim_product (product_key),
    order_id            INTEGER NOT NULL,
    quantity            INTEGER NOT NULL,
    unit_price_sold     NUMERIC(10,2) NOT NULL,
    line_total          NUMERIC(12,2) NOT NULL,
    last_updated        TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_fact_orders_date_key ON dw.fact_orders (date_key);

INSERT INTO dw.dim_facility (
    facility_key, facility_id_source, facility_name, facility_type,
    country_name, region_name, last_updated
)
VALUES (
    -1, -1, 'Unknown Facility', 'Unknown',
    NULL, NULL, TIMESTAMP '2000-01-01 00:00:00'
);

INSERT INTO dw.dim_product (
    product_key, product_id_source, product_name, category_name, unit_price,
    is_active, row_start_date, row_end_date, is_current, last_updated
)
VALUES (
    -1, -1, 'Unknown Product', NULL, 0,
    TRUE, DATE '2000-01-01', NULL, TRUE, TIMESTAMP '2000-01-01 00:00:00'
);

-- Part 2

CREATE OR REPLACE VIEW dw.vw_monthly_revenue AS
WITH monthly AS (
    SELECT
        d.year,
        d.month,
        d.month_name,
        SUM(fo.line_total) AS revenue,
        COUNT(DISTINCT fo.order_id) AS order_count,
        SUM(fo.quantity) AS units_sold
    FROM dw.fact_orders fo
    INNER JOIN dw.dim_date d ON fo.date_key = d.date_key
    GROUP BY d.year, d.month, d.month_name
)
SELECT
    m.year,
    m.month,
    m.month_name,
    m.revenue,
    m.order_count,
    m.units_sold,
    LAG(m.revenue) OVER (ORDER BY m.year, m.month) AS previous_month_revenue,
    CASE
        WHEN LAG(m.revenue) OVER (ORDER BY m.year, m.month) IS NULL THEN NULL
        WHEN LAG(m.revenue) OVER (ORDER BY m.year, m.month) = 0 THEN NULL
        ELSE ROUND(
            100.0 * (m.revenue - LAG(m.revenue) OVER (ORDER BY m.year, m.month))
            / LAG(m.revenue) OVER (ORDER BY m.year, m.month),
            2
        )
    END AS month_on_month_growth_pct
FROM monthly m;

CREATE OR REPLACE VIEW dw.vw_product_revenue_rank AS
WITH agg AS (
    SELECT
        cp.product_name,
        cp.category_name,
        SUM(fo.line_total) AS total_revenue,
        SUM(fo.quantity) AS total_units,
        COUNT(DISTINCT fo.order_id) AS order_count
    FROM dw.fact_orders fo
    INNER JOIN dw.dim_product fk ON fo.product_key = fk.product_key
    INNER JOIN dw.dim_product cp
        ON fk.product_id_source = cp.product_id_source
        AND cp.is_current IS TRUE
    GROUP BY fk.product_id_source, cp.product_name, cp.category_name
)
SELECT
    a.product_name,
    a.category_name,
    a.total_revenue,
    a.total_units,
    a.order_count,
    RANK() OVER (ORDER BY a.total_revenue DESC) AS revenue_rank
FROM agg a;
