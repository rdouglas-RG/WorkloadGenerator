USE AdventureWorks;
GO

SELECT DISTINCT Name
FROM Production.Product
WHERE ProductModelID IN (
    SELECT ProductModelID
    FROM Production.ProductModel AS pm
    WHERE p.ProductModelID = pm.ProductModelID
        AND Name LIKE 'Long-Sleeve Logo Jersey%'
);
GO


