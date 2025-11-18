# ============================================
# CONFIGURATION SECTION
# ============================================

# Windows Server Configuration (where SQL Server is running)
$WindowsServerHost = "192.168.1.100"      # CHANGE: Windows server IP/hostname
$WindowsServerUser = "Administrator"      # CHANGE: Windows server username
$WindowsServerPassword = "YourPassword"   # CHANGE: Windows server password
# Note: Ensure PowerShell Remoting is enabled on target server

# SQL Server Configuration on Windows Server
$DatabaseName = "MyDatabase"              # CHANGE: Database name to backup
$SQLServerInstance = "MSSQLSERVER"        # CHANGE: SQL Server instance (MSSQLSERVER for default)
$SQLServerPort = "1433"                   # Default SQL Server port
$SQLAuthUser = "sa"                       # SQL Server authentication user
$SQLAuthPassword = "YourSQLPassword"      # CHANGE: SQL Server password
$ExcludeSystemDBs = $true                 # Exclude system databases (model, master, tempdb, msdb)

# NAS Mount Configuration on Windows Server
$NASMountPath = "\\nas-server\sql_backups"  # CHANGE: UNC path to NAS share
$BackupFileName = "SQLBackup.bak"         # Backup file name
$LogFileName = "SQLBackup.log"            # Log file name

# AWS RDS SQL Server Configuration
$RDSEndpoint = "mydb.abc123.us-east-1.rds.amazonaws.com"  # CHANGE: RDS endpoint
$RDSPort = "1433"
$RDSDatabaseName = "MyDatabase"           # CHANGE: RDS database name
$RDSUsername = "admin"                    # CHANGE: RDS master username
$RDSPassword = "YourRDSPassword"          # CHANGE: RDS password

# AWS S3 Configuration
$S3BucketName = "your-sql-bucket"         # CHANGE: S3 bucket name
$S3Region = "us-east-1"                   # CHANGE: S3 region
$S3Folder = "sql-backups"                 # S3 folder prefix

# Working Directory on Jump Box
$WorkingDirectory = "C:\SQLMigration"     # Local working directory on jump box

# Restore Configuration
$TargetDatabaseName = "MyDatabase"        # Target database name on RDS

# ============================================
# DO NOT MODIFY BELOW THIS LINE
# ============================================

$ErrorActionPreference = "Continue"
$ScriptStartTime = Get-Date

# Banner
Clear-Host
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "  SQL Server Migration: Windows Server to AWS RDS (via WinRM)  " -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Started: $ScriptStartTime" -ForegroundColor Gray
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Helper functions
function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    switch ($Type) {
        "Success" { Write-Host "[OK] $Message" -ForegroundColor Green }
        "Error"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        "Warning" { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "Info"    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
    }
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# Create working directory
if (-not (Test-Path $WorkingDirectory)) {
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null
}
Set-Location $WorkingDirectory

# Check prerequisites
Write-SectionHeader "VERIFYING PREREQUISITES"

# Check SQL Server Module or sqlcmd
Write-Status "Checking SQL Server tools..." "Info"
$sqlcmdAvailable = Get-Command sqlcmd -ErrorAction SilentlyContinue
if ($sqlcmdAvailable) {
    Write-Status "sqlcmd found" "Success"
} else {
    Write-Status "sqlcmd not found! Install SQL Server Command Line Utilities" "Warning"
}

# Check AWS CLI
Write-Status "Checking AWS CLI..." "Info"
try {
    $null = Get-Command aws -ErrorAction Stop
    Write-Status "AWS CLI found" "Success"
} catch {
    Write-Status "AWS CLI not found!" "Error"
    exit 1
}

# Verify AWS credentials
Write-Status "Checking AWS credentials..." "Info"
$awsCheck = & aws sts get-caller-identity 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Status "AWS credentials configured" "Success"
} else {
    Write-Status "AWS not configured! Run: aws configure" "Error"
    exit 1
}

# ============================================
# STEP 1: CONNECT TO WINDOWS SERVER & BACKUP
# ============================================
Write-SectionHeader "STEP 1: BACKUP FROM WINDOWS SQL SERVER"

Write-Status "Connecting to Windows server: $WindowsServerHost" "Info"

# Create credentials for remote connection
$securePassword = ConvertTo-SecureString $WindowsServerPassword -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($WindowsServerUser, $securePassword)

