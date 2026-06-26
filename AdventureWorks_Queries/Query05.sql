SELECT TOP (250000)
    s1.SalesOrderID AS PrimaryOrder,
    s2.SalesOrderID AS RelatedOrder,
    s1.ProductID,
    TotalQuantity = s1.OrderQty + s2.OrderQty,
    PriceVariance = ABS(s1.UnitPrice - s2.UnitPrice)
FROM Sales.SalesOrderDetail s1
INNER JOIN Sales.SalesOrderDetail s2 
    ON s1.ProductID = s2.ProductID 
    AND s1.SalesOrderID < s2.SalesOrderID  -- Forces an explosive nested iteration
WHERE 
    s1.UnitPrice > 50.00
ORDER BY 
    PriceVariance DESC, 
    TotalQuantity DESC;
