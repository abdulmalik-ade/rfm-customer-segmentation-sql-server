/*
===============================================================================
RFM CUSTOMER SEGMENTATION ANALYSIS - SQL SERVER
===============================================================================

DATABASE:
    RFMCustomerSegmentation

EXISTING TABLE:
    dbo.RFM_Staging

IMPORTANT:
    The imported table contains ONLY these columns:

        Transaction ID
        Date
        Product_ID
        Product_Name
        Product_Category
        Quantity
        PPU
        Amount

    Customer ID and Region are NOT separate columns.

    Customer rows are stored in the same table as marker rows, for example:

        Customer-001 | Yangon | NULL | NULL | NULL | NULL | NULL | NULL

    The analysis below therefore reconstructs Customer_ID and Region from
    those marker rows before performing the RFM analysis.

    NO DATABASE IS CREATED.
    NO TABLE IS CREATED.
    NO DATA IS IMPORTED.

    Run this after importing the data into dbo.RFM_Staging.

===============================================================================
*/

USE RFMCustomerSegmentation;
GO

/*===========================================================================
1. CHECK THE IMPORTED DATA
===========================================================================*/

SELECT TOP (20)
    Transaction_ID,
    [Date],
    [Product_ID],
    [Product_Name],
    [Product_Category],
    [Quantity],
    [PPU],
    [Amount]
FROM dbo.RFM_Staging;
GO


/*===========================================================================
2. DATASET OVERVIEW
===========================================================================*/

SELECT
    COUNT(*) AS Total_Rows,
    SUM(CASE WHEN [Product_ID] IS NULL THEN 1 ELSE 0 END) AS Customer_Marker_Rows,
    SUM(CASE WHEN [Product_ID] IS NOT NULL THEN 1 ELSE 0 END) AS Transaction_Rows
FROM dbo.RFM_Staging;
GO


/*===========================================================================
3. DATA QUALITY CHECKS
===========================================================================*/

SELECT
    SUM(CASE WHEN Transaction_ID IS NULL THEN 1 ELSE 0 END) AS Null_Transaction_ID,
    SUM(CASE WHEN [Date] IS NULL THEN 1 ELSE 0 END) AS Null_Date,
    SUM(CASE WHEN [Product_ID] IS NULL THEN 1 ELSE 0 END) AS Null_Product_ID,
    SUM(CASE WHEN [Product_Name] IS NULL THEN 1 ELSE 0 END) AS Null_Product_Name,
    SUM(CASE WHEN [Product_Category] IS NULL THEN 1 ELSE 0 END) AS Null_Product_Category,
    SUM(CASE WHEN [Quantity] IS NULL THEN 1 ELSE 0 END) AS Null_Quantity,
    SUM(CASE WHEN [PPU] IS NULL THEN 1 ELSE 0 END) AS Null_PPU,
    SUM(CASE WHEN [Amount] IS NULL THEN 1 ELSE 0 END) AS Null_Amount
FROM dbo.RFM_Staging;
GO


/*===========================================================================
4. DUPLICATE TRANSACTION CHECK
===========================================================================*/

SELECT
    Transaction_ID,
    COUNT(*) AS Duplicate_Count
FROM dbo.RFM_Staging
WHERE [Product_ID] IS NOT NULL
GROUP BY Transaction_ID
HAVING COUNT(*) > 1
ORDER BY Duplicate_Count DESC;
GO


/*===========================================================================
5. RECONSTRUCT CUSTOMER_ID AND REGION
===========================================================================

The raw table stores customer information in marker rows.

Example:

Customer-001 | Yangon | NULL | NULL | NULL | NULL | NULL | NULL
T000001      | 01.01.2025 | PROD-008 | ...
T000002      | 01.01.2025 | PROD-002 | ...
...

The marker applies to the transaction rows that follow it until the next
Customer-XXX marker.

Because the imported table has no row-number/order column, the first step
creates an internal row sequence from the imported table scan.

The result is stored only in a temporary table for this analysis.
The original dbo.RFM_Staging table is NOT modified.
===========================================================================*/

IF OBJECT_ID('tempdb..#RFM_Base') IS NOT NULL
    DROP TABLE #RFM_Base;

