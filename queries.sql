/* =====================================================================
   CUSTOMER SEGMENTATION ANALYSIS
   Database: customer_segmentation.db (SQLite)
   Tables:
     customers(Customer_ID, Customer_Name, Segment, Region)
     orders(Order_ID, Customer_ID, Order_Date, Category, Product_Name,
            Quantity, Discount, Sales, Profit)
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. SCHEMA SANITY CHECK
   --------------------------------------------------------------------- */
SELECT COUNT(*) AS total_customers FROM customers;
SELECT COUNT(*) AS total_orders FROM orders;
SELECT MIN(Order_Date) AS first_order, MAX(Order_Date) AS last_order FROM orders;


/* ---------------------------------------------------------------------
   2. BASIC AGGREGATION — spend and order frequency per customer
   --------------------------------------------------------------------- */
SELECT
    c.Customer_ID,
    c.Customer_Name,
    c.Segment,
    c.Region,
    COUNT(o.Order_ID)      AS order_count,
    SUM(o.Sales)            AS total_spend,
    ROUND(AVG(o.Sales), 2)  AS avg_order_value
FROM customers c
JOIN orders o ON o.Customer_ID = c.Customer_ID
GROUP BY c.Customer_ID
ORDER BY total_spend DESC
LIMIT 20;


/* ---------------------------------------------------------------------
   3. RFM ANALYSIS — Recency, Frequency, Monetary
   Reference date = the day after the last order in the dataset,
   so "recency" is always measured relative to the most current data point.
   --------------------------------------------------------------------- */
WITH reference_date AS (
    SELECT DATE(MAX(Order_Date), '+1 day') AS ref_date FROM orders
),
rfm_base AS (
    SELECT
        c.Customer_ID,
        c.Customer_Name,
        c.Segment,
        c.Region,
        JULIANDAY((SELECT ref_date FROM reference_date)) - JULIANDAY(MAX(o.Order_Date)) AS recency_days,
        COUNT(o.Order_ID) AS frequency,
        SUM(o.Sales)      AS monetary
    FROM customers c
    JOIN orders o ON o.Customer_ID = c.Customer_ID
    GROUP BY c.Customer_ID
),
rfm_scored AS (
    SELECT
        *,
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,   -- lower recency_days = more recent = higher score
        NTILE(4) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_base
)
SELECT
    Customer_ID,
    Customer_Name,
    Segment,
    Region,
    ROUND(recency_days, 0) AS recency_days,
    frequency,
    ROUND(monetary, 2) AS monetary,
    r_score, f_score, m_score,
    (r_score + f_score + m_score) AS rfm_total
FROM rfm_scored
ORDER BY rfm_total DESC
LIMIT 20;


/* ---------------------------------------------------------------------
   4. CUSTOMER TIERING — label each customer using RFM total score
   Tiers:
     10-12  -> Champion       (recent, frequent, high spend)
     7-9    -> Loyal          (solid across the board)
     4-6    -> At Risk        (used to buy, going quiet)
     3      -> Lost / Low Value
   --------------------------------------------------------------------- */
WITH reference_date AS (
    SELECT DATE(MAX(Order_Date), '+1 day') AS ref_date FROM orders
),
rfm_base AS (
    SELECT
        c.Customer_ID, c.Customer_Name, c.Segment, c.Region,
        JULIANDAY((SELECT ref_date FROM reference_date)) - JULIANDAY(MAX(o.Order_Date)) AS recency_days,
        COUNT(o.Order_ID) AS frequency,
        SUM(o.Sales)      AS monetary
    FROM customers c
    JOIN orders o ON o.Customer_ID = c.Customer_ID
    GROUP BY c.Customer_ID
),
rfm_scored AS (
    SELECT *,
        NTILE(4) OVER (ORDER BY recency_days DESC) AS r_score,
        NTILE(4) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(4) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_base
),
rfm_tiered AS (
    SELECT *,
        (r_score + f_score + m_score) AS rfm_total,
        CASE
            WHEN (r_score + f_score + m_score) >= 10 THEN 'Champion'
            WHEN (r_score + f_score + m_score) >= 7  THEN 'Loyal'
            WHEN (r_score + f_score + m_score) >= 4  THEN 'At Risk'
            ELSE 'Lost / Low Value'
        END AS tier
    FROM rfm_scored
)
SELECT
    tier,
    COUNT(*) AS customer_count,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM customers), 1) AS pct_of_customers,
    ROUND(SUM(monetary), 2) AS tier_revenue,
    ROUND(100.0 * SUM(monetary) / (SELECT SUM(Sales) FROM orders), 1) AS pct_of_revenue,
    ROUND(AVG(monetary), 2) AS avg_spend_per_customer
FROM rfm_tiered
GROUP BY tier
ORDER BY tier_revenue DESC;


/* ---------------------------------------------------------------------
   5. SEGMENT x REGION BREAKDOWN — where does each business segment spend?
   --------------------------------------------------------------------- */
SELECT
    c.Segment,
    c.Region,
    COUNT(DISTINCT c.Customer_ID) AS customers,
    SUM(o.Sales) AS total_sales,
    ROUND(SUM(o.Sales) / COUNT(DISTINCT c.Customer_ID), 2) AS avg_spend_per_customer
FROM customers c
JOIN orders o ON o.Customer_ID = c.Customer_ID
GROUP BY c.Segment, c.Region
ORDER BY total_sales DESC;


/* ---------------------------------------------------------------------
   6. AT-RISK HIGH VALUE CUSTOMERS — worth a retention campaign
   High historical spend (top 25% monetary) but recency in bottom half
   --------------------------------------------------------------------- */
WITH reference_date AS (
    SELECT DATE(MAX(Order_Date), '+1 day') AS ref_date FROM orders
),
rfm_base AS (
    SELECT
        c.Customer_ID, c.Customer_Name, c.Segment, c.Region,
        JULIANDAY((SELECT ref_date FROM reference_date)) - JULIANDAY(MAX(o.Order_Date)) AS recency_days,
        COUNT(o.Order_ID) AS frequency,
        SUM(o.Sales)      AS monetary
    FROM customers c
    JOIN orders o ON o.Customer_ID = c.Customer_ID
    GROUP BY c.Customer_ID
),
thresholds AS (
    SELECT
        (SELECT monetary FROM rfm_base ORDER BY monetary DESC LIMIT 1 OFFSET (SELECT COUNT(*)/4 FROM rfm_base)) AS monetary_p75,
        (SELECT AVG(recency_days) FROM rfm_base) AS avg_recency
    FROM rfm_base LIMIT 1
)
SELECT
    r.Customer_ID, r.Customer_Name, r.Region,
    ROUND(r.recency_days, 0) AS days_since_last_order,
    r.frequency,
    ROUND(r.monetary, 2) AS lifetime_spend
FROM rfm_base r, thresholds t
WHERE r.monetary >= t.monetary_p75
  AND r.recency_days >= t.avg_recency
ORDER BY r.monetary DESC;
