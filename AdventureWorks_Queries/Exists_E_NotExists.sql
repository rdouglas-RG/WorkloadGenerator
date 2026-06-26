USE AdventureWorks;
GO

SELECT p.FirstName,
       p.LastName,
       e.JobTitle
FROM Person.Person AS p
     INNER JOIN HumanResources.Employee AS e
         ON e.BusinessEntityID = p.BusinessEntityID
WHERE NOT EXISTS (SELECT *
      FROM HumanResources.Department AS d
            INNER JOIN HumanResources.EmployeeDepartmentHistory AS edh
               ON d.DepartmentID = edh.DepartmentID
      WHERE e.BusinessEntityID = edh.BusinessEntityID
            AND d.Name LIKE 'P%')
ORDER BY LastName, FirstName;
GO
