-- Target Execution: ~3 to 5 seconds
SELECT TOP (150000)
    soh1.SalesOrderID AS Order1,
    soh2.SalesOrderID AS Order2,
    soh1.OrderDate,
    soh1.CustomerID,
    (soh1.TotalDue + soh2.TotalDue) as CombinedDue
FROM Sales.SalesOrderHeader soh1
INNER JOIN Sales.SalesOrderHeader soh2 
    ON soh1.CustomerID = soh2.CustomerID 
   AND soh1.SalesOrderID < soh2.SalesOrderID -- Forces looping/heavy scans
WHERE soh1.OrderDate >= '2011-01-01'
ORDER BY CombinedDue DESC;