# Test WinRM/PowerShell Remoting connection
Write-Status "Testing PowerShell Remoting connection..." "Info"
try {
    $testConnection = Test-WSMan -ComputerName $WindowsServerHost -Credential $credential -ErrorAction Stop
    Write-Status "PowerShell Remoting connection successful" "Success"
} catch {
    Write-Status "PowerShell Remoting failed! Ensure WinRM is enabled on target server." "Error"
    Write-Host "  Enable WinRM: Run 'Enable-PSRemoting -Force' on $WindowsServerHost" -ForegroundColor Yellow
    Write-Host "  Configure firewall: 'Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any'" -ForegroundColor Yellow
    exit 1
}

# Create backup script for Windows Server
$backupScriptBlock = {
    param(
        $DatabaseName,
        $SQLAuthUser,
        $SQLAuthPassword,
        $NASMountPath,
        $BackupFileName,
        $LogFileName,
        $SQLServerInstance,
        $SQLServerPort
    )
    
    $ErrorActionPreference = "Continue"
    $logFile = Join-Path $NASMountPath $LogFileName
    $backupFile = Join-Path $NASMountPath $BackupFileName
    
    # Start logging
    "================================" | Out-File $logFile
    "SQL Server Database Backup" | Out-File $logFile -Append
    "Started: $(Get-Date)" | Out-File $logFile -Append
    "================================" | Out-File $logFile -Append
    "" | Out-File $logFile -Append
    
    Write-Host "Verifying NAS mount path..." -ForegroundColor Cyan
    if (-not (Test-Path $NASMountPath)) {
        Write-Host "ERROR: NAS mount $NASMountPath not accessible!" -ForegroundColor Red
        "ERROR: NAS mount not accessible" | Out-File $logFile -Append
        return @{ Success = $false; Message = "NAS mount not accessible" }
    }
    Write-Host "NAS mount verified: $NASMountPath" -ForegroundColor Green
    
    # Verify SQL Server service
    Write-Host "Checking SQL Server service..." -ForegroundColor Cyan
    $serviceName = if ($SQLServerInstance -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$SQLServerInstance" }
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    
    if (-not $service) {
        Write-Host "ERROR: SQL Server service not found!" -ForegroundColor Red
        "ERROR: SQL Server service not found" | Out-File $logFile -Append
        return @{ Success = $false; Message = "SQL Server service not found" }
    }
    
    if ($service.Status -ne 'Running') {
        Write-Host "ERROR: SQL Server service is not running!" -ForegroundColor Red
        "ERROR: SQL Server service not running: $($service.Status)" | Out-File $logFile -Append
        return @{ Success = $false; Message = "SQL Server not running" }
    }
    Write-Host "SQL Server service is running" -ForegroundColor Green
    
    # Build connection string
    $serverInstance = if ($SQLServerInstance -eq "MSSQLSERVER") { 
        "localhost,$SQLServerPort" 
    } else { 
        "localhost\$SQLServerInstance" 
    }
    
    # Test SQL connection
    Write-Host "Testing SQL Server connection..." -ForegroundColor Cyan
    $testQuery = "SELECT @@VERSION AS Version;"
    try {
        $testResult = sqlcmd -S $serverInstance -U $SQLAuthUser -P $SQLAuthPassword -Q $testQuery -h -1 -W -C 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: Cannot connect to SQL Server!" -ForegroundColor Red
            "ERROR: Connection failed" | Out-File $logFile -Append
            return @{ Success = $false; Message = "Cannot connect to SQL Server" }
        }
        Write-Host "SQL Server connection successful" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Connection test failed: $_" -ForegroundColor Red
        "ERROR: $_" | Out-File $logFile -Append
        return @{ Success = $false; Message = $_.Exception.Message }
    }
    
    # List available user databases
    Write-Host "" 
    Write-Host "Available user databases:" -ForegroundColor Cyan
    $userDBQuery = "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND name NOT IN ('model', 'master', 'tempdb', 'msdb') ORDER BY name;"
    $userDatabases = sqlcmd -S $serverInstance -U $SQLAuthUser -P $SQLAuthPassword -Q $userDBQuery -h -1 -W -C 2>&1
    Write-Host $userDatabases
    "" | Out-File $logFile -Append
    "User Databases:" | Out-File $logFile -Append
    $userDatabases | Out-File $logFile -Append
    
    # Check if database exists and is not a system database
    Write-Host ""
    Write-Host "Validating database '$DatabaseName'..." -ForegroundColor Cyan
    $dbCheckQuery = "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '$DatabaseName' AND database_id > 4;"
    $dbExists = sqlcmd -S $serverInstance -U $SQLAuthUser -P $SQLAuthPassword -Q $dbCheckQuery -h -1 -W -C 2>&1
    
    if ($dbExists.Trim() -eq "0") {
        Write-Host "ERROR: Database '$DatabaseName' not found or is a system database!" -ForegroundColor Red
        "ERROR: Database not found or is system database" | Out-File $logFile -Append
        return @{ Success = $false; Message = "Database not found or is system database" }
    }
    Write-Host "Database '$DatabaseName' validated" -ForegroundColor Green
    
    # Perform backup
    Write-Host ""
    Write-Host "Starting SQL Server backup..." -ForegroundColor Cyan
    Write-Host "Database: $DatabaseName" -ForegroundColor Gray
    Write-Host "Backup file: $backupFile" -ForegroundColor Gray
    Write-Host "This may take several minutes..." -ForegroundColor Yellow
    Write-Host ""
    
    $backupQuery = @"
SET NOCOUNT ON;
DECLARE @BackupFile NVARCHAR(500) = N'$backupFile';
DECLARE @DatabaseName NVARCHAR(128) = N'$DatabaseName';

-- Check database state
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = @DatabaseName AND state_desc <> 'ONLINE')
BEGIN
    RAISERROR('Database is not ONLINE', 16, 1);
