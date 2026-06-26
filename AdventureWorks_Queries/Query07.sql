USE AdventureWorks;
go

SELECT TOP (500000)
    th.ProductID,
    p.[Name] AS ProductName,
    Year = DATEPART(year, th.TransactionDate),
    Month = DATEPART(month, th.TransactionDate),
    TotalQty = SUM(th.Quantity),
    AvgCost = AVG(th.ActualCost),
    -- High memory/CPU operation: concatenating order numbers into a massive string string
    OrdersList = STRING_AGG(CAST(th.ReferenceOrderID AS VARCHAR(10)), ',')
FROM Production.TransactionHistory th
INNER JOIN Production.Product p 
    ON th.ProductID = p.ProductID
WHERE (
    th.ActualCost % 2 = 0
    OR th.ActualCost % 2 = 0.12
    OR th.ActualCost % 2 = 0.13
    OR th.ActualCost % 2 = 0.1
    OR th.ActualCost % 2 = 0.5
    OR th.ActualCost % 2 = 0.2
    OR th.ActualCost % 2 = 0.9
    OR th.ActualCost % 2 = 0.8
    OR th.ActualCost % 2 = 0.7
    OR th.ActualCost % 2 = 1.8
    OR th.ActualCost % 2 = 1.2
    )
GROUP BY 
    th.ProductID, 
    p.[Name],
    DATEPART(year, th.TransactionDate), 
    DATEPART(month, th.TransactionDate)
HAVING 
    (AVG(th.ActualCost) % 2 = 0
    or AVG(th.ActualCost) % 2 = 0.1
    or AVG(th.ActualCost) % 2 = 0.2
    or AVG(th.ActualCost) % 2 = 0.3
    or AVG(th.ActualCost) % 2 = 0.4
    or AVG(th.ActualCost) % 2 = 0.5
    or AVG(th.ActualCost) % 2 = 0.6
    or AVG(th.ActualCost) % 2 = 0.8
    or AVG(th.ActualCost) % 2 = 0.9
    or AVG(th.ActualCost) % 2 = 0.25
    or AVG(th.ActualCost) % 2 = 0.35
    or AVG(th.ActualCost) % 2 = 0.45
    or AVG(th.ActualCost) % 2 = 0.55
)
ORDER BY 
    TotalQty DESC,
    AvgCost ASC
;
