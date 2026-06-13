








-- ==========================================
-- 1. DATA CLEANING & STANDARDIZATION
-- ==========================================
SELECT 
    s.OrderID,
    s.CustomerID,
    -- Handle NULL values by replacing them with 0
    COALESCE(s.Discount, 0) AS Cleaned_Discount,
    COALESCE(s.Tax, 0) AS Cleaned_Tax,
    -- Standardize text formatting (e.g., uppercase city names)
    UPPER(c.City) AS Standardized_City,
    -- Ensure Age is valid, replace NULL or 0 with a default (e.g., 25)
    ISNULL(NULLIF(c.Age, 0), 25) AS Valid_Age
FROM 
    dbo.Sales s
LEFT JOIN 
    dbo.customer c ON s.CustomerID = c.CustomerID
-- Filter out corrupt data where Total or Qty is null/zero
WHERE 
    s.Total IS NOT NULL 
    AND s.Qty > 0;



    -- ==========================================
-- 2. MATHEMATICAL OPERATIONS & CALCULATIONS
-- ==========================================
SELECT 
    s.OrderID,
    p.ProductName,
    s.Qty,
    p.CostPrice,
    p.SalePrice,
    -- Calculate Base Revenue before discounts
    (p.SalePrice * s.Qty) AS Base_Revenue,
    
    -- Calculate Net Revenue: (Total) - Discount % + Tax %
    -- Note: Divided by 100.0 to prevent integer division issues
    (s.Total - (s.Total * (COALESCE(s.Discount, 0) / 100.0))) + 
    (s.Total * (COALESCE(s.Tax, 0) / 100.0)) AS Net_Revenue,
    
    -- Calculate True Gross Profit: (SalePrice - CostPrice) * Quantity
    ((p.SalePrice - p.CostPrice) * s.Qty) AS Calculated_Gross_Profit,
    
    -- Calculate Profit Margin Percentage
    ROUND((((p.SalePrice - p.CostPrice) * 1.0) / NULLIF(p.SalePrice, 0)) * 100, 2) AS Profit_Margin_Percent
FROM 
    dbo.Sales s
JOIN 
    dbo.product p ON s.ProductID = p.ProductID;





-- ==========================================
-- 3. ADVANCED ANALYSIS (WINDOW FUNCTIONS)
-- ==========================================
SELECT 
    st.Region,
    st.City,
    SUM(s.Profit) AS Total_City_Profit,
    -- Rank cities within each region based on Profit (1 is the highest)
    RANK() OVER(PARTITION BY st.Region ORDER BY SUM(s.Profit) DESC) AS Profit_Rank_In_Region,
    -- Calculate the total profit of the entire region to find city contribution %
    SUM(SUM(s.Profit)) OVER(PARTITION BY st.Region) AS Total_Region_Profit,
    -- Calculate Percentage Contribution of the city to its Region
    ROUND((SUM(s.Profit) / NULLIF(SUM(SUM(s.Profit)) OVER(PARTITION BY st.Region), 0)) * 100, 2) AS Contribution_Percent
FROM 
    dbo.Sales s
JOIN 
    dbo.store st ON s.StoreID = st.StoreID
GROUP BY 
    st.Region, 
    st.City;




-- ==========================================
-- 4. INVENTORY MANAGEMENT & ALERTS
-- ==========================================
SELECT 
    st.City AS Store_Location,
    p.ProductName,
    p.Category,
    i.Stock AS Current_Stock,
    i.ReorderLevel,
    -- Calculate how many items need to be ordered to meet the Reorder Level
    (i.ReorderLevel - i.Stock) AS Quantity_To_Order,
    -- Calculate the estimated cost for this restock
    ((i.ReorderLevel - i.Stock) * p.CostPrice) AS Estimated_Restock_Cost
FROM 
    dbo.inventory i
JOIN 
    dbo.product p ON i.ProductID = p.ProductID
JOIN 
    dbo.store st ON i.StoreID = st.StoreID
-- Filter ONLY products that are at or below the Reorder Level
WHERE 
    i.Stock <= i.ReorderLevel
ORDER BY 
    Estimated_Restock_Cost DESC;





-- ==========================================
-- 1. CUSTOMER VALUE & SEGMENTATION (LTV)
-- ==========================================
SELECT 
    c.CustomerID,
    c.Loyalty,
    COUNT(DISTINCT s.OrderID) AS Total_Orders,
    SUM(s.Total) AS Lifetime_Value,
    ROUND(AVG(s.Total), 2) AS Average_Order_Value,
    -- Segment customers based on their total spending
    CASE 
        WHEN SUM(s.Total) >= 10000 THEN 'VIP'
        WHEN SUM(s.Total) BETWEEN 2000 AND 9999 THEN 'Regular'
        ELSE 'Occasional'
    END AS Customer_Segment
