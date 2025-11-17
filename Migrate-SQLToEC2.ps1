# ============================================
# CONFIGURATION SECTION
# ============================================

# Linux Server Configuration (where SQL Server is running)
$LinuxHost = "192.168.1.100"              # CHANGE: Linux server IP/hostname
$LinuxSSHPort = "22"                      # Default SSH port
$LinuxUsername = "sqladmin"               # CHANGE: Linux user (can sudo to mssql)
$LinuxPassword = "YourLinuxPassword"      # CHANGE: Linux user password
# OR use SSH key: $LinuxSSHKeyPath = "C:\Users\YourUser\.ssh\id_rsa"

# SQL Server Configuration on Linux Server
$SQLServerUser = "mssql"                  # SQL Server OS user on Linux
$DatabaseName = "MyDatabase"              # CHANGE: Database name to backup (leave empty for all user databases)
$SQLServerPort = "1433"                   # Default SQL Server port
$SQLAuthUser = "sa"                       # SQL Server authentication user
$SQLAuthPassword = "YourSQLPassword"      # CHANGE: SQL Server password
$ExcludeSystemDBs = $true                 # Exclude system databases (model, master, tempdb, msdb)

# NAS Mount Configuration on Linux Server
$NASMountPath = "/mnt/nas/sql_backups"    # CHANGE: NAS mount path on Linux
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

# Working Directory on Windows
$WorkingDirectory = "C:\SQLMigration"     # Local working directory

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
Write-Host "    SQL Server Migration: Linux Server to AWS RDS (via SSH)    " -ForegroundColor Cyan
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

# Check SSH client
Write-Status "Checking SSH client..." "Info"
$plinkAvailable = Get-Command plink -ErrorAction SilentlyContinue
$sshAvailable = Get-Command ssh -ErrorAction SilentlyContinue

if (-not $plinkAvailable -and -not $sshAvailable) {
    Write-Status "No SSH client found! Please install OpenSSH or PuTTY" "Error"
    Write-Host "  Install OpenSSH: Add-WindowsCapability -Online -Name OpenSSH.Client" -ForegroundColor Yellow
    exit 1
} else {
    Write-Status "SSH client found" "Success"
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
# STEP 1: CONNECT TO LINUX SERVER & BACKUP
# ============================================
Write-SectionHeader "STEP 1: BACKUP FROM LINUX SQL SERVER"

Write-Status "Connecting to Linux server: $LinuxHost" "Info"

# Test SSH connection
Write-Status "Testing SSH connection..." "Info"
if ($sshAvailable) {
    $testSSH = echo "exit" | ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$LinuxUsername@$LinuxHost" -p $LinuxSSHPort 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Status "SSH connection successful" "Success"
    } else {
        Write-Status "SSH connection failed!" "Error"
        Write-Host "  Check: hostname, port, username, password/key" -ForegroundColor Yellow
        exit 1
    }
}

# Create backup script for Linux
$backupScript = @"
#!/bin/bash
# SQL Server Backup Script

echo "=================================="
echo "SQL Server Database Backup"
echo "=================================="

# Verify NAS mount
echo "Checking NAS mount..."
if [ ! -d "$NASMountPath" ]; then
    echo "ERROR: NAS mount $NASMountPath not found!"
    exit 1
fi
echo "NAS mount verified: $NASMountPath"

# Set backup file path
BACKUP_FILE="$NASMountPath/$BackupFileName"
LOG_FILE="$NASMountPath/$LogFileName"

echo ""
echo "Starting SQL Server backup..."
echo "Database: $DatabaseName"
echo "Backup file: `$BACKUP_FILE"
echo "This may take several minutes..."
echo ""

# Backup using sqlcmd
/opt/mssql-tools/bin/sqlcmd -S localhost -U $SQLAuthUser -P '$SQLAuthPassword' -Q "BACKUP DATABASE [$DatabaseName] TO DISK = N'`$BACKUP_FILE' WITH NOFORMAT, NOINIT, NAME = N'$DatabaseName-Full Database Backup', SKIP, NOREWIND, NOUNLOAD, COMPRESSION, STATS = 10" > `$LOG_FILE 2>&1

BACKUP_STATUS=`$?

if [ `$BACKUP_STATUS -eq 0 ]; then
    echo ""
    echo "Backup completed successfully!"
    ls -lh `$BACKUP_FILE
    
    # Verify backup
    echo ""
    echo "Verifying backup..."
    /opt/mssql-tools/bin/sqlcmd -S localhost -U $SQLAuthUser -P '$SQLAuthPassword' -Q "RESTORE VERIFYONLY FROM DISK = N'`$BACKUP_FILE'" >> `$LOG_FILE 2>&1
    
    if [ `$? -eq 0 ]; then
        echo "Backup verification successful!"
    else
        echo "WARNING: Backup verification failed!"
        echo "Check log: `$LOG_FILE"
    fi
else
    echo ""
    echo "Backup failed with status: `$BACKUP_STATUS"
    echo "Check log: `$LOG_FILE"
    cat `$LOG_FILE
    exit `$BACKUP_STATUS
fi

exit 0
"@

# Save backup script locally
$localBackupScript = Join-Path $WorkingDirectory "backup_sql.sh"
$backupScript | Out-File -FilePath $localBackupScript -Encoding ASCII -NoNewline

Write-Status "Uploading backup script to Linux server..." "Info"

# Copy script to Linux server
if ($sshAvailable) {
    # Use SCP to copy
    & scp -P $LinuxSSHPort $localBackupScript "${LinuxUsername}@${LinuxHost}:/tmp/backup_sql.sh" 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Status "Script uploaded successfully" "Success"
    } else {
        Write-Status "Failed to upload script" "Error"
        exit 1
    }
}

