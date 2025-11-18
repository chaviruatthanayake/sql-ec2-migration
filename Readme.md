# SQL Server Migration: On-Premises to AWS EC2

This repository contains a PowerShell script to migrate SQL Server databases from on-premises Windows servers to AWS EC2 SQL Server instances via S3.

##  Overview

This script automates the following migration workflow:

1. **Connect** from Windows jump box to Windows server (where SQL Server runs) via PowerShell Remoting
2. **Backup** SQL Server database on Windows server using native backup
3. **Save** backup file to NAS partition (UNC path)
4. **Upload** backup file from NAS to AWS S3 bucket
5. **Download** backup from S3 to EC2 instance
6. **Restore** to SQL Server on AWS EC2 instance
7. **Verify** data integrity on EC2

**Architecture:**
```
┌──────────────┐   WinRM   ┌─────────────────────┐
│   Windows    │ ────────► │  Windows Server     │
│   Jump Box   │           │ (SQL Server here)   │
│ (Run Script) │           │                     │
└──────────────┘           │  - SQL Server       │
                           │  - NAS Mount (UNC)  │
                           └─────────────────────┘
                                     │
                                     │ Upload backup
                                     ▼
                           ┌─────────────────────┐
                           │      AWS S3         │
                           │      Bucket         │
                           └─────────────────────┘
                                     │
                                     │ Download
                                     ▼
                           ┌─────────────────────┐
                           │   AWS EC2 Windows   │
                           │  (SQL Server here)  │
                           └─────────────────────┘
```

---

##  Prerequisites

### 1. Windows Jump Box Requirements

The script must run on a Windows jump box with the following installed:

