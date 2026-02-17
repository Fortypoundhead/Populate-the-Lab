<#
Populate-LabUsers.ps1

One script to populate an on-prem AD lab with:

1) Realistic department USERS (random names from files)
2) RESOURCE accounts (conference rooms + shared accounts)
3) SERVICE accounts
4) Pre-staged DEVICE objects (computer accounts) in Workstations sub-OUs
5) Optional: Assign Managers (within each department)
6) Optional: Redirect default Users/Computers containers

Designed for Windows PowerShell 5.1 compatibility:

- Fixes "$var:" parsing by using ${var} where needed
- Avoids variable-scope collisions by storing all constants in $Config
- Collision-safe object creation (CN + sAMAccountName uniqueness)

Requirements:

- ActiveDirectory module (RSAT) available

- Your OU structure exists (from earlier OU script):
    OU=MyCompany
      OU=Users
        OU=Corporate/IT/Finance/HR/Sales/Marketing/Operations
      OU=Groups
        OU=Security
        OU=Distribution (optional)
      OU=Computers
        OU=Workstations
          OU=Corporate
          OU=IT
          OU=Finance
          OU=Kiosks
      OU=ServiceAccounts

This script will also create (if missing):

    OU=Resources
      OU=Rooms
      OU=Shared

Security group expectations (from Create-MyCompanyUserSecurityGroups.ps1):

    Users-Corporate
    Users-IT
    Users-Finance
    Users-HR
    Users-Sales
    Users-Marketing
    Users-Operations

Outputs:

- CSV in the current directory with created objects (includes passwords for users/resources/service accounts)

Examples:
  # All three categories + devices
  .\Populate-LabUsers.ps1 -CompanyOuName MyCompany -UserCount 500 -RoomCount 25 -SharedCount 10 -ServiceAccountCount 20 -DeviceCount 500

  # Add manager assignments
  .\Populate-LabUsers.ps1 -UserCount 200 -AssignManagers

  # WhatIf dry run
  .\Populate-LabUsers.ps1 -UserCount 30 -RoomCount 5 -SharedCount 3 -ServiceAccountCount 5 -DeviceCount 20 -WhatIf

  # Also redirect default containers (optional)
  .\Populate-LabUsers.ps1 -UserCount 50 -RedirectDefaultContainers
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [string]$CompanyOuName = "MyCompany",

  # Inputs
  [string]$SurnameFile     = ".\names-surnames.txt",
  [string]$FemaleFirstFile = ".\names-first-female.txt",
  [string]$MaleFirstFile   = ".\names-first-male.txt",

  # Counts
  [int]$UserCount = 50,
  [int]$RoomCount = 6,
  [int]$SharedCount = 6,
  [int]$ServiceAccountCount = 8,
  [int]$DeviceCount = 30,

  # User realism knobs
  [int]$FemalePercent = 50,
  [switch]$RequireUniqueDisplayNames,
  [int]$MaxUniqueNameAttempts = 20,

  # Optional behavior
  [switch]$AssignManagers,
  [int]$ManagerPercent = 12,
  [switch]$DisableRoomAccounts,
  [switch]$DisableSharedAccounts,
  [switch]$DisableServiceAccounts,
  [switch]$CreateSvcGroupsAndNest,
  [switch]$RedirectDefaultContainers,

  # Device knobs
  [int]$LaptopPercent = 55,
  [int]$KioskPercent  = 10,
  [string]$LaptopPrefix = "LAP",
  [string]$DesktopPrefix= "DESK",
  [string]$KioskPrefix  = "KIOSK",

  # Identity defaults
  [string]$Company = "MyCompany",
  [string]$GroupPrefix = "Users",
  [int]$PasswordLength = 16,
  [string]$EmailDomain = "",
  [string]$UPNSuffix   = ""
)

# -----------------------------
# Helpers
# -----------------------------
function Assert-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Required module '$Name' not found. Install RSAT AD tools or run on a DC."
  }
  Import-Module $Name -ErrorAction Stop
}

function Read-NameFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^\s*#' }
  if (-not $lines -or $lines.Count -lt 5) { throw "File '$Path' has too few usable entries." }
  return $lines
}