;WITH OrderedRows AS
(
    SELECT
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS Row_ID,
        Transaction_ID,
        [Date],
        [Product_ID],
        [Product_Name],
        [Product_Category],
        [Quantity],
        [PPU],
        [Amount]
    FROM dbo.RFM_Staging
),
MarkedRows AS
(
    SELECT
        *,
        CASE
            WHEN Transaction_ID LIKE 'Customer-%'
                 AND [Product_ID] IS NULL
            THEN 1
            ELSE 0
        END AS Is_Customer_Marker
    FROM OrderedRows
),
CustomerGroups AS
(
    SELECT
        *,
        SUM(Is_Customer_Marker) OVER
        (
            ORDER BY Row_ID
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS Customer_Group
    FROM MarkedRows
)
SELECT
    Row_ID,
    Transaction_ID,
    TRY_CONVERT(DATE, [Date], 104) AS Transaction_Date,
    [Product_ID] AS Product_ID,
    LTRIM(RTRIM([Product_Name])) AS Product_Name,
    LTRIM(RTRIM([Product_Category])) AS Product_Category,
    TRY_CONVERT(DECIMAL(18,2), [Quantity]) AS Quantity,
    TRY_CONVERT
    (
        DECIMAL(18,2),
        REPLACE(CONVERT(VARCHAR(100), [PPU]), ',', '')
    ) AS PPU,
    TRY_CONVERT
    (
        DECIMAL(18,2),
        REPLACE(CONVERT(VARCHAR(100), [Amount]), ',', '')
    ) AS Amount,

    MAX(
        CASE
            WHEN Is_Customer_Marker = 1
            THEN Transaction_ID
        END
    ) OVER
    (
        PARTITION BY Customer_Group
    ) AS Customer_ID,

    MAX(
        CASE
            WHEN Is_Customer_Marker = 1
            THEN [Date]
        END
    ) OVER
    (
        PARTITION BY Customer_Group
    ) AS Region

INTO #RFM_Base
FROM CustomerGroups
WHERE [Product_ID] IS NOT NULL;
GO


/*===========================================================================
6. VERIFY RECONSTRUCTED CUSTOMER DATA
===========================================================================*/

SELECT TOP (20)
    Customer_ID,
    Region,
    Transaction_ID AS Transaction_ID,
    Transaction_Date,
    Product_ID,
    Product_Name,
    Product_Category,
    Quantity,
    PPU,
    Amount
FROM #RFM_Base
ORDER BY Row_ID;
GO


/*===========================================================================
7. CUSTOMER / REGION COVERAGE
===========================================================================*/

SELECT
    COUNT(DISTINCT Customer_ID) AS Total_Customers,
    COUNT(DISTINCT Region) AS Total_Regions,
    COUNT(DISTINCT Product_ID) AS Total_Products,
    COUNT(DISTINCT Product_Category) AS Total_Categories,
    COUNT(*) AS Total_Transactions
FROM #RFM_Base;
GO


/*===========================================================================
8. CHECK FOR UNASSIGNED CUSTOMERS
===========================================================================*/

SELECT
    COUNT(*) AS Transactions_Without_Customer
FROM #RFM_Base
WHERE Customer_ID IS NULL;
GO


/*===========================================================================
9. CHECK DATE RANGE
===========================================================================*/

SELECT
    MIN(Transaction_Date) AS First_Transaction_Date,
    MAX(Transaction_Date) AS Last_Transaction_Date
FROM #RFM_Base;
GO


/*===========================================================================
10. CHECK AMOUNT = QUANTITY * PPU
===========================================================================*/

SELECT
    COUNT(*) AS Amount_Mismatches
FROM #RFM_Base
WHERE ABS(Amount - (Quantity * PPU)) > 0.01;
GO


/*===========================================================================
11. EXECUTIVE SALES KPIs
===========================================================================*/

SELECT
    COUNT(DISTINCT Transaction_ID) AS Total_Transactions,
    COUNT(DISTINCT Customer_ID) AS Total_Customers,
    COUNT(DISTINCT Product_ID) AS Total_Products,
    SUM(Quantity) AS Total_Units_Sold,
    SUM(Amount) AS Total_Revenue,
    AVG(Amount) AS Average_Transaction_Value
FROM #RFM_Base;
GO


/*===========================================================================
12. SALES BY REGION
===========================================================================*/

SELECT
    Region,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    COUNT(DISTINCT Customer_ID) AS Customers,
    SUM(Quantity) AS Units_Sold,
    SUM(Amount) AS Revenue,
    AVG(Amount) AS Average_Transaction_Value,
    CAST(
        100.0 * SUM(Amount)
        / NULLIF(SUM(SUM(Amount)) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS Revenue_Share_Pct
FROM #RFM_Base
GROUP BY Region
ORDER BY Revenue DESC;
GO


/*===========================================================================
13. PRODUCT CATEGORY PERFORMANCE
===========================================================================*/

SELECT
    Product_Category,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    COUNT(DISTINCT Product_ID) AS Products,
    SUM(Quantity) AS Units_Sold,
    SUM(Amount) AS Revenue,
    AVG(Amount) AS Average_Transaction_Value
FROM #RFM_Base
GROUP BY Product_Category
ORDER BY Revenue DESC;
GO


/*===========================================================================
14. TOP 10 PRODUCTS BY REVENUE
===========================================================================*/

SELECT TOP (10)
    Product_ID,
    Product_Name,
    Product_Category,
    SUM(Quantity) AS Units_Sold,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    SUM(Amount) AS Revenue,
    AVG(PPU) AS Average_Unit_Price
FROM #RFM_Base
GROUP BY
    Product_ID,
    Product_Name,
    Product_Category
ORDER BY Revenue DESC;
GO


/*===========================================================================
15. MONTHLY SALES TREND
===========================================================================*/

SELECT
    DATEFROMPARTS(
        YEAR(Transaction_Date),
        MONTH(Transaction_Date),
        1
    ) AS Sales_Month,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    SUM(Quantity) AS Units_Sold,
    SUM(Amount) AS Revenue,
    AVG(Amount) AS Average_Transaction_Value
FROM #RFM_Base
GROUP BY
    YEAR(Transaction_Date),
    MONTH(Transaction_Date)
ORDER BY Sales_Month;
GO


/*===========================================================================
16. CUSTOMER SALES RANKING
===========================================================================*/

SELECT
    Customer_ID,
    Region,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    SUM(Amount) AS Customer_Revenue,
    RANK() OVER
    (
        ORDER BY SUM(Amount) DESC
    ) AS Revenue_Rank
FROM #RFM_Base
GROUP BY
    Customer_ID,
    Region
ORDER BY Revenue_Rank;
GO


/*===========================================================================
17. CUSTOMER RFM METRICS
===========================================================================

Recency  = Days since the customer's last purchase
Frequency = Number of transactions
Monetary = Total customer revenue

Analysis date = one day after the latest transaction date.
===========================================================================*/

IF OBJECT_ID('tempdb..#CustomerRFM') IS NOT NULL
    DROP TABLE #CustomerRFM;

SELECT
    Customer_ID,
    MAX(Transaction_Date) AS Last_Purchase_Date,

    DATEDIFF(
        DAY,
        MAX(Transaction_Date),
        DATEADD(DAY, 1, (SELECT MAX(Transaction_Date) FROM #RFM_Base))
    ) AS Recency,

    COUNT(DISTINCT Transaction_ID) AS Frequency,

    SUM(Amount) AS Monetary

INTO #CustomerRFM
FROM #RFM_Base
GROUP BY Customer_ID;
GO


/*===========================================================================
18. VIEW CUSTOMER RFM METRICS
===========================================================================*/

SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary
FROM #CustomerRFM
ORDER BY Monetary DESC;
GO


/*===========================================================================
19. RFM 1-5 QUINTILE SCORING
===========================================================================*/

SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary,

    6 - NTILE(5) OVER
    (
        ORDER BY Recency ASC
    ) AS R_Score,

    NTILE(5) OVER
    (
        ORDER BY Frequency ASC
    ) AS F_Score,

    NTILE(5) OVER
    (
        ORDER BY Monetary ASC
    ) AS M_Score

FROM #CustomerRFM
ORDER BY Monetary DESC;
GO


/*===========================================================================
20. COMPLETE RFM SCORE
===========================================================================*/

;WITH Scored AS
(
    SELECT
        Customer_ID,
        Last_Purchase_Date,
        Recency,
        Frequency,
        Monetary,

        6 - NTILE(5) OVER
        (
            ORDER BY Recency ASC
        ) AS R_Score,

        NTILE(5) OVER
        (
            ORDER BY Frequency ASC
        ) AS F_Score,

        NTILE(5) OVER
        (
            ORDER BY Monetary ASC
        ) AS M_Score

    FROM #CustomerRFM
)
SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary,
    R_Score,
    F_Score,
    M_Score,
    CONCAT(R_Score, F_Score, M_Score) AS RFM_Score
FROM Scored
ORDER BY Monetary DESC;
GO


/*===========================================================================
21. CUSTOMER SEGMENTATION
===========================================================================

8 practical segments based on median High/Low thresholds.

===========================================================================*/

;WITH Thresholds AS
(
    SELECT
        *,
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Recency)
        OVER () AS Recency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Frequency)
        OVER () AS Frequency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Monetary)
        OVER () AS Monetary_Median

    FROM #CustomerRFM
)
SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary,

    CASE
        WHEN Recency <= Recency_Median
        THEN 'Recent'
        ELSE 'At Risk'
    END AS Recency_Group,

    CASE
        WHEN Frequency >= Frequency_Median
        THEN 'High'
        ELSE 'Low'
    END AS Frequency_Group,

    CASE
        WHEN Monetary >= Monetary_Median
        THEN 'High'
        ELSE 'Low'
    END AS Monetary_Group,

    CASE
        WHEN Recency <= Recency_Median
             AND Frequency >= Frequency_Median
             AND Monetary >= Monetary_Median
            THEN 'Champions'

        WHEN Recency <= Recency_Median
             AND Frequency >= Frequency_Median
             AND Monetary < Monetary_Median
            THEN 'Loyal Low-Value'

        WHEN Recency <= Recency_Median
             AND Frequency < Frequency_Median
             AND Monetary >= Monetary_Median
            THEN 'Potential High-Value'

        WHEN Recency <= Recency_Median
             AND Frequency < Frequency_Median
             AND Monetary < Monetary_Median
            THEN 'New / Developing'

        WHEN Recency > Recency_Median
             AND Frequency >= Frequency_Median
             AND Monetary >= Monetary_Median
            THEN 'At-Risk High-Value'

        WHEN Recency > Recency_Median
             AND Frequency >= Frequency_Median
             AND Monetary < Monetary_Median
            THEN 'At-Risk Loyal'

        WHEN Recency > Recency_Median
             AND Frequency < Frequency_Median
             AND Monetary >= Monetary_Median
            THEN 'High-Value Win-Back'

        ELSE 'Low-Value Inactive'
    END AS Customer_Segment

FROM Thresholds
ORDER BY Monetary DESC;
GO


/*===========================================================================
22. SEGMENT SUMMARY
===========================================================================*/

;WITH Thresholds AS
(
    SELECT
        *,
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Recency)
        OVER () AS Recency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Frequency)
        OVER () AS Frequency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Monetary)
        OVER () AS Monetary_Median

    FROM #CustomerRFM
),
Segments AS
(
    SELECT
        *,
        CASE
            WHEN Recency <= Recency_Median
                 AND Frequency >= Frequency_Median
                 AND Monetary >= Monetary_Median
                THEN 'Champions'

            WHEN Recency <= Recency_Median
                 AND Frequency >= Frequency_Median
                 AND Monetary < Monetary_Median
                THEN 'Loyal Low-Value'

            WHEN Recency <= Recency_Median
                 AND Frequency < Frequency_Median
                 AND Monetary >= Monetary_Median
                THEN 'Potential High-Value'

            WHEN Recency <= Recency_Median
                 AND Frequency < Frequency_Median
                 AND Monetary < Monetary_Median
                THEN 'New / Developing'

            WHEN Recency > Recency_Median
                 AND Frequency >= Frequency_Median
                 AND Monetary >= Monetary_Median
                THEN 'At-Risk High-Value'

            WHEN Recency > Recency_Median
                 AND Frequency >= Frequency_Median
                 AND Monetary < Monetary_Median
                THEN 'At-Risk Loyal'

            WHEN Recency > Recency_Median
                 AND Frequency < Frequency_Median
                 AND Monetary >= Monetary_Median
                THEN 'High-Value Win-Back'

            ELSE 'Low-Value Inactive'
        END AS Customer_Segment
    FROM Thresholds
)
SELECT
    Customer_Segment,
    COUNT(*) AS Customers,
    SUM(Monetary) AS Segment_Revenue,
    AVG(Monetary) AS Average_Customer_Value,
    AVG(Frequency) AS Average_Frequency,
    AVG(Recency) AS Average_Recency,
    CAST(
        100.0 * SUM(Monetary)
        / NULLIF(SUM(SUM(Monetary)) OVER (), 0)
        AS DECIMAL(10,2)
    ) AS Revenue_Share_Pct