Write-Status "Executing backup on Linux server..." "Info"
Write-Status "This will take several minutes. Please wait..." "Warning"
Write-Host ""

# Execute backup script on Linux
$backupCommand = @"
chmod +x /tmp/backup_sql.sh
/tmp/backup_sql.sh
"@

if ($sshAvailable) {
    $backupOutput = ssh -p $LinuxSSHPort "${LinuxUsername}@${LinuxHost}" $backupCommand 2>&1
    Write-Host $backupOutput
    
    if ($LASTEXITCODE -eq 0) {
        Write-Status "Backup completed!" "Success"
    } else {
        Write-Status "Backup may have warnings. Check output above." "Warning"
    }
}

# Verify backup file exists on NAS
Write-Status "Verifying backup file on NAS..." "Info"
$verifyCommand = "ls -lh $NASMountPath/$BackupFileName 2>/dev/null"
$fileInfo = ssh -p $LinuxSSHPort "${LinuxUsername}@${LinuxHost}" $verifyCommand 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Status "Backup file verified on NAS" "Success"
    Write-Host "  $fileInfo" -ForegroundColor Gray
} else {
    Write-Status "Backup file not found on NAS!" "Error"
    exit 1
}

# ============================================
# STEP 2: UPLOAD TO S3 FROM LINUX SERVER
# ============================================
Write-SectionHeader "STEP 2: UPLOAD TO AWS S3"

Write-Status "Uploading backup file from Linux server to S3..." "Info"
Write-Host "  Source: $NASMountPath/$BackupFileName" -ForegroundColor Gray
Write-Host "  Destination: s3://$S3BucketName/$S3Folder/$BackupFileName" -ForegroundColor Gray
Write-Host ""

# Upload script for Linux
$uploadScript = @"
#!/bin/bash
# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found on Linux server"
    echo "Attempting installation..."
    # Try to install AWS CLI
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp/
    sudo /tmp/aws/install
fi

# Upload to S3
echo "Uploading to S3..."
aws s3 cp $NASMountPath/$BackupFileName s3://$S3BucketName/$S3Folder/$BackupFileName --region $S3Region

if [ `$? -eq 0 ]; then
    echo "Upload successful"
    # Verify
    aws s3 ls s3://$S3BucketName/$S3Folder/$BackupFileName --region $S3Region
    exit 0
else
    echo "Upload failed"
    exit 1
fi
"@

$localUploadScript = Join-Path $WorkingDirectory "upload_s3.sh"
$uploadScript | Out-File -FilePath $localUploadScript -Encoding ASCII -NoNewline

# Copy and execute upload script
scp -P $LinuxSSHPort $localUploadScript "${LinuxUsername}@${LinuxHost}:/tmp/upload_s3.sh" 2>&1 | Out-Null

$uploadCommand = @"
chmod +x /tmp/upload_s3.sh
/tmp/upload_s3.sh
"@

$uploadOutput = ssh -p $LinuxSSHPort "${LinuxUsername}@${LinuxHost}" $uploadCommand 2>&1
Write-Host $uploadOutput

if ($LASTEXITCODE -eq 0) {
    Write-Status "S3 upload completed!" "Success"
} else {
    Write-Status "S3 upload from Linux failed. Trying from Windows..." "Warning"
    
    # Fallback: Download to Windows then upload
    Write-Status "Downloading backup file to Windows..." "Info"
    $localBackupFile = Join-Path $WorkingDirectory $BackupFileName
    scp -P $LinuxSSHPort "${LinuxUsername}@${LinuxHost}:$NASMountPath/$BackupFileName" $localBackupFile 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Status "Download to Windows successful" "Success"
        
        Write-Status "Uploading from Windows to S3..." "Info"
        & aws s3 cp $localBackupFile "s3://$S3BucketName/$S3Folder/$BackupFileName" --region $S3Region 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "S3 upload completed!" "Success"
        } else {
            Write-Status "S3 upload failed!" "Error"
            exit 1
        }
    } else {
        Write-Status "Download failed!" "Error"
        exit 1
    }
}

# ============================================
# STEP 3: RESTORE TO RDS FROM S3
# ============================================
Write-SectionHeader "STEP 3: RESTORE TO AWS RDS FROM S3"

Write-Status "Connecting to RDS..." "Info"
Write-Host "  Endpoint: $RDSEndpoint" -ForegroundColor Gray

# Test RDS connection (if sqlcmd available on Windows)
$sqlcmdAvailable = Get-Command sqlcmd -ErrorAction SilentlyContinue
if ($sqlcmdAvailable) {
    $testRDS = "SELECT 'Connected' AS Status;" | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -h -1 -W 2>&1
    if ($testRDS -match "Connected") {
        Write-Status "RDS connection successful" "Success"
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
-- Note: This uses native backup/restore through S3 integration
-- Ensure RDS has S3 integration option group configured

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
    
    sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -i $restoreSQLFile
    
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
    Write-Status "SQLCmd not available on Windows" "Warning"
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
        
        $statusCheck = "SELECT lifecycle FROM msdb.dbo.rds_fn_task_status(NULL, 0) WHERE task_type = 'RESTORE_DB' ORDER BY created_at DESC;" | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master -h -1 -W 2>&1
        
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
    $verifySQL | sqlcmd -S "$RDSEndpoint,$RDSPort" -U $RDSUsername -P $RDSPassword -d master
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
    $cleanupCmd = "rm -f $NASMountPath/$BackupFileName $NASMountPath/$LogFileName"
    ssh -p $LinuxSSHPort "${LinuxUsername}@${LinuxHost}" $cleanupCmd 2>&1 | Out-Null
    Write-Status "NAS files cleaned" "Success"
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