function Ensure-OU {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ParentDn,
    [string]$Description
  )
  $dn = "OU=$Name,$ParentDn"
  $existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue
  if ($existing) { return $dn }

  $p = @{
    Name=$Name
    Path=$ParentDn
    ProtectedFromAccidentalDeletion=$true
  }
  if ($Description) { $p.Description = $Description }
  New-ADOrganizationalUnit @p | Out-Null
  Write-Host "Created OU: $dn"
  return $dn
}

function Normalize-NamePart {
  param([string]$s)
  ($s -replace "[^A-Za-z]", "")
}

function Get-RandomPassword {
  param([int]$Length = 16)
  $lower = "abcdefghijkmnopqrstuvwxyz"
  $upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  $digit = "23456789"
  $sym   = "!@#$%&*?-_+"

  $all = ($lower + $upper + $digit + $sym).ToCharArray()

  $chars = @()
  $chars += ($lower.ToCharArray() | Get-Random -Count 4)
  $chars += ($upper.ToCharArray() | Get-Random -Count 4)
  $chars += ($digit.ToCharArray() | Get-Random -Count 4)
  $chars += ($sym.ToCharArray()   | Get-Random -Count 2)

  $remaining = [Math]::Max(0, $Length - $chars.Count)
  if ($remaining -gt 0) { $chars += ($all | Get-Random -Count $remaining) }

  -join ($chars | Get-Random -Count $chars.Count)
}

function Get-UniqueSamForUser {
  param([Parameter(Mandatory)][string]$BaseSam)

  $base = $BaseSam.ToLower()
  if ($base.Length -gt 20) { $base = $base.Substring(0,20) }

  $sam = $base
  $i = 2
  while (Get-ADUser -LDAPFilter "(sAMAccountName=$sam)" -ErrorAction SilentlyContinue) {
    $suffix = "$i"
    $maxBaseLen = 20 - $suffix.Length
    $trimmed = $base
    if ($trimmed.Length -gt $maxBaseLen) { $trimmed = $trimmed.Substring(0, $maxBaseLen) }
    $sam = ($trimmed + $suffix)
    $i++
    if ($i -gt 999) { throw "Could not find unique sAMAccountName for base '$BaseSam'." }
  }
  return $sam
}

function Get-UniqueCnInOu {
  param(
    [Parameter(Mandatory)][string]$BaseCn,
    [Parameter(Mandatory)][string]$SearchBaseDn
  )
  # Fast check via LDAPFilter on CN within the OU
  $exists = Get-ADObject -LDAPFilter "(cn=$BaseCn)" -SearchBase $SearchBaseDn -ErrorAction SilentlyContinue
  if (-not $exists) { return $BaseCn }

  for ($i = 2; $i -le 2000; $i++) {
    $cn = "$BaseCn-$i"
    $exists2 = Get-ADObject -LDAPFilter "(cn=$cn)" -SearchBase $SearchBaseDn -ErrorAction SilentlyContinue
    if (-not $exists2) { return $cn }
  }
  throw "Could not find a unique CN under $SearchBaseDn for base '$BaseCn'."
}

function Ensure-Group {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$PathDn,
    [ValidateSet("Global","DomainLocal","Universal")][string]$Scope = "Global",
    [ValidateSet("Security","Distribution")][string]$Category = "Security",
    [string]$Description
  )
  $existing = Get-ADGroup -LDAPFilter "(cn=$Name)" -SearchBase $PathDn -ErrorAction SilentlyContinue
  if ($existing) { return $existing }

  $sam = $Name
  if ($sam.Length -gt 20) {
    $hash = ([Math]::Abs($Name.GetHashCode()) % 10000).ToString("0000")
    $sam  = ($Name.Substring(0, 15) + $hash)
  }

  $p = @{
    Name=$Name
    SamAccountName=$sam
    GroupScope=$Scope
    GroupCategory=$Category
    Path=$PathDn
  }
  if ($Description) { $p.Description = $Description }
  New-ADGroup @p -ErrorAction Stop
}

