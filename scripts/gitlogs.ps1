
param(
    [string[]]$RepoPaths = @("."),
    [string]$Since = "",
    [string]$Until = ""
)


# Get timestamp for output file
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "gitlog-summary-$timestamp.csv"

# Prepare CSV header
$csv = @()
$csv += "Repo,Author,Added,Deleted,Net,Since,Until"

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

    # Get unique authors
    $authors = git log @dateArgs --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique

    foreach ($author in $authors) {
        $added = 0
        $deleted = 0
        git log --author="$author" @dateArgs --pretty=tformat: --numstat |
            ForEach-Object {
                $fields = $_ -split "\s+"
                if ($fields.Length -ge 2) {
                    $added += [int]$fields[0]
                    $deleted += [int]$fields[1]
                }
            }
        $net = $added - $deleted
        $csv += "$repoName,`"$author`",$added,$deleted,$net,$Since,$Until"
    }
    Pop-Location
}

# Write to CSV file
$csv | Set-Content $outputFile

Write-Host "CSV output written to $outputFile"