/*
PART 1 (Setup)
    - Remove DB if exists
    - Create DB MedSupply_DW
    - Create schemas staging, and dw
*/


USE master;
GO

IF DB_ID('MedSupply_DW') IS NOT NULL
BEGIN
    DROP DATABASE MedSupply_DW;
END
GO

CREATE DATABASE MedSupply_DW;
GO

USE MedSupply_DW;
GO

CREATE SCHEMA staging;
GO

CREATE SCHEMA dw;
GO



/* 
PART 2 (Staging)
    - Create staging tables for product, facility, and order
*/

CREATE TABLE staging.raw_product (
      product_id INTEGER,
      product_name VARCHAR(100),
      category_name VARCHAR(100),
      unit_price NUMERIC(10,2),
      is_active BIT,
      source_load_date DATETIME2 DEFAULT GETDATE()
);

CREATE TABLE staging.raw_facility (
    facility_id INTEGER,
    facility_name VARCHAR(200),
    facility_type VARCHAR(50),
    country_name VARCHAR(100),
    region_name VARCHAR(50),
    source_load_date DATETIME2 DEFAULT GETDATE()
);

CREATE TABLE staging.raw_order (
    order_line_id INTEGER,
    order_id INTEGER,
    order_date DATE,
    facility_id INTEGER,
    product_id INTEGER,
    quantity INTEGER,
    unit_price_sold NUMERIC(10,2),
    line_total NUMERIC(12,2),
    source_load_data DATETIME2 DEFAULT GETDATE()
);
GO

/*
PART 3 (Dimension Tables)
    - Create dimension dim_date
    - Create dimension dim_facility (SCD Type 1)
    - Create dimension dim_product (SCD Type 2)
*/

CREATE TABLE dw.dim_date (
    date_key INTEGER PRIMARY KEY IDENTITY(1,1),
    full_date DATE NOT NULL UNIQUE,
    year INTEGER NOT NULL,
    quarter INTEGER NOT NULL,
    month INTEGER NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    day_of_month INTEGER NOT NULL,
    day_of_week INTEGER NOT NULL,
    is_weekend BIT NOT NULL,
    last_updated DATETIME2 DEFAULT SYSDATETIME()
);

-- SCD Type 1 - Overwrite
CREATE TABLE dw.dim_facility (
    facility_key INTEGER PRIMARY KEY IDENTITY(1,1),
    facility_id_source INTEGER NOT NULL UNIQUE,
    facility_name VARCHAR(200) NOT NULL,
    facility_type VARCHAR(50) NOT NULL,
    country_name VARCHAR(100),
    region_name VARCHAR(50),
    last_updated DATETIME2 DEFAULT SYSDATETIME()
);


-- SCD Type 2 - History Tracking on Price
CREATE TABLE dw.dim_product (
    product_key INTEGER PRIMARY KEY IDENTITY(1,1),
    product_id_source INTEGER NOT NULL,
    product_name VARCHAR(100) NOT NULL,
    category_name VARCHAR(100),
    unit_price NUMERIC(10,2) NOT NULL,
    is_active BIT DEFAULT 1,
    row_start_date DATE NOT NULL DEFAULT '2000-01-01',
    row_end_date DATE NULL DEFAULT NULL,
    is_current BIT NOT NULL DEFAULT 1,
    last_updated DATETIME2 DEFAULT SYSDATETIME()
);
GO

/*
PART 4 (Fact Table)
    - Create fact table fact_orders
    - Make sure to add an appropriate index
*/


CREATE TABLE dw.fact_orders (
    order_line_key INTEGER IDENTITY(1,1),
    date_key INTEGER NOT NULL REFERENCES dw.dim_date(date_key),
    facility_key INTEGER NOT NULL REFERENCES dw.dim_facility(facility_key),
    product_key INTEGER NOT NULL REFERENCES dw.dim_product(product_key),
    order_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    unit_price_sold NUMERIC(10,2) NOT NULL,
    line_total NUMERIC(12,2) NOT NULL,
    last_updated DATETIME2 DEFAULT SYSDATETIME()
);
GO

CREATE CLUSTERED COLUMNSTORE INDEX CCI_fact_orders
ON dw.fact_orders;

GO