function Get-RandomStreetAddress {
  $streetNames = @("Main","Oak","Pine","Cedar","Maple","Park","Lake","Hill","Sunset","Ridge","Washington","Jefferson","Lincoln","Adams","Madison","Jackson","Franklin")
  $streetTypes = @("St","Ave","Blvd","Rd","Ln","Dr","Way","Ct")
  $num = Get-Random -Minimum 100 -Maximum 9999
  "$num $($streetNames | Get-Random) $($streetTypes | Get-Random)"
}

function ComputerExistsByCn {
  param([string]$Name)
  $obj = Get-ADComputer -LDAPFilter "(cn=$Name)" -ErrorAction SilentlyContinue
  return [bool]$obj
}

function New-ComputerIfMissing {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$PathDn,
    [string]$Description
  )
  if (ComputerExistsByCn -Name $Name) { return $false }
  New-ADComputer -Name $Name -SamAccountName ($Name + '$') -Path $PathDn -Description $Description -Enabled $true -ErrorAction Stop
  return $true
}

function Get-DeptAbbrev {
  param([string]$Dept)
  switch ($Dept.ToUpperInvariant()) {
    "CORPORATE" { "CORP" }
    "FINANCE"   { "FIN" }
    default     { $Dept.ToUpperInvariant() }
  }
}