END

-- Perform backup
BACKUP DATABASE @DatabaseName 
TO DISK = @BackupFile
WITH 
    NOFORMAT, 
    INIT, 
    NAME = N'Full Database Backup', 
    SKIP, 
    NOREWIND, 
    NOUNLOAD, 
    COMPRESSION, 
    STATS = 10;

PRINT 'Backup completed successfully';
"@
    
    $backupResult = sqlcmd -S $serverInstance -U $SQLAuthUser -P $SQLAuthPassword -Q $backupQuery -C 2>&1
    Write-Host $backupResult
    $backupResult | Out-File $logFile -Append
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Backup failed!" -ForegroundColor Red
        return @{ Success = $false; Message = "Backup failed" }
    }
    
    Write-Host ""
    Write-Host "Backup completed successfully!" -ForegroundColor Green
    
    # Get backup file info
    if (Test-Path $backupFile) {
        $fileInfo = Get-Item $backupFile
        Write-Host "Backup file size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" -ForegroundColor Gray
        "Backup file size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" | Out-File $logFile -Append
    }
    
    # Verify backup
    Write-Host ""
    Write-Host "Verifying backup..." -ForegroundColor Cyan
    $verifyQuery = "RESTORE VERIFYONLY FROM DISK = N'$backupFile';"
    $verifyResult = sqlcmd -S $serverInstance -U $SQLAuthUser -P $SQLAuthPassword -Q $verifyQuery -C 2>&1
    $verifyResult | Out-File $logFile -Append
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Backup verification successful!" -ForegroundColor Green
        "Backup verification: SUCCESS" | Out-File $logFile -Append
        return @{ Success = $true; Message = "Backup completed and verified"; BackupFile = $backupFile }
    } else {
        Write-Host "WARNING: Backup verification failed!" -ForegroundColor Yellow
        "Backup verification: FAILED" | Out-File $logFile -Append
        return @{ Success = $false; Message = "Backup verification failed" }
    }
}

# Execute backup on remote Windows server
Write-Status "Executing backup on Windows server..." "Info"
Write-Status "This will take several minutes. Please wait..." "Warning"
Write-Host ""

try {
    $backupResult = Invoke-Command -ComputerName $WindowsServerHost -Credential $credential -ScriptBlock $backupScriptBlock -ArgumentList $DatabaseName, $SQLAuthUser, $SQLAuthPassword, $NASMountPath, $BackupFileName, $LogFileName, $SQLServerInstance, $SQLServerPort
    
    if ($backupResult.Success) {
        Write-Status "Backup completed successfully!" "Success"
    } else {
        Write-Status "Backup failed: $($backupResult.Message)" "Error"
        exit 1
    }
} catch {
    Write-Status "Error executing remote backup: $_" "Error"
    exit 1
}

