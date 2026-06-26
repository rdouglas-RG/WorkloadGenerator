USE AdventureWorks;
GO

-- Force a table scan by using INDEX = 0.
USE AdventureWorks;
GO

SELECT pp.LastName,
    pp.FirstName,
    e.JobTitle
FROM HumanResources.Employee AS e WITH (INDEX = 0)
INNER JOIN Person.Person AS pp
    ON e.BusinessEntityID = pp.BusinessEntityID
WHERE LastName = 'Johnson';
GO
