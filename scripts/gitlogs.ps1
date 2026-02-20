param(
    [string]$RepoPath = ".",
    [string]$Since = "",
    [string]$Until = ""
)

# Change to the repo directory
Set-Location $RepoPath

# Get repo name from folder
$repoName = Split-Path -Leaf (Get-Location)

# Get timestamp
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Output file name
$outputFile = "$repoName-gitlog-$timestamp.txt"


# Build date filter args as array
$dateArgs = @()
if ($Since -ne "") { $dateArgs += "--since=$Since" }
if ($Until -ne "") { $dateArgs += "--until=$Until" }

# Get unique authors
$authors = git log @dateArgs --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique

# Prepare output
$output = @()
foreach ($author in $authors) {
    $output += $author
    $stats = git log --author="$author" @dateArgs --pretty=tformat: --numstat |
        ForEach-Object {
            $fields = $_ -split "\s+"
            if ($fields.Length -ge 2) {
                [int]$fields[0], [int]$fields[1]
            }
        }
    $added = 0
    $deleted = 0
    foreach ($stat in $stats) {
        $added += $stat[0]
        $deleted += $stat[1]
    }
    $output += "Added: $added Deleted: $deleted Net: $(($added - $deleted))"
    $output += ""
}

# Write to file
$output | Set-Content $outputFile

Write-Host "Output written to $outputFile"