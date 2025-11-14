# SQL Server Migration: On-Premises to AWS RDS

This repository contains a PowerShell script to migrate SQL Server databases from on-premises Linux servers to AWS RDS SQL Server instances via S3.

##  Overview

This script automates the following migration workflow:

1. **Connect** from Windows machine to Linux server (where SQL Server runs) via SSH
2. **Backup** SQL Server database on Linux server using native backup
3. **Save** backup file to NAS partition mounted on Linux server
4. **Upload** backup file from Linux/NAS to AWS S3 bucket
5. **Restore** to AWS RDS SQL Server using S3 integration
6. **Verify** data integrity on RDS

**Architecture:**
```
┌──────────────┐    SSH    ┌─────────────────────┐
│   Windows    │ ────────► │   Linux Server      │
│   Machine    │           │  (SQL Server here)  │
│ (Run Script) │           │                     │
└──────────────┘           │  - SQL Server       │
                           │  - NAS Mount        │
                           └─────────────────────┘
                                     │
                                     │ Upload backup
                                     ▼
                           ┌─────────────────────┐
                           │      AWS S3         │
                           │      Bucket         │
                           └─────────────────────┘
                                     │
                                     │ RDS S3 Integration
                                     ▼
                           ┌─────────────────────┐
                           │  AWS RDS SQL Server │
                           └─────────────────────┘
```

---

##  Prerequisites

### 1. Windows Machine Requirements

The script must run on a Windows machine with the following installed:

