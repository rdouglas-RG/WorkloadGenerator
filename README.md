# Workload Generator

A PowerShell load generator that runs scripts in a parallel sliding window. It launches
multiple concurrent instances of Python (`.py`), PowerShell (`.ps1`), or SQL Server (`.sql`)
scripts as background jobs, keeping a fixed number running at once until a count and/or
duration limit is reached.

The bundled [AdventureWorks_Queries](AdventureWorks_Queries/) folder contains nine
deliberately expensive read queries (large joins, cross joins, `STRING_AGG`, etc.) designed
to stress CPU, memory, and tempdb against an **enlarged** AdventureWorks database.

## Prerequisites

1. **PowerShell** (Windows PowerShell 5.1 or PowerShell 7+).
2. **A SQL Server execution method** — one of:
   - `SqlServer` module (recommended): `Install-Module SqlServer -Scope CurrentUser`
   - `sqlcmd` (fallback): https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility
3. **The AdventureWorks sample database** plus the enlargement script (see below).
4. If your execution policy blocks unsigned scripts:
   `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

## Setting up AdventureWorks

The bundled queries target large tables (e.g. `Production.TransactionHistory`,
`Sales.SalesOrderDetail`) and only produce meaningful load against an **enlarged** copy of
AdventureWorks. Two steps:

1. **Download and restore the AdventureWorks OLTP sample database** from Microsoft:
   https://learn.microsoft.com/en-us/sql/samples/adventureworks-install-configure
   (Restore the `AdventureWorks` full-database `.bak` for your SQL Server version.)

2. **Run Jonathan Kehayias' AdventureWorks enlargement script** from SQLskills, which
   inflates the key tables by orders of magnitude so the workload actually does work:
   https://www.sqlskills.com/blogs/jonathan/enlarging-the-adventureworks-sample-databases/

> The enlargement script is a single large `INSERT ... SELECT`. On the default database
> settings it can generate **a lot** of transaction log — see
> [Reducing log growth during enlargement](#reducing-log-growth-during-enlargement) before
> you run it.

## Configuration

Connection details live in [run-parallel-config.json](run-parallel-config.json) as named
**profiles**. Edit it for your environment. Each profile supports:

| Field                   | Required        | Notes                                                       |
| ----------------------- | --------------- | ----------------------------------------------------------- |
| `server`                | yes             | Host or `host\instance` (e.g. `localhost\SQL2022`).         |
| `database`              | yes             | Target database, e.g. `AdventureWorks`.                     |
| `auth`                  | yes             | `windows` or `sql`.                                         |
| `port`                  | no              | Defaults to the instance default if omitted.                |
| `username` / `password` | when `auth=sql` | SQL login credentials.                                      |
| `trustServerCertificate`| no              | `true` to skip TLS cert validation (common for local/dev).  |

Example profile for a local machine using Windows authentication:

```json
{
  "profiles": {
    "local-windows": {
      "server": "localhost\\SQL2022",
      "database": "AdventureWorks",
      "port": 1433,
      "auth": "windows",
      "trustServerCertificate": true
    }
  }
}
```

> **Keep this file out of source control** — it can contain plain-text passwords. Add
> `run-parallel-config.json` to your `.gitignore`.

By default the script looks for `run-parallel-config.json` next to `Run-Parallel.ps1`; point
elsewhere with `-ConfigPath`.

## Running

```powershell
.\Run-Parallel.ps1 -Language <python|powershell|sqlserver> -ScriptPath <file-or-folder> `
    [-Count <n>] [-Duration <minutes>] [-MaxConcurrent <n>] [-Delay <seconds>] `
    [-SqlProfile <name>] [-ConfigPath <path>]
```

You must supply **at least one** of `-Count` (total executions to launch) or `-Duration`
(minutes — decimals allowed). When `-Count` is reached, in-flight jobs finish naturally; when
`-Duration` is reached, in-flight jobs are stopped immediately. `-MaxConcurrent` is the
sliding-window size (required when using `-Duration` without `-Count`).

When `-ScriptPath` is a **folder**, each slot picks a matching script at random on every
launch — ideal for mixing the AdventureWorks queries.

### Examples — SQL Server

Run the whole query folder for 10 minutes, 5 at a time, against the `local-windows` profile:

```powershell
.\Run-Parallel.ps1 -Language sqlserver -ScriptPath ".\AdventureWorks_Queries" `
    -Duration 10 -MaxConcurrent 5 -SqlProfile local-windows
```

Launch exactly 100 executions, 10 concurrent, with a half-second stagger between launches:

```powershell
.\Run-Parallel.ps1 -Language sqlserver -ScriptPath ".\AdventureWorks_Queries" `
    -Count 100 -MaxConcurrent 10 -Delay 0.5 -SqlProfile dev