/*
PART 5 (Unknown Members)
    - Take care of unknown facilities
    - Take care of unknown products
*/

SET IDENTITY_INSERT dw.dim_facility ON;
INSERT INTO dw.dim_facility
    (facility_key, facility_id_source, facility_name, facility_type)
VALUES
    (-1, -1, 'Unknown Facility', 'Unknown');
SET IDENTITY_INSERT dw.dim_facility OFF;

SET IDENTITY_INSERT dw.dim_product ON;
INSERT INTO dw.dim_product
    (product_key, product_id_source, product_name, unit_price, row_start_date, is_current)
VALUES
    (-1, -1, 'Unknown Product', 0, '2000-01-01', 1);
GO
SET IDENTITY_INSERT dw.dim_product OFF;

GO

/*
PART 6 (Dimension Loading)
    - Create procedure to populate facility (SCD Type 1)
    - Create procedure to populate product (SCD Type 2)
    - Create procedure to populate date
*/

CREATE OR ALTER PROCEDURE dw.usp_populate_dim_facility
AS BEGIN
UPDATE target
SET
    facility_name = source.facility_name,
    facility_type = source.facility_type,
    country_name  = source.country_name,
    region_name   = source.region_name
FROM dw.dim_facility target
JOIN staging.raw_facility source
    ON target.facility_id_source = source.facility_id;

INSERT INTO dw.dim_facility (
    facility_id_source,
    facility_name,
    facility_type,
    country_name,
    region_name
)
SELECT
    source.facility_id,
    source.facility_name,
    source.facility_type,
    source.country_name,
    source.region_name
FROM staging.raw_facility source
LEFT JOIN dw.dim_facility target
    ON target.facility_id_source = source.facility_id
WHERE target.facility_id_source IS NULL;

END;
GO

CREATE OR ALTER PROCEDURE dw.usp_populate_dim_product
AS BEGIN
    SET NOCOUNT ON;
 

    -- Step 1 - If price changes expire current records
    UPDATE dp
    SET 
        is_current = 0, 
        row_end_date = CAST(GETDATE() AS DATE)
    FROM dw.dim_product dp 
    JOIN staging.raw_product rp
    ON dp.product_id_source = rp.product_id
    WHERE dp.is_current = 1
    AND dp.unit_price <> rp.unit_price;

    -- Step 2 - Insert new versions (changed products)
    INSERT INTO dw.dim_product 
        (product_id_source, product_name, category_name, unit_price, is_active,
         row_start_date, is_current)
    SELECT rp.product_id, rp.product_name, rp.category_name, rp.unit_price,
        rp.is_active, CAST(GETDATE() AS DATE), 1
    FROM staging.raw_product rp
    WHERE NOT EXISTS (
        SELECT 1 FROM dw.dim_product dp WHERE dp.product_id_source = rp.product_id
        AND dp.is_current = 1
    )
    AND EXISTS (
        SELECT 1 FROM dw.dim_product dp WHERE dp.product_id_source = rp.product_id
    )

    -- Step 3 : Insert brand new products
     INSERT INTO dw.dim_product 
        (product_id_source, product_name, category_name, unit_price, is_active,
         row_start_date, is_current)
    SELECT
        rp.product_id, rp.product_name, rp.category_name, rp.unit_price,
        rp.is_active, '2000-01-01', 1
    FROM staging.raw_product rp
    WHERE NOT EXISTS (
        SELECT 1
        FROM dw.dim_product d
        WHERE d.product_id_source = rp.product_id
    );

END
GO

CREATE OR ALTER PROCEDURE dw.usp_populate_dim_date
    (@start_year int, @end_year int)
