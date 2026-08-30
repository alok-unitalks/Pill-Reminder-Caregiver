$filePath = "lib/main.dart"
$content = [System.IO.File]::ReadAllText($filePath)

if ($content -match 'const String appVersion = "Beta v1\.1\.2\+(\d+)";') {
    $currentBuild = [int]$Matches[1]
    $newBuild = $currentBuild + 1
    $oldLine = $Matches[0]
    $newLine = "const String appVersion = `"Beta v1.1.2+$newBuild`";"
    
    $content = $content.Replace($oldLine, $newLine)
    [System.IO.File]::WriteAllText($filePath, $content)
    
    Write-Host "Version incremented to: Beta v1.1.2+$newBuild" -ForegroundColor Green
    $versionStr = "Beta v1.1.2+$newBuild"
} else {
    Write-Host "appVersion pattern not matched." -ForegroundColor Yellow
    $versionStr = "Manual Build"
}

Write-Host "Compiling Flutter Web..." -ForegroundColor Cyan
flutter build web --release --base-href "/"

if ($LASTEXITCODE -eq 0) {
    Write-Host "Copying assets..." -ForegroundColor Cyan
    Copy-Item -Path build\web\* -Destination . -Recurse -Force
    
    Write-Host "Pushing to GitHub..." -ForegroundColor Cyan
    git add .
    git commit -m "Deploy Build: $versionStr"
    git push
    Write-Host "Build complete!" -ForegroundColor Green
}