FROM 
    dbo.customer c
JOIN 
    dbo.Sales s ON c.CustomerID = s.CustomerID
GROUP BY 
    c.CustomerID, 
    c.Loyalty
ORDER BY 
    Lifetime_Value DESC;




-- ==========================================
-- 2. TIME-SERIES ANALYSIS: MONTH-OVER-MONTH GROWTH
-- ==========================================
WITH MonthlySales AS (
    SELECT 
        YEAR(Date) AS Sales_Year,
        MONTH(Date) AS Sales_Month,
        SUM(Total) AS Monthly_Revenue,
        SUM(Profit) AS Monthly_Profit
    FROM 
        dbo.Sales
    -- Clean data: ignore records without a valid date
    WHERE 
        Date IS NOT NULL
    GROUP BY 
        YEAR(Date), 
        MONTH(Date)
)
SELECT 
    Sales_Year,
    Sales_Month,
    Monthly_Revenue,
    -- Get the revenue from the previous month
    LAG(Monthly_Revenue, 1) OVER(ORDER BY Sales_Year, Sales_Month) AS Previous_Month_Revenue,
    
    -- Calculate Month-over-Month (MoM) Growth Percentage
    ROUND(
        ((Monthly_Revenue - LAG(Monthly_Revenue, 1) OVER(ORDER BY Sales_Year, Sales_Month)) / 
        NULLIF(LAG(Monthly_Revenue, 1) OVER(ORDER BY Sales_Year, Sales_Month), 0)) * 100, 
    2) AS MoM_Growth_Percent
FROM 
    MonthlySales;






-- ==========================================
-- 3. ADVANCED CLEANING: DUPLICATES & OUTLIERS
-- ==========================================
WITH RankedSales AS (
    SELECT 
        OrderID,
        CustomerID,
        Date,
        Total,
        Qty,
        -- Assign a row number to find duplicate OrderIDs
        ROW_NUMBER() OVER(PARTITION BY OrderID ORDER BY Date DESC) AS Duplicate_Check
    FROM 
        dbo.Sales
)
SELECT 
    OrderID,
    CustomerID,
    Date,
    Total,
    Qty,
    -- Detect Outliers using Standard Deviation (Z-Score method approximation)
    CASE 
        WHEN Total > (SELECT AVG(Total) + (3 * STDEV(Total)) FROM dbo.Sales) THEN 'High Outlier (Suspicious)'
        WHEN Total <= 0 THEN 'Invalid/Zero Total'
        ELSE 'Normal Transaction'
    END AS Transaction_Status
FROM 
    RankedSales
-- Keep only the first instance of each OrderID (removes exact duplicates)
WHERE 
    Duplicate_Check = 1;





-- ==========================================
-- 1. RFM ANALYSIS (RECENCY, FREQUENCY, MONETARY)
-- ==========================================
WITH CustomerBase AS (
    SELECT 
        CustomerID,
        -- Recency: Days since last purchase (Assuming today is GETDATE())
        DATEDIFF(DAY, MAX(Date), GETDATE()) AS Recency_Days,
        -- Frequency: Total number of orders
        COUNT(DISTINCT OrderID) AS Frequency,
        -- Monetary: Total money spent
        SUM(Total) AS Monetary_Value
    FROM 
        dbo.Sales
    WHERE 
        Date IS NOT NULL
    GROUP BY 
        CustomerID
)
SELECT 
    CustomerID,
    Recency_Days,
    Frequency,
    Monetary_Value,
    -- Simple RFM Scoring (1 to 3 scale for demonstration)
    NTILE(3) OVER(ORDER BY Recency_Days DESC) AS R_Score,
    NTILE(3) OVER(ORDER BY Frequency ASC) AS F_Score,
    NTILE(3) OVER(ORDER BY Monetary_Value ASC) AS M_Score
FROM 
    CustomerBase;




-- ==========================================
-- 2. MARKET BASKET ANALYSIS (PRODUCTS BOUGHT TOGETHER)
-- ==========================================
SELECT 
    p1.Category AS Category_A,
    p2.Category AS Category_B,
    COUNT(DISTINCT s1.OrderID) AS Times_Bought_Together
FROM 
    dbo.Sales s1
JOIN 
    dbo.Sales s2 ON s1.OrderID = s2.OrderID AND s1.ProductID != s2.ProductID
JOIN 
    dbo.product p1 ON s1.ProductID = p1.ProductID
JOIN 
    dbo.product p2 ON s2.ProductID = p2.ProductID
-- Ensure we don't count A-B and B-A as two separate combinations
WHERE 
    p1.Category < p2.Category
GROUP BY 
    p1.Category, 
    p2.Category
HAVING 
    COUNT(DISTINCT s1.OrderID) > 5 -- Filter combinations with significant frequency
