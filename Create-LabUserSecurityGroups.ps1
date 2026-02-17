<#
Create-MyCompanyUserSecurityGroups.ps1
Creates a matching set of security groups for the user OUs under:
  OU=Users,OU=MyCompany,<domainDN>

What it creates (by default):
  - One "Users-<Dept>" global security group per department (for access control)
  - One "Users-<Dept>-All" global security group per department (optional alias/umbrella)
  - One "Users-All" global security group (optional)
  - (Optional) One "Users-<Dept>-DL" distribution group if you want mail-style groups later

Notes:
- Groups are NOT placed inside the Users OUs (best practice). They go in:
    OU=Groups,OU=MyCompany,<domainDN>
  and under OU=Security within that.

Safe to re-run: checks for existence.
#>

[CmdletBinding()]
param(
  [string]$CompanyOuName = "MyCompany",

  # Departments to mirror under Users
  [string[]]$Departments = @("Corporate","IT","Finance","HR","Sales","Marketing","Operations"),

  # Group name prefix (keep it consistent; avoid spaces)
  [string]$GroupPrefix = "Users",

  # Also create an "All Users" group
  [switch]$CreateAllUsersGroup,

  # Also create a "-All" umbrella group per department (can be useful if you later nest role groups)
  [switch]$CreatePerDeptUmbrellaGroup,

  # Create matching distribution groups too (off by default)
  [switch]$AlsoCreateDistributionGroups
)

function Assert-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Required module '$Name' not found. Install RSAT AD tools or run on a DC."
  }
  Import-Module $Name -ErrorAction Stop
}

function Get-DomainDn { (Get-ADDomain -ErrorAction Stop).DistinguishedName }

function Get-OuDnOrThrow {
  param([string]$Dn)
  $ou = Get-ADOrganizationalUnit -Identity $Dn -ErrorAction SilentlyContinue
  if (-not $ou) { throw "OU not found: $Dn" }
  $ou.DistinguishedName
}

function Ensure-Group {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][ValidateSet("Global","DomainLocal","Universal")][string]$Scope,
    [Parameter(Mandatory)][ValidateSet("Security","Distribution")][string]$Category,
    [string]$Description
  )

  # Use samAccountName <= 20 chars? (Not strictly required anymore, but still can bite older tooling)
  # We'll auto-trim if needed and ensure uniqueness by appending a short hash.
  $sam = $Name
  if ($sam.Length -gt 20) {
    $hash = ([Math]::Abs($Name.GetHashCode()) % 10000).ToString("0000")
    $sam  = ($Name.Substring(0, 15) + $hash)  # 19 chars max
  }

  $existing = Get-ADGroup -LDAPFilter "(cn=$Name)" -SearchBase $Path -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Verbose "Group exists: $($existing.DistinguishedName)"
    return $existing
  }

  $params = @{
    Name          = $Name
    SamAccountName= $sam
    GroupScope    = $Scope
    GroupCategory = $Category
    Path          = $Path
  }
  if ($Description) { $params["Description"] = $Description }

  $g = New-ADGroup @params -ErrorAction Stop
  Write-Host "Created $Category group ($Scope): $Name"
  return $g
}

try {
  Assert-Module -Name "ActiveDirectory"

  $domainDn = Get-DomainDn

  $usersOuDn   = "OU=Users,OU=$CompanyOuName,$domainDn"
  $secGroupsDn = "OU=Security,OU=Groups,OU=$CompanyOuName,$domainDn"
  $distGroupsDn= "OU=Distribution,OU=Groups,OU=$CompanyOuName,$domainDn"

  # Validate OU paths exist (so failures are obvious)
  $null = Get-OuDnOrThrow -Dn $usersOuDn
  $null = Get-OuDnOrThrow -Dn $secGroupsDn
  if ($AlsoCreateDistributionGroups) { $null = Get-OuDnOrThrow -Dn $distGroupsDn }

  if ($CreateAllUsersGroup) {
    Ensure-Group -Name "$GroupPrefix-All" -Path $secGroupsDn -Scope Global -Category Security `
      -Description "All user accounts (company-wide umbrella group)" | Out-Null
  }

  foreach ($dept in $Departments) {
    # Create a primary per-department security group (recommended)
    $deptGroupName = "$GroupPrefix-$dept"
    Ensure-Group -Name $deptGroupName -Path $secGroupsDn -Scope Global -Category Security `
      -Description "Users in department OU=$dept (access control group)" | Out-Null

    if ($CreatePerDeptUmbrellaGroup) {
      $umbrellaName = "$GroupPrefix-$dept-All"
      $umbrella = Ensure-Group -Name $umbrellaName -Path $secGroupsDn -Scope Global -Category Security `
        -Description "Umbrella group for $dept (nest role groups under this)" 

      # Nest the primary group into the umbrella group (handy pattern)
      Add-ADGroupMember -Identity $umbrella.DistinguishedName -Members $deptGroupName -ErrorAction SilentlyContinue
    }

    if ($AlsoCreateDistributionGroups) {
      Ensure-Group -Name "$GroupPrefix-$dept-DL" -Path $distGroupsDn -Scope Universal -Category Distribution `
        -Description "Distribution group for $dept" | Out-Null
    }
  }

  Write-Host "Done."
  Write-Host "Tip: Use these groups for access control, not OUs."
  Write-Host "     If you later want auto-membership based on OU, that’s a separate (scheduled) sync script."
}
catch {
  Write-Error $_
  throw
}