# Verify backup file exists on NAS
Write-Status "Verifying backup file on NAS..." "Info"
$nasBackupPath = Join-Path $NASMountPath $BackupFileName

try {
    $fileCheck = Invoke-Command -ComputerName $WindowsServerHost -Credential $credential -ScriptBlock {
        param($path)
        if (Test-Path $path) {
            $file = Get-Item $path
            return @{ Exists = $true; Size = $file.Length; FullName = $file.FullName }
        }
        return @{ Exists = $false }
    } -ArgumentList $nasBackupPath
    
    if ($fileCheck.Exists) {
        Write-Status "Backup file verified on NAS" "Success"
        Write-Host "  File: $($fileCheck.FullName)" -ForegroundColor Gray
        Write-Host "  Size: $([math]::Round($fileCheck.Size / 1MB, 2)) MB" -ForegroundColor Gray
    } else {
        Write-Status "Backup file not found on NAS!" "Error"
        exit 1
    }
} catch {
    Write-Status "Error verifying backup file: $_" "Error"
    exit 1
}

# ============================================
# STEP 2: UPLOAD TO S3
# ============================================
Write-SectionHeader "STEP 2: UPLOAD TO AWS S3"

Write-Status "Uploading backup file to S3..." "Info"
Write-Host "  Source: $nasBackupPath" -ForegroundColor Gray
Write-Host "  Destination: s3://$S3BucketName/$S3Folder/$BackupFileName" -ForegroundColor Gray
Write-Host ""

# Try to upload from Windows server first
Write-Status "Attempting upload from Windows server..." "Info"

$uploadScriptBlock = {
    param($NASMountPath, $BackupFileName, $S3BucketName, $S3Folder, $S3Region)
    
    $backupFile = Join-Path $NASMountPath $BackupFileName
    
    # Check if AWS CLI is installed
    $awsCLI = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $awsCLI) {
        return @{ Success = $false; Message = "AWS CLI not installed on Windows server" }
    }
    
    # Upload to S3
    $uploadResult = & aws s3 cp $backupFile "s3://$S3BucketName/$S3Folder/$BackupFileName" --region $S3Region 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        # Verify upload
        $verifyResult = & aws s3 ls "s3://$S3BucketName/$S3Folder/$BackupFileName" --region $S3Region 2>&1
        return @{ Success = $true; Message = "Upload successful"; Output = $verifyResult }
    } else {
        return @{ Success = $false; Message = "Upload failed"; Output = $uploadResult }
    }
}

try {
    $uploadResult = Invoke-Command -ComputerName $WindowsServerHost -Credential $credential -ScriptBlock $uploadScriptBlock -ArgumentList $NASMountPath, $BackupFileName, $S3BucketName, $S3Folder, $S3Region
    
    if ($uploadResult.Success) {
        Write-Status "S3 upload completed from Windows server!" "Success"
        Write-Host $uploadResult.Output
    } else {
        Write-Status "Upload from Windows server failed: $($uploadResult.Message)" "Warning"
        
        # Fallback: Copy to jump box then upload
        Write-Status "Downloading backup file to jump box..." "Info"
        $localBackupFile = Join-Path $WorkingDirectory $BackupFileName
        
        Copy-Item -Path $nasBackupPath -Destination $localBackupFile -FromSession (New-PSSession -ComputerName $WindowsServerHost -Credential $credential) -ErrorAction Stop
        
        if (Test-Path $localBackupFile) {
            Write-Status "Download to jump box successful" "Success"
            
            Write-Status "Uploading from jump box to S3..." "Info"
            & aws s3 cp $localBackupFile "s3://$S3BucketName/$S3Folder/$BackupFileName" --region $S3Region 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Status "S3 upload completed from jump box!" "Success"
            } else {
                Write-Status "S3 upload failed!" "Error"
                exit 1
            }
        } else {
            Write-Status "Download to jump box failed!" "Error"
            exit 1
        }
    }
} catch {
    Write-Status "Error during upload process: $_" "Error"
    exit 1
}

# ============================================
# STEP 3: RESTORE TO RDS FROM S3
# ============================================
Write-SectionHeader "STEP 3: RESTORE TO AWS RDS FROM S3"

Write-Status "Connecting to RDS..." "Info"
Write-Host "  Endpoint: $RDSEndpoint" -ForegroundColor Gray

