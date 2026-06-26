USE AdventureWorks;
GO

SELECT p.FirstName,
       p.LastName,
       e.JobTitle
FROM Person.Person AS p
     INNER JOIN HumanResources.Employee AS e
         ON e.BusinessEntityID = p.BusinessEntityID
     INNER JOIN HumanResources.EmployeeDepartmentHistory AS edh
         ON e.BusinessEntityID = edh.BusinessEntityID
WHERE edh.DepartmentID IN (SELECT DepartmentID
      FROM HumanResources.Department
      WHERE Name LIKE 'P%');
GO
