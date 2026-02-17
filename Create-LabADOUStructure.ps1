<#
Build-MyCompanyAdOuStructure.ps1
Creates an OU structure under OU=MyCompany in the current domain.

Run as: Domain Admin (or equivalent rights to create OUs).
Safe to re-run: it checks for existence before creating.

Tip: If you're in a fresh lab and want new objects to land in your OUs:
  redircmp "OU=Workstations,OU=Computers,OU=MyCompany,DC=corp,DC=company,DC=com"
  redirusr "OU=Corporate,OU=Users,OU=MyCompany,DC=corp,DC=company,DC=com"
#>

[CmdletBinding()]
param(
  # Top-level OU name
  [string]$CompanyOuName = "MyCompany",

  # If set, also redirects default containers for new computers/users
  [switch]$RedirectDefaultContainers
)

function Assert-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Required module '$Name' not found. Install RSAT AD tools or run on a DC."
  }
  Import-Module $Name -ErrorAction Stop
}

function Get-DomainDn {
  (Get-ADDomain -ErrorAction Stop).DistinguishedName
}

function Ensure-OU {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$ParentDn,
    [string]$Description
  )

  $dn = "OU=$Name,$ParentDn"

  $existing = Get-ADOrganizationalUnit -LDAPFilter "(distinguishedName=$dn)" -ErrorAction SilentlyContinue
  if ($null -ne $existing) {
    Write-Verbose "OU exists: $dn"
    return $dn
  }

  $params = @{
    Name        = $Name
    Path        = $ParentDn
    ProtectedFromAccidentalDeletion = $true
  }
  if ($Description) { $params["Description"] = $Description }

  New-ADOrganizationalUnit @params | Out-Null
  Write-Host "Created OU: $dn"
  return $dn
}

try {
  Assert-Module -Name "ActiveDirectory"

  $domainDn = Get-DomainDn
  Write-Host "Domain DN: $domainDn"

  # Root: OU=MyCompany,DC=...
  $companyDn = Ensure-OU -Name $CompanyOuName -ParentDn $domainDn -Description "Lab OU root for $CompanyOuName"

  # Level 1
  $usersDn           = Ensure-OU -Name "Users"           -ParentDn $companyDn -Description "User accounts"
  $computersDn       = Ensure-OU -Name "Computers"       -ParentDn $companyDn -Description "Computer accounts"
  $serviceAccountsDn = Ensure-OU -Name "ServiceAccounts" -ParentDn $companyDn -Description "Service and managed accounts"
  $groupsDn          = Ensure-OU -Name "Groups"          -ParentDn $companyDn -Description "AD groups"
  $adminDn           = Ensure-OU -Name "Admin"           -ParentDn $companyDn -Description "Privileged/admin objects"

  # Users children
  foreach ($dept in @("Corporate","IT","Finance","HR","Sales","Marketing","Operations")) {
    Ensure-OU -Name $dept -ParentDn $usersDn -Description "Users - $dept" | Out-Null
  }

  # Computers children
  $workstationsDn = Ensure-OU -Name "Workstations" -ParentDn $computersDn -Description "End-user workstations"
  $serversDn      = Ensure-OU -Name "Servers"      -ParentDn $computersDn -Description "Server computer accounts"
  $vdiDn          = Ensure-OU -Name "VDI"          -ParentDn $computersDn -Description "Virtual desktops (optional)"

  # Workstations children
  foreach ($w in @("Corporate","IT","Finance","Kiosks")) {
    Ensure-OU -Name $w -ParentDn $workstationsDn -Description "Workstations - $w" | Out-Null
  }

  # Servers children
  foreach ($s in @("DomainControllers","FileServers","SQL","Web","App")) {
    Ensure-OU -Name $s -ParentDn $serversDn -Description "Servers - $s" | Out-Null
  }

  # Groups children
  Ensure-OU -Name "Security"     -ParentDn $groupsDn -Description "Security groups"     | Out-Null
  Ensure-OU -Name "Distribution" -ParentDn $groupsDn -Description "Distribution groups" | Out-Null

  # Admin children (tiering)
  Ensure-OU -Name "PrivilegedUsers" -ParentDn $adminDn -Description "Highly privileged user accounts" | Out-Null
  foreach ($t in @("Tier0","Tier1","Tier2")) {
    Ensure-OU -Name $t -ParentDn $adminDn -Description "Admin tier - $t" | Out-Null
  }

  if ($RedirectDefaultContainers) {
    $redirComputers = "OU=Workstations,OU=Computers,OU=$CompanyOuName,$domainDn"
    $redirUsers     = "OU=Corporate,OU=Users,OU=$CompanyOuName,$domainDn"

    Write-Host "Redirecting default containers..."
    & redircmp $redirComputers | Out-Null
    & redirusr $redirUsers     | Out-Null
    Write-Host "Default containers redirected:"
    Write-Host "  Computers -> $redirComputers"
    Write-Host "  Users     -> $redirUsers"
  }

  Write-Host "Done."
}
catch {
  Write-Error $_
  throw
}