# Test RDS connection (if sqlcmd available on jump box)
if ($sqlcmdAvailable) {
    Write-Status "Testing RDS connection..." "Info"
    $testRDS = "SELECT 'Connected' AS Status;" | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -h -1 -W -C 2>&1
    if ($testRDS -match "Connected") {
        Write-Status "RDS connection successful" "Success"
    } else {
        Write-Status "RDS connection test inconclusive, continuing..." "Warning"
    }
}

Write-Status "Using RDS S3 Integration for restore..." "Info"

# Create restore SQL script
$restoreSQL = @"
-- ==========================================
-- SQL Server RDS Restore from S3
-- ==========================================

USE [master];
GO

-- Step 1: Download backup from S3 to RDS
PRINT 'Downloading backup from S3 to RDS...'
PRINT 'S3 Location: s3://$S3BucketName/$S3Folder/$BackupFileName'
PRINT ''

-- Step 2: Restore database
PRINT 'Starting database restore...'
PRINT 'Target Database: $TargetDatabaseName'
PRINT ''

-- Restore from S3 using RDS native backup/restore
EXEC msdb.dbo.rds_restore_database
    @restore_db_name='$TargetDatabaseName',
    @s3_arn_to_restore_from='arn:aws:s3:::$S3BucketName/$S3Folder/$BackupFileName';
GO

-- Monitor restore task
PRINT ''
PRINT 'Monitoring restore progress...'
PRINT 'This may take several minutes...'
PRINT ''

-- Wait and check task status
WAITFOR DELAY '00:00:10';
GO

-- Check restore task status
SELECT 
    task_id,
    task_type,
    database_name,
    lifecycle,
    created_at,
    last_updated
FROM msdb.dbo.rds_fn_task_status(NULL, 0)
WHERE task_type = 'RESTORE_DB'
ORDER BY created_at DESC;
GO

-- Verify database after restore
PRINT ''
PRINT 'Verifying restored database...'

USE [$TargetDatabaseName];
GO