```

Stop at whichever limit comes first (up to 100 runs **or** 5 minutes):

```powershell
.\Run-Parallel.ps1 -Language sqlserver -ScriptPath ".\AdventureWorks_Queries" `
    -Count 100 -Duration 5 -MaxConcurrent 10 -SqlProfile prod
```

> `-SqlProfile` (and `-ConfigPath`) only apply to `-Language sqlserver`. PowerShell and
> Python runs ignore them — they take no connection profile.

### Examples — PowerShell

Run a single PowerShell script 20 times, 5 instances at a time:

```powershell
.\Run-Parallel.ps1 -Language powershell -ScriptPath "C:\Scripts\Do-Work.ps1" `
    -Count 20 -MaxConcurrent 5
```

Randomly pick `.ps1` scripts from a folder and run them for 10 minutes, 4 at a time:

```powershell
.\Run-Parallel.ps1 -Language powershell -ScriptPath "C:\Scripts" `
    -Duration 10 -MaxConcurrent 4
```

### Examples — Python

Run a single Python script 50 times, 8 concurrent, with a half-second stagger:

```powershell
.\Run-Parallel.ps1 -Language python -ScriptPath "C:\Queries\run_queries.py" `
    -Count 50 -MaxConcurrent 8 -Delay 0.5
```

Randomly pick `.py` scripts from a folder and run for up to 100 executions or 5 minutes,
whichever comes first, 10 at a time:

```powershell
.\Run-Parallel.ps1 -Language python -ScriptPath "C:\Queries" `
    -Count 100 -Duration 5 -MaxConcurrent 10
```

> Python runs require `python` to be on your `PATH`. Each instance is launched as
> `python <script>`, so the script is responsible for its own arguments, environment, and any
> database connection it needs.

## Reducing log growth during enlargement

Jonathan Kehayias' enlargement script populates the big tables with one massive
`INSERT ... SELECT`. A single set-based insert of millions of rows is one transaction, so the
log must hold the entire operation before it can be truncated — this is the usual cause of
runaway `.ldf` growth (and slow autogrow stalls) when first building the enlarged database.
Two mitigations:

### 1. Batch the inserts

Break the population into smaller committed batches so the log can be truncated between them.
The pattern, adapted to whichever table the script is loading:

```sql
-- SIMPLE recovery lets the log truncate at each checkpoint between batches
ALTER DATABASE AdventureWorks SET RECOVERY SIMPLE;

DECLARE @BatchSize int = 100000;
WHILE 1 = 1
BEGIN
    INSERT INTO dbo.bigTransactionHistory WITH (TABLOCK) (/* columns */)
    SELECT TOP (@BatchSize) /* columns */
    FROM <source>
    WHERE <not-already-inserted>;   -- e.g. a key range or NOT EXISTS guard

    IF @@ROWCOUNT = 0 BREAK;        -- nothing left to insert
    CHECKPOINT;                     -- force log truncation under SIMPLE recovery
END
```

Key points:
- Set the database to **`SIMPLE`** recovery for the duration of the load so each committed
  batch lets the log reuse space (switch back to `FULL` afterward if you need point-in-time
  recovery, and take a fresh full backup).
- Commit each batch (a loop of separate `INSERT`s, or `BEGIN TRAN`/`COMMIT` per batch) and
  `CHECKPOINT` so the log is truncated before the next batch.
- The `WITH (TABLOCK)` hint enables minimal logging for the inserts under `SIMPLE`/`BULK_LOGGED`
  recovery, cutting log volume further.
- A batch size of ~50k–250k rows is a reasonable starting point; tune to your log/disk.

### 2. Pre-size files and fix autogrowth

Repeated small autogrowth events fragment the log (many VLFs) and pause work while the file
grows. Before running the enlargement, grow the files **once** to roughly their expected final
size and set sane growth increments:

```sql
ALTER DATABASE AdventureWorks
    MODIFY FILE (NAME = N'AdventureWorks_Data', SIZE = 8GB,  FILEGROWTH = 1GB);

ALTER DATABASE AdventureWorks
    MODIFY FILE (NAME = N'AdventureWorks_Log',  SIZE = 4GB,  FILEGROWTH = 512MB);
```

Recommendations:
- **Pre-grow** the data and log files to their expected final size in one step rather than
  letting them creep up during the load.
- Use **fixed-size growth increments** (e.g. 512MB–1GB), **not** percentage growth — percentage
  growth produces ever-larger, unpredictable autogrow events.
- Check actual logical file names first with `SELECT name, size FROM sys.database_files;`
  (defaults are typically `AdventureWorks_Data` / `AdventureWorks_Log`).
- After loading, the log can be shrunk back down if it grew larger than you need for ongoing
  workload runs.

## Output

The script prints each launched job, reports failures with their output, and ends with a
summary of how many jobs were launched, completed, failed, and (for duration runs) stopped.
It exits with code `1` if any job failed.