AS BEGIN
    SET NOCOUNT ON;

    DECLARE @start_date DATE = DATEFROMPARTS(@start_year, 1, 1)
    DECLARE @end_date DATE = DATEFROMPARTS(@end_year, 12, 31)

    INSERT INTO dw.dim_date
        (full_date, year, quarter, month, month_name,
         day_of_month, day_of_week, is_weekend)
    SELECT
        DATEADD(DAY, value, @start_date) AS full_date,
        YEAR(DATEADD(DAY, value, @start_date)) AS year,
        DATEPART(QUARTER, DATEADD(DAY, value, @start_date)) AS quarter,
        MONTH(DATEADD(DAY, value, @start_date)) AS month,
        DATENAME(MONTH, DATEADD(DAY, value, @start_date)) AS month_name,
        DAY(DATEADD(DAY, value, @start_date)) AS day_of_month,
        DATEPART(WEEKDAY, DATEADD(DAY, value, @start_date)) AS day_of_week,
        CASE 
            WHEN DATEPART(WEEKDAY, DATEADD(DAY, value, @start_date)) IN (6,7)
            THEN 1 ELSE 0
        END AS is_weekend
    FROM GENERATE_SERIES(0, DATEDIFF(DAY, @start_date, @end_date));


END
GO

/*
PART 7 - (Fact Loading)
    - Create procedure to populate fact orders
*/

CREATE OR ALTER PROCEDURE dw.usp_populate_fact_orders
AS BEGIN
    INSERT INTO dw.fact_orders (
        date_key, facility_key, product_key,
        order_id, quantity, unit_price_sold, line_total
    )
    SELECT
        d.date_key,
        COALESCE(f.facility_key, -1),
        COALESCE(p.product_key, -1),
        ro.order_id,
        ro.quantity,
        ro.unit_price_sold,
        ro.line_total
    FROM staging.raw_order ro
    LEFT JOIN dw.dim_facility f ON ro.facility_id = f.facility_id_source
    LEFT JOIN dw.dim_product p
        ON ro.product_id = p.product_id_source
        AND ro.order_date >= p.row_start_date
        AND (ro.order_date < p.row_end_date OR p.row_end_date IS NULL)
    LEFT JOIN dw.dim_date d ON
        ro.order_date = d.full_date;

END;
GO

/*
PART 8 - (Pipeline)
   - Statements to delete data from staging schema, and dw schema
   - Statements to load data into staging tables
   - Statements to populate dimensions
   - Statement to update product prices
   - Statement to populate fact table
*/


DELETE staging.raw_facility;
DELETE staging.raw_order;
DELETE staging.raw_product;

DELETE dw.fact_orders;
DELETE dw.dim_date;
DELETE dw.dim_facility;
DELETE dw.dim_product;
GO

INSERT INTO staging.raw_facility
    (facility_id, facility_name, facility_type, country_name, region_name)
SELECT f.FacilityID, f.FacilityName, f.FacilityType, c.CountryName, r.RegionName
FROM MedSupply_Source.Ref.Facility f
JOIN MedSupply_Source.Ref.Country c ON f.CountryID = c.CountryID
JOIN MedSupply_Source.Ref.Region r ON c.RegionID = r.RegionID;
GO

INSERT INTO staging.raw_product
    (product_id, product_name, category_name, unit_price, is_active)
SELECT p.ProductID, p.ProductName, c.CategoryName, p.UnitPrice, p.IsActive
FROM MedSupply_Source.Ref.Product p
JOIN MedSupply_Source.Ref.ProductCategory c ON p.CategoryID = c.CategoryID;
GO

INSERT INTO staging.raw_order
    (order_line_id, order_id, order_date, facility_id, product_id, quantity,
     unit_price_sold, line_total)
SELECT ol.OrderLineID, po.OrderID, po.OrderDate, po.FacilityID, ol.ProductID,
ol.Quantity, ol.UnitPriceSold, ol.LineTotal
FROM MedSupply_Source.Sales.OrderLine ol
JOIN MedSupply_Source.Sales.PurchaseOrder po ON ol.OrderID = po.OrderID;
GO

EXEC dw.usp_populate_dim_date @start_year=2025, @end_year=2027;
GO
EXEC dw.usp_populate_dim_facility;
GO
EXEC dw.usp_populate_dim_product;
GO

UPDATE staging.raw_facility
SET facility_name = 'UK Central Hospital'
WHERE facility_id = 1;
GO

UPDATE staging.raw_product 
SET unit_price = unit_price * 1.2 
WHERE product_id IN (1,2);
GO

EXEC dw.usp_populate_dim_product;
GO

EXEC dw.usp_populate_dim_facility;
GO

EXEC dw.usp_populate_fact_orders;
GO

SELECT *  FROM dw.fact_orders;