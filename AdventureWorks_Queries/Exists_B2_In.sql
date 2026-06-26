USE AdventureWorks;
GO

SELECT a.FirstName,
       a.LastName
FROM Person.Person AS a
WHERE a.LastName IN (SELECT a.LastName
      FROM HumanResources.Employee AS b
      WHERE a.BusinessEntityID = b.BusinessEntityID
            AND a.LastName = 'Johnson');
GO
