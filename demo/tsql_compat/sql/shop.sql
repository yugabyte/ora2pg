-- Sample "shop" application for the ora2pg + tsql_compat demo.
-- Uses the SQL Server types and functions emulated by tsql_compat.
USE master;
GO
IF DB_ID('shop') IS NOT NULL
BEGIN
    ALTER DATABASE shop SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE shop;
END;
GO
CREATE DATABASE shop;
GO
USE shop;
GO

CREATE TABLE dbo.customers (
    customer_id   INT IDENTITY(1,1) PRIMARY KEY,
    customer_uid  UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    full_name     NVARCHAR(100) NOT NULL,
    email         NVARCHAR(200) NULL,
    country       NCHAR(2) NULL,
    is_active     BIT NOT NULL DEFAULT 1,
    rating        TINYINT NULL,
    credit_limit  MONEY NULL,
    discount      SMALLMONEY NULL,
    created_at    DATETIME NOT NULL DEFAULT GETDATE(),
    last_login    SMALLDATETIME NULL,
    updated_at    DATETIME2(3) NULL,
    signup_tz     DATETIMEOFFSET NULL,
    notes         NTEXT NULL,
    avatar        VARBINARY(MAX) NULL,
    badge         BINARY(4) NULL,
    legacy_photo  IMAGE NULL,
    created_by    SYSNAME NOT NULL DEFAULT SUSER_SNAME()
);
GO

CREATE TABLE dbo.orders (
    order_id     INT IDENTITY(1,1) PRIMARY KEY,
    customer_id  INT NOT NULL REFERENCES dbo.customers(customer_id),
    order_ref    UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
    order_date   DATETIME NOT NULL DEFAULT GETDATE(),
    ship_date    DATETIME NULL,
    total        MONEY NOT NULL DEFAULT 0,
    is_paid      BIT NOT NULL DEFAULT 0,
    status       NVARCHAR(20) NOT NULL DEFAULT N'NEW'
);
GO

CREATE TABLE dbo.order_items (
    order_id    INT NOT NULL REFERENCES dbo.orders(order_id),
    line_no     TINYINT NOT NULL,
    product     NVARCHAR(100) NOT NULL,
    qty         SMALLINT NOT NULL,
    unit_price  MONEY NOT NULL,
    PRIMARY KEY (order_id, line_no)
);
GO

CREATE VIEW dbo.v_customer_summary AS
SELECT c.customer_id,
       ISNULL(c.email, N'n/a') AS email,
       LEN(c.full_name) AS name_len,
       DATEPART(year, c.created_at) AS signup_year,
       DATENAME(month, c.created_at) AS signup_month,
       COUNT(o.order_id) AS nb_orders,
       ISNULL(SUM(o.total), 0) AS total_spent
FROM dbo.customers c
LEFT JOIN dbo.orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.email, c.full_name, c.created_at;
GO

CREATE FUNCTION dbo.fn_order_age(@order_date DATETIME)
RETURNS INT
AS
BEGIN
    RETURN DATEDIFF(day, @order_date, GETDATE());
END;
GO

CREATE PROCEDURE dbo.usp_place_order
    @customer_id INT,
    @product NVARCHAR(100),
    @qty SMALLINT,
    @price MONEY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @order_id INT;
    DECLARE @ship DATETIME;
    DECLARE @label NVARCHAR(200);
    DECLARE @ref UNIQUEIDENTIFIER;

    SET @ship = DATEADD(day, 3, GETDATE());
    SET @ref = NEWID();
    SET @label = UPPER(LEFT(@product, 3)) + REPLICATE(N'-', 2) + CAST(YEAR(GETDATE()) AS NVARCHAR(4));

    INSERT INTO dbo.orders (customer_id, order_ref, ship_date, total, status)
    VALUES (@customer_id, @ref, @ship, @qty * @price, IIF(@qty > 10, N'BULK', N'NEW'));

    SET @order_id = SCOPE_IDENTITY();

    INSERT INTO dbo.order_items (order_id, line_no, product, qty, unit_price)
    VALUES (@order_id, 1, @label + N' ' + @product, @qty, @price);
END;
GO

CREATE PROCEDURE dbo.usp_customer_stats
    @customer_id INT
AS
BEGIN
    DECLARE @first DATETIME;
    DECLARE @days INT;
    DECLARE @pos INT;
    DECLARE @name NVARCHAR(100);

    SELECT @name = full_name, @first = created_at FROM dbo.customers WHERE customer_id = @customer_id;
    SET @days = DATEDIFF(day, @first, SYSDATETIME());
    SET @pos = CHARINDEX(N' ', @name);
    SELECT @name AS name, @days AS days_since_signup, @pos AS space_pos,
           DATALENGTH(@name) AS name_bytes, EOMONTH(@first) AS month_end;
END;
GO

CREATE TRIGGER dbo.trg_customers_touch ON dbo.customers
AFTER UPDATE
AS
BEGIN
    UPDATE dbo.customers SET updated_at = SYSDATETIME()
    WHERE customer_id IN (SELECT customer_id FROM inserted);
END;
GO

INSERT INTO dbo.customers (full_name, email, country, is_active, rating, credit_limit, discount, created_at, last_login, updated_at, signup_tz, notes, avatar, badge, legacy_photo)
VALUES
 (N'Ana María López', N'ana@example.com', N'ES', 1, 5, 1500.50, 12.25, '2022-06-14T09:30:00', '2024-03-01T10:15:00', '2024-03-01T10:15:30.123', '2024-03-01T10:15:30.1234567+01:00', N'Prefers email — ünïcödé ✓', 0x89504E470D0A1A0A, 0xDEADBEEF, 0x0102030405),
 (N'Bob O''Brien', NULL, N'IE', 0, 3, 0, NULL, '2023-11-02T16:45:10.500', NULL, NULL, NULL, N'Tab	and ''quote''', NULL, NULL, NULL),
 (N'Chen Wei', N'chen@example.com', N'CN', 1, 255, 922337203685477.5807, -214748.3648, '2024-02-29T08:00:00', '2023-12-31T23:59:00', '2023-12-31T23:59:59.999', '2023-12-31T23:59:59.9999999-08:00', NULL, 0x00, 0x00000001, NULL);
GO

EXEC dbo.usp_place_order 1, N'Widget', 2, 9.99;
EXEC dbo.usp_place_order 1, N'Gadget', 12, 1.50;
EXEC dbo.usp_place_order 3, N'Doohickey', 1, 100.00;
GO

-- Give the orders some history
UPDATE dbo.orders SET order_date = DATEADD(day, -45 * order_id, order_date);
UPDATE dbo.orders SET ship_date = NULL WHERE order_id = 3;
GO
