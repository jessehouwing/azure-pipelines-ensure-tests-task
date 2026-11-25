$ErrorActionPreference = 'Stop'

$repository = $env:GITHUB_REPOSITORY
$token = $env:GH_TOKEN
$releaseVersion = $env:RELEASE_VERSION
$targetSha = $env:RELEASE_TARGET_SHA
$vsixPath = $env:VSIX_PATH
$zipPath = $env:ZIP_PATH
$vsixAttestationUrl = $env:VSIX_ATTESTATION_URL
$zipAttestationUrl = $env:ZIP_ATTESTATION_URL

if (-not $repository -or -not $token -or -not $releaseVersion -or -not $targetSha) {
  throw 'GITHUB_REPOSITORY, GH_TOKEN, RELEASE_VERSION, and RELEASE_TARGET_SHA are required.'
}
if ($releaseVersion -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
  throw 'RELEASE_VERSION must use X.Y.Z format.'
}
if ($targetSha -notmatch '^[0-9a-f]{40,64}$') {
  throw 'RELEASE_TARGET_SHA must be a Git commit SHA.'
}
foreach ($path in @($vsixPath, $zipPath)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Release asset is missing: $path"
  }
}
if (-not $vsixAttestationUrl -or -not $zipAttestationUrl) {
  throw 'Both attestation URLs are required.'
}

$baseUri = "https://api.github.com/repos/$repository"
$headers = @{
  Authorization = "Bearer $token"
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
}
$encodedTag = [uri]::EscapeDataString($releaseVersion)

function Invoke-GitHubApi {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('GET', 'POST')]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [object]$Body
  )

  $parameters = @{
    Method = $Method
    Uri = "$baseUri/$Path"
    Headers = $headers
    ErrorAction = 'Stop'
  }
  if ($null -ne $Body) {
    $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
    $parameters.ContentType = 'application/json'
  }

  try {
    return Invoke-RestMethod @parameters
  }
  catch {
    $statusCode = 0
    if ($_.Exception.Response) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 404) {
      return $null
    }
    throw "GitHub API request failed ($Method $Path): $($_.Exception.Message)"
  }
}

function Get-Release {
  return Invoke-GitHubApi -Method GET -Path "releases/tags/$encodedTag"
}

function Resolve-TagTarget {
  $tagRef = Invoke-GitHubApi -Method GET -Path "git/ref/tags/$encodedTag"
  if ($null -eq $tagRef) {
    return $null
  }

  $tagObject = $tagRef.object
  if ($tagObject.type -eq 'tag') {
    $tagObject = Invoke-GitHubApi -Method GET -Path "git/tags/$($tagObject.sha)"
    if ($null -eq $tagObject) {
      throw "Could not resolve annotated release tag $releaseVersion."
    }
    $tagObject = $tagObject.object
  }
  if ($tagObject.type -ne 'commit') {
    throw "Release tag $releaseVersion does not point to a commit."
  }
  return [string]$tagObject.sha
}

$release = Get-Release
if ($null -eq $release) {
  $existingTagTarget = Resolve-TagTarget
  if ($existingTagTarget -and $existingTagTarget -ne $targetSha) {
    throw "Release tag $releaseVersion already points to a different commit."
  }

  $provenanceNotes = @"
Build provenance:

- VSIX: $vsixAttestationUrl
- ZIP: $zipAttestationUrl
"@
  $releaseBody = @{
    tag_name = $releaseVersion
    target_commitish = $targetSha
    name = $releaseVersion
    body = $provenanceNotes.Trim()
    draft = $true
    generate_release_notes = $true
  }

  try {
    $release = Invoke-GitHubApi -Method POST -Path 'releases' -Body $releaseBody
  }
  catch {
    $release = Get-Release
    if ($null -eq $release) {
      throw
    }
  }
}

$tagTarget = Resolve-TagTarget
if ($tagTarget -ne $targetSha) {
  throw "Release tag $releaseVersion does not point to the expected source commit."
}

$expectedAssets = @(
  @{ Path = $vsixPath; Name = [IO.Path]::GetFileName($vsixPath) },
  @{ Path = $zipPath; Name = [IO.Path]::GetFileName($zipPath) }
)
$expectedNames = @($expectedAssets | ForEach-Object { $_.Name })
$unexpectedAssets = @($release.assets | Where-Object { $_.name -notin $expectedNames })
if ($unexpectedAssets.Count -gt 0) {
  throw "Draft release contains unexpected assets: $($unexpectedAssets.name -join ', ')."
}

foreach ($asset in $expectedAssets) {
  $matchingAssets = @($release.assets | Where-Object { $_.name -eq $asset.Name })
  if ($matchingAssets.Count -eq 0) {
    if (-not $release.draft) {
      throw "Published release is missing expected asset $($asset.Name)."
    }
    $uploadUrl = $release.upload_url -replace '\{\?name,label\}$', ''
    $encodedName = [uri]::EscapeDataString($asset.Name)
    Invoke-RestMethod `
      -Method POST `
      -Uri ('{0}?name={1}' -f $uploadUrl, $encodedName) `
      -Headers $headers `
      -InFile $asset.Path `
      -ContentType 'application/octet-stream' `
      -ErrorAction Stop | Out-Null
    $release = Get-Release
    $matchingAssets = @($release.assets | Where-Object { $_.name -eq $asset.Name })
  }

  if ($matchingAssets.Count -ne 1 -or -not $matchingAssets[0].digest) {
    throw "Could not verify the SHA-256 digest for release asset $($asset.Name)."
  }
  $expectedDigest = 'sha256:' + (Get-FileHash -LiteralPath $asset.Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($matchingAssets[0].digest.ToLowerInvariant() -ne $expectedDigest) {
    throw "Release asset $($asset.Name) does not match the verified workflow artifact."
  }
}

if ($release.assets.Count -ne $expectedAssets.Count) {
  throw 'Release must contain exactly the verified VSIX and ZIP assets.'
}
if (-not $release.draft) {
  Write-Host "Published release $releaseVersion already matches the verified candidate."
}