FROM Segments
GROUP BY Customer_Segment
ORDER BY Segment_Revenue DESC;
GO


/*===========================================================================
23. TOP 20 CUSTOMERS
===========================================================================*/

SELECT TOP (20)
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary
FROM #CustomerRFM
ORDER BY Monetary DESC;
GO


/*===========================================================================
24. AT-RISK HIGH-VALUE CUSTOMERS
===========================================================================*/

;WITH Thresholds AS
(
    SELECT
        *,
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Recency)
        OVER () AS Recency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Monetary)
        OVER () AS Monetary_Median

    FROM #CustomerRFM
)
SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary
FROM Thresholds
WHERE Recency > Recency_Median
  AND Monetary >= Monetary_Median
ORDER BY Monetary DESC;
GO


/*===========================================================================
25. CHAMPIONS
===========================================================================*/

;WITH Thresholds AS
(
    SELECT
        *,
        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Recency)
        OVER () AS Recency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Frequency)
        OVER () AS Frequency_Median,

        PERCENTILE_CONT(0.5)
        WITHIN GROUP (ORDER BY Monetary)
        OVER () AS Monetary_Median

    FROM #CustomerRFM
)
SELECT
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary
FROM Thresholds
WHERE Recency <= Recency_Median
  AND Frequency >= Frequency_Median
  AND Monetary >= Monetary_Median
