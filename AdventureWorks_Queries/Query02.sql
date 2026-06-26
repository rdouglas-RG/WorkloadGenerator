SELECT 
    p.[Name] AS ProductName,
    p.ProductNumber,
    p.Color,
    sod.SalesOrderID,
    sod.OrderQty,
    sod.UnitPrice,
    CONVERT(NVARCHAR(MAX), sod.rowguid) as GuidString
FROM Sales.SalesOrderDetail sod
INNER JOIN Production.Product p ON sod.ProductID = p.ProductID
WHERE p.[Name] LIKE '%Touring%' 
   OR p.[Name] LIKE '%Mountain%'
   OR p.ProductNumber LIKE '%-[0-9]%'
ORDER BY GuidString DESC, sod.UnitPrice ASC;