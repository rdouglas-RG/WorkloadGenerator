SELECT TOP (60000)
    sod.SalesOrderID,
    sod.ProductID,
    p.[Name] AS ProductName,
    ComputedKey = CHECKSUM(sod.rowguid, p.rowguid)
FROM Sales.SalesOrderDetail sod
INNER JOIN Production.Product p 
    -- Forces evaluation of shifted criteria across tables
    ON sod.ProductID = p.ProductID 
   AND ABS(CHECKSUM(sod.rowguid)) % 10 = ABS(CHECKSUM(p.rowguid)) % 10
WHERE 
    p.ListPrice >= 0.00
ORDER BY 
    ComputedKey DESC, 
    sod.SalesOrderID ASC;