ORDER BY Monetary DESC;
GO


/*===========================================================================
26. CUSTOMER REVENUE CONCENTRATION
===========================================================================*/

;WITH CustomerRevenue AS
(
    SELECT
        Customer_ID,
        Monetary AS Customer_Revenue
    FROM #CustomerRFM
),
Cumulative AS
(
    SELECT
        Customer_ID,
        Customer_Revenue,

        SUM(Customer_Revenue) OVER ()
            AS Total_Revenue,

        SUM(Customer_Revenue) OVER
        (
            ORDER BY Customer_Revenue DESC
            ROWS BETWEEN UNBOUNDED PRECEDING
            AND CURRENT ROW
        ) AS Cumulative_Revenue

    FROM CustomerRevenue
)
SELECT
    Customer_ID,
    Customer_Revenue,

    CAST(
        100.0 * Customer_Revenue
        / NULLIF(Total_Revenue, 0)
        AS DECIMAL(10,2)
    ) AS Revenue_Share_Pct,

    CAST(
        100.0 * Cumulative_Revenue
        / NULLIF(Total_Revenue, 0)
        AS DECIMAL(10,2)
    ) AS Cumulative_Revenue_Pct

FROM Cumulative
ORDER BY Customer_Revenue DESC;
GO


/*===========================================================================
27. CUSTOMER VALUE BY REGION
===========================================================================*/