#### **SQL Server Command-Line Tools**
- Download: [SQL Server Command Line Utilities](https://docs.microsoft.com/en-us/sql/tools/sqlcmd-utility)
- Or install via: SQL Server Management Studio (SSMS) includes sqlcmd

**Verify installation:**
```powershell
sqlcmd -?
```

#### **SSH Client**
- Windows 10/11: OpenSSH is pre-installed
- Or download: [PuTTY](https://www.putty.org/)

**Verify installation:**
```powershell
ssh -V
```

#### **AWS CLI**
- Download: [AWS CLI for Windows](https://aws.amazon.com/cli/)
- Or install via: `winget install Amazon.AWSCLI`

**Verify installation:**
```powershell
aws --version
```

#### **PowerShell**
- Version 5.1 or higher (pre-installed on Windows 10/11)

**Verify version:**
```powershell
$PSVersionTable.PSVersion
```

### 2. Network Connectivity

Ensure the Windows machine can connect to:
-  Linux server via SSH (port 22)
-  AWS RDS SQL Server (port 1433)
-  AWS S3 (HTTPS/443)

The Linux server must have:
-  SQL Server installed and running
-  NAS mounted and accessible
-  AWS CLI installed (or script will attempt to install)

**Test connectivity:**
```powershell
# Test SSH to Linux server
Test-NetConnection -ComputerName <linux-server-ip> -Port 22

# Test RDS SQL Server
Test-NetConnection -ComputerName <rds-endpoint> -Port 1433
```

### 3. Database Permissions

#### **SQL Server on Linux:**
- SQL Authentication user with backup privileges (typically `sa` or sysadmin role)
- Or database owner with BACKUP DATABASE permission
- SSH user on Linux with permissions to access NAS mount

#### **AWS RDS SQL Server:**
- Master user account (usually `admin`)
- Or user with db_owner role on target database

### 4. AWS Configuration

#### **S3 Bucket:**
- Create an S3 bucket in your preferred region
- Note the bucket name and region

#### **IAM Credentials:**
- AWS Access Key ID with S3 read/write permissions
- AWS Secret Access Key

**Configure AWS CLI:**
```powershell
aws configure
# Enter: Access Key ID, Secret Access Key, Region, Output format (json)
```

**Verify S3 access:**
```powershell
aws s3 ls s3://your-bucket-name
```

#### **RDS S3 Integration:**
- RDS SQL Server must have S3 integration option group configured
- See: [AWS RDS SQL Server Native Backup/Restore](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Procedural.Importing.html)

### 5. Disk Space

Ensure sufficient disk space:
- **On Linux server NAS mount:** Space for the backup file
- **On Windows machine (optional):** 2x backup file size if fallback download needed

**Check available space:**
```powershell
Get-PSDrive -PSProvider FileSystem
```

---

##  Quick Start

### Step 1: Download the Script

```powershell
# Clone this repository
git clone https://github.com/yourusername/sql-rds-migration.git
cd sql-rds-migration

# Or download the script directly
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/yourusername/sql-rds-migration/main/Migrate-SQLToRDS.ps1" -OutFile "Migrate-SQLToRDS.ps1"
```

### Step 2: Configure the Script

Open `Migrate-SQLToRDS.ps1` in a text editor and update the **CONFIGURATION SECTION**.

### Step 3: Run the Script

```powershell
# Navigate to script directory
cd C:\path\to\script

# Run the migration script
.\Migrate-SQLToRDS.ps1
```

---

##  Configuration

Edit the **CONFIGURATION SECTION** in `Migrate-SQLToRDS.ps1`:

### 1. Linux Server & SQL Server Configuration

```powershell
# Linux Server Configuration (where SQL Server is running)
$LinuxHost = "192.168.1.100"              # Linux server IP/hostname
$LinuxSSHPort = "22"                      # SSH port
$LinuxUsername = "sqladmin"               # Linux user (with sudo if needed)
$LinuxPassword = "YourLinuxPassword"      # Linux user password

# SQL Server Configuration on Linux Server
$SQLServerUser = "mssql"                  # SQL Server OS user on Linux
$DatabaseName = "MyDatabase"              # Database name to backup
$SQLServerPort = "1433"                   # SQL Server port
$SQLAuthUser = "sa"                       # SQL authentication user
$SQLAuthPassword = "YourSQLPassword"      # SQL Server password

# NAS Mount Configuration on Linux Server
$NASMountPath = "/mnt/nas/sql_backups"    # NAS mount path on Linux
```

**How to find SQL Server information on Linux:**
```bash
# SSH to Linux server
ssh username@linux-server

# Check SQL Server status
systemctl status mssql-server

# Connect to SQL Server
/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P 'YourPassword'

# List databases
SELECT name FROM sys.databases;
GO

# Check NAS mount
df -h | grep nas
```

### 2. AWS RDS SQL Server Configuration

```powershell
# RDS SQL Server Configuration
$RDSEndpoint = "mydb.c9akciq32.us-east-1.rds.amazonaws.com"  # RDS endpoint
$RDSPort = "1433"                         # SQL Server port
$RDSDatabaseName = "MyDatabase"           # RDS database name
$RDSUsername = "admin"                    # RDS master username
$RDSPassword = "YourRDSPassword"          # RDS master password
```

**How to find your RDS Endpoint:**
1. Go to AWS Console → RDS → Databases
2. Click on your RDS instance
3. Copy the "Endpoint" under "Connectivity & security"

### 3. AWS S3 Configuration

```powershell
# AWS S3 Configuration
$S3BucketName = "my-sql-migration-bucket"  # Your S3 bucket name
$S3Region = "us-east-1"                    # S3 bucket region
```

**Supported AWS Regions:**
- `us-east-1` (N. Virginia)
- `us-west-2` (Oregon)
- `eu-west-1` (Ireland)
- `ap-south-1` (Mumbai)
- [Full list](https://docs.aws.amazon.com/general/latest/gr/rande.html#s3_region)

### 4. Working Directory

```powershell
# Working Directory on Windows
$WorkingDirectory = "D:\SQLMigration"  # Path with sufficient disk space
```

 **Important:** Ensure this drive has enough free space (2-3x your database size)

---

##  Running the Migration

### Option 1: Interactive Execution

```powershell
# Run the script
.\Migrate-SQLToRDS.ps1

# The script will:
# 1. Test connections
# 2. Backup from Linux SQL Server
# 3. Upload to S3
# 4. Restore to RDS
# 5. Verify data
```

### Option 2: Scheduled Execution

To run the migration during off-peak hours:

```powershell
# Create a scheduled task
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-File C:\path\to\Migrate-SQLToRDS.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At "2:00 AM"
Register-ScheduledTask -TaskName "SQL_Migration" -Action $action -Trigger $trigger
```

### Option 3: Run with Logging

```powershell
# Run with transcript logging
.\Migrate-SQLToRDS.ps1 | Tee-Object -FilePath "migration_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
```

---

##  What the Script Does

### Step 1: Connection Testing
- Tests SSH connectivity to Linux server
- Verifies AWS CLI configuration
- Checks AWS credentials

### Step 2: Backup from Linux SQL Server
```
SQL Server Database Backup
==========================
Database: MyDatabase
Backup file: /mnt/nas/sql_backups/SQLBackup.bak
...
Backup completed successfully!
Backup verification successful!
```

### Step 3: Upload to S3
```
Uploading to s3://bucket-name/sql-backups/SQLBackup.bak
Upload completed successfully!
File verified in S3
```

### Step 4: Restore to RDS
```
Downloading backup from S3 to RDS...
Starting database restore...
Target Database: MyDatabase
...
Restore process initiated successfully!
```

### Step 5: Verification
```
Restore Task Status:
task_id  task_type   database_name  lifecycle   percent_complete
-------  ----------  -------------  ---------   ----------------
12345    RESTORE_DB  MyDatabase     SUCCESS     100

Tables in database:
SchemaName  TableName        RowCount
----------  ---------------  --------
dbo         Customers        15000
dbo         Orders           125000
dbo         Products         5000
```

---

##  Pre-Migration Checklist

- [ ] Windows machine meets all prerequisites
- [ ] SSH client installed (OpenSSH or PuTTY)
- [ ] SQL Server Command-Line Tools installed (sqlcmd)
- [ ] AWS CLI installed and configured
- [ ] Linux server accessible via SSH
- [ ] SQL Server running on Linux server
- [ ] NAS mounted on Linux server
- [ ] SQL Server credentials verified
- [ ] RDS SQL Server credentials verified
- [ ] S3 bucket created and accessible
- [ ] RDS has S3 integration option group configured
- [ ] Network connectivity tested (SSH, RDS, S3)
- [ ] Sufficient disk space on NAS mount
- [ ] Script configuration updated with correct values
- [ ] Test SSH connection: `ssh username@linux-server`
- [ ] Verify NAS mount on Linux: `df -h | grep nas`
- [ ] Test SQL Server on Linux: `sqlcmd -S localhost -U sa -P password`
- [ ] Test RDS connection: `sqlcmd -S rds-endpoint -U admin -P password`
- [ ] Test AWS S3 access: `aws s3 ls s3://bucket-name`
- [ ] Backup existing data (if any) on RDS
- [ ] Schedule migration during maintenance window
- [ ] Notify stakeholders of migration timeline

---

##  Important Notes

### RDS S3 Integration Setup

Before running the script, ensure your RDS SQL Server instance has S3 integration enabled:

1. Create an IAM role with S3 access (AmazonS3FullAccess policy)
2. Create or modify RDS option group
3. Add `SQLSERVER_BACKUP_RESTORE` option with the IAM role
4. Apply the option group to your RDS instance
5. Reboot RDS instance if required

**AWS CLI commands:**
```bash
# Create IAM role (example)
aws iam create-role --role-name rds-s3-integration-role --assume-role-policy-document file://trust-policy.json

# Attach S3 policy
aws iam attach-role-policy --role-name rds-s3-integration-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Add to RDS option group
aws rds add-option-to-option-group \
  --option-group-name my-option-group \
  --options "OptionName=SQLSERVER_BACKUP_RESTORE,OptionSettings=[{Name=IAM_ROLE_ARN,Value=arn:aws:iam::123456789012:role/rds-s3-integration-role}]"
```

See: [AWS Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Procedural.Importing.html)

### Database Compatibility

- Ensure source and target SQL Server versions are compatible
- RDS SQL Server supports: 2016, 2017, 2019, 2022
- Backup from higher version cannot restore to lower version
- Consider database compatibility level settings

### Backup Compression

The script uses `WITH COMPRESSION` for faster backups and smaller file sizes. Ensure:
- SQL Server on Linux supports backup compression (Enterprise/Standard editions)
- Sufficient CPU resources during backup

---

##  Additional Resources

- [SQL Server on Linux Documentation](https://docs.microsoft.com/en-us/sql/linux/)
- [AWS RDS SQL Server Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_SQLServer.html)
- [RDS Native Backup/Restore](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Procedural.Importing.html)
- [AWS CLI S3 Commands](https://docs.aws.amazon.com/cli/latest/reference/s3/)
- [SQL Server Backup Documentation](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql)

---

##  License

This script is provided as-is for database migration purposes. Use at your own risk.

---

##  Critical Reminders

1. **Always test in a non-production environment first**
2. **Backup your data before migration**
3. **Schedule migrations during maintenance windows**
4. **Monitor RDS performance after migration**
5. **Update application connection strings to point to RDS**
6. **Keep the backup files until you verify the migration**
7. **Review and test all database objects after restore**
8. **Check SQL Server Agent jobs, logins, and linked servers separately**
9. **Migrate logins separately** (not included in database backup)
10. **Test application functionality thoroughly after migration**

---

**Ready to migrate? Follow the Quick Start guide above!**