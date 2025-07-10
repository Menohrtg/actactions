<#
    Repo Backup Script
    Authors: John Leese & Marccelus Enoh
    Date: 03/19/2025

    Usage:
    This script should be invoked from Azure DevOps using AzurePowerShell@5
    and passing these 5 arguments:
      - OrganizationUrl
      - PersonalAccessToken
      - Project
      - StorageAccountName
      - StorageAccountKey
#>

param (
    [string]$OrganizationUrl,
    [string]$PersonalAccessToken,
    [string]$Project,
    [string]$StorageAccountName,
    [string]$StorageAccountKey
)

function Invoke-RepoBackup {
    param (
        [Parameter(Mandatory)]
        [string]$OrganizationUrl,

        [Parameter(Mandatory)]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$StorageAccountKey
    )

    $reposApiUrl = "$OrganizationUrl/$Project/_apis/git/repositories?api-version=7.1"
    $encodedPAT = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PersonalAccessToken"))
    $repositories = Invoke-RestMethod -Uri $reposApiUrl -Method Get -Headers @{ Authorization = "Basic $encodedPAT" }

    $currentDate = (Get-Date).ToString("yyyy-MM-dd")
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

    foreach ($repo in $repositories.value) {
        $repoName = $repo.name
        $encodedRepoName = [uri]::EscapeDataString($repoName)
        $repoCloneUrl = "$OrganizationUrl/$Project/_git/$encodedRepoName"
        $storageContainerName = ($repoName.ToLower() -replace "[^a-z0-9]", "")

        Write-Output "Processing Repository: $repoName"
        Write-Output "Creating storage container: $storageContainerName"

        az storage container create --name $storageContainerName --account-name $StorageAccountName --account-key $StorageAccountKey | Out-Null

        $localDirectory = Join-Path -Path $scriptPath -ChildPath $repoName
        if (Test-Path -Path $localDirectory) {
            Remove-Item -Recurse -Force $localDirectory
        }

        git -c http.extraHeader="Authorization: Basic $encodedPAT" clone $repoCloneUrl $localDirectory

        if ($LASTEXITCODE -ne 0) {
            Write-Output "  ERROR: Failed to clone repository $repoName"
            exit 1
        }

        Write-Host "  Successfully cloned $repoName into $localDirectory"

        # Optional: Trim file names ending in whitespace
        $filesWithSpaces = Get-ChildItem -Path $localDirectory -Recurse | Where-Object { $_.Name -match '\s$' }
        foreach ($file in $filesWithSpaces) {
            $newFileName = $file.Name.TrimEnd()
            $newFilePath = Join-Path -Path $file.DirectoryName -ChildPath $newFileName
            Rename-Item -Path $file.FullName -NewName $newFilePath
            Write-Output "  Renamed file '$($file.Name)' to '$newFileName'"
        }

        $parentPath = Split-Path -Path $localDirectory -Parent
        $folderName = Split-Path -Path $localDirectory -Leaf
        $archivePath = "$localDirectory`_$currentDate.tar.gz"

        tar -czf $archivePath -C $parentPath $folderName
        Write-Output "  Repository archived as $archivePath"

        az storage blob upload `
            --account-name $StorageAccountName `
            --account-key $StorageAccountKey `
            --container-name $storageContainerName `
            --file $archivePath `
            --name "$(Split-Path -Leaf $archivePath)" `
            --tier Cool | Out-Null

        Write-Output "  Successfully uploaded $archivePath to container $storageContainerName"

        Remove-Item -Recurse -Force $localDirectory
        Remove-Item -Force $archivePath
    }

    Write-Host " ❤️✅✅✅ Done backing up all repositories with full history"
}

# 🔁 Call the function with passed parameters
Invoke-RepoBackup `
    -OrganizationUrl $OrganizationUrl `
    -PersonalAccessToken $PersonalAccessToken `
    -Project $Project `
    -StorageAccountName $StorageAccountName `
    -StorageAccountKey $StorageAccountKey