#### **SQL Server Command-Line Tools**
- Download: [SQL Server Command Line Utilities](https://docs.microsoft.com/en-us/sql/tools/sqlcmd-utility)
- Or install via: SQL Server Management Studio (SSMS) includes sqlcmd

**Verify installation:**
```powershell
sqlcmd -?
```

#### **PowerShell Remoting**
- Enabled by default on Windows Server
- For workstations: May need to enable

**Enable PowerShell Remoting (on target servers):**
```powershell
# Run on source Windows server and EC2 instance
Enable-PSRemoting -Force
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any
```

**Verify PowerShell Remoting:**
```powershell
Test-WSMan -ComputerName <server-name>
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

Ensure the Windows jump box can connect to:
-  Source Windows server via PowerShell Remoting (port 5985/5986)
-  EC2 Windows instance via PowerShell Remoting (port 5985/5986)
-  EC2 SQL Server (port 1433)
-  AWS S3 (HTTPS/443)

The source Windows server must have:
-  SQL Server installed and running
-  AS accessible via UNC path (\\nas-server\share)
-  PowerShell Remoting enabled

The EC2 instance must have:
-  SQL Server installed and running
-  AWS CLI installed
-  PowerShell Remoting enabled
-  Sufficient disk space for backup files

**Test connectivity:**
```powershell
# Test PowerShell Remoting to source server
Test-WSMan -ComputerName <windows-server>

# Test PowerShell Remoting to EC2
Test-WSMan -ComputerName <ec2-instance>

# Test SQL Server on EC2
Test-NetConnection -ComputerName <ec2-instance> -Port 1433
```

### 3. Database Permissions

#### **SQL Server on Source Windows Server:**
- SQL Authentication user with backup privileges (typically `sa` or sysadmin role)
- Or database owner with BACKUP DATABASE permission
- Windows user with access to NAS share

#### **SQL Server on EC2:**
- SQL Authentication user with restore privileges (typically `sa` or sysadmin role)
- Or database owner with CREATE DATABASE and RESTORE permission
- Windows user credentials for PowerShell Remoting access

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

#### **EC2 Requirements:**
- EC2 instance must have AWS CLI configured with S3 access
- No RDS S3 Integration required (direct restore to EC2)

### 5. Disk Space

Ensure sufficient disk space:
- **On source Windows server NAS:** Space for the backup file
- **On EC2 instance:** 2x backup file size (for download + restore)
- **On Windows jump box (optional):** 2x backup file size if fallback download needed

**Check available space:**
```powershell
Get-PSDrive -PSProvider FileSystem
```

---

##  Quick Start

### Step 1: Download the Script

```powershell
# Clone this repository
git clone https://github.com/yourusername/sql-ec2-migration.git
cd sql-ec2-migration

# Or download the script directly
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/yourusername/sql-ec2-migration/main/Migrate-SQLToEC2.ps1" -OutFile "Migrate-SQLToEC2.ps1"
```

### Step 2: Configure the Script

Open `Migrate-SQLToEC2.ps1` in a text editor and update the **CONFIGURATION SECTION**.

### Step 3: Run the Script

```powershell
# Navigate to script directory
cd C:\path\to\script

# Run the migration script
.\Migrate-SQLToEC2.ps1
```

---

##  Configuration

Edit the **CONFIGURATION SECTION** in `Migrate-SQLToEC2.ps1`:

### 1. Source Windows Server & SQL Server Configuration

```powershell
# Windows Server Configuration (where SQL Server is running)
$WindowsServerHost = "192.168.1.100"      # Windows server IP/hostname
$WindowsServerUser = "Administrator"      # Windows server username
$WindowsServerPassword = "YourPassword"   # Windows server password

# SQL Server Configuration on Windows Server
$DatabaseName = "MyDatabase"              # Database name to backup
$SQLServerInstance = "MSSQLSERVER"        # SQL Server instance (MSSQLSERVER for default)
$SQLServerPort = "1433"                   # SQL Server port
$SQLAuthUser = "sa"                       # SQL authentication user
$SQLAuthPassword = "YourSQLPassword"      # SQL Server password
$ExcludeSystemDBs = $true                 # Exclude system databases (model, master, tempdb, msdb)

# NAS Mount Configuration on Windows Server
$NASMountPath = "\\nas-server\sql_backups"  # UNC path to NAS share
```

**How to find SQL Server information on Windows:**
```powershell
# Connect to Windows server
Enter-PSSession -ComputerName windows-server -Credential (Get-Credential)

# Check SQL Server service
Get-Service -Name MSSQLSERVER

# Connect to SQL Server
sqlcmd -S localhost -U sa -P 'YourPassword'

# List databases
SELECT name FROM sys.databases WHERE database_id > 4;
GO

# Check NAS access
Test-Path \\nas-server\sql_backups
```

### 2. AWS EC2 SQL Server Configuration

```powershell
# AWS EC2 SQL Server Configuration
$EC2SQLServerHost = "ec2-12-34-56-78.compute-1.amazonaws.com"  # EC2 instance IP/hostname
$EC2SQLServerPort = "1433"                # SQL Server port
$EC2SQLServerInstance = "MSSQLSERVER"     # SQL Server instance
$EC2SQLAuthUser = "sa"                    # SQL authentication user
$EC2SQLAuthPassword = "YourEC2SQLPassword"  # SQL Server password on EC2
$EC2WindowsUser = "Administrator"         # EC2 Windows username
$EC2WindowsPassword = "YourEC2WinPassword"  # EC2 Windows password

# Restore Configuration
$TargetDatabaseName = "MyDatabase"        # Target database name on EC2
$EC2RestorePath = "C:\SQLBackups"         # Restore path on EC2 instance
```

**How to find your EC2 information:**
1. Go to AWS Console → EC2 → Instances
2. Click on your EC2 instance
3. Copy the "Public IPv4 DNS" or "Public IPv4 address"
4. Ensure Security Group allows:
   - Port 5985 (WinRM HTTP) from your jump box
   - Port 1433 (SQL Server) from your jump box

**Enable PowerShell Remoting on EC2:**
```powershell
# Connect via RDP to EC2, then run:
Enable-PSRemoting -Force
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any

# Or use EC2 User Data script:
<powershell>
Enable-PSRemoting -Force
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any
</powershell>
```

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
# Working Directory on Jump Box
$WorkingDirectory = "D:\SQLMigration"  # Path with sufficient disk space
```

 **Important:** Ensure this drive has enough free space (optional, for fallback scenarios)

---

##  Running the Migration

### Option 1: Interactive Execution

```powershell
# Run the script
.\Migrate-SQLToEC2.ps1

# The script will:
# 1. Test connections
# 2. Backup from Windows SQL Server
# 3. Upload to S3
# 4. Download to EC2 and restore
# 5. Verify data
```

### Option 2: Scheduled Execution

To run the migration during off-peak hours:

```powershell
# Create a scheduled task
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-File C:\path\to\Migrate-SQLToEC2.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At "2:00 AM"
Register-ScheduledTask -TaskName "SQL_Migration" -Action $action -Trigger $trigger
```

### Option 3: Run with Logging

```powershell
# Run with transcript logging
.\Migrate-SQLToEC2.ps1 | Tee-Object -FilePath "migration_log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
```

---

##  What the Script Does

### Step 1: Connection Testing
- Tests PowerShell Remoting to source Windows server
- Tests PowerShell Remoting to EC2 instance
- Verifies AWS CLI configuration
- Checks AWS credentials

### Step 2: Backup from Windows SQL Server
```
SQL Server Database Backup
==========================
Database: MyDatabase
Backup file: \\nas-server\sql_backups\SQLBackup.bak
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

### Step 4: Restore to EC2
```
Downloading backup from S3 to EC2...
Source: s3://bucket-name/sql-backups/SQLBackup.bak
Destination: C:\SQLBackups\SQLBackup.bak
Download successful!

Starting database restore...
Target Database: MyDatabase
...
Database restore completed successfully!
```

### Step 5: Verification
```
Database Info:
DatabaseName  State   RecoveryModel  CompatibilityLevel
------------  -----   -------------  ------------------
MyDatabase    ONLINE  FULL          150

Tables in database:
SchemaName  TableName        RowCount
----------  ---------------  --------
dbo         Customers        15000
dbo         Orders           125000
dbo         Products         5000
```

---

##  Pre-Migration Checklist

- [ ] Windows jump box meets all prerequisites
- [ ] PowerShell Remoting enabled on source Windows server
- [ ] PowerShell Remoting enabled on EC2 instance
- [ ] SQL Server Command-Line Tools installed (sqlcmd)
- [ ] AWS CLI installed and configured
- [ ] Source Windows server accessible via WinRM
- [ ] EC2 instance accessible via WinRM
- [ ] SQL Server running on source Windows server
- [ ] SQL Server running on EC2 instance
- [ ] NAS accessible from source server (UNC path)
- [ ] SQL Server credentials verified (source and EC2)
- [ ] S3 bucket created and accessible
- [ ] AWS CLI configured on EC2 instance
- [ ] Network connectivity tested (WinRM, SQL, S3)
- [ ] Sufficient disk space on NAS
- [ ] Sufficient disk space on EC2 (2x backup size)
- [ ] Script configuration updated with correct values
- [ ] Test WinRM to source: `Test-WSMan -ComputerName windows-server`
- [ ] Test WinRM to EC2: `Test-WSMan -ComputerName ec2-instance`
- [ ] Verify NAS access: `Test-Path \\nas-server\share`
- [ ] Test SQL Server on source: `sqlcmd -S source-server -U sa -P password`
- [ ] Test SQL Server on EC2: `sqlcmd -S ec2-instance -U sa -P password`
- [ ] Test AWS S3 access: `aws s3 ls s3://bucket-name`
- [ ] EC2 Security Group allows WinRM (5985) and SQL (1433)
- [ ] Backup existing data (if any) on EC2
- [ ] Schedule migration during maintenance window
- [ ] Notify stakeholders of migration timeline

---

##  Important Notes

### PowerShell Remoting Setup

Ensure PowerShell Remoting is enabled on both source and target servers:

**On Source Windows Server and EC2:**
```powershell
# Enable PowerShell Remoting
Enable-PSRemoting -Force

# Allow connections from any address (adjust for security)
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress Any

# Or specify specific IPs
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -RemoteAddress 10.0.0.0/8,172.16.0.0/12

# Test from jump box
Test-WSMan -ComputerName <server-name>
```

**For EC2 instances, update Security Group:**
- Inbound rule: Port 5985 (WinRM HTTP) from jump box IP
- Inbound rule: Port 1433 (SQL Server) from application servers

### EC2 SQL Server Setup

Ensure SQL Server is installed and configured on EC2:

1. **Install SQL Server** on EC2 Windows instance
2. **Configure SQL Authentication** (Mixed Mode)
3. **Install AWS CLI** on EC2:
   ```powershell
   # Download and install AWS CLI
   msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi
   
   # Configure AWS CLI
   aws configure
   ```
4. **Create restore directory**: `C:\SQLBackups`

### Database Compatibility

- Ensure source and target SQL Server versions are compatible
- EC2 SQL Server supports all versions (2012, 2014, 2016, 2017, 2019, 2022)
- Backup from higher version cannot restore to lower version
- Consider database compatibility level settings
- **System databases are automatically excluded** (model, master, tempdb, msdb)

### Backup Compression

The script uses `WITH COMPRESSION` for faster backups and smaller file sizes. Ensure:
- SQL Server supports backup compression (Enterprise/Standard editions)
- Sufficient CPU resources during backup on source server

---

##  Additional Resources

- [SQL Server on Windows Documentation](https://docs.microsoft.com/en-us/sql/sql-server/)
- [PowerShell Remoting Documentation](https://docs.microsoft.com/en-us/powershell/scripting/learn/remoting/running-remote-commands)
- [AWS EC2 Windows Documentation](https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/)
- [AWS CLI S3 Commands](https://docs.aws.amazon.com/cli/latest/reference/s3/)
- [SQL Server Backup Documentation](https://docs.microsoft.com/en-us/sql/t-sql/statements/backup-transact-sql)
- [SQL Server Restore Documentation](https://docs.microsoft.com/en-us/sql/t-sql/statements/restore-statements-transact-sql)

---

##  License

This script is provided as-is for database migration purposes. Use at your own risk.

---

##  Critical Reminders

1. **Always test in a non-production environment first**
2. **Backup your data before migration**
3. **Schedule migrations during maintenance windows**
4. **Monitor EC2 SQL Server performance after migration**
5. **Update application connection strings to point to EC2**
6. **Keep the backup files until you verify the migration**
7. **Review and test all database objects after restore**
8. **Check SQL Server Agent jobs, logins, and linked servers separately**
9. **Migrate logins separately** (not included in database backup)
10. **Test application functionality thoroughly after migration**
11. **System databases are automatically excluded** from migration
12. **Configure EC2 SQL Server backups and maintenance plans**
13. **Set up monitoring and alerts for EC2 SQL Server**
14. **Review EC2 Security Groups** and restrict access appropriately

---

**Ready to migrate? Follow the Quick Start guide above!**