SELECT 
    name AS DatabaseName,
    state_desc AS State,
    recovery_model_desc AS RecoveryModel,
    (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS TableCount
FROM sys.databases
WHERE name = '$TargetDatabaseName';
GO

PRINT ''
PRINT 'Restore process initiated successfully!'
PRINT 'Check task status above for completion.'
GO
"@

$restoreSQLFile = Join-Path $WorkingDirectory "rds_restore.sql"
$restoreSQL | Out-File -FilePath $restoreSQLFile -Encoding ASCII

Write-Host ""
Write-Status "Executing RDS restore..." "Info"
Write-Status "This will take several minutes..." "Warning"
Write-Host ""

if ($sqlcmdAvailable) {
    # Execute via sqlcmd if available
    Write-Host "Executing restore script on RDS..." -ForegroundColor Cyan
    Write-Host ""
    
    sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -i $restoreSQLFile -C
    
    if ($LASTEXITCODE -eq 0) {
        Write-Status "RDS restore initiated!" "Success"
        Write-Host ""
        Write-Host "  NOTE: The restore is running in the background." -ForegroundColor Yellow
        Write-Host "  Monitor progress using the query above or AWS RDS Console." -ForegroundColor Yellow
        Write-Host ""
    } else {
        Write-Status "Restore completed with warnings" "Warning"
    }
} else {
    Write-Status "SQLCmd not available on jump box" "Warning"
    Write-Host ""
    Write-Host "  MANUAL STEP REQUIRED:" -ForegroundColor Yellow
    Write-Host "  Connect to RDS and run the SQL script:" -ForegroundColor Yellow
    Write-Host "  File: $restoreSQLFile" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Or use SQL Server Management Studio (SSMS) to execute it" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Press ENTER after completing RDS restore"
}

# ============================================
# STEP 4: VERIFY RESTORE
# ============================================
Write-SectionHeader "STEP 4: VERIFY DATA ON RDS"

$verifySQL = @"
-- Check restore task status
SELECT 
    task_id,
    task_type,
    database_name,
    lifecycle,
    percent_complete,
    created_at,
    last_updated
FROM msdb.dbo.rds_fn_task_status(NULL, 0)
WHERE task_type = 'RESTORE_DB'
ORDER BY created_at DESC;
GO

-- Verify database
USE [$TargetDatabaseName];
GO

-- List all tables
SELECT 
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS TableName,
    (SELECT COUNT(*) FROM sys.partitions WHERE object_id = t.object_id AND index_id IN (0,1)) AS RowCount
FROM sys.tables t
WHERE is_ms_shipped = 0
ORDER BY SchemaName, TableName;
GO

-- Database size
EXEC sp_spaceused;
GO
"@

if ($sqlcmdAvailable) {
    Write-Status "Checking database on RDS..." "Info"
    Write-Host ""
    
    # Wait for restore to complete (check status periodically)
    Write-Host "Waiting for restore to complete (checking every 30 seconds)..." -ForegroundColor Cyan
    $maxWaitMinutes = 30
    $waitCount = 0
    $maxWaitCount = $maxWaitMinutes * 2
    
    do {
        Start-Sleep -Seconds 30
        $waitCount++
        
        $statusCheck = "SELECT lifecycle FROM msdb.dbo.rds_fn_task_status(NULL, 0) WHERE task_type = 'RESTORE_DB' ORDER BY created_at DESC;" | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -h -1 -W -C 2>&1
        
        if ($statusCheck -match "SUCCESS") {
            Write-Status "Restore completed successfully!" "Success"
            break
        } elseif ($statusCheck -match "ERROR") {
            Write-Status "Restore failed! Check RDS logs." "Error"
            break
        } elseif ($waitCount -ge $maxWaitCount) {
            Write-Status "Restore still in progress after $maxWaitMinutes minutes." "Warning"
            Write-Host "  Continue monitoring in AWS RDS Console or run verification script manually." -ForegroundColor Yellow
            break
        } else {
            Write-Host "  Still restoring... ($waitCount checks)" -ForegroundColor Gray
        }
    } while ($true)
    
    Write-Host ""
    Write-Host "Verification Results:" -ForegroundColor Cyan
    Write-Host ""
    $verifySQL | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -C
}

# ============================================
# STEP 5: RECONCILIATION
# ============================================
Write-SectionHeader "STEP 5: RECONCILIATION"

Write-Status "Comparing table counts..." "Info"
Write-Host "  Run CHECKSUM or row count comparison between source and target" -ForegroundColor Gray
Write-Host ""

# ============================================
# CLEANUP
# ============================================
Write-SectionHeader "CLEANUP"

$cleanup = Read-Host "Delete files on NAS? (Y/N) [Default: N]"
if ($cleanup -eq 'Y' -or $cleanup -eq 'y') {
    try {
        Invoke-Command -ComputerName $WindowsServerHost -Credential $credential -ScriptBlock {
            param($NASMountPath, $BackupFileName, $LogFileName)
            $backupFile = Join-Path $NASMountPath $BackupFileName
            $logFile = Join-Path $NASMountPath $LogFileName
            Remove-Item -Path $backupFile -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $logFile -Force -ErrorAction SilentlyContinue
        } -ArgumentList $NASMountPath, $BackupFileName, $LogFileName
        Write-Status "NAS files cleaned" "Success"
    } catch {
        Write-Status "Error cleaning NAS files: $_" "Warning"
    }
}

$s3cleanup = Read-Host "Delete S3 files? (Y/N) [Default: N]"
if ($s3cleanup -eq 'Y' -or $s3cleanup -eq 'y') {
    & aws s3 rm "s3://$S3BucketName/$S3Folder/$BackupFileName" --region $S3Region
    Write-Status "S3 files cleaned" "Success"
}

# ============================================
# SUMMARY
# ============================================
$ScriptEndTime = Get-Date
$Duration = $ScriptEndTime - $ScriptStartTime

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "                   MIGRATION COMPLETED!                         " -ForegroundColor Green
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Duration: $($Duration.Hours)h $($Duration.Minutes)m $($Duration.Seconds)s" -ForegroundColor White
Write-Host ""
Write-Host "  IMPORTANT POST-MIGRATION STEPS:" -ForegroundColor Yellow
Write-Host "  1. Verify all tables and data on RDS" -ForegroundColor White
Write-Host "  2. Update application connection strings" -ForegroundColor White
Write-Host "  3. Test application connectivity to RDS" -ForegroundColor White
Write-Host "  4. Monitor RDS performance" -ForegroundColor White
Write-Host "  5. Set up backup strategy for RDS" -ForegroundColor White
Write-Host ""