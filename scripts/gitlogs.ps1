
param(
    [string[]]$RepoPaths = @("."),
    [string]$Since = "",
    [string]$Until = ""
)

# --- Developer LOC per Branch ---
$devLocCsv = @("Repo,Branch,Author,Added,Deleted,Net,Since,Until")
foreach ($RepoPath in $RepoPaths) {
    if (!(Test-Path $RepoPath)) {
        Write-Host "Repo path not found: $RepoPath"
        continue
    }
    Push-Location $RepoPath
    $repoName = Split-Path -Leaf (Get-Location)
    $allBranches = git for-each-ref --format="%(refname:short)" refs/heads/
    $branches = @()
    $dateArgs = @()
    if ($Since -ne "") { $dateArgs += "--since=$Since" }
    if ($Until -ne "") { $dateArgs += "--until=$Until" }
    foreach ($branch in $allBranches) {
        $commitCount = git log $branch @dateArgs --oneline | Measure-Object -Line
        if ($commitCount.Lines -gt 0) {
            $branches += $branch
        }
    }
    foreach ($branch in $branches) {
        $authors = git log $branch @dateArgs --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique
        foreach ($author in $authors) {
            $added = 0
            $deleted = 0
            git log $branch --author="$author" @dateArgs --pretty=tformat: --numstat |
                ForEach-Object {
                    $fields = $_ -split "\s+"
                    if ($fields.Length -ge 2) {
                        $added += [int]$fields[0]
                        $deleted += [int]$fields[1]
                    }
                }
            $net = $added - $deleted
            $devLocCsv += "$repoName,`"$branch`",`"$author`",$added,$deleted,$net,$Since,$Until"
        }
    }
    Pop-Location
}
$devLocFile = "dev-branch-loc-$timestamp.csv"
$devLocCsv | Set-Content $devLocFile
Write-Host "Developer branch LOC CSV output written to $devLocFile"


# --- Branch LOC Calculation ---
$locCsv = @("Repo,Branch,LOC")
foreach ($RepoPath in $RepoPaths) {
    if (!(Test-Path $RepoPath)) {
        Write-Host "Repo path not found: $RepoPath"
        continue
    }
    Push-Location $RepoPath
    $repoName = Split-Path -Leaf (Get-Location)
    # Use the same filtered branches as above
    $allBranches = git for-each-ref --format="%(refname:short)" refs/heads/
    $branches = @()
    $dateArgs = @()
    if ($Since -ne "") { $dateArgs += "--since=$Since" }
    if ($Until -ne "") { $dateArgs += "--until=$Until" }
    foreach ($branch in $allBranches) {
        $commitCount = git log $branch @dateArgs --oneline | Measure-Object -Line
        if ($commitCount.Lines -gt 0) {
            $branches += $branch
        }
    }
    foreach ($branch in $branches) {
        git checkout $branch | Out-Null
        $loc = Get-ChildItem -Recurse -File | Where-Object { $_.FullName -notmatch '\.git\\' } | Get-Content | Measure-Object -Line
        $locCsv += "$repoName,`"$branch`",$($loc.Lines)"
    }
    Pop-Location
}
$locFile = "branch-loc-$timestamp.csv"
$locCsv | Set-Content $locFile
Write-Host "Branch LOC CSV output written to $locFile"



# --- User-Branch Contribution Map ---
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$userBranchCsv = @("Repo,Author,Branches")

foreach ($RepoPath in $RepoPaths) {
    if (!(Test-Path $RepoPath)) {
        Write-Host "Repo path not found: $RepoPath"
        continue
    }
    Push-Location $RepoPath
    $repoName = Split-Path -Leaf (Get-Location)

    $allBranches = git for-each-ref --format="%(refname:short)" refs/heads/
    $branches = @()
    foreach ($branch in $allBranches) {
        $commitCount = git log $branch @dateArgs --oneline | Measure-Object -Line
        if ($commitCount.Lines -gt 0) {
            $branches += $branch
        }
    }
    $userBranchMap = @{}

    foreach ($branch in $branches) {
        $authors = git log $branch --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique
        foreach ($author in $authors) {
            if (-not $userBranchMap.ContainsKey($author)) {
                $userBranchMap[$author] = @()
            }
            $userBranchMap[$author] += $branch
        }
    }

    foreach ($author in $userBranchMap.Keys) {
        $branchesStr = ($userBranchMap[$author] | Sort-Object | Get-Unique) -join ";"
        $userBranchCsv += "$repoName,`"$author`",`"$branchesStr`""
    }
    Pop-Location
}

$userBranchFile = "user-branch-map-$timestamp.csv"
$userBranchCsv | Set-Content $userBranchFile
Write-Host "User-branch CSV output written to $userBranchFile"


# Get timestamp for output file
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "gitlog-summary-$timestamp.csv"

# Prepare CSV header

$csv = @()
$csv += "Repo,Branch,Author,Added,Deleted,Net,Since,Until"

foreach ($RepoPath in $RepoPaths) {
    if (!(Test-Path $RepoPath)) {
        Write-Host "Repo path not found: $RepoPath"
        continue
    }
    Push-Location $RepoPath
    $repoName = Split-Path -Leaf (Get-Location)

    # Build date filter args as array
    $dateArgs = @()
    if ($Since -ne "") { $dateArgs += "--since=$Since" }
    if ($Until -ne "") { $dateArgs += "--until=$Until" }

    # Get all branches
    $branches = git for-each-ref --format="%(refname:short)" refs/heads/

    foreach ($branch in $branches) {
        # Get unique authors for this branch
        $authors = git log $branch @dateArgs --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique

        foreach ($author in $authors) {
            $added = 0
            $deleted = 0
            git log $branch --author="$author" @dateArgs --pretty=tformat: --numstat |
                ForEach-Object {
                    $fields = $_ -split "\s+"
                    if ($fields.Length -ge 2) {
                        $added += [int]$fields[0]
                        $deleted += [int]$fields[1]
                    }
                }
            $net = $added - $deleted
            $csv += "$repoName,`"$branch`",`"$author`",$added,$deleted,$net,$Since,$Until"
        }
    }
    Pop-Location
}

# Write to CSV file
$csv | Set-Content $outputFile

Write-Host "CSV output written to $outputFile"