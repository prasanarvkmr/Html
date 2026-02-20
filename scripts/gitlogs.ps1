# Set your date filters (format: yyyy-MM-dd)
$since = "2025-01-01"
$until = "2026-02-20"

$authors = git log --since="$since" --until="$until" --pretty=format:"%an <%ae>" | Sort-Object | Get-Unique
foreach ($author in $authors) {
    Write-Host $author
    $stats = git log --author="$author" --since="$since" --until="$until" --pretty=tformat: --numstat | 
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
    Write-Host "Added: $added Deleted: $deleted Net: $(($added - $deleted))"
}