SELECT
    Region,
    COUNT(DISTINCT Customer_ID) AS Customers,
    SUM(Amount) AS Revenue,
    AVG(Customer_Revenue) AS Average_Customer_Value
FROM
(
    SELECT
        Customer_ID,
        Region,
        SUM(Amount) OVER
        (
            PARTITION BY Customer_ID
        ) AS Customer_Revenue,
        Amount
    FROM #RFM_Base
) AS x
GROUP BY Region
ORDER BY Revenue DESC;
GO


/*===========================================================================
28. REGION + PRODUCT CATEGORY PERFORMANCE
===========================================================================*/

SELECT
    Region,
    Product_Category,
    COUNT(DISTINCT Transaction_ID) AS Transactions,
    SUM(Quantity) AS Units_Sold,
    SUM(Amount) AS Revenue
FROM #RFM_Base
GROUP BY
    Region,
    Product_Category
ORDER BY
    Region,
    Revenue DESC;
GO


/*===========================================================================
29. FINAL RETENTION PRIORITY LIST
===========================================================================*/

SELECT TOP (20)
    Customer_ID,
    Last_Purchase_Date,
    Recency,
    Frequency,
    Monetary,

    CASE
        WHEN Recency >= 90
             AND Monetary >= (SELECT AVG(Monetary) FROM #CustomerRFM)
            THEN 'URGENT WIN-BACK'

        WHEN Recency >= 60
            THEN 'RETENTION'

        ELSE 'MONITOR'
    END AS Retention_Priority

FROM #CustomerRFM
ORDER BY
    CASE
        WHEN Recency >= 90
             AND Monetary >= (SELECT AVG(Monetary) FROM #CustomerRFM)
            THEN 1
        WHEN Recency >= 60
            THEN 2
        ELSE 3
    END,
    Monetary DESC;
GO


/*===========================================================================
END OF RFM CUSTOMER SEGMENTATION ANALYSIS
===========================================================================*/