# -----------------------------
# Main
# -----------------------------
try {
  Assert-Module -Name "ActiveDirectory"

  $domain   = Get-ADDomain -ErrorAction Stop
  $domainDn = $domain.DistinguishedName
  $dnsRoot  = $domain.DNSRoot

  if (-not $EmailDomain) { $EmailDomain = $dnsRoot }
  if (-not $UPNSuffix)   { $UPNSuffix   = $dnsRoot }

  # Config object prevents accidental variable collisions across sections
  $Config = @{
    Company = $Company
    PasswordLength = $PasswordLength
    GroupPrefix = $GroupPrefix

    Departments = @("Corporate","IT","Finance","HR","Sales","Marketing","Operations")

    TitlesByDept = @{
      Corporate  = @("Executive Assistant","Office Coordinator","Project Coordinator","Business Analyst","Operations Analyst")
      IT         = @("Helpdesk Technician","Systems Administrator","Windows Engineer","Network Administrator","Security Analyst","IT Support Specialist")
      Finance    = @("Staff Accountant","Accounts Payable Specialist","Accounts Receivable Specialist","Payroll Specialist","Financial Analyst")
      HR         = @("HR Generalist","Recruiter","People Operations Specialist","Benefits Coordinator","HR Coordinator")
      Sales      = @("Account Executive","Sales Development Rep","Sales Operations Specialist","Account Manager","Customer Solutions Rep")
      Marketing  = @("Marketing Specialist","Content Coordinator","Digital Marketing Specialist","SEO Specialist","Brand Coordinator")
      Operations = @("Operations Specialist","Facilities Coordinator","Logistics Coordinator","Service Coordinator","Implementation Specialist")
    }

    Offices = @(
      [pscustomobject]@{ Office="HQ - Everett";     City="Everett";     State="WA"; PostalCode="98201"; PhoneArea="425" },
      [pscustomobject]@{ Office="Seattle Office";   City="Seattle";     State="WA"; PostalCode="98101"; PhoneArea="206" },
      [pscustomobject]@{ Office="Bellevue Office";  City="Bellevue";    State="WA"; PostalCode="98004"; PhoneArea="425" },
      [pscustomobject]@{ Office="Redmond Office";   City="Redmond";     State="WA"; PostalCode="98052"; PhoneArea="425" },
      [pscustomobject]@{ Office="Portland Office";  City="Portland";    State="OR"; PostalCode="97205"; PhoneArea="503" }
    )

    RoomPools = @{
      Buildings = @("A","B","C")
      Types     = @("Conf","Huddle","Training")
      Caps      = @(4,6,8,10,12,16,20)
    }

    SharedPools = @{
      Names = @("Reception","FrontDesk","Facilities","IT-Dispatch","Helpdesk","Training","HR-Shared","Finance-Shared","Marketing-Shared","Sales-Shared")
    }

    ServicePools = @{
      Names = @("Backup","Patch","Monitoring","SQLAgent","WebApp","FileSync","Automation","Deploy","Reporting","AppPool","Ingest","Scheduler","Inventory","PKI","SFTP")
    }

    DevicePools = @{
      AllowedDeptsForWorkstations = @("Corporate","IT","Finance") # matches OU layout
      LaptopPercent = $LaptopPercent
      KioskPercent  = $KioskPercent
      LaptopPrefix  = $LaptopPrefix
      DesktopPrefix = $DesktopPrefix
      KioskPrefix   = $KioskPrefix
    }
  }

  # DN roots
  $companyRootDn = "OU=$CompanyOuName,$domainDn"
  $usersRootDn   = "OU=Users,$companyRootDn"
  $groupsSecDn   = "OU=Security,OU=Groups,$companyRootDn"
  $svcOuDn       = "OU=ServiceAccounts,$companyRootDn"
  $computersRootDn = "OU=Computers,$companyRootDn"
  $workstationsDn  = "OU=Workstations,$computersRootDn"

  # Validate expected OUs exist
  $null = Get-ADOrganizationalUnit -Identity $companyRootDn     -ErrorAction Stop
  $null = Get-ADOrganizationalUnit -Identity $usersRootDn       -ErrorAction Stop
  $null = Get-ADOrganizationalUnit -Identity $groupsSecDn       -ErrorAction Stop
  $null = Get-ADOrganizationalUnit -Identity $svcOuDn           -ErrorAction Stop
  $null = Get-ADOrganizationalUnit -Identity $workstationsDn    -ErrorAction Stop

  # Ensure Resources subtree exists
  $resourcesDn = Ensure-OU -Name "Resources" -ParentDn $companyRootDn -Description "Resource accounts (rooms/shared)"
  $roomsDn     = Ensure-OU -Name "Rooms"     -ParentDn $resourcesDn   -Description "Conference rooms"
  $sharedDn    = Ensure-OU -Name "Shared"    -ParentDn $resourcesDn   -Description "Shared accounts"

  # Workstation sub-OUs (must exist per earlier OU script)
  $wsOuMap = @{
    Corporate = "OU=Corporate,$workstationsDn"
    IT        = "OU=IT,$workstationsDn"
    Finance   = "OU=Finance,$workstationsDn"
    Kiosks    = "OU=Kiosks,$workstationsDn"
  }
  foreach ($k in $wsOuMap.Keys) {
    if (-not (Get-ADOrganizationalUnit -Identity $wsOuMap[$k] -ErrorAction SilentlyContinue)) {
      throw "Required Workstations OU not found: $($wsOuMap[$k])"
    }
  }

  # Read name files
  $Surnames    = Read-NameFile -Path $SurnameFile
  $FemaleFirst = Read-NameFile -Path $FemaleFirstFile
  $MaleFirst   = Read-NameFile -Path $MaleFirstFile

  # Validate dept OUs and groups
  $DeptGroups = @{}
  foreach ($dept in $Config.Departments) {
    $deptOuDn = "OU=$dept,$usersRootDn"
    if (-not (Get-ADOrganizationalUnit -Identity $deptOuDn -ErrorAction SilentlyContinue)) {
      throw "Required Users OU not found: $deptOuDn"
    }
    $gName = "$($Config.GroupPrefix)-$dept"
    if (-not (Get-ADGroup -Identity $gName -ErrorAction SilentlyContinue)) {
      throw "Required security group not found: $gName"
    }
    $DeptGroups[$dept] = $gName
  }

  # Optional: service groups
  if ($CreateSvcGroupsAndNest) {
    Ensure-Group -Name "Svc-Accounts-All"   -PathDn $groupsSecDn -Description "All service accounts" | Out-Null
    Ensure-Group -Name "Svc-Accounts-App"   -PathDn $groupsSecDn -Description "Application service accounts" | Out-Null
    Ensure-Group -Name "Svc-Accounts-Infra" -PathDn $groupsSecDn -Description "Infrastructure service accounts" | Out-Null
  }

  # Created objects tracking
  $Created = New-Object System.Collections.Generic.List[object]
  $SeenDisplayNames = New-Object 'System.Collections.Generic.HashSet[string]'

  # -----------------------------
  # OPTION 1: USERS
  # -----------------------------
  for ($i = 1; $i -le $UserCount; $i++) {
    $attempts = 0
    do {
      $attempts++
      $isFemale = ((Get-Random -Minimum 1 -Maximum 101) -le $FemalePercent)
      $firstRaw = if ($isFemale) { $FemaleFirst | Get-Random } else { $MaleFirst | Get-Random }
      $lastRaw  = $Surnames | Get-Random

      $first = $firstRaw.Trim()
      $last  = $lastRaw.Trim()
      $displayName = "$first $last"

      $okDisplay = $true
      if ($RequireUniqueDisplayNames) { $okDisplay = $SeenDisplayNames.Add($displayName) }
    } while (-not $okDisplay -and $attempts -lt $MaxUniqueNameAttempts)

    $firstNorm = Normalize-NamePart $first
    $lastNorm  = Normalize-NamePart $last
    if (-not $firstNorm -or -not $lastNorm) { $i--; continue }

    $baseSam = ($firstNorm.Substring(0,1) + $lastNorm).ToLower()
    $sam = Get-UniqueSamForUser -BaseSam $baseSam

    $dept = $Config.Departments | Get-Random
    $targetOuDn = "OU=$dept,$usersRootDn"
    $groupName = $DeptGroups[$dept]

    $titlePool = $null
    if ($Config.TitlesByDept.ContainsKey($dept)) { $titlePool = $Config.TitlesByDept[$dept] }
    if (-not $titlePool -or $titlePool.Count -eq 0) { $titlePool = @("Employee") }
    $title = $titlePool | Get-Random

    $office = $Config.Offices | Get-Random
    $street = Get-RandomStreetAddress
    $phone  = "{0}-{1:D3}-{2:D4}" -f $office.PhoneArea, (Get-Random -Minimum 200 -Maximum 999), (Get-Random -Minimum 0 -Maximum 9999)

    $upn   = "$sam@$UPNSuffix"
    $email = "$sam@$EmailDomain"
    $pwPlain  = Get-RandomPassword -Length $Config.PasswordLength
    $pwSecure = ConvertTo-SecureString $pwPlain -AsPlainText -Force
    $employeeId = (Get-Random -Minimum 100000 -Maximum 999999).ToString()

    if ($PSCmdlet.ShouldProcess($displayName, "Create user in $dept and add to $groupName")) {
      New-ADUser `
        -Name $displayName `
        -GivenName $first `
        -Surname $last `
        -DisplayName $displayName `
        -SamAccountName $sam `
        -UserPrincipalName $upn `
        -EmailAddress $email `
        -Company $Config.Company `
        -Department $dept `
        -Title $title `
        -Office $office.Office `
        -City $office.City `
        -State $office.State `
        -PostalCode $office.PostalCode `
        -StreetAddress $street `
        -OfficePhone $phone `
        -EmployeeID $employeeId `
        -Description "$($Config.Company) lab user ($dept) - created $(Get-Date -Format 'yyyy-MM-dd')" `
        -Path $targetOuDn `
        -AccountPassword $pwSecure `
        -Enabled $true `
        -ChangePasswordAtLogon $false `
        -PasswordNeverExpires $true `
        -ErrorAction Stop

      Add-ADGroupMember -Identity $groupName -Members $sam -ErrorAction Stop

      $potentialMgr = ((Get-Random -Minimum 1 -Maximum 101) -le $ManagerPercent)

      $Created.Add([pscustomobject]@{
        ObjectType="User"; Name=$displayName; SamAccountName=$sam; UPN=$upn; Dept=$dept; Title=$title;
        Office=$office.Office; City=$office.City; State=$office.State; Group=$groupName; Password=$pwPlain; Path=$targetOuDn;
        PotentialManager=$potentialMgr
      }) | Out-Null
    }
  }

  # Optional manager assignment
  if ($AssignManagers -and -not $WhatIfPreference) {
    Write-Host "Assigning managers..."
    foreach ($dept in $Config.Departments) {
      $deptUsers = $Created | Where-Object { $_.ObjectType -eq "User" -and $_.Dept -eq $dept }
      if (-not $deptUsers -or $deptUsers.Count -lt 3) { continue }

      $mgrPool = $deptUsers | Where-Object { $_.PotentialManager -eq $true }
      if (-not $mgrPool -or $mgrPool.Count -lt 1) {
        $mgrPool = $deptUsers | Get-Random -Count ([Math]::Min(2, $deptUsers.Count))
      }

      foreach ($u in $deptUsers) {
        if ($mgrPool.SamAccountName -contains $u.SamAccountName) { continue }
        $mgr = $mgrPool | Get-Random
        try { Set-ADUser -Identity $u.SamAccountName -Manager $mgr.SamAccountName -ErrorAction Stop }
        catch { Write-Warning "Could not set manager for ${($u.SamAccountName)}: $($_.Exception.Message)" }
      }
    }
  }

  # -----------------------------
  # OPTION 2: RESOURCES (Rooms + Shared)
  # -----------------------------
  # Rooms
  for ($r = 1; $r -le $RoomCount; $r++) {
    $attempt = 0
    $createdRoom = $false

    while (-not $createdRoom -and $attempt -lt 2000) {
      $attempt++
      $b = $Config.RoomPools.Buildings | Get-Random
      $t = $Config.RoomPools.Types     | Get-Random
      $num = Get-Random -Minimum 101 -Maximum 399
      $cap = $Config.RoomPools.Caps    | Get-Random

      $roomDisplay = "{0} {1}-{2} ({3})" -f $t, $b, $num, $cap
      $roomCnBase = "Room-$t-$b-$num"
      $roomCn = Get-UniqueCnInOu -BaseCn $roomCnBase -SearchBaseDn $roomsDn

      $baseSam = ("rm{0}{1}{2}" -f $t.Substring(0,1).ToLower(), $b.ToLower(), $num)
      $roomSam = Get-UniqueSamForUser -BaseSam $baseSam

      $pwPlain  = Get-RandomPassword -Length $Config.PasswordLength
      $pwSecure = ConvertTo-SecureString $pwPlain -AsPlainText -Force

      try {
        if ($PSCmdlet.ShouldProcess($roomDisplay, "Create room account")) {
          New-ADUser `
            -Name $roomCn `
            -DisplayName $roomDisplay `
            -SamAccountName $roomSam `
            -UserPrincipalName "$roomSam@$UPNSuffix" `
            -EmailAddress "$roomSam@$EmailDomain" `
            -Company $Config.Company `
            -Department "Resources" `
            -Title "Room" `
            -Office "Resources" `
            -Description "Room resource: $roomDisplay; Capacity=$cap" `
            -Path $roomsDn `
            -AccountPassword $pwSecure `
            -Enabled (-not $DisableRoomAccounts) `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false `
            -ErrorAction Stop
        }

        $Created.Add([pscustomobject]@{
          ObjectType="Room"; Name=$roomDisplay; SamAccountName=$roomSam; UPN="$roomSam@$UPNSuffix"; Dept="Resources";
          Title="Room"; Office="Resources"; Group=""; Password=$pwPlain; Path=$roomsDn
        }) | Out-Null

        $createdRoom = $true
      }
      catch {
        if ($_.Exception.Message -match "name that is already in use") { continue }
        throw
      }
    }

    if (-not $createdRoom) { throw "Could not create a unique room account after many attempts (iteration $r)." }
  }

  # Shared accounts
  for ($s = 1; $s -le $SharedCount; $s++) {
    $sharedLabel = $Config.SharedPools.Names | Get-Random
    $cnBase = "Shared-$sharedLabel"
    $cn = Get-UniqueCnInOu -BaseCn $cnBase -SearchBaseDn $sharedDn

    $baseSam = ("shr{0}{1}" -f (Normalize-NamePart $sharedLabel).ToLower(), (Get-Random -Minimum 1 -Maximum 99))
    $sharedSam = Get-UniqueSamForUser -BaseSam $baseSam

    $pwPlain  = Get-RandomPassword -Length $Config.PasswordLength
    $pwSecure = ConvertTo-SecureString $pwPlain -AsPlainText -Force

    if ($PSCmdlet.ShouldProcess($cn, "Create shared account")) {
      New-ADUser `
        -Name $cn `
        -DisplayName $cn `
        -SamAccountName $sharedSam `
        -UserPrincipalName "$sharedSam@$UPNSuffix" `
        -EmailAddress "$sharedSam@$EmailDomain" `
        -Company $Config.Company `
        -Department "Resources" `
        -Title "Shared Account" `
        -Office "Resources" `
        -Description "Shared resource account: $sharedLabel" `
        -Path $sharedDn `
        -AccountPassword $pwSecure `
        -Enabled (-not $DisableSharedAccounts) `
        -PasswordNeverExpires $true `
        -ChangePasswordAtLogon $false `
        -ErrorAction Stop

      $Created.Add([pscustomobject]@{
        ObjectType="Shared"; Name=$cn; SamAccountName=$sharedSam; UPN="$sharedSam@$UPNSuffix"; Dept="Resources";
        Title="Shared Account"; Office="Resources"; Group=""; Password=$pwPlain; Path=$sharedDn
      }) | Out-Null
    }
  }

  # -----------------------------
  # OPTION 3: SERVICE ACCOUNTS
  # -----------------------------
  for ($x = 1; $x -le $ServiceAccountCount; $x++) {
    $svc = $Config.ServicePools.Names | Get-Random
    $n = Get-Random -Minimum 1 -Maximum 50

    $raw = "svc-$svc$n"
    $base = Normalize-NamePart $raw
    if (-not $base) { $base = "svc$svc$n" }
    if (-not $base.ToLower().StartsWith("svc")) { $base = "svc$base" }

    $svcSam = Get-UniqueSamForUser -BaseSam $base
    $pwPlain  = Get-RandomPassword -Length $Config.PasswordLength
    $pwSecure = ConvertTo-SecureString $pwPlain -AsPlainText -Force

    if ($PSCmdlet.ShouldProcess($svcSam, "Create service account")) {
      New-ADUser `
        -Name $svcSam `
        -DisplayName "Service Account - $svc ($svcSam)" `
        -SamAccountName $svcSam `
        -UserPrincipalName "$svcSam@$UPNSuffix" `
        -Company $Config.Company `
        -Department "ServiceAccounts" `
        -Title "Service Account" `
        -Description "Lab service account for $svc. Created $(Get-Date -Format 'yyyy-MM-dd')." `
        -Path $svcOuDn `
        -AccountPassword $pwSecure `
        -Enabled (-not $DisableServiceAccounts) `
        -PasswordNeverExpires $true `
        -ChangePasswordAtLogon $false `
        -CannotChangePassword $true `
        -ErrorAction Stop

      if ($CreateSvcGroupsAndNest) {
        try {
          Add-ADGroupMember -Identity "Svc-Accounts-All" -Members $svcSam -ErrorAction Stop
          if ($svc -in @("Backup","Patch","Monitoring","PKI","Inventory")) {
            Add-ADGroupMember -Identity "Svc-Accounts-Infra" -Members $svcSam -ErrorAction Stop
          } else {
            Add-ADGroupMember -Identity "Svc-Accounts-App" -Members $svcSam -ErrorAction Stop
          }
        } catch {
          Write-Warning "Group add failed for ${svcSam}: $($_.Exception.Message)"
        }
      }

      $Created.Add([pscustomobject]@{
        ObjectType="ServiceAccount"; Name=$svcSam; SamAccountName=$svcSam; UPN="$svcSam@$UPNSuffix"; Dept="ServiceAccounts";
        Title="Service Account"; Office=""; Group=$(if($CreateSvcGroupsAndNest){"Svc-Accounts-All (+ App/Infra)"}else{""}); Password=$pwPlain; Path=$svcOuDn
      }) | Out-Null
    }
  }

  # -----------------------------
  # DEVICES: Computer objects (pre-staged)
  # -----------------------------
  # Create a picker array with the requested ratios, then shuffle
  $lCount = [int][Math]::Round($DeviceCount * ($Config.DevicePools.LaptopPercent/100.0))
  $kCount = [int][Math]::Round($DeviceCount * ($Config.DevicePools.KioskPercent/100.0))
  $dCount = [Math]::Max(0, $DeviceCount - $lCount - $kCount)

  $typePicker = @()
  if ($lCount -gt 0) { $typePicker += @($Config.DevicePools.LaptopPrefix)  * $lCount }
  if ($dCount -gt 0) { $typePicker += @($Config.DevicePools.DesktopPrefix) * $dCount }
  if ($kCount -gt 0) { $typePicker += @($Config.DevicePools.KioskPrefix)   * $kCount }

  if (-not $typePicker -or $typePicker.Count -eq 0) { $typePicker = @($Config.DevicePools.DesktopPrefix) * $DeviceCount }
  $typePicker = $typePicker | Get-Random -Count $typePicker.Count

  $serial = 1
  foreach ($dtype in $typePicker) {
    $deptForName = if ($dtype -eq $Config.DevicePools.KioskPrefix) { "Corporate" } else { ($Config.DevicePools.AllowedDeptsForWorkstations | Get-Random) }
    $deptTag = Get-DeptAbbrev -Dept $deptForName
    $ouDn = if ($dtype -eq $Config.DevicePools.KioskPrefix) { $wsOuMap["Kiosks"] } else { $wsOuMap[$deptForName] }

    $tries = 0
    do {
      $tries++
      $num = "{0:D3}" -f $serial
      $compName = "$dtype-$deptTag-$num"
      $serial++
      if ($serial -gt 999) { $serial = 1 }
      if ($tries -gt 5000) { throw "Too many attempts finding unique computer names." }
    } while (ComputerExistsByCn -Name $compName)

    $desc = "Lab device ($dtype) for $deptForName; pre-staged $(Get-Date -Format 'yyyy-MM-dd')"

    if ($PSCmdlet.ShouldProcess($compName, "Create computer object in $ouDn")) {
      $made = New-ComputerIfMissing -Name $compName -PathDn $ouDn -Description $desc
      if ($made) {
        $Created.Add([pscustomobject]@{
          ObjectType="Computer"; Name=$compName; SamAccountName=($compName + '$'); UPN=""; Dept=$deptForName;
          Title=""; Office=""; Group=""; Password=""; Path=$ouDn
        }) | Out-Null
      }
    }
  }

  # -----------------------------
  # Optional: Redirect default containers
  # -----------------------------
  if ($RedirectDefaultContainers -and -not $WhatIfPreference) {
    $redirComputers = "OU=Workstations,OU=Computers,OU=$CompanyOuName,$domainDn"
    $redirUsers     = "OU=Corporate,OU=Users,OU=$CompanyOuName,$domainDn"
    & redircmp $redirComputers | Out-Null
    & redirusr $redirUsers     | Out-Null
    Write-Host "Redirected default containers:"
    Write-Host "  Computers -> $redirComputers"
    Write-Host "  Users     -> $redirUsers"
  }

  # Export CSV (includes passwords for User/Room/Shared/ServiceAccount)
  $csvPath = Join-Path -Path (Get-Location) -ChildPath ("lab-objects-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
  $Created | Export-Csv -NoTypeInformation -Path $csvPath -Encoding UTF8

  Write-Host ""
  Write-Host "Done."
  Write-Host ("  Users:            {0}" -f (($Created | Where-Object ObjectType -eq "User").Count))
  Write-Host ("  Room accounts:    {0}" -f (($Created | Where-Object ObjectType -eq "Room").Count))
  Write-Host ("  Shared accounts:  {0}" -f (($Created | Where-Object ObjectType -eq "Shared").Count))
  Write-Host ("  Service accounts: {0}" -f (($Created | Where-Object ObjectType -eq "ServiceAccount").Count))
  Write-Host ("  Computers:        {0}" -f (($Created | Where-Object ObjectType -eq "Computer").Count))
  Write-Host ""
  Write-Host "CSV export (includes passwords for users/resources/service accounts): $csvPath"
}
catch {
  Write-Error $_
  throw
}