ORDER BY 
    Times_Bought_Together DESC;





-- ==========================================
-- 3. MASTER VIEW FOR BUSINESS INTELLIGENCE DASHBOARD
-- ==========================================
CREATE VIEW vw_BusinessIntelligenceDashboard_Data AS
SELECT 
    s.OrderID,
    s.Date AS Order_Date,
    YEAR(s.Date) AS Order_Year,
    MONTH(s.Date) AS Order_Month,
    c.Gender AS Customer_Gender,
    st.City AS Store_City,
    st.Region AS Store_Region,
    p.Category AS Product_Category,
    p.Brand AS Product_Brand,
    s.Qty AS Quantity_Sold,
    
    -- Financials
    (p.SalePrice * s.Qty) AS Gross_Revenue,
    s.Total AS Net_Revenue,
    s.Profit AS Net_Profit,
    
    -- KPIs
    CASE WHEN s.Profit > 0 THEN 1 ELSE 0 END AS Is_Profitable_Transaction
FROM 
    dbo.Sales s
LEFT JOIN dbo.customer c ON s.CustomerID = c.CustomerID
LEFT JOIN dbo.product p ON s.ProductID = p.ProductID
LEFT JOIN dbo.store st ON s.StoreID = st.StoreID
WHERE 
    s.Total IS NOT NULL AND s.Qty > 0;





CREATE VIEW Fact_Sales AS
SELECT 
    OrderID,
    Date AS Order_Date,
    CustomerID,
    ProductID,
    StoreID,
    Qty AS Quantity_Sold,
    COALESCE(Discount, 0) AS Discount_Percentage,
    COALESCE(Tax, 0) AS Tax_Percentage,
    
    -- Total Revenue before deductions
    Total AS Gross_Revenue,
    
    -- Net Revenue after applying discount and adding tax
    ROUND((Total - (Total * (COALESCE(Discount, 0) / 100.0))) + (Total * (COALESCE(Tax, 0) / 100.0)), 2) AS Net_Revenue,
    
    -- Net Profit
    Profit AS Net_Profit
FROM 
    dbo.Sales
WHERE 
    Total IS NOT NULL AND Qty > 0;



CREATE VIEW Dim_Product AS
SELECT 
    ProductID,
    ProductName,
    Category,
    Gender AS Target_Gender,
    Brand,
    CostPrice,
    SalePrice,
    
    -- Profit per single unit
    (SalePrice - CostPrice) AS Unit_Profit_Margin,
    
    -- Profit Margin Percentage per unit
    ROUND(((SalePrice - CostPrice) * 1.0 / NULLIF(SalePrice, 0)) * 100, 2) AS Unit_Profit_Margin_Percent
FROM 
    dbo.product;




CREATE VIEW Dim_Customer AS
SELECT 
    CustomerID,
    Gender,
    Age,
    City,
    Loyalty AS Loyalty_Status,
    
    -- Dynamic Age Segmentation for BI Filtering
    CASE 
        WHEN Age < 20 THEN 'Under 20'
        WHEN Age BETWEEN 20 AND 34 THEN '20-34 (Youth)'
        WHEN Age BETWEEN 35 AND 50 THEN '35-50 (Adult)'
        ELSE 'Above 50'
    END AS Age_Group
FROM 
    dbo.customer;




CREATE VIEW Dim_Inventory AS
SELECT 
    StoreID,
    ProductID,
    Stock AS Current_Stock,
    ReorderLevel,
    
    -- Calculate stock deficit
    CASE 
        WHEN Stock <= ReorderLevel THEN (ReorderLevel - Stock)
        ELSE 0 
    END AS Shortage_Quantity,
    
    -- Inventory Status Alert
    CASE 
        WHEN Stock = 0 THEN 'Out of Stock'
        WHEN Stock <= ReorderLevel THEN 'Requires Restocking'
        ELSE 'Safe Stock Level'
    END AS Stock_Status
FROM 
    dbo.inventory;


CREATE VIEW Dim_Store AS
SELECT 
    StoreID,
    City AS Store_City,
    Region AS Store_Region
FROM 
    dbo.store;


CREATE VIEW Dim_Calendar AS
SELECT DISTINCT
    Date AS Calendar_Date,
    YEAR(Date) AS Calendar_Year,
    MONTH(Date) AS Month_Number,
    DATENAME(MONTH, Date) AS Month_Name,
    DATEPART(QUARTER, Date) AS Calendar_Quarter,
    
    -- Adjusting Week calculations where Saturday is the 1st day of the week
    DATEPART(WEEK, DATEADD(DAY, 1, Date)) AS Fiscal_Week_Number,
    DATENAME(WEEKDAY, Date) AS Day_Name
FROM 
    dbo.Sales
WHERE 
    Date IS NOT NULL;








































































































































